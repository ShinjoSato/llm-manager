import Foundation

// 「端末の画面」（ホスト中のルームの端末の今の表示と、決まったキーを 1 回ずつ送る口）の型。仕様は mac/docs/remote-api.md。

/// 送れるキー（mac の「端末の画面」のシートと同じ表。文字の自由入力は無い）。
public enum RemoteTerminalKey: String, Codable, Sendable, CaseIterable {
    case left, up, down, right
    case enter, escape, tab, space
    case digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4", digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"

    /// ボタンと結果の一言に出す名前。
    public var label: String {
        switch self {
        case .left: return "←"
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        case .enter: return "Enter"
        case .escape: return "Esc"
        case .tab: return "Tab"
        case .space: return "Space"
        default: return rawValue
        }
    }

    /// 読み上げに使う名前（矢印の記号は読み上げで伝わりにくい）。
    public var accessibilityName: String {
        switch self {
        case .left: return "左矢印"
        case .up: return "上矢印"
        case .down: return "下矢印"
        case .right: return "右矢印"
        default: return label
        }
    }
}

/// 端末のカーソルの位置（0 始まり。`row` は `lines` の位置（範囲内の時だけ送る）、`column` は桁）。
public struct RemoteTerminalCursor: Codable, Sendable, Equatable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// `GET /v1/rooms/{roomId}/terminal` の応答。
public struct RemoteTerminalScreen: Codable, Sendable, Equatable {
    /// 端末の今の表示（上の行から。末尾の空行は除く・右端の空白は除く）。
    public var lines: [String]
    public var cursor: RemoteTerminalCursor?
    /// 端末の幅（桁）と高さ（行）。
    public var columns: Int
    public var rows: Int
    /// 読み取った時刻（epoch ミリ秒）。
    public var capturedAt: Double
    /// Esc で claude が終わるメニューが出ている（Esc を送るには `confirmExit: true` が要る）。
    public var escapeExits: Bool

    public init(lines: [String], cursor: RemoteTerminalCursor?, columns: Int, rows: Int, capturedAt: Double, escapeExits: Bool) {
        self.lines = lines
        self.cursor = cursor
        self.columns = columns
        self.rows = rows
        self.capturedAt = capturedAt
        self.escapeExits = escapeExits
    }

    /// 返す行の上限（端末の高さより十分に大きい）。
    public static let maxLines = 300
    /// 1 行の文字数の上限（端末の幅より十分に大きい）。
    public static let maxLineLength = 1024

    /// 読み取った時刻を除いた中身が同じか（取り直しのたびに描き直さないため）。
    public func sameContent(as other: RemoteTerminalScreen) -> Bool {
        lines == other.lines && cursor == other.cursor && columns == other.columns && rows == other.rows && escapeExits == other.escapeExits
    }

    /// 上限に収めて作る。上を切った分だけカーソルの行をずらし、`lines` の外になったら落とす。
    public static func limited(lines: [String], cursor: RemoteTerminalCursor?, columns: Int, rows: Int, capturedAt: Double,
                               escapeExits: Bool) -> RemoteTerminalScreen {
        let dropped = max(0, lines.count - maxLines)
        let kept = lines.suffix(maxLines).map { $0.count > maxLineLength ? String($0.prefix(maxLineLength)) : $0 }
        let moved = cursor.flatMap { c -> RemoteTerminalCursor? in
            let row = c.row - dropped
            guard row >= 0, row < min(lines.count, maxLines), c.column >= 0 else { return nil }
            return RemoteTerminalCursor(row: row, column: c.column)
        }
        return RemoteTerminalScreen(lines: Array(kept), cursor: moved, columns: max(0, columns), rows: max(0, rows),
                                    capturedAt: capturedAt, escapeExits: escapeExits)
    }
}

/// `POST /v1/rooms/{roomId}/terminal/key`。`key` は `RemoteTerminalKey` の値（知らない値は `unsupported_key` で断る）。
public struct RemoteTerminalKeyRequest: Codable, Sendable, Equatable {
    public var key: String
    /// Esc で claude が終わるメニュー（`escapeExits`）に Esc を送る時に true。
    public var confirmExit: Bool?

    public init(key: RemoteTerminalKey, confirmExit: Bool? = nil) {
        self.key = key.rawValue
        self.confirmExit = confirmExit
    }

    public init(rawKey: String, confirmExit: Bool? = nil) {
        key = rawKey
        self.confirmExit = confirmExit
    }
}

/// 定期の取り直しと操作の後の取り直しが重なった時に、先に出した要求の遅れた応答で新しい表示を上書きしないための通し番号。
public struct RemoteResponseOrder: Sendable, Equatable {
    private var issued = 0
    private var applied = 0
    /// これより前に出した要求の応答は捨てる。
    private var floor = 0

    public init() {}

    /// 要求を出す時に番号を取る。
    public mutating func issue() -> Int {
        issued += 1
        return issued
    }

    /// 今までに出した要求の応答を古いものとして捨てる（キーを送った後など）。
    public mutating func invalidateIssued() {
        floor = issued + 1
    }

    /// 応答を使ってよいか。使うならそれより前の要求の応答は以後捨てる。
    public mutating func accept(_ number: Int) -> Bool {
        guard number >= floor, number > applied else { return false }
        applied = number
        return true
    }
}
