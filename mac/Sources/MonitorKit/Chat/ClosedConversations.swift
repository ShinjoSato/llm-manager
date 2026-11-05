import Foundation

/// 閉じたホストのルームの会話。監視が終了したセッションを墓標として残すので、外部ルームとして出し直さないために起動中だけ覚える。
public struct ClosedConversations: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var sessionId: String?
        public var pid: Int32?
        /// 閉じた時刻（epoch ミリ秒）。
        public var closedAt: Double
    }

    /// 墓標が現れる前に忘れないための猶予（claude の起動直後はまだ監視に載っていないことがある）。
    public static let grace: Double = 30_000

    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// 閉じた会話を覚える。sessionId も pid も分からなければ見分けようが無いので覚えない。
    public mutating func remember(sessionId: String?, pid: Int32?, closedAt: Double) {
        guard sessionId != nil || pid != nil else { return }
        entries.append(Entry(sessionId: sessionId, pid: pid, closedAt: closedAt))
    }

    /// 外部ルームとして出さないか。閉じた claude 自身（終わる途中を含む・`/clear` 前の会話も pid で拾う）と、終了済みの閉じた会話を隠す。
    /// 同じ会話が別の claude で再開されて動いていれば出す。
    public func hides(_ snapshot: SessionSnapshot) -> Bool {
        entries.contains { entry in
            if Self.isClosedProcess(entry, snapshot) { return true }
            return !snapshot.alive && entry.sessionId == snapshot.sessionId
        }
    }

    /// 監視の一覧に関係するセッションが無くなった分を手放す（集合が増え続けないように）。
    public mutating func prune(sessions: [SessionSnapshot], now: Double) {
        entries.removeAll { entry in
            guard now - entry.closedAt > Self.grace else { return false }
            return !sessions.contains { Self.isClosedProcess(entry, $0) || entry.sessionId == $0.sessionId }
        }
    }

    /// pid は使い回されるので、閉じた後に起動したプロセスは別物とみなす。
    private static func isClosedProcess(_ entry: Entry, _ snapshot: SessionSnapshot) -> Bool {
        guard let pid = entry.pid else { return false }
        return snapshot.pid == pid && snapshot.startedAt <= entry.closedAt
    }
}
