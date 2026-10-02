import XCTest
import SwiftTerm
@testable import MonitorKit

/// 子プロセスのシグナル処理（無視・捕捉のビット集合。ビット n-1 がシグナル n）。macOS の ps には sigignore が無いので sysctl で読む。
private func signalDispositions(_ pid: pid_t) -> (ignored: UInt32, caught: UInt32)? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return (info.kp_proc.p_sigignore, info.kp_proc.p_sigcatch)
}

/// 終了済み（ゾンビを含む）なら false。
private func isRunning(_ pid: pid_t) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
    return info.kp_proc.p_stat != SZOMB
}

private func bit(_ sig: Int32) -> UInt32 { 1 << UInt32(sig - 1) }

/// forkpty と同じく、シグナル設定を既定に戻さずに exec する。
private func spawnInheriting(_ args: [String]) throws -> pid_t {
    var cArgs = args.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, args[0], nil, nil, &cArgs, environ)
    guard rc == 0 else { throw PosixSpawnError.failed(rc) }
    return pid
}

private func reap(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

private final class NullTerminalDelegate: LocalProcessDelegate, @unchecked Sendable {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func dataReceived(slice: ArraySlice<UInt8>) {}
    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
}

final class TerminationSignalsTests: XCTestCase {
    private let signals: [Int32] = [SIGTERM, SIGINT]
    private var saved: [Int32: sigaction] = [:]

    override func setUp() {
        super.setUp()
        for sig in signals {
            var old = sigaction()
            sigaction(sig, nil, &old)
            saved[sig] = old
        }
    }

    override func tearDown() {
        for (sig, old) in saved {
            var action = old
            sigaction(sig, &action, nil)
        }
        super.tearDown()
    }

    /// 検査方法そのものの確認: SIG_IGN なら exec 後の子にも無視が残る（以前の不具合の再現）。
    func testIgnoredSignalsLeakIntoExecdChild() throws {
        for sig in signals { signal(sig, SIG_IGN) }
        let pid = try spawnInheriting(["/bin/sleep", "30"])
        defer { reap(pid) }
        let child = try XCTUnwrap(signalDispositions(pid))
        XCTAssertNotEqual(child.ignored & bit(SIGTERM), 0)
        XCTAssertNotEqual(child.ignored & bit(SIGINT), 0)
    }

    /// 何もしないハンドラなら、親は捕捉しつつ exec 後の子は既定（終了）に戻る。
    func testNoopHandlersDoNotLeakIntoExecdChild() throws {
        TerminationSignals.installNoopHandlers(for: signals)
        let me = try XCTUnwrap(signalDispositions(getpid()))
        XCTAssertNotEqual(me.caught & bit(SIGTERM), 0)
        XCTAssertEqual(me.ignored & bit(SIGTERM), 0)

        let pid = try spawnInheriting(["/bin/sleep", "30"])
        defer { reap(pid) }
        let child = try XCTUnwrap(signalDispositions(pid))
        for sig in signals {
            XCTAssertEqual(child.ignored & bit(sig), 0, "子が \(sig) を無視している")
            XCTAssertEqual(child.caught & bit(sig), 0)
        }
    }

    /// 端末ペインと同じ SwiftTerm の起動経路で、terminate()（SIGTERM）で子が終わる。
    func testSwiftTermChildStillDiesOnTerminate() throws {
        TerminationSignals.installNoopHandlers(for: signals)
        let delegate = NullTerminalDelegate()
        let process = LocalProcess(delegate: delegate)
        process.startProcess(executable: "/bin/sleep", args: ["30"], environment: nil, execName: nil, currentDirectory: nil)
        let pid = process.shellPid
        XCTAssertGreaterThan(pid, 0)
        defer { if isRunning(pid) { kill(pid, SIGKILL) } }

        // fork 直後は親の捕捉を引き継いでいるので、exec で外れるまで待つ。
        let execDeadline = Date().addingTimeInterval(5)
        while Date() < execDeadline, (signalDispositions(pid)?.caught ?? 0) & bit(SIGTERM) != 0 {
            usleep(10_000)
        }
        let child = try XCTUnwrap(signalDispositions(pid))
        XCTAssertEqual(child.caught & bit(SIGTERM), 0, "exec が終わっていない")
        XCTAssertEqual(child.ignored & (bit(SIGTERM) | bit(SIGINT)), 0, "端末の子が SIGTERM / SIGINT を無視している")

        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while isRunning(pid) && Date() < deadline { usleep(20_000) }
        XCTAssertFalse(isRunning(pid), "terminate() で子が終わらない")
    }
}
