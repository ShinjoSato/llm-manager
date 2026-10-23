import Foundation

// `GET /v1/projects`（登録したプロジェクトとリンク。読むだけ）の型。仕様は mac/docs/remote-api.md。

/// プロジェクトの状態（mac の設定の `status`）。
public enum RemoteProjectStatus: String, LenientStringEnum {
    case active, paused, archived
    case unknown
    public static var unknownCase: RemoteProjectStatus { .unknown }

    public var label: String {
        switch self {
        case .active: return "進行中"
        case .paused: return "休止"
        case .archived: return "保管"
        case .unknown: return "不明"
        }
    }
}

/// リンクの種類（mac の `ProjectLinkKind` と同じ値。知らない値は「その他」）。
public enum RemoteLinkKind: String, LenientStringEnum, CaseIterable {
    case billing, dashboard, store, docs, other
    public static var unknownCase: RemoteLinkKind { .other }

    public var label: String {
        switch self {
        case .billing: return "請求"
        case .dashboard: return "ダッシュボード"
        case .store: return "ストア"
        case .docs: return "ドキュメント"
        case .other: return "その他"
        }
    }

    /// SF Symbol の名前（mac の一覧と同じ）。
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

/// GitHub の紐づけの要約（owner / リポジトリ / ボードの番号）。
public struct RemoteGitHubSummary: Codable, Sendable, Equatable {
    public var owner: String
    public var repo: String?
    public var projectNumber: Int?

    public init(owner: String, repo: String? = nil, projectNumber: Int? = nil) {
        self.owner = owner
        self.repo = repo
        self.projectNumber = projectNumber
    }

    /// `owner/repo #N` の形（無い部分は省く）。
    public var label: String {
        var text = owner
        if let repo, !repo.isEmpty { text += "/\(repo)" }
        if let projectNumber { text += " #\(projectNumber)" }
        return text
    }
}

/// プロジェクトのリンク 1 件（mac で開けると判定したものだけが届く）。
public struct RemoteProjectLink: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
    public var kind: RemoteLinkKind
    public var pinned: Bool
    public var note: String?

    public init(name: String, url: String, kind: RemoteLinkKind = .other, pinned: Bool = false, note: String? = nil) {
        self.name = name
        self.url = url
        self.kind = kind
        self.pinned = pinned
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case name, url, kind, pinned, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(String.self, forKey: .url)
        kind = try c.decodeIfPresent(RemoteLinkKind.self, forKey: .kind) ?? .other
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// 開いてよい URL（http / https で host があり、資格情報の無いもの）。iPhone も開く前に自分で確かめる。
    public var openableURL: URL? { Self.openableURL(url) }

    public static func openableURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    /// 一覧に添える接続先（host だけ。`www.` は落とす）。
    public var hostLabel: String {
        guard var host = openableURL?.host else { return url }
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

/// 登録したプロジェクト 1 件。フォルダのパスなど手元の情報は載せない。
public struct RemoteProject: Codable, Sendable, Equatable, Identifiable {
    /// 設定の id（UUID の文字列）。
    public var id: String
    public var name: String
    public var status: RemoteProjectStatus
    public var github: RemoteGitHubSummary?
    /// 設定の順。
    public var links: [RemoteProjectLink]
    /// このプロジェクトのルーム（要対応 → 稼働中 → 待機、終了したものも含む）。`RemoteRoom.id` と同じ値。
    public var roomIds: [String]

    public init(id: String, name: String, status: RemoteProjectStatus, github: RemoteGitHubSummary? = nil,
                links: [RemoteProjectLink] = [], roomIds: [String] = []) {
        self.id = id
        self.name = name
        self.status = status
        self.github = github
        self.links = links
        self.roomIds = roomIds
    }

    private enum CodingKeys: String, CodingKey { case id, name, status, github, links, roomIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decodeIfPresent(RemoteProjectStatus.self, forKey: .status) ?? .unknown
        github = try c.decodeIfPresent(RemoteGitHubSummary.self, forKey: .github)
        links = try c.decodeIfPresent([RemoteProjectLink].self, forKey: .links) ?? []
        roomIds = try c.decodeIfPresent([String].self, forKey: .roomIds) ?? []
    }

    public var isActive: Bool { status == .active }

    /// ピン留めしたものを先に（それぞれの中は設定の順）。
    public var linksPinnedFirst: [RemoteProjectLink] {
        links.filter(\.pinned) + links.filter { !$0.pinned }
    }
}

/// `GET /v1/projects` の応答。並びは mac の「ディレクトリ」と同じ（進行中 → 休止・保管、それぞれ設定の順）。
public struct RemoteProjectList: Codable, Sendable, Equatable {
    public var projects: [RemoteProject]

    public init(projects: [RemoteProject]) {
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey { case projects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([RemoteProject].self, forKey: .projects) ?? []
    }

    public func project(_ id: String) -> RemoteProject? { projects.first { $0.id == id } }

    public var active: [RemoteProject] { projects.filter(\.isActive) }
    public var inactive: [RemoteProject] { projects.filter { !$0.isActive } }

    /// 横断のリンク一覧（リンクのあるプロジェクトだけ・プロジェクトは並びの順・中はピンを先頭に）。
    public var linkSections: [RemoteProject] {
        projects.filter { !$0.links.isEmpty }.map { project in
            var sorted = project
            sorted.links = project.linksPinnedFirst
            return sorted
        }
    }

    /// プロジェクトのルームのうち、今の一覧にあるもの（並びはプロジェクトの順）。
    public static func rooms(of project: RemoteProject, in rooms: [RemoteRoom]) -> [RemoteRoom] {
        let byId = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return project.roomIds.compactMap { byId[$0] }
    }
}
