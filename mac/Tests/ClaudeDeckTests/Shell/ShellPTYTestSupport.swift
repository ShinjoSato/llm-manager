import Foundation
import SwiftTerm
import XCTest
@testable import MonitorKit

/// PTY の出力をためる（SwiftTerm の LocalProcess を専用のキューで動かす）。
final class PTYRecorder: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var exited = false

    var text: String { lock.withLock { String(decoding: buffer, as: UTF8.self) } }
    var hasExited: Bool { lock.withLock { exited } }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { lock.withLock { exited = true } }
    func dataReceived(slice: ArraySlice<UInt8>) { lock.withLock { buffer.append(contentsOf: slice) } }
    func getWindowSize() -> winsize { winsize(ws_row: 40, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0) }
}

/// テスト用のダミーのシェルを PTY で起動する（アプリのシェルと同じ forkpty の経路）。
final class DummyPTY {
    let recorder = PTYRecorder()
    let process: LocalProcess
    private let queue = DispatchQueue(label: "test.pty")

    init(executable: String, args: [String], environment: [String], directory: String? = nil) {
        process = LocalProcess(delegate: recorder, dispatchQueue: queue)
        ChildProcessControl.withSpawnLock {
            process.startProcess(executable: executable, args: args, environment: environment, execName: nil, currentDirectory: directory)
            ChildProcessControl.setCloseOnExec(process.childfd)
        }
    }

    var pid: pid_t { process.shellPid }
    var master: Int32 { process.childfd }

    func type(_ text: String) {
        process.send(data: ArraySlice(Array(text.utf8)))
    }

    /// 後片付け（試験で止め切れなかった時だけ。自分で起動したものにだけ送る）。
    func kill() {
        if process.running { process.terminate() }
    }
}

/// 終わっていない（ゾンビでない）プロセスか。
func isAlive(_ pid: pid_t) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
    return info.kp_proc.p_stat != SZOMB
}

/// 環境の写し（テストの外の値を持ち込まない最小限）。
func minimalEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
    var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
    env.merge(extra) { _, new in new }
    return env
}

/// セッションの中のプロセス（一覧を取れなければ失敗にする）。
func sessionMembers(_ leader: pid_t, file: StaticString = #filePath, line: UInt = #line) -> [ShellSessionStop.Member] {
    guard let members = ShellSessionStop.sessionProcesses(leader: leader) else {
        XCTFail("プロセスの一覧を取れません", file: file, line: line)
        return []
    }
    return members
}
