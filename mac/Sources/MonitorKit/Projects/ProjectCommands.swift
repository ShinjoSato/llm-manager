import Foundation

/// 実行コマンドの判定（見出しのボタンに出すもの・ホバーの中身・検証の上限）。
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
}
