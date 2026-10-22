import CryptoKit
import Foundation

/// 実行コマンドの判定（見出しのボタンに出すもの・ホバーの中身・検証の上限・送ってはいけない本文・承認の鍵）。
public enum ProjectCommands {
    /// 名前の文字数の上限。
    public static let nameLimit = 40
    /// 本文の文字数の上限。
    public static let commandLimit = 4000
    /// アイコンが無い時の SF Symbol。
    public static let defaultSymbol = "play"
    /// ホバーに出す本文の行数の上限。
    public static let helpLineLimit = 6

    /// 設定画面で選べるアイコン。
    public static let symbolChoices = [
        "play", "terminal", "hammer", "testtube.2", "shippingbox", "arrow.clockwise", "server.rack",
        "globe", "wrench.and.screwdriver", "doc.text", "trash", "bolt",
    ]

    /// 見出しに出せるもの（名前と本文が正しく、同じ名前は先のものだけ）。並びは設定の順。
    public static func runnable(_ commands: [ProjectCommand]) -> [ProjectCommand] {
        var seen = Set<String>()
        return commands.filter { command in
            SettingsValidation.projectCommandProblems(command).isEmpty
                && seen.insert(command.name.trimmingCharacters(in: .whitespaces)).inserted
        }
    }

    /// ホバーに出す本文（長いものは先頭の数行と残りの行数）。
    public static func help(for command: ProjectCommand) -> String {
        let lines = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > helpLineLimit else { return lines.joined(separator: "\n") }
        return (lines.prefix(helpLineLimit) + ["…（ほか \(lines.count - helpLineLimit) 行）"]).joined(separator: "\n")
    }

    /// 使うアイコン（無い・空なら既定）。
    public static func symbol(for command: ProjectCommand) -> String {
        guard let icon = command.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty else { return defaultSymbol }
        return icon
    }

    // MARK: - 送ってはいけない本文

    /// claude の headless 起動（`-p` / `--print`）を含むか。API 課金の経路になりうるので、パス付き・`command` / `exec` / `npx` 経由も含めて広めに拾う。
    public static func launchesHeadlessClaude(_ text: String) -> Bool {
        simpleCommands(text).contains { words in
            guard let index = words.firstIndex(where: isClaudeWord) else { return false }
            return words[(index + 1)...].contains(where: isPrintFlag)
        }
    }

    /// 区切り（; & | ( ) { } ` $( 改行）で単純なコマンドに分け、空白で語に分ける（引用符とバックスラッシュは落とす）。
    static func simpleCommands(_ text: String) -> [[String]] {
        let separators: Set<Character> = [";", "&", "|", "(", ")", "{", "}", "`", "\n", "\r"]
        var unified = ""
        for character in text { unified.append(separators.contains(character) ? "\n" : character) }
        return unified.split(separator: "\n").map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { $0.filter { !"'\"\\$".contains($0) } }
                .filter { !$0.isEmpty }
        }
    }

    static func isClaudeWord(_ word: String) -> Bool {
        let base = word.split(separator: "/").last.map(String.init) ?? word
        return base == "claude" || word.hasPrefix("@anthropic-ai/claude-code")
    }

    static func isPrintFlag(_ word: String) -> Bool {
        if word == "--print" || word.hasPrefix("--print=") { return true }
        // 短い形はまとめ書き（-cp 等）も拾う。
        guard word.hasPrefix("-"), !word.hasPrefix("--") else { return false }
        let letters = word.dropFirst()
        return !letters.isEmpty && letters.allSatisfy(\.isLetter) && letters.contains("p")
    }

    /// 見た目と中身を違えられる文字（方向制御・ゼロ幅）を含むか。
    public static func containsHiddenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200F, 0x2060...0x2064, 0xFEFF, 0x180E, 0x061C: return true
            default: return false
            }
        }
    }

    // MARK: - 承認

    /// 確かめた本文の鍵（本文だけの SHA-256。設定ファイルの外に覚える）。
    public static func approvalKey(_ command: ProjectCommand) -> String {
        SHA256.hash(data: Data(command.command.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
