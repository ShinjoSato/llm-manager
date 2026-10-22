import XCTest
@testable import MonitorKit

final class ShellInputTests: XCTestCase {
    func testBracketedBodyKeepsLinesAndDropsControls() {
        let body = ShellInput.body("\n  npm run build\r\nnpm test\u{1b}[A\u{3}\n\n", bracketedPaste: true)
        XCTAssertEqual(body, "\u{1b}[200~npm run build\nnpm test[A\u{1b}[201~")
    }

    func testPlainBodyTypesEachLine() {
        XCTAssertEqual(ShellInput.body("cd web\n\tnpm test", bracketedPaste: false), "cd web\r npm test")
        XCTAssertNil(ShellInput.body(" \n\u{7}\n", bracketedPaste: false))
    }

    func testReadyWaitsForPasteModeOrQuietOutput() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ShellInput.isReady(bracketedPaste: true, startedAt: start, lastOutputAt: nil, now: start))
        XCTAssertFalse(ShellInput.isReady(bracketedPaste: false, startedAt: start, lastOutputAt: nil, now: start + 1))
        XCTAssertFalse(ShellInput.isReady(bracketedPaste: false, startedAt: start, lastOutputAt: start + 1, now: start + 1.2))
        XCTAssertTrue(ShellInput.isReady(bracketedPaste: false, startedAt: start, lastOutputAt: start + 1, now: start + 1.6))
        XCTAssertTrue(ShellInput.isReady(bracketedPaste: false, startedAt: start, lastOutputAt: nil, now: start + ShellInput.readyTimeout))
    }
}

final class ShellForegroundTests: XCTestCase {
    func testStateComparesForegroundGroupWithShell() {
        XCTAssertEqual(ShellForeground.state(foregroundGroup: 100, shellGroup: 100), .prompt)
        XCTAssertEqual(ShellForeground.state(foregroundGroup: 120, shellGroup: 100), .busy)
        XCTAssertEqual(ShellForeground.state(foregroundGroup: -1, shellGroup: 100), .unknown)
        XCTAssertEqual(ShellForeground.state(foregroundGroup: 100, shellGroup: 0), .unknown)
        XCTAssertFalse(ShellForeground.prompt.needsConfirmation)
        XCTAssertTrue(ShellForeground.busy.needsConfirmation)
        XCTAssertTrue(ShellForeground.unknown.needsConfirmation)
        XCTAssertEqual(ShellForeground.current(master: -1, shellPid: 100), .unknown)
    }

    /// ダミーの対話 zsh（設定なし）で、プロンプト → コマンドの実行中 → Ctrl-C で戻る、を PTY の前面のグループで見分ける。
    func testDetectsRunningCommandOnRealPTY() async throws {
        let pty = DummyPTY(executable: "/bin/zsh", args: ["-f", "-i"], environment: ShellLaunch.make(base: minimalEnvironment(), wrapperDirectory: nil).environmentList)
        defer { pty.kill() }
        let master = pty.master, pid = pty.pid
        try await waitUntil { ShellForeground.current(master: master, shellPid: pid) == .prompt }
        pty.type("sleep 30\r")
        try await waitUntil { ShellForeground.current(master: master, shellPid: pid) == .busy }
        pty.type("\u{3}")
        try await waitUntil { ShellForeground.current(master: master, shellPid: pid) == .prompt }
        let stop = ShellSessionStop(leader: pid, master: master)
        pty.process.terminate()
        await stop.finish()
    }
}

final class ShellSessionStopTests: XCTestCase {
    func testPlanHangsUpThenTerminatesThenKills() {
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ShellStopPlan.next(alive: false, hangupAt: nil, terminateAt: nil, killAt: nil, now: t), .finished)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: nil, terminateAt: nil, killAt: nil, now: t), .hangup)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: t, terminateAt: nil, killAt: nil, now: t + 0.5), .wait)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: t, terminateAt: nil, killAt: nil, now: t + 1), .terminate)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: t, terminateAt: t + 1, killAt: nil, now: t + 2), .wait)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: t, terminateAt: t + 1, killAt: nil, now: t + 2.5), .kill)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: t, terminateAt: t + 1, killAt: t + 2.5, now: t + 3), .wait)
        XCTAssertEqual(ShellStopPlan.next(alive: true, hangupAt: t, terminateAt: t + 1, killAt: t + 2.5, now: t + 3.5), .finished)
    }

    /// ルームを閉じた時と同じ手順で、シェル・ジョブ（別グループ）・HUP と TERM を無視して切り離したジョブまで止まり、外のプロセスは残る。
    func testStopsWholeSessionIncludingJobsButNothingElse() async throws {
        let outsider = try spawnSleep()
        defer { reapOutsider(outsider) }
        let pty = DummyPTY(executable: "/bin/zsh", args: ["-f", "-i"], environment: ShellLaunch.make(base: minimalEnvironment(), wrapperDirectory: nil).environmentList)
        defer { pty.kill() }
        let master = pty.master, pid = pty.pid
        try await waitUntil { ShellForeground.current(master: master, shellPid: pid) == .prompt }
        pty.type("sleep 301 &\r")
        pty.type("/bin/sh -c 'trap \"\" HUP TERM; exec sleep 302' &!\r")
        try await waitUntil { Set(sessionMembers(pid).map(\.group)).count >= 3 }
        let members = sessionMembers(pid)
        XCTAssertTrue(members.contains { $0.pid == pid })

        let stop = ShellSessionStop(leader: pid, master: master)
        pty.process.terminate()
        await stop.finish()
        XCTAssertTrue(sessionMembers(pid).isEmpty, "\(sessionMembers(pid))")
        for member in members { XCTAssertFalse(isAlive(member.pid), "\(member.pid) が残っている") }
        XCTAssertTrue(isAlive(outsider), "セッションの外のプロセスまで止めた")
    }

    /// アプリの終了時と同じく、複数のシェルをまとめて止め切る。
    func testFinishAllBlockingStopsEveryShell() async throws {
        let env = ShellLaunch.make(base: minimalEnvironment(), wrapperDirectory: nil).environmentList
        let ptys = [DummyPTY(executable: "/bin/zsh", args: ["-f", "-i"], environment: env),
                    DummyPTY(executable: "/bin/zsh", args: ["-f", "-i"], environment: env)]
        defer { ptys.forEach { $0.kill() } }
        for pty in ptys {
            let master = pty.master, pid = pty.pid
            try await waitUntil { ShellForeground.current(master: master, shellPid: pid) == .prompt }
            pty.type("sleep 303 &\r")
        }
        try await waitUntil { ptys.allSatisfy { Set(sessionMembers($0.pid).map(\.group)).count >= 2 } }
        let stops = ptys.map { ShellSessionStop(leader: $0.pid, master: $0.master) }
        ptys.forEach { $0.process.terminate() }
        ShellSessionStop.finishAllBlocking(stops)
        for pty in ptys { XCTAssertTrue(sessionMembers(pty.pid).isEmpty) }
    }

    /// シェルが自分で終わると端末の紐づけが外れるので、動いている間に記録したグループから残ったジョブを探して止める。
    func testStopsJobsLeftAfterShellExitedUsingRecordedGroups() async throws {
        let pty = DummyPTY(executable: "/bin/zsh", args: ["-f", "-i"], environment: ShellLaunch.make(base: minimalEnvironment(), wrapperDirectory: nil).environmentList)
        defer { pty.kill() }
        let master = pty.master, pid = pty.pid
        try await waitUntil { ShellForeground.current(master: master, shellPid: pid) == .prompt }
        pty.type("/bin/sh -c 'trap \"\" HUP; exec sleep 305' &!\r")
        try await waitUntil { (ShellSessionStop.currentGroups(leader: pid, master: master)?.count ?? 0) >= 2 }
        let recorded = try XCTUnwrap(ShellSessionStop.currentGroups(leader: pid, master: master))
        let job = try XCTUnwrap(sessionMembers(pid).first { $0.pid != pid })
        pty.type("exit\r")
        try await waitUntil { pty.recorder.hasExited && !isAlive(pid) }
        XCTAssertTrue(isAlive(job.pid), "HUP を無視するジョブが残っていない（試験の前提が崩れている）")

        let stop = ShellSessionStop(leader: pid, master: master, knownGroups: recorded)
        await stop.finish()
        XCTAssertFalse(isAlive(job.pid), "残ったジョブが止まっていない")
    }

    func testLeaderOutsideOurSessionsIsLeftAlone() {
        XCTAssertTrue(sessionMembers(1).isEmpty)
        XCTAssertTrue(sessionMembers(getpid()).isEmpty)
        XCTAssertFalse(ShellSessionStop.isOwnChild(getsid(0)))
    }

    private func spawnSleep() throws -> pid_t {
        let argv: [String] = ["/bin/sleep", "60"]
        var args = argv.map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/sleep", nil, nil, &args, environ)
        guard rc == 0 else { throw PosixSpawnError.failed(rc) }
        return pid
    }

    private func reapOutsider(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

final class ShellSendRulesTests: XCTestCase {
    func testPendingLineInputFollowsKeys() {
        XCTAssertTrue(ShellLineInput.pending(after: Array("ls".utf8), previous: false))
        XCTAssertFalse(ShellLineInput.pending(after: [0x0D], previous: true))
        XCTAssertFalse(ShellLineInput.pending(after: [0x03], previous: true))
        XCTAssertTrue(ShellLineInput.pending(after: [0x1B, 0x5B, 0x41], previous: false), "履歴を呼び出した")
        XCTAssertTrue(ShellLineInput.pending(after: [0x04], previous: true))
        XCTAssertFalse(ShellLineInput.pending(after: [0x04], previous: false))
        XCTAssertFalse(ShellLineInput.pending(after: [0x1B, 0x5B, 0x49], previous: false), "フォーカスの知らせ")
        XCTAssertFalse(ShellLineInput.pending(after: Array("\u{1b}[200~npm test\u{1b}[201~\r".utf8), previous: true))
    }

    func testExitStatusMessage() {
        XCTAssertEqual(ShellExitStatus.message(rawStatus: 0), "シェルは終了しました（終了コード 0）")
        XCTAssertEqual(ShellExitStatus.message(rawStatus: 3 << 8), "シェルは終了しました（終了コード 3）")
        XCTAssertEqual(ShellExitStatus.message(rawStatus: SIGKILL), "シェルは終了しました（シグナル 9 で終了）")
        XCTAssertEqual(ShellExitStatus.message(rawStatus: nil), "シェルは終了しました")
    }

    func testSendReasons() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ShellSendCheck.reasons(approved: true, running: true, foreground: .prompt, pendingInput: false,
                                              queued: false, lastSentAt: nil, now: now), [])
        XCTAssertEqual(ShellSendCheck.reasons(approved: false, running: false, foreground: .unknown, pendingInput: true,
                                              queued: true, lastSentAt: now, now: now), [.notApproved])
        XCTAssertEqual(ShellSendCheck.reasons(approved: true, running: true, foreground: .busy, pendingInput: true,
                                              queued: false, lastSentAt: now - 1, now: now), [.busy, .pendingInput, .queued])
        XCTAssertEqual(ShellSendCheck.reasons(approved: true, running: true, foreground: .prompt, pendingInput: false,
                                              queued: true, lastSentAt: nil, now: now), [.queued])
        XCTAssertEqual(ShellSendCheck.reasons(approved: true, running: true, foreground: .prompt, pendingInput: false,
                                              queued: false, lastSentAt: now - ShellSendCheck.repeatWindow, now: now), [])
        XCTAssertTrue(ShellSendCheck.stillSafe(foreground: .prompt, pendingInput: false))
        XCTAssertFalse(ShellSendCheck.stillSafe(foreground: .prompt, pendingInput: true))
        XCTAssertFalse(ShellSendCheck.stillSafe(foreground: .busy, pendingInput: false))
    }
}
