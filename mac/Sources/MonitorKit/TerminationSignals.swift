import Foundation

/// SIGTERM / SIGINT の既定動作（即終了）だけを外す。
public enum TerminationSignals {
    /// SIG_IGN は exec を越えて子（端末ペインの claude 等）に残るが、登録したハンドラは exec で既定に戻るので漏れない。
    public static func installNoopHandlers(for signals: [Int32] = [SIGTERM, SIGINT]) {
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
