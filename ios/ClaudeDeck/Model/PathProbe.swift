import DeckCore
import Foundation
import Network

/// 接続先へ TCP を短く張り、経路が無い理由（ローカルネットワークの許可・経路なし）を確かめる。
enum PathProbe {
    static func check(host: String, port: Int, timeout: TimeInterval = 2) async -> RemoteIssue.PathReason {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .inconclusive }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "claude-deck.path-probe")
        let once = Once()
        return await withCheckedContinuation { continuation in
            let finish: @Sendable (RemoteIssue.PathReason) -> Void = { reason in
                guard once.claim() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: reason)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.inconclusive)
                case .waiting, .failed:
                    // 経路が満たされない理由が分かる時だけ言い切る（それ以外は時間切れまで待つ）。
                    let reason = Self.reason(connection.currentPath)
                    if reason != .inconclusive { finish(reason) } else if case .failed = state { finish(.inconclusive) }
                case .cancelled:
                    finish(.inconclusive)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(Self.reason(connection.currentPath)) }
        }
    }

    static func reason(_ path: NWPath?) -> RemoteIssue.PathReason {
        guard let path, path.status == .unsatisfied else { return .inconclusive }
        switch path.unsatisfiedReason {
        case .localNetworkDenied: return .localNetworkDenied
        case .notAvailable: return .notAvailable
        default: return .inconclusive
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
