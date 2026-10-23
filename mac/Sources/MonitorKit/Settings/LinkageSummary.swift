import Foundation

/// 設定画面の紐づけ・実行コマンドを 1 行に収める時の、今の値の要約。
public enum LinkageSummary {
    /// 値が無い時。
    public static let none = "なし"
    /// 走査の結果がまだ無い時。
    public static let searching = "探しています…"

    /// GitHub: `owner/repo #N`（リポジトリ・番号の無いものは省く）。
    public static func github(_ link: GitHubLink?) -> String {
        guard let link else { return none }
        let owner = link.owner.trimmingCharacters(in: .whitespaces)
        let repo = link.repo?.trimmingCharacters(in: .whitespaces) ?? ""
        var text = repo.isEmpty || owner.isEmpty ? owner + repo : "\(owner)/\(repo)"
        if let number = link.projectNumber { text += text.isEmpty ? "#\(number)" : " #\(number)" }
        return text.isEmpty ? none : text
    }

    /// リポジトリに紐づかないボード: `owner #N`。
    public static func board(_ board: GitHubBoard) -> String {
        github(GitHubLink(owner: board.owner, projectNumber: board.number > 0 ? board.number : nil))
    }

    /// Xcode: 「自動（ios/App.xcodeproj）」「指定（…）」「使わない」。`scanned` が偽の間は自動の中身を探している旨、
    /// `choosing`（「指定」を選んだがまだ場所を選んでいない）の間は未選択にする。
    public static func xcode(_ link: XcodeLink?, detected: String?, scanned: Bool, choosing: Bool = false) -> String {
        if choosing, link?.configuredPath == nil { return "指定（未選択）" }
        switch link {
        case .path(let path): return "指定（\(path)）"
        case .disabled: return "使わない"
        case nil:
            guard scanned else { return "自動（\(searching)）" }
            return "自動（\(detected ?? "見つかりません")）"
        }
    }

    /// サイト: 「自動（site）」「指定（site）」「見つかりません」。書き出しが無ければ添える。
    public static func site(configured: ProjectSite?, lookup: SiteLookup?, exported: Bool) -> String {
        guard let lookup else {
            return configured.map { "指定（\($0.path)）" } ?? "自動（\(searching)）"
        }
        guard let location = lookup.location else {
            return configured.map { "指定（\($0.path)）" } ?? "見つかりません"
        }
        let place = location.relativePath == "." ? "直下" : location.relativePath
        let text = "\(location.source == .configured ? "指定" : "自動")（\(place)）"
        return exported ? text : "\(text) · 書き出しなし"
    }

    /// 件数（0 件は「なし」）。
    public static func count(_ count: Int) -> String {
        count > 0 ? "\(count) 件" : none
    }

    /// 実行コマンドの本文の最初の空でない行（続きがあれば「…」を付ける）。
    public static func firstLine(_ command: String) -> String {
        let lines = command.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }
        return lines.count > 1 ? "\(first) …" : first
    }
}
