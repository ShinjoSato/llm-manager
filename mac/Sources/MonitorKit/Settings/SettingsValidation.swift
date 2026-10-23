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

    /// サイトの場所: プロジェクトからの相対パスで、外を指さないもの。
    public static func sitePathProblem(_ path: String) -> String? {
        SiteLocator.normalizedRelativePath(path).failure
    }

    /// リンクの URL: http / https で host があるもの。
    public static func linkURLProblem(_ url: String) -> String? {
        if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "URL を入れてください" }
        return ProjectLinks.url(from: url) == nil ? "URL は http:// か https:// で始まるアドレスにしてください" : nil
    }

    /// 毎月の確認の日: 1〜31 の整数だけ（無ければ確認しない）。
    public static func reminderDayProblem(_ day: Int?) -> String? {
        guard let day else { return nil }
        return (1...31).contains(day) ? nil : "毎月の確認の日は 1〜31 です"
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

    /// App Store のアプリの行ごとの問題（appId は数字だけ・同じ appId は後の行の問題にする）。
    public static func appStoreRowProblems(_ apps: [AppStoreAppLink]) -> [[String]] {
        var seen = Set<String>()
        return apps.map { app in
            var problems: [String] = []
            if !AppStoreRequest.isAppID(app.appId) { problems.append("appId は数字だけです（\(app.appId)）") }
            if app.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("名前を入れてください") }
            if !app.appId.isEmpty, !seen.insert(app.appId).inserted { problems.append("同じ appId のアプリが他にもあります") }
            return problems
        }
    }

    public static func projectCommandProblems(_ command: ProjectCommand) -> [String] {
        var problems: [String] = []
        let name = command.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            problems.append("コマンドの名前を入れてください")
        } else if name.count > ProjectCommands.nameLimit {
            problems.append("コマンドの名前は \(ProjectCommands.nameLimit) 文字までです")
        } else if name.contains(where: \.isNewline) {
            problems.append("コマンドの名前は 1 行にしてください")
        }
        let body = command.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            problems.append("実行するコマンドを入れてください")
        } else if command.command.count > ProjectCommands.commandLimit {
            problems.append("コマンドは \(ProjectCommands.commandLimit) 文字までです")
        }
        if ProjectCommands.containsHiddenCharacters(command.name) || ProjectCommands.containsHiddenCharacters(command.command) {
            problems.append("見えない文字（方向制御・ゼロ幅）は使えません")
        }
        if ProjectCommands.launchesHeadlessClaude(command.command) {
            problems.append("claude の headless 起動（-p / --print）は実行コマンドにできません（API 課金の経路になるため）")
        }
        return problems
    }

    /// 行ごとの問題。同じ名前が前の行にもあれば、後の行の問題にする。
    public static func projectCommandRowProblems(_ commands: [ProjectCommand]) -> [[String]] {
        var seen = Set<String>()
        return commands.map { command in
            var problems = projectCommandProblems(command)
            let name = command.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !seen.insert(name).inserted { problems.append("同じ名前のコマンドが他にもあります") }
            return problems
        }
    }

    /// コマンドのアイコン: 書くなら空でないこと（無ければ既定）。
    public static func commandIconProblem(_ icon: String?) -> String? {
        guard let icon else { return nil }
        return icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "アイコンが空です（SF Symbol の名前を書くか、キーを消してください）。既定の \(ProjectCommands.defaultSymbol) で出します" : nil
    }

    public static func boardProblems(_ board: GitHubBoard) -> [String] {
        var problems: [String] = []
        if board.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("名前を入れてください") }
        if let p = ownerProblem(board.owner) { problems.append(p) }
        if board.number <= 0 { problems.append("Project 番号は 1 以上の整数です") }
        return problems
    }

    /// 画面の欄のボードを保存できない理由。`excluding` の行（編集中の自分）を除いて同じボードがあればそれも出す。
    public static func boardProblems(_ board: GitHubBoard, among boards: [GitHubBoard], excluding id: UUID?) -> [String] {
        let problems = boardProblems(board)
        if problems.isEmpty, boards.contains(where: { $0.id != id && $0.sameBoard(as: board) }) {
            return ["同じボードが既にあります"]
        }
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
                if let p = reminderDayProblem(link.reminderDay) { result.append("「\(project.name)」のリンク「\(link.name)」: \(p)（保存で落とします）") }
            }
            if let site = project.site, let p = sitePathProblem(site.path) { result.append("「\(project.name)」のサイト: \(p)") }
            for (command, problems) in zip(project.commands, projectCommandRowProblems(project.commands)) {
                for p in problems { result.append("「\(project.name)」のコマンド「\(command.name)」: \(p)") }
                if let p = commandIconProblem(command.icon) { result.append("「\(project.name)」のコマンド「\(command.name)」: \(p)") }
            }
            if project.ignoredCommands.isSet {
                result.append("「\(project.name)」の実行コマンド: 形が正しくないため無視しました（[{\"name\": \"名前\", \"command\": \"コマンド\"}] の形で書いてください）")
            }
            if project.ignoredSite.isSet { result.append("「\(project.name)」のサイト: 形が正しくないため無視しました（{\"path\": \"相対パス\"} の形で書いてください）") }
            for (app, problems) in zip(project.appStoreApps, appStoreRowProblems(project.appStoreApps)) {
                for p in problems { result.append("「\(project.name)」の App Store「\(app.name)」: \(p)") }
            }
            if project.ignoredAppStore.isSet { result.append("「\(project.name)」の App Store: 形が正しくないため無視しました（[{\"appId\": \"数字\", \"name\": \"名前\"}] の形で書いてください）") }
            if let path = project.xcode?.configuredPath, let p = XcodeLinks.pathProblem(path) { result.append("「\(project.name)」の Xcode: \(p)") }
            if project.ignoredXcode.isSet {
                result.append("「\(project.name)」の Xcode: 形が正しくないため無視しました（{\"path\": \"相対パス\"} か {\"disabled\": true} の形で書いてください）")
            }
            if let p = ProjectBadge.colorProblem(project.color) { result.append("「\(project.name)」の印: \(p)") }
            if let p = ProjectBadge.iconProblem(project.icon) { result.append("「\(project.name)」の印: \(p)") }
        }
        for (index, board) in settings.boards.enumerated() {
            for p in boardProblems(board) { result.append("ボード「\(board.name)」: \(p)") }
            if settings.boards[..<index].contains(where: { $0.sameBoard(as: board) }) {
                result.append("ボード「\(board.name)」: 同じボード（\(board.owner) #\(board.number)）が他にもあります")
            }
        }
        return result
    }
}
