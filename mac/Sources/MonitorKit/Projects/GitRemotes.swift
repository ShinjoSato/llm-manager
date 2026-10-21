import Foundation

/// git の remote から読んだ GitHub のリポジトリ（設定画面の GitHub の候補）。
public struct GitHubRemoteCandidate: Equatable, Sendable {
    /// remote の名前（origin 等）。
    public var remote: String
    public var owner: String
    public var repo: String

    public init(remote: String, owner: String, repo: String) {
        self.remote = remote
        self.owner = owner
        self.repo = repo
    }
}

/// フォルダの git の設定（`.git/config`）を読むだけで remote を拾う（`git` は実行しない）。
public enum GitRemotes {
    /// 読む設定ファイルの大きさの上限。
    static let maxConfigBytes = 256 * 1024
    /// `.git` ファイル・`commondir` の大きさの上限。
    static let maxPointerBytes = 4 * 1024

    public struct Remote: Equatable, Sendable {
        public var name: String
        public var url: String
    }

    /// GitHub のリポジトリの候補（origin を先に、残りは設定の順。同じリポジトリは 1 つだけ）。
    public static func githubCandidates(projectPath: String) -> [GitHubRemoteCandidate] {
        guard let config = configPath(projectPath: projectPath), let text = readSmallFile(config, limit: maxConfigBytes) else { return [] }
        return githubCandidates(remotes: remotes(inConfig: text))
    }

    public static func githubCandidates(remotes: [Remote]) -> [GitHubRemoteCandidate] {
        let ordered = remotes.filter { $0.name == "origin" } + remotes.filter { $0.name != "origin" }
        var seen = Set<String>()
        return ordered.compactMap { remote in
            guard let (owner, repo) = githubRepository(fromURL: remote.url),
                  seen.insert("\(owner)/\(repo)".lowercased()).inserted else { return nil }
            return GitHubRemoteCandidate(remote: remote.name, owner: owner, repo: repo)
        }
    }

    /// remote の設定のあるファイル。`.git` がファイルなら `gitdir:` を辿り、共通の `commondir` があればそちらを読む。
    public static func configPath(projectPath: String) -> String? {
        let dotGit = (projectPath as NSString).appendingPathComponent(".git")
        var st = stat()
        guard lstat(dotGit, &st) == 0 else { return nil }
        let gitDir: String
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            gitDir = dotGit
        case S_IFLNK:
            // フォルダの外へ出るリンクは辿らない。
            guard let real = FilePaths.realPath(dotGit), let realProject = FilePaths.realPath(projectPath),
                  real.hasPrefix(realProject + "/"), FilePaths.isDirectory(real) else { return nil }
            gitDir = real
        case S_IFREG:
            guard let text = readSmallFile(dotGit, limit: maxPointerBytes),
                  let pointer = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            gitDir = absolute(target, from: projectPath)
        default:
            return nil
        }
        var configDir = gitDir
        if let common = readSmallFile((gitDir as NSString).appendingPathComponent("commondir"), limit: maxPointerBytes)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            configDir = absolute(common, from: gitDir)
        }
        return (configDir as NSString).appendingPathComponent("config")
    }

    /// `[remote "name"]` の `url`（remote ごとに最初のもの・ファイルの順）。
    public static func remotes(inConfig text: String) -> [Remote] {
        var result: [Remote] = []
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") {
                current = remoteName(fromSection: line)
                continue
            }
            guard let name = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url", !result.contains(where: { $0.name == name }) else { continue }
            let value = unquote(String(line[line.index(after: eq)...]))
            if !value.isEmpty { result.append(Remote(name: name, url: value)) }
        }
        return result
    }

    /// github.com の URL（https / http / git / ssh:// / `git@github.com:owner/repo`）から owner と repo を取る。
    public static func githubRepository(fromURL raw: String) -> (owner: String, repo: String)? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        var path: Substring
        if let scheme = url.range(of: "://") {
            let allowed: Set<String> = ["https", "http", "ssh", "git", "git+ssh", "ssh+git"]
            guard allowed.contains(url[..<scheme.lowerBound].lowercased()) else { return nil }
            let rest = url[scheme.upperBound...]
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = rest[..<slash]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            if let colon = authority.firstIndex(of: ":") { authority = authority[..<colon] }
            host = authority
            path = rest[slash...]
        } else {
            // scp 風の `user@host:path`（`:` より前に `/` があればローカルのパス）。
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            var authority = url[..<colon]
            if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
            host = authority
            path = url[url.index(after: colon)...]
        }
        guard ["github.com", "www.github.com"].contains(host.lowercased()) else { return nil }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.lowercased().hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]), repo = String(parts[1])
        guard SettingsValidation.ownerProblem(owner) == nil, SettingsValidation.repoProblem(repo) == nil else { return nil }
        return (owner, repo)
    }

    /// `[remote "origin"]` / 古い形の `[remote.origin]` から名前を取る（remote 以外は nil）。
    private static func remoteName(fromSection line: String) -> String? {
        guard let close = line.firstIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        if let quote = inner.firstIndex(of: "\"") {
            guard inner[..<quote].trimmingCharacters(in: .whitespaces).lowercased() == "remote" else { return nil }
            let name = inner[inner.index(after: quote)...]
            guard let end = name.lastIndex(of: "\"") else { return nil }
            let value = String(name[..<end])
            return value.isEmpty ? nil : value
        }
        let parts = inner.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "remote" else { return nil }
        return String(parts[1])
    }

    /// 値の前後の空白・引用符と、引用符の外の `#` `;` 以降を落とす。
    private static func unquote(_ raw: String) -> String {
        var result = ""
        var quoted = false
        for ch in raw {
            if ch == "\"" { quoted.toggle(); continue }
            if !quoted, ch == "#" || ch == ";" { break }
            result.append(ch)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func absolute(_ path: String, from base: String) -> String {
        let joined = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    /// 通常のファイル（リンクでない）で、上限以下の時だけ読む。
    private static func readSmallFile(_ path: String, limit: Int) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= off_t(limit),
              let data = FileManager.default.contents(atPath: path), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
