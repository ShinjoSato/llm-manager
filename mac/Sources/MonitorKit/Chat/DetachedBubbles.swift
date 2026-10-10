import Foundation

/// 別ウィンドウで開いた吹き出しを指す鍵。transcript の項目の id は会話の中でだけ一意なので sessionId と組にする。
public struct BubbleKey: Hashable, Sendable {
    public let sessionId: String
    public let itemId: String

    public init(sessionId: String, itemId: String) {
        self.sessionId = sessionId
        self.itemId = itemId
    }
}

/// 開いた時点の吹き出しの写し。ルームが閉じても会話が流れても出し続けられるよう、本文と見出しを値で持つ。
public struct BubbleSnapshot: Sendable, Equatable {
    public let key: BubbleKey
    public let roomName: String
    /// Markdown の原文。
    public let text: String
    /// 発言の時刻（epoch ミリ秒）。
    public let at: Double?

    public init(key: BubbleKey, roomName: String, text: String, at: Double?) {
        self.key = key
        self.roomName = roomName
        self.text = text
        self.at = at
    }

    /// Claude の返答で本文があるものだけ写す（自分の発話・伝言・ツールの行は開かない）。
    public init?(entry: ChatEntry, sessionId: String?, roomName: String) {
        guard entry.role == .assistant, let sessionId,
              !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(key: BubbleKey(sessionId: sessionId, itemId: entry.id), roomName: roomName, text: entry.text, at: entry.at)
    }

    /// ウィンドウのタイトル（「ai-manager · 14:32」。時刻が無ければルーム名だけ）。
    public func title(time: String) -> String {
        time.isEmpty ? roomName : "\(roomName) · \(time)"
    }
}

/// 別ウィンドウで開いている吹き出し。ウィンドウごとの印（token）で持ち、同じ吹き出しは 1 枚のウィンドウにだけ出す。
public struct DetachedBubbles: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let token: UUID
        public let snapshot: BubbleSnapshot
    }

    /// 開いた順。
    public private(set) var entries: [Entry] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    public func token(for key: BubbleKey) -> UUID? {
        entries.first { $0.snapshot.key == key }?.token
    }

    public func snapshot(for token: UUID) -> BubbleSnapshot? {
        entries.first { $0.token == token }?.snapshot
    }

    /// 吹き出しのウィンドウを開く。既に開いていればそのウィンドウの印を返し、写しは最初のまま残す（`isNew` は false）。
    @discardableResult
    public mutating func open(_ snapshot: BubbleSnapshot, token: UUID = UUID()) -> (token: UUID, isNew: Bool) {
        if let existing = self.token(for: snapshot.key) { return (existing, false) }
        entries.append(Entry(token: token, snapshot: snapshot))
        return (token, true)
    }

    public mutating func close(_ token: UUID) {
        entries.removeAll { $0.token == token }
    }
}
