import Foundation

/// 別ウィンドウで開いているルーム。ウィンドウごとの印（token）で持ち、同じルームは 1 枚のウィンドウにだけ出す。
public struct DetachedRooms<Room: Hashable & Sendable>: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let token: UUID
        public fileprivate(set) var room: Room
    }

    /// 開いた順。
    public private(set) var entries: [Entry] = []

    public init() {}

    public var rooms: [Room] { entries.map(\.room) }
    public var isEmpty: Bool { entries.isEmpty }

    public func token(for room: Room) -> UUID? {
        entries.first { $0.room == room }?.token
    }

    public func room(for token: UUID) -> Room? {
        entries.first { $0.token == token }?.room
    }

    /// `room` のウィンドウを開く。既に開いていればそのウィンドウの印を返す（`isNew` は false）。
    @discardableResult
    public mutating func open(_ room: Room, token: UUID = UUID()) -> (token: UUID, isNew: Bool) {
        if let existing = self.token(for: room) { return (existing, false) }
        entries.append(Entry(token: token, room: room))
        return (token, true)
    }

    public mutating func close(_ token: UUID) {
        entries.removeAll { $0.token == token }
    }

    /// ルームが別の id へ移った（引き継ぎ）。移し先が既に別のウィンドウにあれば、移し元のウィンドウの印を返す（重ねないよう閉じてもらう）。
    public mutating func retarget(from old: Room, to new: Room) -> UUID? {
        guard old != new, let index = entries.firstIndex(where: { $0.room == old }) else { return nil }
        if token(for: new) != nil {
            return entries.remove(at: index).token
        }
        entries[index].room = new
        return nil
    }
}

/// 会話を取得し既読にする対象の決め方。
public enum ShownSessions {
    /// メインに出している会話と別ウィンドウの会話の sessionId（この順・重複と nil を除く）。
    public static func sessionIds(main: String?, detached: [String?]) -> [String] {
        var seen: Set<String> = []
        return ([main] + detached).compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// 手元に持っておく会話の決め方。
public enum TranscriptRetention {
    /// 直近に開いた `kept` 件・取得中のもの・別ウィンドウで出しているもの（数に関わらず手放すと追記が止まる）。
    public static func keep(recent: [String], kept: Int, loading: Set<String>, pinned: Set<String>) -> Set<String> {
        Set(recent.suffix(max(0, kept))).union(loading).union(pinned)
    }
}
