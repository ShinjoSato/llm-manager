import Foundation

/// カードの操作・入力欄からの送信の各段階を直近の数百行だけ残す（固まった時に辿るため。本文は入れず 0600 で置く）。
public final class MenuOpsLog: @unchecked Sendable {
    /// 残す行数。
    public static let maxLines = 500
    /// 続けて書く記録をまとめて書き出すまでの待ち。
    static let flushDelay: TimeInterval = 0.5
    /// 値の長さの上限（取り違えて本文を渡しても長く残さない）。
    static let maxValueLength = 48

    public static let shared = MenuOpsLog(url: DeckPaths.logs.appendingPathComponent("menu-ops.log"))
    /// 入力欄からの送信の各段階（貼り付け・入力欄の読み取り・Enter・取りやめ・残りの判定と抜け道）。
    public static let send = MenuOpsLog(url: DeckPaths.logs.appendingPathComponent("send-ops.log"))

    public let url: URL
    private let keep: Int
    private let queue = DispatchQueue(label: "claude-deck.menu-ops-log")
    private var pending: [String] = []
    private var scheduled = false

    public init(url: URL, keep: Int = MenuOpsLog.maxLines) {
        self.url = url
        self.keep = max(1, keep)
    }

    /// 1 行足す（書き出しは裏でまとめて行う。失敗しても動作には影響させない）。
    public func record(_ event: String, _ fields: [(String, String)] = [], date: Date = Date()) {
        let line = Self.line(event, fields, date: date)
        queue.async {
            self.pending.append(line)
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + Self.flushDelay) { self.writePending() }
        }
    }

    /// 溜まっている行をすぐ書き出す。
    public func flush() {
        queue.sync { writePending() }
    }

    private func writePending() {
        scheduled = false
        guard !pending.isEmpty else { return }
        let lines = pending
        pending = []
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? SecureFile.write(Data(Self.appending(lines, to: existing, keep: keep).utf8), to: url)
    }

    // ISO8601DateFormatter はスレッドをまたいで使ってよく、行ごとに作ると重いので 1 つを使い回す。
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 1 行分（`時刻 出来事 名前=値 …`）。値の空白・改行・`=` は `_` に置き換え、長さを切る。
    public static func line(_ event: String, _ fields: [(String, String)], date: Date) -> String {
        let parts = [timestampFormatter.string(from: date), clean(event)] + fields.map { "\(clean($0.0))=\(clean($0.1))" }
        return parts.joined(separator: " ")
    }

    static func clean(_ value: String) -> String {
        let replaced = value.map { $0.isWhitespace || $0.isNewline || $0 == "=" ? "_" : String($0) }.joined()
        return replaced.isEmpty ? "-" : String(replaced.prefix(maxValueLength))
    }

    /// 既存の中身に行を足し、古いものを落として直近 `keep` 行にする。
    public static func appending(_ lines: [String], to existing: String, keep: Int = maxLines) -> String {
        let old = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return (old + lines).suffix(max(1, keep)).joined(separator: "\n") + "\n"
    }
}
