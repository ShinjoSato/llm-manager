import Foundation

/// 旧 TSV（registry.tsv / github-projects.tsv）と書き出した settings.json の取り込み。
/// 既にあるものは上書きせず、足りないものだけ足す。
public enum SettingsImport {
    public enum Format: Equatable, Sendable {
        case registryTSV
        case githubProjectsTSV
        case settingsJSON
    }

    public struct Summary: Equatable, Sendable {
        public var format: Format
        public var addedProjects = 0
        public var linkedGitHub = 0
        public var addedLinks = 0
        public var addedBoards = 0
        /// 既にあった・読めなかったため足さなかった行。
        public var skipped = 0
        /// repo 付きなのに同じ名前のプロジェクトが無く、取り込まなかった行。
        public var unmatched = 0
        /// 名前が空・URL が開ける形でないため足さなかったリンク。
        public var invalidLinks = 0

        public var message: String {
            var parts: [String] = []
            if addedProjects > 0 { parts.append("プロジェクト \(addedProjects) 件") }
            if linkedGitHub > 0 { parts.append("GitHub の紐づけ \(linkedGitHub) 件") }
            if addedLinks > 0 {
                parts.append(invalidLinks > 0 ? "リンク \(addedLinks) 件（不正 \(invalidLinks) 件は除外）" : "リンク \(addedLinks) 件")
            }
            if addedBoards > 0 { parts.append("ボード \(addedBoards) 件") }
            let added = parts.isEmpty ? "足したものはありません" : parts.joined(separator: "・") + "を足しました"
            var result = skipped > 0 ? "\(added)（既にある・読めない \(skipped) 件は飛ばしました）" : added
            if unmatched > 0 {
                result += "。リポジトリ付きで該当するプロジェクトが無い \(unmatched) 件は取り込んでいません（先に registry.tsv を読み込んでください）"
            }
            if addedLinks == 0, invalidLinks > 0 {
                result += "。名前が空・URL が http / https でないリンク \(invalidLinks) 件は取り込んでいません"
            }
            return result
        }
    }

    public enum Failure: Error, Equatable {
        case unknownFormat
        case unreadable(String)

        public var message: String {
            switch self {
            case .unknownFormat: return "取り込める形式ではありません（registry.tsv・github-projects.tsv・settings.json のいずれか）"
            case .unreadable(let reason): return reason
            }
        }
    }

    /// 中身から形式を決める。
    public static func detect(_ data: Data) -> Format? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return .settingsJSON }
        guard let first = rows(text).first else { return nil }
        if first.count >= 2, first[1].hasPrefix("/") { return .registryTSV }
        if first.count >= 3, isNumber(first[2]) { return .githubProjectsTSV }
        return nil
    }

    public static func merge(_ data: Data, into settings: DeckSettings) throws -> (DeckSettings, Summary) {
        guard let format = detect(data), let text = String(data: data, encoding: .utf8) else { throw Failure.unknownFormat }
        var merged = settings
        var summary = Summary(format: format)
        switch format {
        case .registryTSV:
            for cols in rows(text) {
                guard cols.count >= 2, !cols[0].isEmpty, cols[1].hasPrefix("/") else { summary.skipped += 1; continue }
                let project = ManagedProject(name: cols[0], path: (cols[1] as NSString).standardizingPath,
                                             status: .lenient(cols.count >= 3 ? cols[2] : ""),
                                             note: cols.count >= 4 ? cols[3] : "")
                addProject(project, to: &merged, summary: &summary)
            }
        case .githubProjectsTSV:
            for cols in rows(text) {
                guard cols.count >= 3, !cols[0].isEmpty, SettingsValidation.ownerProblem(cols[1]) == nil,
                      let number = Int(cols[2]), number > 0 else { summary.skipped += 1; continue }
                let rawRepo = cols.count >= 4 ? cols[3] : ""
                guard !rawRepo.isEmpty, rawRepo != "-" else {
                    addBoard(GitHubBoard(name: cols[0], owner: cols[1], number: number), to: &merged, summary: &summary)
                    continue
                }
                guard let repo = repoName(rawRepo) else { summary.skipped += 1; continue }
                // ボードとして入れると repo が落ちるので、プロジェクトが揃ってから読み直してもらう。
                guard let index = merged.projects.firstIndex(where: { $0.name == cols[0] }) else { summary.unmatched += 1; continue }
                guard merged.projects[index].github == nil else { summary.skipped += 1; continue }
                merged.projects[index].github = GitHubLink(owner: cols[1], repo: repo, projectNumber: number)
                summary.linkedGitHub += 1
            }
        case .settingsJSON:
            let incoming: DeckSettings
            switch SettingsFile.decode(data, name: "選んだファイル") {
            case .loaded(let s): incoming = s
            case .unreadable(let reason): throw Failure.unreadable(reason)
            case .missing: throw Failure.unknownFormat
            }
            for var project in incoming.projects {
                if let index = merged.projects.firstIndex(where: { $0.path == project.path }) {
                    var filled = false
                    if merged.projects[index].github == nil, let link = project.github {
                        merged.projects[index].github = link
                        summary.linkedGitHub += 1
                        filled = true
                    }
                    if merged.projects[index].site == nil, let site = project.site {
                        merged.projects[index].site = site
                        filled = true
                    }
                    if merged.projects[index].icon == nil, let icon = project.icon {
                        merged.projects[index].icon = icon
                        filled = true
                    }
                    if merged.projects[index].color == nil, let color = project.color {
                        merged.projects[index].color = color
                        filled = true
                    }
                    let added = addLinks(project.links, to: &merged.projects[index].links, summary: &summary)
                    if added > 0 {
                        summary.addedLinks += added
                        filled = true
                    }
                    if !filled { summary.skipped += 1 }
                    continue
                }
                if merged.projects.contains(where: { $0.id == project.id }) { project.id = UUID() }
                var links: [ProjectLink] = []
                _ = addLinks(project.links, to: &links, summary: &summary)
                project.links = links
                addProject(project, to: &merged, summary: &summary)
            }
            for board in incoming.boards { addBoard(board, to: &merged, summary: &summary) }
        }
        return (merged, summary)
    }

    private static func addProject(_ project: ManagedProject, to settings: inout DeckSettings, summary: inout Summary) {
        guard !settings.projects.contains(where: { $0.path == project.path }) else { summary.skipped += 1; return }
        settings.projects.append(project)
        summary.addedProjects += 1
    }

    /// 名前（前後の空白は除く）の無いものだけ末尾に足し、足した数を返す。名前が空・URL が開けないものは数えるだけで足さない。
    private static func addLinks(_ incoming: [ProjectLink], to links: inout [ProjectLink], summary: inout Summary) -> Int {
        var names = Set(links.map { $0.name.trimmingCharacters(in: .whitespaces) })
        var added = 0
        for link in incoming {
            guard SettingsValidation.projectLinkProblems(link).isEmpty else { summary.invalidLinks += 1; continue }
            guard names.insert(link.name.trimmingCharacters(in: .whitespaces)).inserted else { continue }
            links.append(link)
            added += 1
        }
        return added
    }

    private static func addBoard(_ board: GitHubBoard, to settings: inout DeckSettings, summary: inout Summary) {
        guard !settings.boards.contains(where: { $0.sameBoard(as: board) }) else { summary.skipped += 1; return }
        settings.boards.append(board)
        summary.addedBoards += 1
    }

    /// `owner/repo` か `repo` から名前を取る（使えない名前なら nil）。
    private static func repoName(_ raw: String) -> String? {
        let name = raw.split(separator: "/").last.map(String.init) ?? raw
        return SettingsValidation.repoProblem(name) == nil ? name : nil
    }

    /// `#` の行と空行を除いたタブ区切りの列（前後の空白は落とす）。
    static func rows(_ text: String) -> [[String]] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            return raw.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    private static func isNumber(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
