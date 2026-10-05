import Foundation
import Observation

/// 設定の持ち手。「+」の一覧と設定画面が同じものを見る。変更はその場で `settings.json` に書く。
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore(file: SettingsFile(url: SettingsFile.defaultURL()))

    public let file: SettingsFile
    public private(set) var settings = DeckSettings()
    /// ファイルが読めない理由。ある間は元のファイルを守るため変更を受け付けない。
    public private(set) var problem: String?
    /// 直近の書き込みの失敗。
    public private(set) var saveError: String?

    public var projects: [ManagedProject] { settings.projects }
    public var isEditable: Bool { problem == nil }

    public init(file: SettingsFile) {
        self.file = file
        apply(file.bootstrap())
    }

    /// ファイルを読み直す（外で編集された時に拾う）。
    public func reload() {
        apply(file.load())
    }

    private func apply(_ result: SettingsFile.LoadResult) {
        switch result {
        case .loaded(let loaded):
            if loaded != settings { settings = loaded }
            problem = nil
        case .missing:
            problem = nil
        case .unreadable(let reason):
            problem = reason
        }
    }

    /// 変更して保存する。読めないファイルがある間は何もしない。
    @discardableResult
    public func update(_ change: (inout DeckSettings) -> Void) -> Bool {
        guard isEditable else { return false }
        var next = settings
        change(&next)
        guard next != settings else { return true }
        do {
            try file.save(next)
            settings = next
            saveError = nil
            return true
        } catch SettingsFile.SaveError.existingUnreadable(let reason) {
            problem = reason
            return false
        } catch {
            saveError = "\(file.url.path) に書けませんでした"
            return false
        }
    }

    // MARK: - プロジェクト

    /// フォルダを足す（同じパスは足さない）。
    public func add(paths: [String]) {
        update { settings in
            for path in paths {
                let project = ManagedProject.folder(path)
                if !settings.projects.contains(where: { $0.path == project.path }) { settings.projects.append(project) }
            }
        }
    }

    public func remove(id: UUID) {
        update { $0.projects.removeAll { $0.id == id } }
    }

    public func move(from source: IndexSet, to destination: Int) {
        update { settings in
            let moving = source.map { settings.projects[$0] }
            let insertAt = destination - source.count(in: 0..<destination)
            for index in source.reversed() { settings.projects.remove(at: index) }
            settings.projects.insert(contentsOf: moving, at: insertAt)
        }
    }

    public func updateProject(id: UUID, _ change: (inout ManagedProject) -> Void) {
        update { settings in
            guard let index = settings.projects.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.projects[index])
        }
    }

    // MARK: - ボード

    public func addBoard(_ board: GitHubBoard) {
        update { settings in
            if !settings.boards.contains(where: { $0.sameBoard(as: board) }) { settings.boards.append(board) }
        }
    }

    public func updateBoard(id: UUID, _ change: (inout GitHubBoard) -> Void) {
        update { settings in
            guard let index = settings.boards.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.boards[index])
        }
    }

    public func removeBoard(id: UUID) {
        update { $0.boards.removeAll { $0.id == id } }
    }

    // MARK: - 書き出し・読み込み

    public func exportData() throws -> Data {
        try settings.encoded()
    }

    /// 取り込んで保存する。
    public func importData(_ data: Data) throws -> SettingsImport.Summary {
        guard isEditable else { throw SettingsImport.Failure.unreadable(problem ?? "") }
        let (merged, summary) = try SettingsImport.merge(data, into: settings)
        guard update({ $0 = merged }) else {
            throw SettingsImport.Failure.unreadable(problem ?? saveError ?? "保存できませんでした")
        }
        return summary
    }
}
