import Foundation

/// SIGTERM / SIGINT / SIGHUP の既定動作（即終了）だけを外す。
public enum TerminationSignals {
    /// 通常の終了経路に乗せるシグナル。
    public static let handled: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// SIG_IGN は exec を越えて子（PTY でホストする claude 等）に残るが、登録したハンドラは exec で既定に戻るので漏れない。
    public static func installNoopHandlers(for signals: [Int32] = handled) {
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = noopSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = SA_RESTART
            sigaction(sig, &action, nil)
        }
    }
}

private func noopSignalHandler(_: Int32) {}

public enum PosixSpawnError: Error, CustomStringConvertible {
    case failed(Int32)
    public var description: String { "posix_spawn: \(String(cString: strerror(errnoValue)))" }
    private var errnoValue: Int32 { if case .failed(let e) = self { return e }; return 0 }
}
