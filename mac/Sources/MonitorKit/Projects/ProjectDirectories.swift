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

/// 「ディレクトリ」の一覧の 1 行（登録プロジェクト 1 つと、そこに当たるルーム）。
public struct ProjectDirectory: Sendable, Equatable, Identifiable {
    public var project: ManagedProject
    /// 要対応 → 稼働中 → 待機（終了も含む）、各段は新しく動いた順。終了したルームも詳細のスレッド一覧に出すため含める。
    public var ids: [String]
    /// 終了していないルームの数。
    public var liveCount: Int
    /// 終了していないルームのうちいちばん急ぐ状態（無ければ nil）。
    public var urgentStatus: SessionStatus?

    public var id: UUID { project.id }
    public var isActive: Bool { project.status == .active }
}

/// 「ディレクトリ」の一覧の 1 段。一覧は 1 本の ForEach で描く。
public enum ProjectDirectoryEntry: Sendable, Equatable, Identifiable {
    case directory(ProjectDirectory)
    /// 休止・保管のプロジェクトの見出し（件数はその下の行数）。
    case inactiveHeader(count: Int)

    public var id: String {
        switch self {
        case .directory(let directory): return "d-\(directory.id.uuidString)"
        case .inactiveHeader: return "inactive"
        }
    }
}

public enum ProjectDirectories {
    public static let inactiveTitle = "休止・保管"

    /// 設定の順で全プロジェクトを並べ、進行中を上・休止と保管を下にまとめる。ルームは全プロジェクトのうちいちばん深い一致へ入れる。
    public static func directories(projects: [ManagedProject], rooms: [ProjectRoomKey]) -> [ProjectDirectory] {
        var members: [UUID: [RoomKey]] = [:]
        for room in rooms {
            if let project = ProjectMatcher.project(for: room.cwd, in: projects) {
                members[project.id, default: []].append(room.key)
            }
        }
        var seen = Set<UUID>()
        let unique = projects.filter { seen.insert($0.id).inserted }
        let ordered = unique.filter { $0.status == .active } + unique.filter { $0.status != .active }
        return ordered.map { project in
            let keys = members[project.id] ?? []
            let live = keys.filter { $0.status != .stopped }
            return ProjectDirectory(project: project,
                                    ids: RoomGrouping.group(keys).flatMap(\.ids),
                                    liveCount: live.count,
                                    urgentStatus: live.map(\.status).min { urgency($0) < urgency($1) })
        }
    }

    /// 名前とパスで絞る（空白区切りの語をすべて含むもの）。
    public static func filter(_ directories: [ProjectDirectory], query: String) -> [ProjectDirectory] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return directories }
        return directories.filter { directory in
            let haystack = "\(directory.project.name) \(directory.project.path)"
            return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .widthInsensitive]) != nil }
        }
    }

    /// 進行中の行のあとに、休止・保管があれば見出しを挟んで並べる。
    public static func entries(_ directories: [ProjectDirectory]) -> [ProjectDirectoryEntry] {
        let active = directories.filter(\.isActive)
        let inactive = directories.filter { !$0.isActive }
        var result = active.map(ProjectDirectoryEntry.directory)
        if !inactive.isEmpty {
            result.append(.inactiveHeader(count: inactive.count))
            result += inactive.map(ProjectDirectoryEntry.directory)
        }
        return result
    }

    /// 行に出すパスの末尾（名前と同じ最後の要素だけでは場所が分からないので親も添える）。
    public static func pathTail(_ path: String, components: Int = 2) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return path }
        let tail = parts.suffix(components).joined(separator: "/")
        return parts.count > components ? "…/\(tail)" : "/\(tail)"
    }

    /// 急ぎ具合（小さいほど急ぐ）。
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
}
