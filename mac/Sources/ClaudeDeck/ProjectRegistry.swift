import Foundation

/// ai-manager の管理対象プロジェクト1件。
struct ManagedProject: Equatable, Codable {
    let name: String
    let path: String
    let status: String   // active | paused | archived
    let note: String
    /// このディレクトリに紐づく GitHub Project（任意）。両方あるとき GitHub 画面を開ける。
    let ghOwner: String?
    let ghNumber: String?

    init(name: String, path: String, status: String, note: String,
         ghOwner: String? = nil, ghNumber: String? = nil) {
        self.name = name
        self.path = path
        self.status = status
        self.note = note
        self.ghOwner = ghOwner
        self.ghNumber = ghNumber
    }
}

/// `projects/registry.tsv` を読み込む。
enum ProjectRegistry {
    /// registry.tsv の場所を解決する。
    /// 優先順位: 環境変数 CLAUDE_DECK_REGISTRY → AIManagerRoot 配下。
    static func registryURL() -> URL? {
        AIManagerRoot.file("projects/registry.tsv", envOverride: "CLAUDE_DECK_REGISTRY")
    }

    /// TSV を読み込み、プロジェクト一覧を返す。`#` 始まりと空行は無視。
    static func load() -> [ManagedProject] {
        guard let url = registryURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var result: [ManagedProject] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let cols = rawLine.components(separatedBy: "\t")
            guard cols.count >= 2 else { continue }
            let name = cols[0].trimmingCharacters(in: .whitespaces)
            let path = cols[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !path.isEmpty else { continue }
            let status = cols.count >= 3 ? cols[2].trimmingCharacters(in: .whitespaces) : "active"
            let note = cols.count >= 4 ? cols[3].trimmingCharacters(in: .whitespaces) : ""
            result.append(ManagedProject(name: name, path: path, status: status, note: note))
        }
        return result
    }
}
