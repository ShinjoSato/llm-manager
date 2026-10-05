import Foundation

/// 要対応のルームの移り変わりから、iCloud に書く・消す知らせを決める（副作用なし）。
///
/// - 同じ要対応（待ち始めから解消まで）は 1 回だけ知らせる。待つ種類が変わっても（権限待ち→入力待ち）同じ要対応とみなす。
/// - `settle` 秒続いた要対応が出たら知らせる（mac の前ですぐ答えたものは送らない）。その時に待っている他のルームも含める。
/// - 見出し（と開くルーム）は `settle` 秒続いたものの中で一番新しいもの。まだ続いていないものは「ほか N 件」に回す。
/// - 知らせてから `cooldown` 秒は次を出さず、その間に溜まった要対応は明けた時に 1 件にまとめる。
/// - 解消は `resolve` 秒続けて要対応でなくなってから確定する（その間に戻れば同じ要対応のまま）。
/// - 知らせがまとめたルームが全て解消したら、その知らせを消す。
public struct AttentionNoticePlanner: Sendable {
    public struct Config: Sendable, Equatable {
        public var settle: TimeInterval
        public var cooldown: TimeInterval
        public var resolve: TimeInterval

        public init(settle: TimeInterval = 5, cooldown: TimeInterval = 30, resolve: TimeInterval = 3) {
            self.settle = settle
            self.cooldown = cooldown
            self.resolve = resolve
        }
    }

    public enum Change: Sendable, Equatable {
        case save(AttentionNotice)
        case delete(recordName: String)
    }

    struct Episode: Sendable, Equatable {
        var since: Double
        var candidate: AttentionCandidate
        /// 要対応でなくなった時刻。`resolve` 秒経つまでは解消と決めない。
        var clearedAt: Double?
    }

    public let config: Config
    public let macName: String
    private(set) var episodes: [String: Episode] = [:]
    /// recordName → まだ解消していない、その知らせがまとめたルーム。
    private(set) var coverage: [String: Set<String>] = [:]
    private var lastAlertAt: Double?

    public init(config: Config = Config(), macName: String) {
        self.config = config
        self.macName = macName
    }

    /// 今の要対応のルームを渡す。`now` は epoch ミリ秒。
    public mutating func update(_ candidates: [AttentionCandidate], now: Double) -> [Change] {
        var current: [String: AttentionCandidate] = [:]
        for candidate in candidates where current[candidate.roomId] == nil { current[candidate.roomId] = candidate }

        var changes: [Change] = []
        for (roomId, episode) in episodes where current[roomId] == nil {
            let clearedAt = episode.clearedAt ?? now
            episodes[roomId]?.clearedAt = clearedAt
            guard now - clearedAt >= config.resolve * 1000 else { continue }
            episodes[roomId] = nil
            for (recordName, rooms) in coverage where rooms.contains(roomId) {
                var rest = rooms
                rest.remove(roomId)
                coverage[recordName] = rest
            }
        }
        for recordName in coverage.keys.sorted() where coverage[recordName]?.isEmpty == true {
            coverage[recordName] = nil
            changes.append(.delete(recordName: recordName))
        }

        for (roomId, candidate) in current {
            if var episode = episodes[roomId] {
                episode.candidate = candidate
                episode.clearedAt = nil
                episodes[roomId] = episode
            } else {
                episodes[roomId] = Episode(since: now, candidate: candidate)
            }
        }

        let covered = coverage.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // 新しい順。同時刻はルーム id で決める（並びを毎回同じにする）。
        let waiting = episodes.values
            .filter { $0.clearedAt == nil && !covered.contains($0.candidate.roomId) }
            .sorted { ($0.since, $0.candidate.roomId) > ($1.since, $1.candidate.roomId) }
        // 1 つでも続いたら、その時に待っている他のルームも同じ知らせにまとめる。
        guard let newest = waiting.first(where: { now - $0.since >= config.settle * 1000 }) else { return changes }
        if let lastAlertAt, now - lastAlertAt < config.cooldown * 1000 { return changes }

        let rest = waiting.filter { $0.candidate.roomId != newest.candidate.roomId }
        let others = rest.map(\.candidate.roomName)
        let primary = newest.candidate
        let summary = AttentionNoticeText.summary(kind: primary.kind, toolName: primary.toolName)
        let notice = AttentionNotice(
            recordName: Self.recordName(roomId: primary.roomId, now: now),
            roomId: primary.roomId,
            sessionId: primary.sessionId,
            roomName: AttentionNoticeText.name(primary.roomName),
            kind: primary.kind,
            summary: summary,
            title: AttentionNoticeText.title(roomName: primary.roomName, others: others.count),
            body: AttentionNoticeText.body(summary: summary, otherNames: Array(others)),
            since: newest.since,
            roomIds: [primary.roomId] + rest.map(\.candidate.roomId),
            macName: macName
        )
        coverage[notice.recordName] = Set(notice.roomIds)
        lastAlertAt = now
        changes.append(.save(notice))
        return changes
    }

    /// CloudKit のレコード名に使える文字（英数字・`-`・`_`）だけで作る。同じルームでも時刻で別の知らせになる。
    static func recordName(roomId: String, now: Double) -> String {
        let safe = String(roomId.unicodeScalars.map { scalar -> Character in
            let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
            return ok ? Character(scalar) : "_"
        }.prefix(120))
        return "attn-\(safe)-\(Int64(now))"
    }
}
