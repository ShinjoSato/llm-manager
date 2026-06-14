import Foundation

/// ユーザーが追加・削除したプロジェクト一覧の永続ストア。
/// 実体は `~/Library/Application Support/claude-deck/projects.json`（人が読める JSON）。
///
/// - 初回（ファイル未作成）は `registry.tsv` から取り込んで空にしない。
/// - 以降は完全にユーザー管理（追加・削除がそのまま保存される）。
enum ProjectStore {

    private static var fileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claude-deck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("projects.json")
    }

    static func load() -> [ManagedProject] {
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            // 初回のみ registry.tsv から取り込んで保存
            let seeded = ProjectRegistry.load()
            save(seeded)
            return seeded
        }
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ManagedProject].self, from: data) else {
            return []
        }
        return list
    }

    static func save(_ projects: [ManagedProject]) {
        if let data = try? JSONEncoder().encode(projects) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// フォルダを追加（同一パスは無視）。表示名は未指定ならフォルダ名。
    @discardableResult
    static func add(path: String, name: String? = nil) -> [ManagedProject] {
        var list = load()
        let clean = (path as NSString).standardizingPath
        guard !list.contains(where: { $0.path == clean }) else { return list }
        let displayName = name ?? (clean as NSString).lastPathComponent
        list.append(ManagedProject(name: displayName, path: clean, status: "active", note: ""))
        save(list)
        return list
    }

    /// 指定パスのエントリを削除。
    @discardableResult
    static func remove(path: String) -> [ManagedProject] {
        var list = load()
        list.removeAll { $0.path == path }
        save(list)
        return list
    }

    /// 指定パスのエントリに GitHub Project（owner/number）を設定する。nil で解除。
    @discardableResult
    static func setGitHub(path: String, owner: String?, number: String?) -> [ManagedProject] {
        var list = load()
        if let i = list.firstIndex(where: { $0.path == path }) {
            let p = list[i]
            list[i] = ManagedProject(name: p.name, path: p.path, status: p.status, note: p.note,
                                     ghOwner: owner, ghNumber: number)
            save(list)
        }
        return list
    }

    /// registry.tsv の内容を取り込む（既存パスは重複させない）。
    @discardableResult
    static func importFromRegistry() -> [ManagedProject] {
        var list = load()
        for p in ProjectRegistry.load() where !list.contains(where: { $0.path == p.path }) {
            list.append(p)
        }
        save(list)
        return list
    }
}
