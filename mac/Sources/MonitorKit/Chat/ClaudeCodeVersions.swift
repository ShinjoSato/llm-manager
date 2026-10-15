import Foundation

/// 画面の読み取りを本物の Claude Code で確かめた版（TUI の描き方は版で変わるので、無い版では逃げ道を案内する）。
public enum ClaudeCodeVersions {
    /// 確かめた版（`~/.claude/sessions/<pid>.json` の `version` と同じ書き方）。
    public static let verified: [String] = ["2.1.286", "2.1.288", "2.1.300"]

    /// 確かめた版か。版が分からなければ nil。
    public static func isVerified(_ version: String?) -> Bool? {
        guard let version = normalized(version) else { return nil }
        return verified.contains(version)
    }

    /// 確かめていない版のカードに出す一言（確かめた版・版が分からない時は nil）。
    public static func untestedNote(_ version: String?) -> String? {
        guard isVerified(version) == false, let version = normalized(version) else { return nil }
        return "この版の Claude Code（\(version)）は未確認です。うまく答えられない時は端末の画面から答えてください。"
    }

    static func normalized(_ version: String?) -> String? {
        guard var text = version?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("v") { text.removeFirst() }
        return text
    }
}
