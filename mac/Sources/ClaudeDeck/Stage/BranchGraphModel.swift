import Foundation
import MonitorKit
import Observation

/// ステージパネルの「ブランチ」の状態。見えている間だけ ref の変化を見張り、少し待ってまとめて読み直す。
@MainActor
@Observable
final class BranchGraphModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(GitGraphSnapshot)
        case notRepository
        case missingFolder
        case noGit
        case failed(String)
    }

    enum DetailState: Equatable {
        case loading
        case loaded(GitCommitDetail)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var refreshing = false
    /// 読み直しの失敗（図は前のまま出しておく）。
    private(set) var refreshFailure: String?
    private(set) var selected: String?
    private(set) var details: [String: DetailState] = [:]
    private(set) var directory: String?

    @ObservationIgnored private var limit = GitRepositoryReader.defaultLimit
    @ObservationIgnored private var watcher: GitRefWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var detailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let reader = BranchGraphModel.sharedReader
    /// git の場所はアプリが動いている間は変わらないので 1 回だけ探す。
    private static let sharedReader: GitRepositoryReader? = GitRunner.standard().map(GitRepositoryReader.init)

    /// rebase のように ref が続けて替わる間は描き直さず、落ち着いてから 1 回読む。
    static let coalesce: Duration = .milliseconds(600)

    /// 表示を始める・ルームが替わった時。同じフォルダのままなら読み直さない。
    func show(directory: String?) {
        let directory = directory.flatMap { $0.isEmpty ? nil : $0 }
        guard directory != self.directory || phase == .idle else { return }
        stop()
        self.directory = directory
        guard directory != nil else { return }
        guard reader != nil else {
            phase = .noGit
            return
        }
        phase = .loading
        load()
    }

    /// パネルを離れた時。見張りと読み込みを止め、次に開いた時は読み直す。
    func stop() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        detailTasks.values.forEach { $0.cancel() }
        detailTasks = [:]
        watcher?.stop()
        watcher = nil
        directory = nil
        phase = .idle
        refreshing = false
        refreshFailure = nil
        selected = nil
        details = [:]
        limit = GitRepositoryReader.defaultLimit
    }

    func reload() {
        guard directory != nil, reader != nil else { return }
        if case .loaded = phase {} else { phase = .loading }
        load()
    }

    var canLoadMore: Bool { limit < GitRepositoryReader.maxLimit }

    func loadMore() {
        guard canLoadMore else { return }
        limit = min(limit + GitRepositoryReader.limitStep, GitRepositoryReader.maxLimit)
        load()
    }

    /// 押したコミットの詳細を開く。もう一度押せば閉じる。
    func toggle(_ hash: String) {
        if selected == hash {
            selected = nil
        } else {
            select(hash)
        }
    }

    func select(_ hash: String) {
        selected = hash
        loadDetail(hash)
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesce)
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    private func load() {
        guard let reader, let directory else { return }
        loadTask?.cancel()
        generation += 1
        let token = generation
        let limit = limit
        if case .loaded = phase { refreshing = true }
        loadTask = Task { [weak self] in
            let result = await reader.load(directory: directory, limit: limit)
            guard let self, !Task.isCancelled, token == self.generation else { return }
            self.apply(result)
        }
    }

    private func apply(_ result: GitGraphLoad) {
        refreshing = false
        switch result {
        case .loaded(let snapshot):
            phase = .loaded(snapshot)
            refreshFailure = nil
            if watcher?.location != snapshot.location {
                watcher?.stop()
                let next = GitRefWatcher(location: snapshot.location) { [weak self] in self?.scheduleRefresh() }
                next.start()
                watcher = next
            }
            if let selected, !snapshot.entries.contains(where: { $0.commit.hash == selected }) { self.selected = nil }
        case .failed(let message):
            if case .loaded = phase {
                refreshFailure = message
            } else {
                phase = .failed(message)
            }
        case .notRepository, .missingFolder:
            watcher?.stop()
            watcher = nil
            phase = result == .notRepository ? .notRepository : .missingFolder
        }
    }

    private func loadDetail(_ hash: String) {
        guard let reader, let directory else { return }
        if case .loaded = details[hash] { return }
        if detailTasks[hash] != nil { return }
        details[hash] = .loading
        detailTasks[hash] = Task { [weak self] in
            let result = await reader.detail(directory: directory, hash: hash)
            guard let self, !Task.isCancelled, self.directory == directory else { return }
            self.detailTasks[hash] = nil
            switch result {
            case .success(let detail): self.details[hash] = .loaded(detail)
            case .failure(let error): self.details[hash] = .failed(error.message)
            }
        }
    }
}
