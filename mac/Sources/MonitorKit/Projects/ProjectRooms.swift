import Foundation

/// 一覧の 1 ルーム分（並べ替え・検索の値 + プロジェクトの照合に使う作業ディレクトリ）。
public struct ProjectRoomKey: Sendable, Equatable {
    public var key: RoomKey
    public var cwd: String

    public init(key: RoomKey, cwd: String) {
        self.key = key
        self.cwd = cwd
    }
}

/// ルーム一覧の 1 枠（登録プロジェクト 1 つか、どれにも当たらない「その他」）。
public struct ProjectRoomSection: Sendable, Equatable, Identifiable {
    public static let otherId = "other"

    /// プロジェクトの id（UUID の文字列）か `otherId`。開閉の保存に使う。
    public var id: String
    public var name: String
    /// 「その他」は nil。
    public var project: ManagedProject?
    /// 要対応 → 稼働中 → 待機、各段は新しく動いた順。
    public var ids: [String]
    /// 中でいちばん急ぐ状態（空なら nil）。
    public var urgentStatus: SessionStatus?

    public var isOther: Bool { project == nil }
}

/// 一覧の 1 段（枠の見出し・行・空の枠の「スレッドなし」）。一覧は 1 本の ForEach で描く。
public enum ProjectRoomEntry: Sendable, Equatable, Identifiable {
    case header(ProjectRoomSection, collapsed: Bool)
    /// `last` は枠の最後の段か（枠の下の角を丸めるため）。
    case row(String, sectionId: String, last: Bool)
    case empty(sectionId: String)

    /// 行は枠をまたいでも同じ id のままにする（遅延スタックが移った行を描き直すように）。
    public var id: String {
        switch self {
        case .header(let section, _): return "p-\(section.id)"
        case .row(let key, _, _): return "r-\(key)"
        case .empty(let sectionId): return "e-\(sectionId)"
        }
    }
}

public enum ProjectRoomGrouping {
    /// active のプロジェクトごとに設定の順で枠を作り、どの active のプロジェクトにも当たらないルームは最後の「その他」へ（空なら出さない）。
    /// 検索中は一致するルームのある枠だけを返す。
    public static func sections(projects: [ManagedProject], rooms: [ProjectRoomKey], query: String = "") -> [ProjectRoomSection] {
        let active = projects.filter { $0.status == .active }
        var members: [UUID: [RoomKey]] = [:]
        var others: [RoomKey] = []
        for room in rooms where RoomGrouping.matches(room.key, query: query) {
            // 全プロジェクトで照合するのは「GitHub」ボタンと同じプロジェクトを指すため（いちばん深い一致が paused なら親の枠に入れない）。
            if let project = ProjectMatcher.project(for: room.cwd, in: projects), project.status == .active {
                members[project.id, default: []].append(room.key)
            } else {
                others.append(room.key)
            }
        }
        let searching = !query.split(whereSeparator: \.isWhitespace).isEmpty
        var result: [ProjectRoomSection] = []
        var seen = Set<UUID>()
        for project in active where seen.insert(project.id).inserted {
            let keys = members[project.id] ?? []
            if searching && keys.isEmpty { continue }
            result.append(section(id: project.id.uuidString, name: project.name, project: project, keys: keys))
        }
        if !others.isEmpty {
            result.append(section(id: ProjectRoomSection.otherId, name: "その他", project: nil, keys: others))
        }
        return result
    }

    /// 枠を見出し + 行の 1 列に平らにする。畳んだ枠は見出しだけ。検索中は畳んだ枠も開く（一致を隠さないため）。
    public static func entries(_ sections: [ProjectRoomSection], collapsed: Set<String>, query: String = "") -> [ProjectRoomEntry] {
        let searching = !query.split(whereSeparator: \.isWhitespace).isEmpty
        return sections.flatMap { section -> [ProjectRoomEntry] in
            let isCollapsed = !searching && collapsed.contains(section.id)
            let header = ProjectRoomEntry.header(section, collapsed: isCollapsed)
            if isCollapsed { return [header] }
            if section.ids.isEmpty { return [header, .empty(sectionId: section.id)] }
            return [header] + section.ids.enumerated().map { index, key in
                .row(key, sectionId: section.id, last: index == section.ids.count - 1)
            }
        }
    }

    /// 見出しに出す順の急ぎ具合（小さいほど急ぐ）。
    public static func urgency(_ status: SessionStatus) -> Int {
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

    private static func section(id: String, name: String, project: ManagedProject?, keys: [RoomKey]) -> ProjectRoomSection {
        let ids = RoomGrouping.group(keys).flatMap(\.ids)
        let urgent = keys.map(\.status).min { urgency($0) < urgency($1) }
        return ProjectRoomSection(id: id, name: name, project: project, ids: ids, urgentStatus: urgent)
    }
}
