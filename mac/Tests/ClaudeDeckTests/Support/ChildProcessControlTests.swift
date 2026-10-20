import XCTest
import Darwin
import SwiftTerm
@testable import MonitorKit

/// `pid` が開いている PTY の master（/dev/ptmx）のうち、`masters`（デバイス番号）に入るものの数。他のテストが残した master は数えない。
private func heldMasters(_ pid: pid_t, of masters: Set<Int32>) -> Int? {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return nil }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
    let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
    guard used > 0 else { return nil }
    var count = 0
    for info in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
        var vnode = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, info.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
        let path = withUnsafeBytes(of: vnode.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if path == "/dev/ptmx", masters.contains(Int32(bitPattern: vnode.pvip.vip_vi.vi_stat.vst_rdev)) { count += 1 }
    }
    return count
}

/// 親が持つ master のデバイス番号。
private func masterDevice(_ fd: Int32) -> Int32? {
    var st = stat()
    guard fstat(fd, &st) == 0 else { return nil }
    return st.st_rdev
}

private final class QuietDelegate: LocalProcessDelegate, @unchecked Sendable {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func dataReceived(slice: ArraySlice<UInt8>) {}
    func getWindowSize() -> winsize { winsize(ws_row: 40, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0) }
}

/// ホスト中の claude の代わり。TUI のように端末へ書き続け、SIGHUP を受けたら印を残し、後片付けに時間をかけて終わる。
private let dummyScript = """
trap 'touch "$MARK_DIR/hup.$INDEX"; sleep "$CLEANUP"; exit 129' HUP
line=$(printf '%0.s=' $(seq 1 150))
while :; do printf '%s\\r\\n' "$line"; sleep 0.05; done
"""

final class ChildProcessControlTests: XCTestCase {
    private var dir: URL!
    private var processes: [LocalProcess] = []
    private let delegate = QuietDelegate()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // このテストが起動したダミーだけを片付ける。
        for process in processes where process.shellPid > 0 {
            if let facts = ProcessFacts.inspect(pid: process.shellPid), !facts.isZombie { kill(process.shellPid, SIGKILL) }
            var status: Int32 = 0
            waitpid(process.shellPid, &status, WNOHANG)
        }
        processes = []
        try? FileManager.default.removeItem(at: dir)
    }

    /// ClaudeTerminalView の起動と同じく SwiftTerm の forkpty で起動し、`cloexec` なら直後に master へ印を付ける。
    private func launchDummies(_ count: Int, cloexec: Bool, cleanup: Double = 1) throws -> [pid_t] {
        var pids: [pid_t] = []
        for index in 0..<count {
            let process = LocalProcess(delegate: delegate)
            process.startProcess(executable: "/bin/bash", args: ["-c", dummyScript],
                                 environment: ["PATH=/usr/bin:/bin", "MARK_DIR=\(dir.path)", "INDEX=\(index)", "CLEANUP=\(cleanup)"],
                                 execName: nil, currentDirectory: nil)
            processes.append(process)
            let pid = process.shellPid
            XCTAssertGreaterThan(pid, 0)
            if cloexec { XCTAssertTrue(ChildProcessControl.setCloseOnExec(process.childfd)) }
            try waitForExec(pid)
            pids.append(pid)
        }
        return pids
    }

    /// fork の直後は親の fd を全部持っているので、exec で bash に替わるまで待つ。
    private func waitForExec(_ pid: pid_t) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if ProcessFacts.inspect(pid: pid)?.executablePath == "/bin/bash" { return }
            usleep(10_000)
        }
        XCTFail("pid \(pid) が exec しない")
    }

    func testSetCloseOnExecMarksDescriptor() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        defer { fds.forEach { close($0) } }
        XCTAssertFalse(ChildProcessControl.isCloseOnExec(fds[0]))
        XCTAssertTrue(ChildProcessControl.setCloseOnExec(fds[0]))
        XCTAssertTrue(ChildProcessControl.isCloseOnExec(fds[0]))
        XCTAssertFalse(ChildProcessControl.setCloseOnExec(-1))
    }

    /// 検査方法そのものの確認: 印を付けないと、後の子が先の子の master を持つ（直す前の不具合の再現）。
    func testLaterChildInheritsEarlierMasterWithoutCloseOnExec() throws {
        let pids = try launchDummies(2, cloexec: false)
        // master はこのテストの後も少しの間開いているので、後のテストの子に漏らさないよう印を付けておく。
        defer { processes.forEach { ChildProcessControl.setCloseOnExec($0.childfd) } }
        let masters = Set(processes.compactMap { masterDevice($0.childfd) })
        XCTAssertEqual(masters.count, 2)
        XCTAssertEqual(heldMasters(pids[0], of: masters), 0)
        XCTAssertEqual(heldMasters(pids[1], of: masters), 1)
    }

    func testLaterChildrenDoNotHoldEarlierMasters() throws {
        let pids = try launchDummies(3, cloexec: true)
        let masters = Set(processes.compactMap { masterDevice($0.childfd) })
        XCTAssertEqual(masters.count, 3)
        for (index, pid) in pids.enumerated() {
            XCTAssertEqual(heldMasters(pid, of: masters), 0, "\(index) 本目が先の子の master を持っている")
        }
        for process in processes { XCTAssertTrue(ChildProcessControl.isCloseOnExec(process.childfd)) }
    }

    /// 終了の処理で全部に同時に SIGHUP が届き、後片付けが並んで進むので 1 本分の時間で終わる。
    func testHangUpReachesAllChildrenAtOnce() throws {
        let cleanup = 1.0
        let pids = try launchDummies(3, cloexec: true, cleanup: cleanup)
        let started = Date()
        let remaining = ChildProcessControl.hangUp(pids, grace: 5)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(remaining, [])
        // 1 本ずつ届くなら 3 本分（3 秒）かかる。
        XCTAssertLessThan(elapsed, cleanup * 2, "SIGHUP が同時に届いていない（\(elapsed) 秒）")
        for index in pids.indices {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("hup.\(index)").path),
                          "\(index) 本目に SIGHUP が届いていない")
        }
    }

    /// 後片付けが上限を超えても待ち切らずに返し、残りを知らせる（終了を長く引き止めない）。
    func testHangUpStopsWaitingAtGrace() throws {
        let pids = try launchDummies(1, cloexec: true, cleanup: 10)
        let started = Date()
        let remaining = ChildProcessControl.hangUp(pids, grace: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(remaining, pids)
    }

    /// 前回ホストしていた claude が終わる途中は待ち、終わったら再開に進む（記録の pid と起動時刻で見分ける）。
    func testRestoreWaitsForPreviousDummyAndResumesAfterItExits() throws {
        let pid = try XCTUnwrap(try launchDummies(1, cloexec: true, cleanup: 0.5).first)
        let facts = try XCTUnwrap(ProcessFacts.inspect(pid: pid))
        let sessionId = "acb12868-4061-4d7e-987c-0522878e518d"
        let record = HostedSessionRecord(name: "p", cwd: "/p", sessionId: sessionId, status: .working, pid: pid,
                                         procStart: facts.startedAt.timeIntervalSince1970)
        let previous: (HostedSessionRecord) -> Int32? = { record in
            guard let pid = record.pid,
                  SessionRestore.isPreviousProcess(record, facts: ProcessFacts.inspect(pid: pid), ownUid: getuid()) else { return nil }
            return pid
        }
        func decide() -> SessionRestore.Decision? {
            SessionRestore.plan(records: [record], limitReached: false, askToContinue: true, hostedSessionIds: [],
                                directoryExists: { _ in true }, liveDuplicate: { _ in nil }, previousProcess: previous).first?.decision
        }
        XCTAssertEqual(decide(), .awaitingExit(pid))
        let wait = PreviousExitWait(startedAt: Date())
        XCTAssertEqual(wait.step(alive: previous(record) != nil, now: Date()), .wait)

        XCTAssertEqual(ChildProcessControl.hangUp([pid], grace: 5), [])
        XCTAssertEqual(wait.step(alive: previous(record) != nil, now: Date()), .exited)
        XCTAssertEqual(decide(), .launch(nudge: true))
    }
}
