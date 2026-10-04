import Foundation
import MonitorKit

/// 「+」のプロジェクト一覧（Application Support の projects.json）。初回だけ registry.tsv から取り込み、以降はユーザーが管理する。
enum ProjectStore {

    private static var fileURL: URL {
        // 試験用の一覧で本物の一覧を汚さないため、環境変数で差し替えられるようにする。
        if let path = ProcessInfo.processInfo.environment["CLAUDE_DECK_PROJECTS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = DeckPaths.applicationSupport
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

    /// フォルダを追加（同一パスは無視）。表示名はフォルダ名。
    static func add(path: String) {
        var list = load()
        let clean = (path as NSString).standardizingPath
        guard !list.contains(where: { $0.path == clean }) else { return }
        list.append(ManagedProject(name: (clean as NSString).lastPathComponent, path: clean, status: "active", note: ""))
        save(list)
    }

    static func remove(path: String) {
        var list = load()
        list.removeAll { $0.path == path }
        save(list)
    }

    /// registry.tsv の内容を取り込む（既存パスは重複させない）。
    static func importFromRegistry() {
        var list = load()
        for p in ProjectRegistry.load() where !list.contains(where: { $0.path == p.path }) {
            list.append(p)
        }
        save(list)
    }
}
