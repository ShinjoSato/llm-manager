import Foundation

/// 購読の指定。
public enum TranscriptSubscription: Sendable, Hashable {
    case none
    case all
    case sessions(Set<String>)
}

/// ログの読み出しと購読者への配信をまとめて持つ。
/// 監視（SessionHub）とは別の actor にして、画像の読み直しで状態の更新を待たせない。
public actor TranscriptStore {
    public static let pollInterval: Duration = .milliseconds(250)
    /// 手元に保持するログの上限。購読中のものは数に関わらず残す（ログは会話を丸ごと持つので多くしない）。
    static let maxLogs = 8

    public struct Known: Sendable, Equatable {
        public var sessionId: String
        public var cwd: String
        public init(sessionId: String, cwd: String) {
            self.sessionId = sessionId
            self.cwd = cwd
        }
    }

    private struct Subscriber {
        /// nil は全セッション。
        var ids: Set<String>?
        var fn: @Sendable (TranscriptEvent) -> Void
    }

    private var logs: [String: TranscriptLog] = [:]
    /// LRU の順（末尾が新しい）。
    private var order: [String] = []
    private var subscribers: [Int: Subscriber] = [:]
    private var subscriberSeq = 0
    private var known: [Known] = []
    private var pollTask: Task<Void, Never>?
    private let resolver: @Sendable (String, String) -> String?

    /// `resolve` は sessionId と cwd から jsonl の場所を引く（試験では差し替える）。
    public init(home: ClaudeHome) {
        let locator = LockedLocator(home: home)
        resolver = { locator.resolve(sessionId: $0, cwd: $1) }
    }

    init(resolve: @escaping @Sendable (String, String) -> String?) {
        resolver = resolve
    }

    public func setKnown(_ sessions: [Known]) {
        known = sessions
    }

    private func logFor(_ sessionId: String) -> TranscriptLog? {
        if let existing = logs[sessionId] {
            // 最近使ったものを後ろへ回して、追い出し順を LRU にする。
            order.removeAll { $0 == sessionId }
            order.append(sessionId)
            return existing
        }
        let cwd = known.first { $0.sessionId == sessionId }?.cwd ?? ""
        guard let path = resolver(sessionId, cwd) else { return nil }
        let log = TranscriptLog(path: path)
        logs[sessionId] = log
        order.append(sessionId)
        evict()
        return log
    }

    private func evict() {
        let watched = watchedIds()
        for id in order where logs.count > Self.maxLogs && !watched.contains(id) {
            logs[id] = nil
            order.removeAll { $0 == id }
        }
    }

    /// 追記を読み、増えた分を購読者へ配る。取得経由で読んだ分も購読側に取りこぼさせない。
    @discardableResult
    private func refresh(_ sessionId: String) -> TranscriptLog? {
        guard let log = logFor(sessionId) else { return nil }
        let fresh = log.read()
        if !fresh.isEmpty {
            let event = TranscriptEvent(sessionId: sessionId, items: fresh)
            for sub in subscribers.values where sub.ids == nil || sub.ids!.contains(sessionId) { sub.fn(event) }
        }
        return log
    }

    /// 履歴を返す。ログが見つからなければ nil。
    public func get(_ sessionId: String, after: String? = nil) -> TranscriptResponse? {
        guard TranscriptFormat.isValidSessionId(sessionId), let log = refresh(sessionId) else { return nil }
        let (items, reset) = log.since(after)
        return TranscriptResponse(sessionId: sessionId, items: items, reset: reset)
    }

    /// 発話に添えられた画像の本体。履歴・発話・画像が見つからなければ nil。
    public func image(sessionId: String, itemId: String, index: Int) async -> TranscriptImageData? {
        guard TranscriptFormat.isValidSessionId(sessionId), TranscriptFormat.isValidItemId(itemId), index >= 0,
              let log = refresh(sessionId) else { return nil }
        switch log.lookupImage(itemId: itemId, index: index) {
        case .cached(let hit): return hit
        case .missing: return nil
        case .load(let path, let ref):
            // 行の読み直しはファイル全体の走査になりうるので、その間も追記の配信を止めない。
            guard let (loaded, found) = await Task.detached(priority: .userInitiated, operation: {
                TranscriptLog.loadImages(path: path, ref: ref)
            }).value else { return nil }
            return log.storeLoaded(itemId: itemId, loaded, ref: found, index: index)
        }
    }

    private func watchedIds() -> Set<String> {
        var ids = Set<String>()
        var all = false
        for sub in subscribers.values {
            if let set = sub.ids { ids.formUnion(set) } else { all = true }
        }
        if all { ids.formUnion(known.map(\.sessionId)) }
        return ids
    }

    /// 追記の購読。登録時点までの内容は既読として扱い、以降の追記だけを届ける。解除用の番号を返す（購読しなければ nil）。
    /// `replacing` を渡すと、その購読を同じ呼び出しの中で差し替える（間に届いた追記を取りこぼさない）。
    @discardableResult
    public func subscribe(_ subscription: TranscriptSubscription, replacing previous: Int? = nil,
                          _ fn: @escaping @Sendable (TranscriptEvent) -> Void) -> Int? {
        let ids: Set<String>?
        switch subscription {
        case .none: ids = []
        case .all: ids = nil
        case .sessions(let set): ids = set.filter(TranscriptFormat.isValidSessionId)
        }
        // 既読の基準線を先に引く。登録後に読むと過去の全件が「追記」として届いてしまう。
        // 差し替え前の購読はまだ残っているので、ここで読んだ追記はそちらに届く。
        for id in ids.map(Array.init) ?? known.map(\.sessionId) { refresh(id) }
        if let previous { subscribers[previous] = nil }
        guard ids?.isEmpty != true else {
            if subscribers.isEmpty { stop() }
            evict()
            return nil
        }
        subscriberSeq += 1
        subscribers[subscriberSeq] = Subscriber(ids: ids, fn: fn)
        startPolling()
        evict()
        return subscriberSeq
    }

    public func unsubscribe(_ id: Int) {
        subscribers[id] = nil
        if subscribers.isEmpty { stop() }
    }

    /// 購読されているセッションの追記を読む。
    public func poll() {
        for id in watchedIds() { refresh(id) }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = repeatingTask(every: Self.pollInterval, owner: self) { store in await store.poll() }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// 試験用: 購読者と保持しているログの数。
    var subscriberCount: Int { subscribers.count }
    var logCount: Int { logs.count }

    /// 試験用: 保持しているログ。
    func log(for sessionId: String) -> TranscriptLog? { logs[sessionId] }
}

/// 複数の actor から引けるよう、場所のキャッシュを錠で守る。
final class LockedLocator: @unchecked Sendable {
    private let lock = NSLock()
    private var locator: TranscriptLocator

    init(home: ClaudeHome) {
        locator = TranscriptLocator(home: home)
    }

    func resolve(sessionId: String, cwd: String) -> String? {
        lock.withLock { locator.resolve(sessionId: sessionId, cwd: cwd) }
    }
}
