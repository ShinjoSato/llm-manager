import Foundation

/// 設定の入力の検証。画面の欄ごとの案内と、保存前の確認に使う。
public enum SettingsValidation {
    /// GitHub のユーザー / Organization 名: 英数字と途中のハイフン、39 文字まで。
    public static func ownerProblem(_ owner: String) -> String? {
        if owner.isEmpty { return "owner を入れてください" }
        guard owner.count <= 39,
              owner.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9]))*$"#, options: .regularExpression) != nil else {
            return "owner は英数字とハイフン（先頭・末尾・連続は不可）で 39 文字までです"
        }
        return nil
    }

    /// リポジトリ名: 英数字と `.` `_` `-`、100 文字まで（`.` と `..` は不可）。
    public static func repoProblem(_ repo: String) -> String? {
        if repo.isEmpty { return "リポジトリ名を入れてください" }
        guard repo.count <= 100, repo != ".", repo != "..",
              repo.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return "リポジトリ名は英数字と . _ - で 100 文字までです"
        }
        return nil
    }

    public static func numberProblem(_ number: Int?) -> String? {
        guard let number else { return nil }
        return number > 0 ? nil : "Project 番号は 1 以上の整数です"
    }

    /// 画面の文字欄から番号を読む。空は nil、数字でなければ 0（＝不正）として返す。
    public static func parseNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard trimmed.allSatisfy(\.isASCII), let value = Int(trimmed) else { return 0 }
        return value
    }

    public static func linkProblems(_ link: GitHubLink) -> [String] {
        var problems: [String] = []
        if let p = ownerProblem(link.owner) { problems.append(p) }
        if let repo = link.repo, let p = repoProblem(repo) { problems.append(p) }
        if let p = numberProblem(link.projectNumber) { problems.append(p) }
        if link.repo == nil && link.projectNumber == nil { problems.append("リポジトリか Project 番号のどちらかを入れてください") }
        return problems
    }

    public static func projectProblems(_ project: ManagedProject) -> [String] {
        var problems: [String] = []
        if project.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("名前を入れてください") }
        if !project.path.hasPrefix("/") { problems.append("パスは絶対パスにしてください") }
        if let link = project.github { problems += linkProblems(link) }
        for row in projectLinkRowProblems(project.links) { problems += row }
        if let site = project.site, let p = sitePathProblem(site.path) { problems.append(p) }
        return problems
    }

    /// サイトの場所: プロジェクトからの相対パスで、外を指さないもの。
    public static func sitePathProblem(_ path: String) -> String? {
        SiteLocator.normalizedRelativePath(path).failure
    }

    /// リンクの URL: http / https で host があるもの。
    public static func linkURLProblem(_ url: String) -> String? {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "URL を入れてください" }
        return ProjectLinks.url(from: url) == nil ? "URL は http:// か https:// で始まるアドレスにしてください" : nil
    }

    public static func projectLinkProblems(_ link: ProjectLink) -> [String] {
        var problems: [String] = []
        if link.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("リンクの名前を入れてください") }
        if let p = linkURLProblem(link.url) { problems.append(p) }
        return problems
    }

    /// 行ごとの問題。同じ名前が前の行にもあれば、後の行の問題にする。
    public static func projectLinkRowProblems(_ links: [ProjectLink]) -> [[String]] {
        var seen = Set<String>()
        return links.map { link in
            var problems = projectLinkProblems(link)
            let name = link.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.insert(name).inserted { problems.append("同じ名前のリンクが他にもあります") }
            return problems
        }
    }

    public static func boardProblems(_ board: GitHubBoard) -> [String] {
        var problems: [String] = []
        if board.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("名前を入れてください") }
        if let p = ownerProblem(board.owner) { problems.append(p) }
        if board.number <= 0 { problems.append("Project 番号は 1 以上の整数です") }
        return problems
    }

    /// 読めない扱いにする問題（画面の一覧・削除が id とパスで行を見分けるため、重複や相対パスがあると壊れる）。
    public static func blockingProblems(_ settings: DeckSettings) -> [String] {
        var result: [String] = []
        var ids = Set<UUID>()
        var paths = Set<String>()
        for project in settings.projects {
            if !ids.insert(project.id).inserted { result.append("「\(project.name)」: 同じ id（\(project.id.uuidString)）のプロジェクトが他にもあります") }
            if !project.path.hasPrefix("/") {
                result.append("「\(project.name)」: パスが絶対パスではありません（\(project.path)）")
            } else if !paths.insert(project.path).inserted {
                result.append("「\(project.name)」: 同じパスのプロジェクトが他にもあります")
            }
        }
        return result
    }

    /// 読めるが直した方がよいもの（名前が空・GitHub の文字種・番号など）。画面に警告として出す。
    public static func warnings(_ settings: DeckSettings) -> [String] {
        var result: [String] = []
        for project in settings.projects {
            if project.name.trimmingCharacters(in: .whitespaces).isEmpty { result.append("「\(project.path)」: 名前が空です") }
            if let link = project.github {
                for p in linkProblems(link) { result.append("「\(project.name)」の GitHub: \(p)") }
            }
            for (link, problems) in zip(project.links, projectLinkRowProblems(project.links)) {
                for p in problems { result.append("「\(project.name)」のリンク「\(link.name)」: \(p)") }
            }
            if let site = project.site, let p = sitePathProblem(site.path) { result.append("「\(project.name)」のサイト: \(p)") }
            if project.ignoredSite.isSet { result.append("「\(project.name)」のサイト: 形が正しくないため無視しました（{\"path\": \"相対パス\"} の形で書いてください）") }
        }
        for (index, board) in settings.boards.enumerated() {
            for p in boardProblems(board) { result.append("ボード「\(board.name)」: \(p)") }
            if settings.boards[..<index].contains(where: { $0.sameBoard(as: board) }) {
                result.append("ボード「\(board.name)」: 同じボード（\(board.owner) #\(board.number)）が他にもあります")
            }
        }
        return result
    }

    /// 設定全体の問題（読めないもの + 警告）。空なら問題なし。
    public static func problems(_ settings: DeckSettings) -> [String] {
        blockingProblems(settings) + warnings(settings)
    }
}
