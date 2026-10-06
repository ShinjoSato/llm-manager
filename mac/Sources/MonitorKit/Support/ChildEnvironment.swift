import Foundation

/// アプリから起動する子プロセス（claude・開発サーバー）に渡す環境。
public enum ChildEnvironment {
    /// 課金経路になる API キーと、Claude Code の中から起動された時の子セッション印（transcript 保存オフ・SDK 扱い等）を外す。
    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in !isRemoved(key) }
    }

    static func isRemoved(_ key: String) -> Bool {
        ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT"].contains(key)
            || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
    }

    /// ログインシェルの設定が API キーを戻しても効かないよう、シェルの中でも外してから exec する。
    public static let unsetCommand = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN"
}
