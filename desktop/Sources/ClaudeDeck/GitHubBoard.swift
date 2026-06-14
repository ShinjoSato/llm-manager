import Foundation

/// 管理対象名と GitHub Project（ボード）の紐づけ1件。
struct BoardMapping {
    let name: String
    let owner: String
    let number: String
    let repo: String
    let url: String
}

/// ボード上の1アイテム（Issue / Draft）。
struct BoardItem {
    let number: Int?
    let title: String
    let status: String
    let repo: String
    let assignee: String
    let url: String?
}

enum GitHubBoardError: Error {
    case ghFailed(String)
    case parseFailed
}

/// `projects/github-projects.tsv` の読み込みと `gh` によるボード取得。
enum GitHubBoard {

    // MARK: - マッピング表

    private static func mappingURL() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["CLAUDE_DECK_GH_PROJECTS"],
           fm.fileExists(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("projects/github-projects.tsv")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        let fallback = "/Users/shinjo/project/ai-manager/projects/github-projects.tsv"
        return fm.fileExists(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil
    }

    static func loadMappings() -> [BoardMapping] {
        guard let url = mappingURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var result: [BoardMapping] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let c = rawLine.components(separatedBy: "\t")
            guard c.count >= 3 else { continue }
            result.append(BoardMapping(
                name: c[0].trimmingCharacters(in: .whitespaces),
                owner: c[1].trimmingCharacters(in: .whitespaces),
                number: c[2].trimmingCharacters(in: .whitespaces),
                repo: c.count >= 4 ? c[3].trimmingCharacters(in: .whitespaces) : "",
                url: c.count >= 5 ? c[4].trimmingCharacters(in: .whitespaces) : ""
            ))
        }
        return result
    }

    /// プロジェクト名に対応するボードを返す（無ければ nil → GitHub タブは出さない）。
    static func mapping(forProjectNamed name: String) -> BoardMapping? {
        loadMappings().first { $0.name == name }
    }

    /// プロジェクトに対応するボードを返す。
    /// 解決順: そのエントリに保存された GitHub 参照（owner/number）→ github-projects.tsv（名前一致）。
    static func mapping(forProject p: ManagedProject) -> BoardMapping? {
        if let owner = p.ghOwner, let number = p.ghNumber,
           !owner.isEmpty, !number.isEmpty {
            return BoardMapping(name: p.name, owner: owner, number: number, repo: "", url: "")
        }
        return mapping(forProjectNamed: p.name)
    }

    // MARK: - 入力解析 / git remote

    /// Project URL または "owner/番号" / 単なる番号（owner は git remote 補完）を解析する。
    /// 受理例:
    ///   https://github.com/users/ShinjoSato/projects/5
    ///   https://github.com/orgs/acme/projects/12
    ///   ShinjoSato/5
    ///   5  （ownerFallback がある場合）
    static func parseProjectRef(_ raw: String, ownerFallback: String?) -> (owner: String, number: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let g = firstMatch(#"github\.com/(?:users|orgs)/([^/]+)/projects/(\d+)"#, in: s),
           let owner = g[1], let num = g[2] {
            return (owner, num)
        }
        if let g = firstMatch(#"^([A-Za-z0-9._-]+)/(\d+)$"#, in: s),
           let owner = g[1], let num = g[2] {
            return (owner, num)
        }
        if s.range(of: #"^\d+$"#, options: .regularExpression) != nil,
           let owner = ownerFallback, !owner.isEmpty {
            return (owner, s)
        }
        return nil
    }

    /// ディレクトリの git remote origin から owner を推定する（無ければ nil）。
    static func gitRemoteOwner(forPath path: String) -> String? {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        guard case .success(let data) = runLoginShell("git -C '\(escaped)' config --get remote.origin.url"),
              let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let g = firstMatch(#"github\.com[:/]([^/]+)/"#, in: url),
              let owner = g[1] else {
            return nil
        }
        return owner
    }

    /// 正規表現の最初のマッチを返す（[0]=全体, [1..]=各グループ。マッチ無しは nil）。
    private static func firstMatch(_ pattern: String, in text: String) -> [Int: String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range) else { return nil }
        var result: [Int: String] = [:]
        for i in 0..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                result[i] = String(text[r])
            }
        }
        return result
    }

    // MARK: - 取得（gh）

    /// `gh project item-list` を実行してアイテム一覧を取得する。
    /// ログインシェル経由で PATH（gh の場所）を継承する。完了は指定キューで呼ぶ。
    static func fetchItems(for mapping: BoardMapping,
                           on queue: DispatchQueue = .main,
                           completion: @escaping (Result<[BoardItem], GitHubBoardError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let cmd = "gh project item-list \(mapping.number) --owner \(mapping.owner) --limit 1000 --format json"
            let result = runLoginShell(cmd)
            switch result {
            case .failure(let error):
                queue.async { completion(.failure(error)) }
            case .success(let data):
                if let items = parse(data) {
                    queue.async { completion(.success(items)) }
                } else {
                    queue.async { completion(.failure(.parseFailed)) }
                }
            }
        }
    }

    private static func runLoginShell(_ command: String) -> Result<Data, GitHubBoardError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failure(.ghFailed("起動に失敗: \(error.localizedDescription)"))
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.ghFailed(msg.isEmpty ? "gh の実行に失敗（認証/スコープを確認）" : msg))
        }
        return .success(outData)
    }

    private static func parse(_ data: Data) -> [BoardItem]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        return items.map { it in
            let content = it["content"] as? [String: Any]
            let number = content?["number"] as? Int
            let title = (it["title"] as? String)
                ?? (content?["title"] as? String) ?? "(無題)"
            let status = (it["status"] as? String) ?? "(no status)"
            let repoFull = (content?["repository"] as? String) ?? ""
            let repo = repoFull.split(separator: "/").last.map(String.init) ?? ""
            let url = content?["url"] as? String

            var assignee = ""
            if let s = it["assignees"] as? String {
                assignee = s
            } else if let arr = it["assignees"] as? [String] {
                assignee = arr.joined(separator: ", ")
            } else if let arr = it["assignees"] as? [[String: Any]] {
                assignee = arr.compactMap { $0["login"] as? String }.joined(separator: ", ")
            }
            return BoardItem(number: number, title: title, status: status,
                             repo: repo, assignee: assignee, url: url)
        }
    }
}
