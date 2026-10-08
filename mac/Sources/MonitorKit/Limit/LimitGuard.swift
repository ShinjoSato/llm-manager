import Foundation

/// 上限到達（これ以上使うと止まる・または課金枠に入る）の判定。公式の残量を主に、端末画面の上限表示を補助に使う。
public enum LimitGuard {
    /// 残量を信じる鮮度。statusLine はセッションが動いている間しか書かれないので、古い値で落とさない。
    public static let freshness: TimeInterval = 10 * 60
    /// 取得時刻が未来に見える時の許容（時計のずれ）。
    static let clockSkew: TimeInterval = 60

    /// 残量から見た到達。
    public struct UsageHit: Sendable, Equatable {
        public enum Window: String, Sendable { case fiveHour, sevenDay }
        public var window: Window
        public var usedPercentage: Double
        /// このウィンドウが戻る時刻（不明なら nil）。
        public var resetsAt: Date?

        public var reason: String {
            let name = window == .fiveHour ? "5 時間" : "7 日間"
            return "\(name)の使用率が \(Int(usedPercentage.rounded()))% に達しました"
        }
    }

    /// 公式の残量（statusLine の rate_limits）で 5 時間 / 7 日間のどちらかが 100% 以上なら到達。古い値・nil は判定しない。
    public static func usageHit(_ usage: UsageSnapshot?, now: Date = Date()) -> UsageHit? {
        guard let usage, isFresh(usage, now: now) else { return nil }
        let windows: [(UsageHit.Window, UsageWindow?)] = [(.fiveHour, usage.fiveHour), (.sevenDay, usage.sevenDay)]
        for (kind, window) in windows {
            guard let window, window.usedPercentage >= 100 else { continue }
            // リセット時刻を過ぎた値は前のウィンドウのもの。
            if let resets = window.resetsDate, resets <= now { continue }
            return UsageHit(window: kind, usedPercentage: window.usedPercentage, resetsAt: window.resetsDate)
        }
        return nil
    }

    public static func isFresh(_ usage: UsageSnapshot, now: Date) -> Bool {
        let age = now.timeIntervalSince(usage.fetchedDate)
        return age <= freshness && age >= -clockSkew
    }

    // MARK: - 画面の上限表示

    /// Claude Code（v2.1.286）が上限・課金枠到達を知らせる文の書き出し。バイナリ内の一覧（startsWith で判定しているもの）から写した。
    public static let messagePrefixes: [String] = [
        // 上限到達（"You've hit your session limit · resets 3pm" 等）
        "You've hit your",
        "You've reached your",
        "You're out of usage credits",
        "You're out of extra usage",
        // 課金枠（usage credits / extra usage）に切り替わった
        "You're now using usage credits",
        "You're now using extra usage",
        "Now using usage credits",
        "Now using extra usage",
        // 待機・自動再開・猶予の通知（"Usage limit reached · continuing automatically …" 等）
        "Usage limit reached",
    ]

    /// 上限到達時に自動で開く選択メニュー（/rate-limit-options）の項目。
    public static let menuOption = "Stop and wait for limit to reset"

    /// 入力欄の直上で見る行数（空行を除く）。エラー表示とその下のヒント行が収まる幅だけ見る。
    static let aboveBoxLines = 6
    /// 入力欄が無い時（メニュー表示中）に下から見る行数（空行を除く）。
    static let menuLines = 15

    /// 画面の末尾の上限表示の行。会話本文は見ず、フッター・入力欄直上の最後の `⎿` 行・メニューの選択肢だけを見る。
    public static func screenLimitLine(_ screen: [String]) -> String? {
        let lines = TerminalScreen.droppingTrailingBlankLines(screen)
        guard let boxTop = inputBoxTop(lines) else {
            // 本文の番号付きリストで落とさないよう、メニュー固有の操作案内が出ている時だけ見る。
            let tail = lines.suffix(menuLines)
            guard tail.contains(where: isMenuHint) else { return nil }
            return menuLine(tail)
        }
        let boxBottom = lines[(boxTop + 2)...].firstIndex(where: PermissionPrompt.isSeparator)
        if let boxBottom {
            let footer = lines[(boxBottom + 1)...]
            for line in footer {
                for segment in segments(line) where hasLimitPrefix(segment) { return line.trimmed }
            }
            if let hit = menuLine(footer) { return hit }
        }
        // 入力欄の直上から遡り、最初に当たった表示の塊（⎿ / ⏺ / ❯ で始まる行）が上限エラーの時だけ到達とする。
        let above = lines.indices[..<boxTop].filter { !lines[$0].trimmed.isEmpty }.suffix(aboveBoxLines)
        for index in above.reversed() {
            let line = lines[index]
            var t = Substring(line.trimmed)
            if t.hasPrefix("⏺") || t.hasPrefix("❯") { return nil }
            guard t.hasPrefix("⎿") else { continue }
            t = t.dropFirst().drop(while: { $0.isWhitespace })
            guard hasLimitPrefix(String(t)) else { return nil }
            // ツールの出力（echo 等）に同じ文言が出ただけで落とさない。
            if let header = lines[..<index].last(where: { $0.trimmed.hasPrefix("⏺") || $0.trimmed.hasPrefix("❯") }),
               isToolCallHeader(header) {
                return nil
            }
            return line.trimmed
        }
        return nil
    }

    /// `⏺ Bash(…)` や `⏺ server - tool (MCP)(…)` のようなツール呼び出しの見出し。
    static func isToolCallHeader(_ line: String) -> Bool {
        let t = line.trimmed
        guard t.hasPrefix("⏺") else { return false }
        let rest = t.dropFirst().drop(while: { $0.isWhitespace })
        guard let paren = rest.firstIndex(of: "(") else { return false }
        let name = rest[..<paren]
        return (!name.isEmpty && !name.contains(where: { $0.isWhitespace })) || rest.contains("(MCP)")
    }

    static func isMenuHint(_ line: String) -> Bool {
        let t = line.trimmed
        return t.contains("Enter to confirm") || t.contains("Enter to select") || t.contains("Esc to cancel")
    }

    static func hasLimitPrefix(_ text: String) -> Bool {
        messagePrefixes.contains { text.hasPrefix($0) }
    }

    /// 「❯ 1. Stop and wait for limit to reset」のような選択肢の行。
    static func menuLine<C: Collection>(_ lines: C) -> String? where C.Element == String {
        lines.first { line in
            var t = ChoiceMenu.strippingCursor(line).text
            let digits = t.prefix(while: { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty, digits.count <= 2 else { return false }
            t = t.dropFirst(digits.count)
            guard t.hasPrefix(".") else { return false }
            return t.dropFirst().drop(while: { $0.isWhitespace }).hasPrefix(menuOption)
        }?.trimmed
    }

    /// 入力欄の上の罫線の位置（罫線の直下が `❯` で始まり、選択肢ではない行）。
    static func inputBoxTop(_ lines: [String]) -> Int? {
        lines.indices.last { index in
            guard index + 1 < lines.count, PermissionPrompt.isSeparator(lines[index]) else { return false }
            let next = lines[index + 1].trimmed
            return next.hasPrefix("❯") && !isNumberedChoice(next)
        }
    }

    static func isNumberedChoice(_ line: String) -> Bool {
        let rest = line.dropFirst().drop(while: { $0.isWhitespace })
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        return !digits.isEmpty && rest.dropFirst(digits.count).hasPrefix(".")
    }

    /// フッターは左右に複数の表示が空白で並ぶので、2 つ以上の空白で区切る。
    static func segments(_ line: String) -> [String] {
        line.components(separatedBy: "  ").map(\.trimmed).filter { !$0.isEmpty }
    }
}

/// 残量で到達した事実を、そのウィンドウが戻るまで覚えておく。後から起動したセッションも同じ扱いにするため。
public struct UsageLimitLatch: Sendable, Equatable {
    public private(set) var hit: LimitGuard.UsageHit?
    public private(set) var until: Date?

    public init() {}

    mutating func restore(until date: Date) {
        until = date
    }

    /// 新しい残量を反映し、今が到達中かを返す。新しい値で 100% 未満になったら（前倒しのリセット等）解除する。
    public mutating func update(with usage: UsageSnapshot?, now: Date = Date()) -> Bool {
        if let usage, LimitGuard.isFresh(usage, now: now) {
            if let newHit = LimitGuard.usageHit(usage, now: now) {
                hit = newHit
                // リセット時刻が分からなければ、値が新しい間だけ到達とみなす。
                let end = newHit.resetsAt ?? usage.fetchedDate.addingTimeInterval(LimitGuard.freshness)
                until = max(until ?? end, end)
            } else {
                hit = nil
                until = nil
            }
        }
        if let until, until <= now {
            hit = nil
            self.until = nil
        }
        return until != nil
    }
}
