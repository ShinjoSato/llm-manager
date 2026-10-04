import Foundation

extension MonitorStore {
    /// iPhone からの権限確認（Channels）への答え。画面の権限カードと同じ `decide` を通す。
    public func remoteDecide(key: String, decision: PermissionDecision) async -> RemoteActionResult {
        guard let permission = permissions.first(where: { $0.key == key }) else { return Self.permissionGone }
        do {
            try await decide(permission, decision)
            return .success("decided")
        } catch {
            return Self.remoteDecideFailure(error)
        }
    }

    nonisolated static let permissionGone = RemoteActionResult.failure("gone", "この確認はもう待っていません")

    /// 「もう待っていない」だけを `gone` にし、届けられなかったものは `failed` で分ける（答えたかどうかが違うため）。
    nonisolated static func remoteDecideFailure(_ error: Error) -> RemoteActionResult {
        if let failure = error as? HubFailure, failure.code == "not_found" { return permissionGone }
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return .failure("failed", "答えを届けられませんでした: \(reason)")
    }
}
