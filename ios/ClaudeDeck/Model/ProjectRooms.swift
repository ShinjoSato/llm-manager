import DeckCore

/// ディレクトリの行に添えるルームの様子（mac のディレクトリの行と同じ数え方）。
enum ProjectRooms {
    /// 終了していないルームの数。
    static func liveCount(_ rooms: [RemoteRoom]) -> Int {
        rooms.filter { $0.status != .stopped }.count
    }

    /// 終了していないルームのうち、いちばん急ぐ状態（無ければ nil）。
    static func urgentStatus(_ rooms: [RemoteRoom]) -> SessionStatus? {
        rooms.map(\.status).filter { $0 != .stopped }.min { urgency($0) < urgency($1) }
    }

    /// 小さいほど急ぐ。
    static func urgency(_ status: SessionStatus) -> Int {
        switch status {
        case .permission: return 0
        case .waiting: return 1
        case .error: return 2
        case .working: return 3
        case .idle: return 4
        case .unknown: return 5
        case .stopped: return 6
        }
    }
}
