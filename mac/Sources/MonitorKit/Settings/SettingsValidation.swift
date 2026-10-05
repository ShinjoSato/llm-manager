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
        return problems
    }

    public static func boardProblems(_ board: GitHubBoard) -> [String] {
        var problems: [String] = []
        if board.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("名前を入れてください") }
        if let p = ownerProblem(board.owner) { problems.append(p) }
        if board.number <= 0 { problems.append("Project 番号は 1 以上の整数です") }
        return problems
    }

    /// 設定全体の問題（何件目の何か）。空なら問題なし。
    public static func problems(_ settings: DeckSettings) -> [String] {
        var result: [String] = []
        var paths = Set<String>()
        for project in settings.projects {
            for p in projectProblems(project) { result.append("「\(project.name)」: \(p)") }
            if !paths.insert(project.path).inserted { result.append("「\(project.name)」: 同じパスのプロジェクトが他にもあります") }
        }
        for board in settings.boards {
            for p in boardProblems(board) { result.append("ボード「\(board.name)」: \(p)") }
        }
        return result
    }
}
