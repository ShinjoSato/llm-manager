import Foundation
import Observation

/// 設定の持ち手。「+」の一覧と設定画面が同じものを見る。
/// 保存の直前にファイルを読み直し、外で書き換えられていれば外の内容に変更をかけ直す（外の変更を消さないため）。
/// 外の変更と文字欄の入力が同じ欄で重なった時は、どの経路でも外の変更を残して入力を捨て、案内を出す。
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
    /// 外の変更と重なって変更・入力を捨てた時・ファイルが消された時・以前の projects.json を読めなかった時の案内。
    public private(set) var notice: String?
    /// 文字入力の変換中か（変換中の文字を保存しないため。画面側が差し込む）。
    @ObservationIgnored public var isComposing: @MainActor () -> Bool = { false }

    public var projects: [ManagedProject] { settings.projects }
    public var isEditable: Bool { problem == nil }
    public var warnings: [String] { SettingsValidation.warnings(settings) }
    public var hasPendingEdits: Bool { !pending.isEmpty }
    /// 打った値がまだファイルに入っていないことを画面に出すべきか（問題がある時だけ溜めた入力を見る。打つたびに画面を描き直さないため）。
    public var hasUnsavedInput: Bool { (problem != nil || saveError != nil) && hasPendingEdits }

    public static let droppedNotice = "settings.json が外で変更されたため読み直しました。直前の変更は反映していません"
    public static let droppedInputNotice = "settings.json が外で変更されたため読み直しました。直前の入力は反映していません"
    public static let deletedNotice = "settings.json が外で消されました。空の一覧として扱い、次に変更した時に作り直します"

    /// 最後に読んだ / 書いたファイルの中身（無ければ nil）。外の変更を見分ける基準。
    @ObservationIgnored private var onDisk: DeckSettings?
    /// 一度でも settings.json を読めた・書けたか（後で消されても移行し直さないため）。
    @ObservationIgnored private var knewFile = false
    @ObservationIgnored private var diskStamp: SettingsFile.Stamp?
    private var pending: [PendingEdit] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?

    /// 試験用: 実際に読み直した回数と、溜めた変更を書こうとした回数。
    @ObservationIgnored private(set) var reloadCount = 0
    @ObservationIgnored private(set) var flushAttempts = 0

    /// 文字欄の変更をまとめて書くまでの間。
    public static let editDelay: Duration = .milliseconds(500)
    /// 書きかけのファイルを読んだ時に読み直すまでの間（書き終わりを待つ）。
    static let recheckDelays: [Duration] = [.milliseconds(200), .milliseconds(800)]

    private struct PendingEdit {
        let key: String
        let change: Change
        /// 元の内容と新しい内容で、この変更の欄が違うか（外の変更が同じ欄に触れたか）。
        let touched: ((DeckSettings, DeckSettings) -> Bool)?
    }

    public init(file: SettingsFile) {
        self.file = file
        reload()
    }

    // MARK: - 読み直し

    /// ファイルを読み直す。案内と書き込みの失敗はいったん消し、今の状態から出し直す。
    public func reload() {
        reloadCount += 1
        notice = nil
        saveError = nil
        let previous = settings
        let (result, stamp) = readStable()
        diskStamp = stamp
        switch result {
        case .missing where !knewFile:
            applyBootstrap(file.bootstrap())
            // 移行で書いた後の同一性を取り直す（書いた直後に外で変わっていればその内容を採る）。
            let (after, afterStamp) = readStable()
            if case .loaded(let loaded) = after { adoptLoaded(loaded) }
            diskStamp = afterStamp
        case .missing:
            if onDisk != nil || settings != DeckSettings() { adoptDeleted() }
            problem = nil
        case .loaded(let loaded):
            adoptLoaded(loaded)
        case .unreadable(let reason):
            problem = reason
            scheduleRecheck()
        }
        guard problem == nil else { return }
        dropTouchedPending(old: previous, new: settings)
        if !pending.isEmpty { scheduleFlush() }
    }

    /// 前に読んだ / 書いた時からファイルが替わっていれば読み直す（自分の書き込みの通知では読まない）。
    public func reloadIfChanged() {
        guard file.stamp() != diskStamp else { return }
        reload()
    }

    /// 置き場所のディレクトリとファイル自体を見て、外の変更をすぐ読み直す（置き換えも、その場の書き換えも拾うため）。
    public func startWatching() {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(directory: file.url.deletingLastPathComponent(),
                                       fileName: file.url.lastPathComponent) { [weak self] in
            self?.reloadIfChanged()
        }
        watcher.start()
        self.watcher = watcher
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    public func dismissNotice() {
        notice = nil
    }

    /// 読む前と後の同一性が揃うまで読む。返す同一性は読む前のもの（途中で替わっていれば次の確認で必ず読み直すため）。
    private func readStable() -> (SettingsFile.LoadResult, SettingsFile.Stamp?) {
        var result = SettingsFile.LoadResult.missing
        var before: SettingsFile.Stamp?
        for _ in 0..<3 {
            before = file.stamp()
            result = file.load()
            if file.stamp() == before { break }
        }
        return (result, before)
    }

    private func adoptLoaded(_ loaded: DeckSettings) {
        if loaded != settings { settings = loaded.carryingBoardIDs(from: settings) }
        onDisk = loaded
        knewFile = true
        problem = nil
    }

    private func adoptDeleted() {
        if settings != DeckSettings() { settings = DeckSettings() }
        onDisk = nil
        problem = nil
        notice = Self.deletedNotice
    }

    private func applyBootstrap(_ boot: SettingsFile.Bootstrap) {
        switch boot.result {
        case .loaded(let loaded):
            if let failure = boot.saveFailure {
                // 書けなかった移行の中身は手元にだけ持つ（ファイルは無いまま。次の読み直しで移行をやり直す）。
                if loaded != settings { settings = loaded }
                onDisk = nil
                problem = nil
                saveError = failure
            } else {
                adoptLoaded(loaded)
            }
        case .missing:
            if settings != DeckSettings() { settings = DeckSettings() }
            onDisk = nil
            problem = nil
        case .unreadable(let reason):
            problem = reason
            scheduleRecheck()
        }
        if let legacy = boot.legacyProblem { notice = legacy }
    }

    /// 書きかけのファイルを読んだかもしれないので、少し待って読み直す（その間に書き終われば問題は消える）。
    private func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            for delay in Self.recheckDelays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.problem != nil else { return }
                self.reloadIfChanged()
            }
        }
    }

    /// 外の変更が触れた欄の溜めた入力を捨てる（外の変更を残す）。捨てたら案内を出す。
    @discardableResult
    private func dropTouchedPending(old: DeckSettings, new: DeckSettings) -> Bool {
        guard old != new else { return false }
        let before = pending.count
        pending.removeAll { $0.touched?(old, new) ?? false }
        guard pending.count != before else { return false }
        notice = Self.droppedInputNotice
        return true
    }

    // MARK: - 変更

    /// 変更して保存する。読めないファイルがある間は何もしない。溜まっている文字欄の変更も一緒に書く（変換中は残す）。
    @discardableResult
    public func update(_ change: Change) -> Bool {
        commit(change, immediate: true, includePending: !isComposing())
    }

    /// `immediate` でなければ `change` は使わない（溜めた変更だけを書く）。
    private func commit(_ change: Change, immediate: Bool, includePending: Bool) -> Bool {
        if includePending {
            flushTask?.cancel()
            flushTask = nil
        }
        guard isEditable else { return false }

        let previous = settings
        var external = false
        var roundNotice: String?
        let (disk, stamp) = readStable()
        diskStamp = stamp
        switch disk {
        case .unreadable(let reason):
            // 書きかけを読んだかもしれない。溜めた入力は残し、読めるようになったら書く。
            problem = reason
            scheduleRecheck()
            return false
        case .missing:
            if onDisk != nil {
                external = true
                adoptDeleted()
                roundNotice = Self.deletedNotice
            }
        case .loaded(let loaded):
            if loaded != onDisk {
                external = true
                adoptLoaded(loaded)
            }
        }
        if external, dropTouchedPending(old: previous, new: settings) { roundNotice = Self.droppedInputNotice }

        let edits = includePending ? pending : []
        let base = settings

        // 外の変更と重なった時、元の内容には効いたが新しい内容には効かない変更があれば、捨てたことを知らせる。
        var lostChange = false
        if external {
            func lost(_ c: Change) -> Bool {
                var old = previous
                c(&old)
                var new = base
                c(&new)
                return old != previous && new == base
            }
            if edits.contains(where: { lost($0.change) }) { roundNotice = Self.droppedNotice }
            if immediate, lost(change) {
                lostChange = true
                roundNotice = Self.droppedNotice
            }
        }

        var next = base
        for edit in edits { edit.change(&next) }
        if immediate { change(&next) }
        guard next != base else {
            if includePending { pending.removeAll() }
            if external { notice = roundNotice }
            return !lostChange
        }
        let blocking = SettingsValidation.blockingProblems(next)
        guard blocking.isEmpty else {
            if external {
                notice = Self.droppedNotice
            } else {
                saveError = "保存しませんでした: " + blocking.joined(separator: " / ")
            }
            return false
        }
        do {
            try file.save(next)
        } catch SettingsFile.SaveError.existingUnreadable(let reason) {
            problem = reason
            scheduleRecheck()
            return false
        } catch {
            saveError = "\(file.url.path) に書けませんでした"
            return false
        }
        if includePending { pending.removeAll() }
        settings = next
        onDisk = next
        knewFile = true
        saveError = nil
        notice = roundNotice
        // 書いた後の同一性を取り直す。書いた直後に外で書き換わっていれば、その内容を読み直す。
        let (after, afterStamp) = readStable()
        if case .loaded(let loaded) = after, loaded == next {
            diskStamp = afterStamp
        } else {
            diskStamp = nil
            reloadIfChanged()
        }
        return !lostChange
    }

    /// 文字欄の変更を溜めて、少し間を置いてまとめて書く。同じ `key` は新しいものだけ残す。
    /// `touched` を渡すと、外の変更が同じ欄を別の値にした時にこの入力を捨てる。
    public func schedule(key: String, touched: ((DeckSettings, DeckSettings) -> Bool)? = nil, _ change: @escaping Change) {
        pending.removeAll { $0.key == key }
        pending.append(PendingEdit(key: key, change: change, touched: touched))
        scheduleFlush()
    }

    /// 溜めた変更のうち `key` のものを取り消す（入力が不正になった時など）。
    public func cancelPending(key: String) {
        pending.removeAll { $0.key == key }
    }

    /// 溜めた変更を今すぐ書く。`force` でなければ変換中は待つ。
    public func flushPending(force: Bool = false) {
        guard !pending.isEmpty else { return }
        flushAttempts += 1
        if !force && isComposing() {
            scheduleFlush()
            return
        }
        _ = commit({ _ in }, immediate: false, includePending: true)
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
    public func scheduleProject<Value: Equatable>(id: UUID, field: String,
                                                  _ keyPath: WritableKeyPath<ManagedProject, Value>, _ value: Value) {
        let read: (DeckSettings) -> Value? = { settings in settings.projects.first { $0.id == id }?[keyPath: keyPath] }
        schedule(key: Self.projectKey(id: id, field: field), touched: { read($0) != read($1) && read($1) != value }) { settings in
            guard let index = settings.projects.firstIndex(where: { $0.id == id }) else { return }
            settings.projects[index][keyPath: keyPath] = value
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

    /// 文字欄からのボードの変更（まとめて書く。名前・owner・番号を置き換える）。
    public func scheduleBoard(id: UUID, _ value: GitHubBoard) {
        let read: (DeckSettings) -> GitHubBoard? = { settings in settings.boards.first { $0.id == id } }
        schedule(key: Self.boardKey(id: id), touched: { read($0) != read($1) && read($1) != value }) { settings in
            guard let index = settings.boards.firstIndex(where: { $0.id == id }) else { return }
            settings.boards[index] = GitHubBoard(id: id, name: value.name, owner: value.owner, number: value.number)
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
