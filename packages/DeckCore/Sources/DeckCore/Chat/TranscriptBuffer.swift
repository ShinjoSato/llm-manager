import Foundation

/// 1 セッション分の会話履歴。取得（全件 / `after`）と追記の購読を id で重複除去して 1 本に並べる。
/// 使い方: 購読を始めた後に `beginFetch()` → 取得 → `apply(_:fullReplace:)`。その間に届いた追記は `append(_:)`。
public struct TranscriptBuffer: Sendable, Equatable {
    public private(set) var items: [TranscriptItem] = []
    private var ids: Set<String> = []
    /// 取得の最中に追記で届いた id。取得の結果と順序がずれるので、反映時に後ろへ付け直す。
    private var liveIds: Set<String> = []

    public init() {}

    /// GET を投げる直前に呼ぶ。
    public mutating func beginFetch() {
        liveIds = []
    }

    /// 追記。既にある id は捨てる。
    public mutating func append(_ newItems: [TranscriptItem]) {
        for item in newItems where !ids.contains(item.id) {
            items.append(item)
            ids.insert(item.id)
            liveIds.insert(item.id)
        }
    }

    /// GET の結果を反映する。`fullReplace`（全件取得・`reset: true`）なら手元を置き換える。
    public mutating func apply(_ response: TranscriptResponse, fullReplace: Bool) {
        let live = items.filter { liveIds.contains($0.id) }
        var base: [TranscriptItem] = fullReplace || response.reset ? [] : items.filter { !liveIds.contains($0.id) }
        var seen = Set(base.map(\.id))
        for item in response.items where !seen.contains(item.id) {
            base.append(item)
            seen.insert(item.id)
        }
        for item in live where !seen.contains(item.id) {
            base.append(item)
            seen.insert(item.id)
        }
        items = base
        ids = seen
        liveIds = []
    }
}
