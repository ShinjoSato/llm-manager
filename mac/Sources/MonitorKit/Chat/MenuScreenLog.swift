import Foundation

/// 選択肢カードを出した時・読めなかった時の端末画面の写しを、直近数件だけ手元に残す（TUI の描画が変わった時の調べ用）。
/// 会話の本文が入りうるので、ファイルは本人だけが読める 0600 で置き、外へは送らない。
public enum MenuScreenLog {
    public enum Kind: String, Sendable {
        /// 選択肢として読めた。
        case menu
        /// メニューは出ているが読めなかった。
        case unreadable
    }

    /// 残す件数。
    public static let maxEntries = 5
    /// 1 件の見出し行の頭。画面の行は「| 」を付けて書くので、見出しと取り違えない。
    static let header = "=== "

    public static var defaultURL: URL {
        DeckPaths.logs.appendingPathComponent("menu-screens.log")
    }

    /// 1 件分の文字列。
    public static func entry(kind: Kind, date: Date, columns: Int, screen: [String]) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        let body = TerminalScreen.droppingTrailingBlankLines(screen).map { "| " + $0 }
        return ([header + "\(stamp) \(kind.rawValue) cols=\(columns)"] + body).joined(separator: "\n") + "\n"
    }

    /// 既存の中身に 1 件足し、古いものを落として直近 `keep` 件にする。
    public static func appending(_ entry: String, to existing: String, keep: Int = maxEntries) -> String {
        var entries: [String] = []
        var current: [Substring] = []
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(header), !current.isEmpty {
                entries.append(current.joined(separator: "\n"))
                current = []
            }
            if line.hasPrefix(header) || !current.isEmpty { current.append(line) }
        }
        if !current.isEmpty { entries.append(current.joined(separator: "\n")) }
        entries = entries.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.filter { $0 != "\n" }
        entries.append(entry)
        return entries.suffix(max(1, keep)).joined()
    }

    private static let queue = DispatchQueue(label: "claude-deck.menu-screen-log")

    /// 裏で 1 件書き足す。失敗しても動作には影響させない。
    public static func record(kind: Kind, columns: Int, screen: [String], url: URL = defaultURL, date: Date = Date()) {
        let text = entry(kind: kind, date: date, columns: columns, screen: screen)
        queue.async { try? write(text, to: url) }
    }

    /// 本人だけが読める 0600 で置き換えて書く（書きかけや他人に読める瞬間を作らない）。
    static func write(_ entry: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try SecureFile.write(Data(appending(entry, to: existing).utf8), to: url)
    }
}
