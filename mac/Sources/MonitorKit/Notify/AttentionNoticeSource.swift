import Foundation

/// ルーム一覧の 1 行から、iCloud に知らせる要対応を作る（会話の本文・一覧の一行・タイトルは使わない）。
public enum AttentionNoticeSource {
    /// - Parameters:
    ///   - ended: ホスト中のセッションが終わっている（終わったルームは待っていない）。
    ///   - hookToolName: 権限待ちのフックの tool_name。
    ///   - statusDetail: 状態の補足。権限待ちの通知文の形の時だけツール名を読む。
    ///   - permissionToolNames: Channels で届いている権限確認のツール名。
    public static func candidate(roomId: String, sessionId: String?, name: String, status: SessionStatus, ended: Bool,
                                 hookToolName: String?, statusDetail: String?, permissionToolNames: [String]) -> AttentionCandidate? {
        guard !ended, let kind = AttentionKind(status: status) else { return nil }
        let tool = kind == .permission
            ? (permissionToolNames.lazy.compactMap { AttentionNoticeText.toolName($0) }.first
                ?? AttentionNoticeText.toolName(hookToolName)
                ?? AttentionNoticeText.toolName(fromDetail: statusDetail))
            : nil
        return AttentionCandidate(roomId: roomId, sessionId: sessionId, roomName: name, kind: kind, toolName: tool)
    }

    /// 通知に載せるルーム名。ホスト中のルームは登録したプロジェクト名、外部セッションはフォルダ名だけ。
    /// セッション名（`~/.claude/sessions/<pid>.json` の name）は会話から付くことがあるので使わない。
    public static func roomName(hostedProjectName: String?, project: String?, cwd: String) -> String {
        if let hostedProjectName, !hostedProjectName.isEmpty { return hostedProjectName }
        if let project, !project.isEmpty { return project }
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        return folder == "/" ? "" : folder
    }
}
