import Foundation

/// アプリの設定（`settings.json`）。管理対象のプロジェクトと GitHub のボードの紐づけを持つ。
public struct DeckSettings: Codable, Equatable, Sendable {
    /// このアプリが読み書きできる版。
    public static let currentVersion = 1

    public var version: Int
    public var projects: [ManagedProject]
    public var boards: [GitHubBoard]

    public init(version: Int = DeckSettings.currentVersion, projects: [ManagedProject] = [], boards: [GitHubBoard] = []) {
        self.version = version
        self.projects = projects
        self.boards = boards
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        projects = try c.decodeIfPresent([ManagedProject].self, forKey: .projects) ?? []
        boards = try c.decodeIfPresent([GitHubBoard].self, forKey: .boards) ?? []
    }

    /// 読み直した内容に、前から持っていたボードの画面用 id を引き継ぐ（owner + 番号が同じもの）。
    public func carryingBoardIDs(from old: DeckSettings) -> DeckSettings {
        var result = self
        var used = Set<UUID>()
        for index in result.boards.indices {
            guard let match = old.boards.first(where: { !used.contains($0.id) && $0.sameBoard(as: result.boards[index]) }) else { continue }
            used.insert(match.id)
            result.boards[index].id = match.id
        }
        return result
    }

    /// 人が読み書きしやすい形（整形・キー順固定）。
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

/// 管理対象のプロジェクト 1 件。
public struct ManagedProject: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var status: ProjectStatus
    public var note: String
    public var github: GitHubLink?

    public init(id: UUID = UUID(), name: String, path: String, status: ProjectStatus = .active, note: String = "",
                github: GitHubLink? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.status = status
        self.note = note
        self.github = github
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        status = try c.decode(ProjectStatus.self, forKey: .status)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        github = try c.decodeIfPresent(GitHubLink.self, forKey: .github)
    }

    /// フォルダから作る（表示名はフォルダ名）。
    public static func folder(_ path: String) -> ManagedProject {
        let clean = (path as NSString).standardizingPath
        return ManagedProject(name: (clean as NSString).lastPathComponent, path: clean)
    }
}

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    case active, paused, archived

    public var label: String {
        switch self {
        case .active: return "進行中"
        case .paused: return "休止"
        case .archived: return "保管"
        }
    }

    /// 旧 TSV / projects.json の自由な文字列から読む（知らない値は進行中とみなす）。
    public static func lenient(_ raw: String) -> ProjectStatus {
        ProjectStatus(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .active
    }
}

/// プロジェクトとリポジトリ・GitHub Project（ボード）の紐づけ。
public struct GitHubLink: Codable, Equatable, Sendable {
    public var owner: String
    public var repo: String?
    public var projectNumber: Int?

    public init(owner: String, repo: String? = nil, projectNumber: Int? = nil) {
        self.owner = owner
        self.repo = repo
        self.projectNumber = projectNumber
    }
}

/// リポジトリに紐づかないボード（複数リポジトリを横断するもの等）。
public struct GitHubBoard: Codable, Equatable, Identifiable, Sendable {
    /// 画面で行を見分けるためだけの印（ファイルには書かない）。
    public var id = UUID()
    public var name: String
    public var owner: String
    public var number: Int

    public init(id: UUID = UUID(), name: String, owner: String, number: Int) {
        self.id = id
        self.name = name
        self.owner = owner
        self.number = number
    }

    private enum CodingKeys: String, CodingKey { case name, owner, number }

    public static func == (a: GitHubBoard, b: GitHubBoard) -> Bool {
        a.name == b.name && a.owner == b.owner && a.number == b.number
    }

    /// 同じボードか（owner の大文字小文字は区別しない）。
    public func sameBoard(as other: GitHubBoard) -> Bool {
        owner.caseInsensitiveCompare(other.owner) == .orderedSame && number == other.number
    }
}
