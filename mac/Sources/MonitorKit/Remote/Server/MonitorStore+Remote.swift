import Foundation

extension MonitorStore {
    /// iPhone からの権限確認（Channels）への答え。画面の権限カードと同じ `decide` を通す。
    public func remoteDecide(key: String, decision: PermissionDecision) async -> RemoteActionResult {
        guard let permission = permissions.first(where: { $0.key == key }) else {
            return .failure("not_found", "この確認はもう待っていません")
        }
        do {
            try await decide(permission, decision)
            return .success("decided")
        } catch {
            return .failure("gone", (error as? LocalizedError)?.errorDescription ?? "この確認はもう待っていません")
        }
    }
}
