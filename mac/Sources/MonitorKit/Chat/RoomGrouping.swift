import Foundation

/// ルーム一覧のグループ。
public enum RoomPhase: Int, Sendable, CaseIterable, Comparable {
    /// 権限待ち・入力待ち（ユーザーの手が要る）。
    case attention
    case active
    case idle

    public init(status: SessionStatus) {
        switch status {
        case .permission, .waiting: self = .attention
        case .working: self = .active
        case .idle, .error, .stopped, .unknown: self = .idle
        }
    }

    public var title: String {
        switch self {
        case .attention: return "要対応"
        case .active: return "稼働中"
        case .idle: return "待機"
        }
    }

    public static func < (lhs: RoomPhase, rhs: RoomPhase) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 並べ替え・検索に要る分だけのルーム情報。
public struct RoomKey: Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: SessionStatus
    /// 最後に動いた時刻（epoch ミリ秒）。無ければ一番下へ。
    public var activityAt: Double?
    /// 検索対象（名前・ブランチ・タイトル等）。
    public var searchText: String

    public init(id: String, name: String, status: SessionStatus, activityAt: Double?, searchText: String) {
        self.id = id
        self.name = name
        self.status = status
        self.activityAt = activityAt
        self.searchText = searchText
    }
}

public enum RoomGrouping {
    /// 要対応 → 稼働中 → 待機 の順に、各グループ内は新しく動いた順（同時刻は名前順）。空のグループは返さない。
    public static func group(_ rooms: [RoomKey], query: String = "") -> [(phase: RoomPhase, ids: [String])] {
        let filtered = rooms.filter { matches($0, query: query) }
        return RoomPhase.allCases.compactMap { phase in
            let members = filtered
                .filter { RoomPhase(status: $0.status) == phase }
                .sorted(by: order)
            return members.isEmpty ? nil : (phase, members.map(\.id))
        }
    }

    static func order(_ a: RoomKey, _ b: RoomKey) -> Bool {
        let ta = a.activityAt ?? -1, tb = b.activityAt ?? -1
        if ta != tb { return ta > tb }
        if a.name != b.name { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return a.id < b.id
    }

    /// 空白区切りの語をすべて含むか（大文字小文字・全角半角を無視）。
    public static func matches(_ room: RoomKey, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return true }
        let haystack = "\(room.name) \(room.searchText)"
        return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
    }

    /// 未読数: そのセッションの応答（feed の message）のうち、最後に開いた時刻より後のもの。
    public static func unreadCount(feed: [FeedItem], sessionId: String, since: Double) -> Int {
        feed.reduce(0) { $0 + ($1.sessionId == sessionId && $1.kind == .message && $1.at > since ? 1 : 0) }
    }

    /// プロジェクト名から決まる色番号。`hashValue` はプロセスごとに変わるので自前の FNV-1a を使う。
    public static func colorIndex(for name: String, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(paletteSize))
    }

    /// アイコンに出す頭文字（英字は大文字）。
    public static func initial(of name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first else { return "?" }
        return String(first).uppercased()
    }
}
