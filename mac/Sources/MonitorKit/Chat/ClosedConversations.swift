import Foundation

/// 閉じたホストのルームの会話。監視が終了したセッションを墓標として残すので、外部ルームとして出し直さないために起動中だけ覚える。
public struct ClosedConversations: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var sessionId: String?
        public var pid: Int32?
        /// 閉じた時刻（epoch ミリ秒）。
        public var closedAt: Double
        /// claude が閉じる前に終わっていればその時刻（epoch ミリ秒）。pid の使い回しを見分ける境目に使う。
        public var endedAt: Double?

        /// これより後に起動したプロセスは閉じた claude ではない。
        var boundary: Double { min(endedAt ?? closedAt, closedAt) }
    }

    /// 墓標が現れる前に忘れないための猶予で、閉じた claude が終わり切るのを待つ長さも兼ねる。
    public static let grace: Double = 30_000

    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// 閉じた会話を覚える。sessionId も pid も分からなければ見分けようが無いので覚えない。
    public mutating func remember(sessionId: String?, pid: Int32?, closedAt: Double, endedAt: Double? = nil) {
        guard sessionId != nil || pid != nil else { return }
        entries.append(Entry(sessionId: sessionId, pid: pid, closedAt: closedAt, endedAt: endedAt))
    }

    /// 外部ルームとして出さないか。閉じた claude 自身（終わる途中・`/clear` 前の会話を含む）と、閉じた会話の墓標を隠す。
    /// 同じ会話を後から別の claude で再開したものと、猶予を過ぎても終わらない claude は出す。
    public func hides(_ snapshot: SessionSnapshot, now: Double) -> Bool {
        entries.contains { entry in
            if Self.isClosedProcess(entry, snapshot) {
                return !snapshot.alive || now - entry.closedAt <= Self.grace
            }
            guard !snapshot.alive, entry.sessionId == snapshot.sessionId else { return false }
            return snapshot.startedAt <= 0 || snapshot.startedAt <= entry.boundary
        }
    }

    /// 監視の一覧に関係するセッションが無くなった分を手放す（集合が増え続けないように）。
    public mutating func prune(sessions: [SessionSnapshot], now: Double) {
        entries.removeAll { entry in
            guard now - entry.closedAt > Self.grace else { return false }
            return !sessions.contains { Self.isClosedProcess(entry, $0) || entry.sessionId == $0.sessionId }
        }
    }

    /// pid は使い回されるので、境目より後に起動したもの・起動時刻が読めないものは別物とみなす。
    private static func isClosedProcess(_ entry: Entry, _ snapshot: SessionSnapshot) -> Bool {
        guard let pid = entry.pid, snapshot.pid == pid, snapshot.startedAt > 0 else { return false }
        return snapshot.startedAt <= entry.boundary
    }
}
