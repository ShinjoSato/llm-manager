import Foundation

/// ルーム一覧の 1 行から、iCloud に知らせる要対応を作る（会話の本文・一覧の一行・タイトルは使わない）。
public enum AttentionNoticeSource {
    /// - Parameters:
    ///   - ended: ホスト中のセッションが終わっている（終わったルームは待っていない）。
    ///   - permissionToolNames: Channels で届いている権限確認のツール名。
    public static func candidate(roomId: String, sessionId: String?, name: String, status: SessionStatus, ended: Bool,
                                 statusDetail: String?, permissionToolNames: [String]) -> AttentionCandidate? {
        guard !ended, let kind = AttentionKind(status: status) else { return nil }
        let tool = kind == .permission
            ? (permissionToolNames.lazy.compactMap { AttentionNoticeText.toolName($0) }.first
                ?? AttentionNoticeText.toolName(fromDetail: statusDetail))
            : nil
        return AttentionCandidate(roomId: roomId, sessionId: sessionId, roomName: name, kind: kind, toolName: tool)
    }
}
