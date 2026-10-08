import Foundation
import Observation
import MonitorKit

/// 開いたルームの会話。追記の購読を張ってから全件を取り、直近に開いた数件だけ手元に持つ（他は開き直した時に取り直す）。
@MainActor
@Observable
final class TranscriptCache {
    private let store: MonitorStore
    /// 発話が載った後（全件の取り直し・画像付きの追記）に呼ぶ。送った画像の仮の吹き出しを下げるため。
    private let onRecorded: (_ sessionId: String, _ items: [TranscriptItem]) -> Void

    private(set) var buffers: [String: TranscriptBuffer] = [:]
    private(set) var loading: Set<String> = []
    @ObservationIgnored private var stale: Set<String> = []
    /// 開いた順（末尾が新しい）。会話を持ち・追記を購読するのは直近のこれだけ。
    @ObservationIgnored private var recent: [String] = []
    /// 手元に会話を持っておくルームの数。行き来の多い数件だけ取り直しを省く。
    static let kept = 4
    /// 吹き出しの画像の読み込みとキャッシュ。
    @ObservationIgnored private(set) lazy var imageLoader = ChatImageLoader(source: store.imageSource)

    init(store: MonitorStore, onRecorded: @escaping (_ sessionId: String, _ items: [TranscriptItem]) -> Void) {
        self.store = store
        self.onRecorded = onRecorded
        store.onTranscript = { [weak self] event in self?.receive(event) }
    }

    func items(for sessionId: String?) -> [TranscriptItem] {
        guard let sessionId else { return [] }
        return buffers[sessionId]?.items ?? []
    }

    /// 選択中のルームの履歴を揃える。取り直しも全件で置き換える（止まっていた間の発話は手元の末尾より前に入りうるので `after=` では埋まらない）。
    func ensure(for sessionId: String?) {
        guard let sessionId, store.connection.isConnected else { return }
        recent.removeAll { $0 == sessionId }
        recent.append(sessionId)
        guard !loading.contains(sessionId) else { return }
        guard buffers[sessionId] == nil || stale.contains(sessionId) else { return }
        var buffer = buffers[sessionId] ?? TranscriptBuffer()
        buffer.beginFetch()
        buffers[sessionId] = buffer
        stale.remove(sessionId)
        loading.insert(sessionId)
        forgetOld()
        Task {
            // 購読を先に張る（後だとその間の追記が抜ける）。対象は張る直前に取る（Task が走るまでにルームを開閉しうる）。
            await store.watchTranscripts(Set(buffers.keys))
            // 最初の発話前はログが無い（nil）。以降は購読で届くので空のまま待つ。
            if let response = await store.fetchTranscript(sessionId: sessionId) {
                buffers[sessionId]?.apply(response, fullReplace: true)
                if let items = buffers[sessionId]?.items { onRecorded(sessionId, items) }
            }
            loading.remove(sessionId)
            // 取得中に監視を始め直した。その応答は古いかもしれないので取り直す。
            if stale.contains(sessionId) { ensure(for: sessionId) }
        }
    }

    /// 直近に開いたもの以外の会話を手放す（開き直せば取り直す）。
    private func forgetOld() {
        let keep = Set(recent.suffix(Self.kept)).union(loading)
        recent.removeAll { !keep.contains($0) }
        for id in buffers.keys where !keep.contains(id) {
            buffers[id] = nil
            stale.remove(id)
        }
    }

    /// 監視を始め直した。止まっていた間の分を取り直す（`selected` は選択中のルームの sessionId）。
    func reconnected(selected sessionId: String?) {
        stale = Set(buffers.keys)
        ensure(for: sessionId)
    }

    private func receive(_ event: TranscriptEvent) {
        // 手元に持っていないセッションは、開いた時に GET でまとめて取る。
        guard buffers[event.sessionId] != nil else { return }
        buffers[event.sessionId]?.append(event.items)
        if event.items.contains(where: { !$0.images.isEmpty }) { onRecorded(event.sessionId, items(for: event.sessionId)) }
    }
}
