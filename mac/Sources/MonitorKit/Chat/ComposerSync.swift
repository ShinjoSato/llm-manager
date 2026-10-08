import Foundation

/// 入力欄と下書きの同期。変換中の文字は下書きに無く書き戻すと消えるので、最後に渡した値と違う時（本当の外部変更）だけ書き戻す。
public struct ComposerSync: Sendable, Equatable {
    /// 入力欄から下書きへ最後に渡した値（書き戻した値も含む）。nil はまだ一度も同期していない。
    public private(set) var lastPublished: String?

    public init() {}

    /// 入力欄の内容を下書きへ渡した。
    public mutating func published(_ text: String) {
        lastPublished = text
    }

    /// 下書きの値 `external` を、今表示中の `shown` へ書き戻すべきか。書き戻すなら `published` 済みとして覚える。
    public mutating func shouldApply(external: String, shown: String) -> Bool {
        if external == shown {
            lastPublished = external
            return false
        }
        guard external != lastPublished else { return false }
        lastPublished = external
        return true
    }
}

