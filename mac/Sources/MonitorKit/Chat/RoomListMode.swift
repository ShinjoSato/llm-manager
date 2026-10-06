import Foundation

/// 左の一覧の見方（状態別のルームか、登録ディレクトリか）。
public enum RoomListMode: String, CaseIterable, Sendable {
    case rooms
    case directories

    public static let defaultsKey = "roomList.mode"

    /// 保存値が無い・知らない値なら「ルーム」に戻す。
    public init(saved: String?) {
        self = saved.flatMap(Self.init(rawValue:)) ?? .rooms
    }

    public var title: String {
        switch self {
        case .rooms: return "ルーム"
        case .directories: return "ディレクトリ"
        }
    }

    public var symbol: String {
        switch self {
        case .rooms: return "bubble.left.and.bubble.right"
        case .directories: return "folder"
        }
    }

    /// 検索で隠れた分も数える（どちらの一覧を見ていても気づけるように）。
    public static func attentionCount(_ statuses: [SessionStatus]) -> Int {
        statuses.filter { RoomPhase(status: $0) == .attention }.count
    }
}
