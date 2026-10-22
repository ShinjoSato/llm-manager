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
        try await waitUntil { Set(ShellSessionStop.sessionProcesses(leader: pid).map(\.group)).count >= 3 }
        let members = ShellSessionStop.sessionProcesses(leader: pid)
        XCTAssertTrue(members.contains { $0.pid == pid })

        let stop = ShellSessionStop(leader: pid, master: master)
        pty.process.terminate()
        await stop.finish()
        XCTAssertTrue(ShellSessionStop.sessionProcesses(leader: pid).isEmpty, "\(ShellSessionStop.sessionProcesses(leader: pid))")
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
        try await waitUntil { ptys.allSatisfy { Set(ShellSessionStop.sessionProcesses(leader: $0.pid).map(\.group)).count >= 2 } }
        let stops = ptys.map { ShellSessionStop(leader: $0.pid, master: $0.master) }
        ptys.forEach { $0.process.terminate() }
        ShellSessionStop.finishAllBlocking(stops)
        for pty in ptys { XCTAssertTrue(ShellSessionStop.sessionProcesses(leader: pty.pid).isEmpty) }
    }

    func testLeaderOutsideOurSessionsIsLeftAlone() {
        XCTAssertTrue(ShellSessionStop.sessionProcesses(leader: 1).isEmpty)
        XCTAssertTrue(ShellSessionStop.sessionProcesses(leader: getpid()).isEmpty)
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
