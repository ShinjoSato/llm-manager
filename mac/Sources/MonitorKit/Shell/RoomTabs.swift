import Foundation

/// ルームの中央のタブ。
public enum RoomTab: String, CaseIterable, Sendable {
    case claude
    case terminal

    public var label: String {
        switch self {
        case .claude: return "Claude"
        case .terminal: return "ターミナル"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: return "bubble.left.and.bubble.right"
        case .terminal: return "terminal"
        }
    }
}

/// ルームごとに最後に開いていたタブ（無ければ Claude）。
public struct RoomTabMemory<Room: Hashable & Sendable>: Sendable, Equatable {
    private var tabs: [Room: RoomTab] = [:]

    public init() {}

    public func tab(for room: Room) -> RoomTab { tabs[room] ?? .claude }

    public mutating func set(_ tab: RoomTab, for room: Room) {
        tabs[room] = tab == .claude ? nil : tab
    }

    /// 引き継ぎでルームの id が変わった。
    public mutating func move(from old: Room, to new: Room) {
        guard old != new, let tab = tabs.removeValue(forKey: old) else { return }
        tabs[new] = tab
    }

    public mutating func forget(_ room: Room) {
        tabs[room] = nil
    }
}

/// 1 つの端末を出せる場所（メインと別ウィンドウ）のうち、実際に出す 1 か所。NSView は同時に 2 か所へ置けないため。
public struct TerminalHostOwner<Host: Hashable & Sendable>: Sendable, Equatable {
    /// ウィンドウに載っている場所（最後に名乗り出た順）。
    public private(set) var hosts: [Host] = []

    public init() {}

    /// 端末を出している場所（最後に名乗り出たもの）。
    public var owner: Host? { hosts.last }

    /// 見え始めた・前に出た・「ここに表示」を押した場所が名乗り出る。
    public mutating func claim(_ host: Host) {
        hosts.removeAll { $0 == host }
        hosts.append(host)
    }

    /// ウィンドウから外れた場所。出していたなら、残りのうち最後に名乗り出たものへ移る。
    public mutating func release(_ host: Host) {
        hosts.removeAll { $0 == host }
    }
}
