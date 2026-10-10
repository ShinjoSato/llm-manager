import Foundation

/// 会話の Markdown の文字の段階（pt）。本文の大きさを基準に、見出し・等幅・余白を同じ比率でそろえる。
public struct ChatTypeScale: Sendable, Equatable {
    /// 本文（段落・リスト・表）の大きさ。
    public let body: CGFloat
    /// 本文の行間。
    public let lineSpacing: CGFloat

    public init(body: CGFloat, lineSpacing: CGFloat) {
        self.body = body
        self.lineSpacing = lineSpacing
    }

    /// 発話・伝言・会話以外の Markdown と同じ大きさ。
    public static let standard = ChatTypeScale(body: 14, lineSpacing: 3)
    /// Claude の返答。会話の主な中身なので発話より 2pt 大きく、行間も広げる。
    public static let reply = ChatTypeScale(body: 16, lineSpacing: 5)

    /// `standard` に対する倍率。
    public var ratio: CGFloat { body / Self.standard.body }

    /// コードブロック・インラインでない等幅の文字。
    public var mono: CGFloat { Self.scaled(12, ratio) }

    /// 見出しの大きさ（レベル 1〜3 は段階を付け、4 以降は本文と同じ）。
    public func heading(_ level: Int) -> CGFloat {
        switch level {
        case 1: return Self.scaled(19, ratio)
        case 2: return Self.scaled(16.5, ratio)
        case 3: return Self.scaled(15, ratio)
        default: return body
        }
    }

    /// ブロックの間隔（入れ子の中は詰める）。
    public func blockSpacing(nested: Bool) -> CGFloat { Self.scaled(nested ? 6 : 10, ratio) }

    /// リストの行の間隔。
    public var listSpacing: CGFloat { Self.scaled(4, ratio) }

    /// 番号付きリストの数字 1 桁ぶんの幅。
    public var digitWidth: CGFloat { Self.scaled(8.5, ratio) }

    /// 0.5pt 刻みに丸める（半端な大きさで文字がにじまないように）。
    private static func scaled(_ value: CGFloat, _ ratio: CGFloat) -> CGFloat {
        (value * ratio * 2).rounded() / 2
    }
}
