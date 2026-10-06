import Foundation

/// ルームの作業ディレクトリから、設定のプロジェクトを引く。
public enum ProjectMatcher {
    /// cwd がプロジェクトの path と一致するか配下にあるもののうち、いちばん深いもの。
    public static func project(for cwd: String, in projects: [ManagedProject]) -> ManagedProject? {
        guard let target = normalized(cwd) else { return nil }
        var best: (project: ManagedProject, depth: Int)?
        for project in projects {
            guard let base = normalized(project.path), contains(base, target) else { continue }
            let depth = base == "/" ? 0 : base.split(separator: "/").count
            if best == nil || depth > best!.depth { best = (project, depth) }
        }
        return best?.project
    }

    /// 比べる形にそろえる（`.` `..` と末尾のスラッシュを落とす）。絶対パスでなければ nil。
    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var clean = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false)
        while clean.count > 1 && clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }

    /// 区切りの位置で比べる（`/a/b` が `/a/bc` に当たらないため）。
    static func contains(_ base: String, _ target: String) -> Bool {
        target == base || base == "/" || target.hasPrefix(base + "/")
    }
}

/// GitHub のアカウントの種類。ボードの URL の形が変わる。
public enum GitHubOwnerKind: String, Sendable {
    case user = "User"
    case organization = "Organization"
}

/// 見出しの「GitHub」から開く先。
public enum GitHubDestination: Equatable, Sendable {
    case board(owner: String, number: Int)
    case repository(owner: String, repo: String)

    /// 紐づけから開ける先（ボードが先）。検証に通らない値は含めない。
    public static func all(for link: GitHubLink) -> [GitHubDestination] {
        var result: [GitHubDestination] = []
        guard SettingsValidation.ownerProblem(link.owner) == nil else { return result }
        if let number = link.projectNumber, number > 0 { result.append(.board(owner: link.owner, number: number)) }
        if let repo = link.repo, SettingsValidation.repoProblem(repo) == nil {
            result.append(.repository(owner: link.owner, repo: repo))
        }
        return result
    }

    public var owner: String {
        switch self {
        case .board(let owner, _), .repository(let owner, _): return owner
        }
    }

    public var menuTitle: String {
        switch self {
        case .board(_, let number): return "Project ボードを開く（#\(number)）"
        case .repository(let owner, let repo): return "リポジトリを開く（\(owner)/\(repo)）"
        }
    }

    public var help: String {
        switch self {
        case .board(let owner, let number): return "GitHub Project を開く: \(owner) #\(number)"
        case .repository(let owner, let repo): return "GitHub のリポジトリを開く: \(owner)/\(repo)"
        }
    }

    /// 開く URL。ボードは owner の種類が分からなければ個人の形にする。
    public func url(ownerKind: GitHubOwnerKind?) -> URL? {
        switch self {
        case .board(let owner, let number):
            return GitHubURLs.board(owner: owner, number: number, kind: ownerKind ?? .user)
        case .repository(let owner, let repo):
            return GitHubURLs.repository(owner: owner, repo: repo)
        }
    }
}

/// GitHub の URL の組み立て。値が不正なら nil（開かない）。
public enum GitHubURLs {
    public static func board(owner: String, number: Int, kind: GitHubOwnerKind) -> URL? {
        guard number > 0, SettingsValidation.ownerProblem(owner) == nil, let owner = segment(owner) else { return nil }
        let scope = kind == .organization ? "orgs" : "users"
        return URL(string: "https://github.com/\(scope)/\(owner)/projects/\(number)")
    }

    public static func repository(owner: String, repo: String) -> URL? {
        guard SettingsValidation.ownerProblem(owner) == nil, SettingsValidation.repoProblem(repo) == nil,
              let owner = segment(owner), let repo = segment(repo) else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)")
    }

    /// owner の種類を引く公開 API（認証なし）。
    public static func userAPI(owner: String) -> URL? {
        guard SettingsValidation.ownerProblem(owner) == nil, let owner = segment(owner) else { return nil }
        return URL(string: "https://api.github.com/users/\(owner)")
    }

    /// `/users/<owner>` の応答から種類を読む。
    public static func ownerKind(status: Int, body: Data) -> GitHubOwnerKind? {
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        return GitHubOwnerKind(rawValue: type)
    }

    /// 検証済みでも区切りや `?` `#` が混ざらないよう、1 区間としてエンコードする。
    static func segment(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else { return nil }
        return encoded
    }
}

/// owner の種類を GitHub に問い合わせ、アプリが動いている間は覚えておく。
@MainActor
public final class GitHubOwnerKindResolver {
    public typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: Data)

    public static let defaultTimeout: Duration = .seconds(3)

    private let fetch: Fetch
    private let timeout: Duration
    private var cache: [String: GitHubOwnerKind] = [:]
    private var inFlight: [String: Task<GitHubOwnerKind?, Never>] = [:]

    public init(timeout: Duration = GitHubOwnerKindResolver.defaultTimeout,
                fetch: @escaping Fetch = GitHubOwnerKindResolver.urlSessionFetch) {
        self.timeout = timeout
        self.fetch = fetch
    }

    public func cachedKind(of owner: String) -> GitHubOwnerKind? { cache[owner.lowercased()] }

    /// 取れなければ nil（覚えない。次に押した時に引き直す）。
    public func kind(of owner: String) async -> GitHubOwnerKind? {
        let key = owner.lowercased()
        if let known = cache[key] { return known }
        if let running = inFlight[key] { return await running.value }
        guard let url = GitHubURLs.userAPI(owner: owner) else { return nil }
        let fetch = fetch, timeout = timeout
        let task = Task<GitHubOwnerKind?, Never> {
            await Self.race(timeout: timeout) {
                guard let (status, body) = try? await fetch(url) else { return nil }
                return GitHubURLs.ownerKind(status: status, body: body)
            }
        }
        inFlight[key] = task
        let kind = await task.value
        inFlight[key] = nil
        if let kind { cache[key] = kind }
        return kind
    }

    /// 取得が取り消しに応じなくても、時間切れで先に返す。
    nonisolated static func race(timeout: Duration,
                                 _ operation: @escaping @Sendable () async -> GitHubOwnerKind?) async -> GitHubOwnerKind? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
            let work = Task {
                once.resume(await operation())
                timer.cancel()
            }
            // 時間切れの後も取得を走らせ続けない。
            Task {
                _ = await timer.result
                work.cancel()
            }
        }
    }

    public nonisolated static let urlSessionFetch: Fetch = { url in
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("claude-deck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<GitHubOwnerKind?, Never>?

    init(_ continuation: CheckedContinuation<GitHubOwnerKind?, Never>) { self.continuation = continuation }

    func resume(_ value: GitHubOwnerKind?) {
        let pending = lock.withLock { () -> CheckedContinuation<GitHubOwnerKind?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
