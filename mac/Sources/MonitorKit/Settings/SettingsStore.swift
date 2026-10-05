import Foundation
import Observation

/// 設定の持ち手。「+」の一覧と設定画面が同じものを見る。
/// 保存の直前にファイルを読み直し、外で書き換えられていれば外の内容に変更をかけ直す（外の変更を消さないため）。
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore(file: SettingsFile(url: SettingsFile.defaultURL()))

    public typealias Change = (inout DeckSettings) -> Void

    public let file: SettingsFile
    public private(set) var settings = DeckSettings()
    /// ファイルが読めない理由。ある間は元のファイルを守るため変更を受け付けない。
    public private(set) var problem: String?
    /// 直近の書き込みの失敗。
    public private(set) var saveError: String?
    /// 外の変更と重なって直前の変更を捨てた時・以前の projects.json を読めなかった時の案内。
    public private(set) var notice: String?
    /// 文字入力の変換中か（変換中の文字を保存しないため。画面側が差し込む）。
    @ObservationIgnored public var isComposing: @MainActor () -> Bool = { false }

    public var projects: [ManagedProject] { settings.projects }
    public var isEditable: Bool { problem == nil }
    public var warnings: [String] { SettingsValidation.warnings(settings) }
    public var hasPendingEdits: Bool { !pending.isEmpty }

    /// 最後に読んだ / 書いたファイルの中身（無ければ nil）。外の変更を見分ける基準。
    @ObservationIgnored private var onDisk: DeckSettings?
    @ObservationIgnored private var diskStamp: SettingsFile.Stamp?
    @ObservationIgnored private var pending: [(key: String, change: Change)] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?

    /// 文字欄の変更をまとめて書くまでの間。
    public static let editDelay: Duration = .milliseconds(500)

    public init(file: SettingsFile) {
        self.file = file
        reload()
    }

    // MARK: - 読み直し

    /// ファイルを読み直す。無ければ移行からやり直す。
    public func reload() {
        let result = file.load()
        if result == .missing {
            applyBootstrap(file.bootstrap())
        } else {
            adopt(result)
        }
        diskStamp = file.stamp()
    }

    /// 前に読んだ / 書いた時からファイルが替わっていれば読み直す（自分の書き込みの通知では読まない）。
    public func reloadIfChanged() {
        guard file.stamp() != diskStamp else { return }
        reload()
    }

    /// 置き場所のディレクトリを見て、外の変更を即時に読み直す（原子的な置き換えは inode が替わるのでファイルではなくディレクトリを見る）。
    public func startWatching() {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(directory: file.url.deletingLastPathComponent()) { [weak self] in
            self?.reloadIfChanged()
        }
        watcher.start()
        self.watcher = watcher
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    private func adopt(_ result: SettingsFile.LoadResult) {
        switch result {
        case .loaded(let loaded):
            if loaded != settings { settings = loaded.carryingBoardIDs(from: settings) }
            onDisk = loaded
            problem = nil
        case .missing:
            if settings != DeckSettings() { settings = DeckSettings() }
            onDisk = nil
            problem = nil
        case .unreadable(let reason):
            problem = reason
        }
    }

    private func applyBootstrap(_ boot: SettingsFile.Bootstrap) {
        adopt(boot.result)
        if let failure = boot.saveFailure {
            // 書けなかった移行の中身は手元にだけ持つ（ファイルは無いまま）。
            onDisk = nil
            saveError = failure
        } else if boot.result != .missing {
            saveError = nil
        }
        notice = boot.legacyProblem
    }

    // MARK: - 変更

    /// 変更して保存する。読めないファイルがある間は何もしない。溜まっている文字欄の変更も一緒に書く。
    @discardableResult
    public func update(_ change: Change) -> Bool {
        flushTask?.cancel()
        flushTask = nil
        let queued = pending.map(\.change)
        pending.removeAll()
        guard isEditable else { return false }

        let previous = settings
        var external = false
        let disk = file.load()
        switch disk {
        case .unreadable(let reason):
            problem = reason
            return false
        case .missing:
            if onDisk != nil {
                external = true
                applyBootstrap(file.bootstrap())
            }
        case .loaded(let loaded):
            if loaded != onDisk {
                external = true
                adopt(disk)
            }
        }
        guard isEditable else { return false }

        // 外の変更と重なった時、元の内容に対しては何かを変えるつもりだったか。
        var wanted = false
        if external {
            var intended = previous
            for q in queued { q(&intended) }
            change(&intended)
            wanted = intended != previous
        }
        let base = settings
        var next = base
        for q in queued { q(&next) }
        change(&next)
        if external {
            if wanted && (next == base || !SettingsValidation.blockingProblems(next).isEmpty) {
                notice = "settings.json が外で変更されたため読み直しました。直前の変更は反映していません"
                diskStamp = file.stamp()
                return false
            }
        }
        guard next != base else {
            diskStamp = file.stamp()
            return true
        }
        let blocking = SettingsValidation.blockingProblems(next)
        guard blocking.isEmpty else {
            saveError = "保存しませんでした: " + blocking.joined(separator: " / ")
            return false
        }
        do {
            try file.save(next)
            settings = next
            onDisk = next
            diskStamp = file.stamp()
            saveError = nil
            notice = nil
            return true
        } catch SettingsFile.SaveError.existingUnreadable(let reason) {
            problem = reason
            return false
        } catch {
            saveError = "\(file.url.path) に書けませんでした"
            return false
        }
    }

    /// 文字欄の変更を溜めて、少し間を置いてまとめて書く。同じ `key` は新しいものだけ残す。
    public func schedule(key: String, _ change: @escaping Change) {
        pending.removeAll { $0.key == key }
        pending.append((key, change))
        scheduleFlush()
    }

    /// 溜めた変更のうち `key` のものを取り消す（入力が不正になった時など）。
    public func cancelPending(key: String) {
        pending.removeAll { $0.key == key }
    }

    /// 溜めた変更を今すぐ書く。`force` でなければ変換中は待つ。
    public func flushPending(force: Bool = false) {
        guard !pending.isEmpty else { return }
        if !force && isComposing() {
            scheduleFlush()
            return
        }
        update { _ in }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.editDelay)
            guard !Task.isCancelled else { return }
            self?.flushPending()
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

    /// 表示中の並びでの移動。外の変更で並びが替わっていても、動かすものを id で引き直す。
    public func move(from source: IndexSet, to destination: Int) {
        let shown = settings.projects.map(\.id)
        let moving = source.compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        let anchor = shown[destination...].first { !moving.contains($0) }
        update { settings in
            let picked = moving.compactMap { id in settings.projects.first { $0.id == id } }
            settings.projects.removeAll { moving.contains($0.id) }
            let insertAt = anchor.flatMap { id in settings.projects.firstIndex { $0.id == id } } ?? settings.projects.endIndex
            settings.projects.insert(contentsOf: picked, at: insertAt)
        }
    }

    @discardableResult
    public func updateProject(id: UUID, _ change: (inout ManagedProject) -> Void) -> Bool {
        update { settings in
            guard let index = settings.projects.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.projects[index])
        }
    }

    public static func projectKey(id: UUID, field: String) -> String { "project.\(id.uuidString).\(field)" }
    public static func boardKey(id: UUID) -> String { "board.\(id.uuidString)" }

    /// 文字欄からのプロジェクトの変更（まとめて書く）。
    public func scheduleProject(id: UUID, field: String, _ change: @escaping (inout ManagedProject) -> Void) {
        schedule(key: Self.projectKey(id: id, field: field)) { settings in
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

    @discardableResult
    public func updateBoard(id: UUID, _ change: (inout GitHubBoard) -> Void) -> Bool {
        update { settings in
            guard let index = settings.boards.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.boards[index])
        }
    }

    /// 文字欄からのボードの変更（まとめて書く）。
    public func scheduleBoard(id: UUID, _ change: @escaping (inout GitHubBoard) -> Void) {
        schedule(key: Self.boardKey(id: id)) { settings in
            guard let index = settings.boards.firstIndex(where: { $0.id == id }) else { return }
            change(&settings.boards[index])
        }
    }

    public func removeBoard(id: UUID) {
        cancelPending(key: Self.boardKey(id: id))
        update { $0.boards.removeAll { $0.id == id } }
    }

    // MARK: - 書き出し・読み込み

    public func exportData() throws -> Data {
        flushPending(force: true)
        return try settings.encoded()
    }

    /// 取り込んで保存する（保存の直前に読み直した内容へ取り込む）。
    public func importData(_ data: Data) throws -> SettingsImport.Summary {
        guard isEditable else { throw SettingsImport.Failure.unreadable(problem ?? "") }
        var summary: SettingsImport.Summary?
        var failure: Error?
        let saved = update { settings in
            do {
                let (merged, result) = try SettingsImport.merge(data, into: settings)
                settings = merged
                summary = result
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        guard saved, let summary else {
            throw SettingsImport.Failure.unreadable(problem ?? saveError ?? notice ?? "保存できませんでした")
        }
        return summary
    }
}
