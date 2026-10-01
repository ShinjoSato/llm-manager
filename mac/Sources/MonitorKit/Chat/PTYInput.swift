import Foundation

/// アプリがホストする Claude Code（TUI）へ PTY で送るキー列。値は実機の TUI（v2.1.251）で確認済み。
public enum PTYInput {
    /// 権限プロンプトの「1. Yes」。数字キーで即決定される。
    public static let allowKey = "1"
    /// 権限プロンプトの「Esc to cancel」。選択肢の数（No の番号）が場合で変わるので Esc で拒否する。
    public static let denyKey = "\u{1b}"
    /// 送信（入力欄で Enter）。
    public static let submitKey = "\r"
    /// 貼り付けと Enter を同時に送ると Enter が貼り付けに飲まれるので、少し空ける。
    public static let submitDelay: TimeInterval = 0.3

    /// 入力欄に入れる本文。bracketed paste なら改行を含めたまま 1 回の貼り付けとして届く（Enter で送信されない）。
    /// 返り値が nil なら送るものが無い。
    public static func messageBody(_ text: String, bracketedPaste: Bool) -> String? {
        // 貼り付けの終端（ESC[201~）を本文から作らせないため ESC は落とす。
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{1b}", with: "")
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if bracketedPaste {
            return "\u{1b}[200~" + body + "\u{1b}[201~"
        }
        // 貼り付けモードでない端末では改行が送信になるので、1 行に畳む。
        return body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }
}

/// 端末画面に出ている権限プロンプト。
public struct PermissionPrompt: Sendable, Equatable {
    /// 「Bash command」「Edit file」等の見出し。
    public var title: String
    /// コマンド・説明などの本文行。
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }

    /// 画面の行（上から順）から権限プロンプトを読み取る。出ていなければ nil。
    /// 区切り線（─）から「Do you want to …?」の手前までを本文とし、選択肢（1. Yes …）が続くことを確かめる。
    public static func parse(screen: [String]) -> PermissionPrompt? {
        guard let questionIndex = screen.lastIndex(where: { isQuestion($0) }) else { return nil }
        let after = screen[(questionIndex + 1)...].prefix(6)
        guard after.contains(where: { $0.trimmingCharacters(in: .whitespaces).range(of: #"^(❯\s*)?1\.\s*Yes"#, options: .regularExpression) != nil }) else {
            return nil
        }
        var start = questionIndex
        while start > 0, questionIndex - start < 20 {
            let line = screen[start - 1]
            if isSeparator(line) { break }
            start -= 1
        }
        let body = screen[start..<questionIndex]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Tip:") && !isRule($0, of: "╌") }
        guard let title = body.first else { return PermissionPrompt(title: "権限の確認", lines: []) }
        return PermissionPrompt(title: title, lines: Array(body.dropFirst()))
    }

    static func isQuestion(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("do you want to") && t.hasSuffix("?")
    }

    /// プロンプトの外枠（実線）。コマンドを囲む破線（╌）は枠の内側なので境界にしない。
    static func isSeparator(_ line: String) -> Bool {
        isRule(line, of: "─") || isRule(line, of: "━")
    }

    static func isRule(_ line: String, of character: Character) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 8 && t.allSatisfy { $0 == character }
    }
}
