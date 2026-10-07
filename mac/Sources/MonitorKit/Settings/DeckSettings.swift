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
    /// LP やデザインなど、ルームの見出しから開くリンク（並びは配列の順）。
    public var links: [ProjectLink]
    /// LP の場所（無ければ自動で探す）。
    public var site: ProjectSite?
    /// 印のアイコン（SF Symbol 名。無ければ `ProjectBadge.defaultSymbol`）。
    public var icon: String?
    /// 印の色（`ProjectColor` のキー。無ければ名前から決める）。
    public var color: String?
    /// 形が読めずに捨てた `site`（警告に出すだけで、保存・比較には含めない）。
    public var ignoredSite = IgnoredField()

    private enum CodingKeys: String, CodingKey { case id, name, path, status, note, github, links, site, icon, color }

    public init(id: UUID = UUID(), name: String, path: String, status: ProjectStatus = .active, note: String = "",
                github: GitHubLink? = nil, links: [ProjectLink] = [], site: ProjectSite? = nil,
                icon: String? = nil, color: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.status = status
        self.note = note
        self.github = github
        self.links = links
        self.site = site
        self.icon = icon
        self.color = color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        status = try c.decode(ProjectStatus.self, forKey: .status)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        github = try c.decodeIfPresent(GitHubLink.self, forKey: .github)
        links = try c.decodeIfPresent([ProjectLink].self, forKey: .links) ?? []
        // 手で書いた `site` の形が違っても、設定全体を読めなくしない。
        if c.contains(.site), (try? c.decodeNil(forKey: .site)) != true {
            site = try? c.decode(ProjectSite.self, forKey: .site)
            ignoredSite.isSet = site == nil
        } else {
            site = nil
        }
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    /// `links` は無い時だけ出さない（手で書いたファイルの形を変えないため）。`site` / `icon` / `color` も無ければ書かない。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(status, forKey: .status)
        try c.encode(note, forKey: .note)
        try c.encodeIfPresent(github, forKey: .github)
        if !links.isEmpty { try c.encode(links, forKey: .links) }
        try c.encodeIfPresent(site, forKey: .site)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(color, forKey: .color)
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

/// プロジェクトに紐づく外部のリンク（LP・デザイン・ドキュメント等）。見出しの「リンク」から開く。
public struct ProjectLink: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    /// 種類（無ければ「その他」として扱う）。
    public var kind: ProjectLinkKind?

    public init(name: String, url: String, kind: ProjectLinkKind? = nil) {
        self.name = name
        self.url = url
        self.kind = kind
    }

    /// 画面で使う種類（無ければその他）。
    public var resolvedKind: ProjectLinkKind { kind ?? .other }

    private enum CodingKeys: String, CodingKey { case name, url, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        kind = try c.decodeIfPresent(ProjectLinkKind.self, forKey: .kind)
    }

    /// `kind` は無い時だけ出さない（手で書いたファイルの形を変えないため）。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(kind, forKey: .kind)
    }
}

/// リンクの種類。アイコンで見分け、メニューを区切る。知らない値は「その他」として読む。
public enum ProjectLinkKind: String, LenientStringEnum, CaseIterable {
    case billing, dashboard, store, docs, other

    public static let unknownCase = ProjectLinkKind.other

    public var label: String {
        switch self {
        case .billing: return "請求"
        case .dashboard: return "ダッシュボード"
        case .store: return "ストア"
        case .docs: return "ドキュメント"
        case .other: return "その他"
        }
    }

    /// SF Symbol の名前。
    public var symbol: String {
        switch self {
        case .billing: return "creditcard"
        case .dashboard: return "gauge"
        case .store: return "storefront"
        case .docs: return "book"
        case .other: return "link"
        }
    }
}

/// 読み込み時の印。設定の中身ではないので、比較では常に等しい。
public struct IgnoredField: Equatable, Sendable {
    public var isSet = false

    public init(isSet: Bool = false) {
        self.isSet = isSet
    }

    public static func == (a: IgnoredField, b: IgnoredField) -> Bool { true }
}

/// LP（静的書き出しのあるサイト）の場所。`path` はプロジェクトからの相対パス（`.` はプロジェクト直下）。
public struct ProjectSite: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
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
