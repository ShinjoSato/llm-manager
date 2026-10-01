import Foundation

/// 入力欄（NSTextView）とモデル側の下書きの同期判定。
///
/// 日本語入力の変換中（marked text）は NSTextView が textDidChange を出さないため、下書きは確定済みの部分しか持たない。
/// その間に再描画で下書きを書き戻すと変換中の文字ごと消えるので、自分が最後に渡した値と違う時（送信後の空など本当の外部変更）だけ書き戻す。
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

