import Foundation
import MonitorKit
import Observation

/// 1 つのサイトの開発サーバー（`npm run dev`）。出力の末尾と、見つけたアドレスを持つ。
@MainActor
@Observable
final class DevServer {
    enum Phase: Equatable {
        /// 起動して、出力にアドレスが出るのを待っている。
        case starting
        case running(URL)
        case stopping
        case stopped
        case failed(String)
    }

    let root: String
    let projectId: UUID
    private(set) var phase: Phase = .starting
    private(set) var lines: [String] = []

    @ObservationIgnored private var log = DevServerLog()
    @ObservationIgnored fileprivate var process: DevServerProcess?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var foundAddress = false

    init(root: String, projectId: UUID) {
        self.root = root
        self.projectId = projectId
    }

    var url: URL? {
        if case .running(let url) = phase { return url }
        return nil
    }

    /// 起動中・動作中・停止中（もう一度起動させない間）。
    var isActive: Bool {
        switch phase {
        case .starting, .running, .stopping: return true
        case .stopped, .failed: return false
        }
    }

    var failure: String? {
        if case .failed(let reason) = phase { return reason }
        return nil
    }

    var statusText: String {
        switch phase {
        case .starting: return "起動中（アドレスが出るのを待っています）"
        case .running(let url): return "動作中 \(url.absoluteString)"
        case .stopping: return "停止中…"
        case .stopped: return "停止しています"
        case .failed(let reason): return reason
        }
    }

    fileprivate func fail(_ reason: String) {
        phase = .failed(reason)
    }

    fileprivate func receive(_ data: Data) {
        let completed = log.append(data)
        if !foundAddress, case .starting = phase,
           let url = completed.lazy.compactMap(DevServerRules.address(in:)).first(where: DevServerRules.isLocalAddress) {
            foundAddress = true
            phase = .running(url)
        }
        lines = log.tail
    }

    fileprivate func exited(_ exit: DevServerExit) {
        log.finish()
        lines = log.tail
        process = nil
        phase = stopRequested ? .stopped : .failed(DevServerRules.failureReason(exit: exit, log: log.lines, foundAddress: foundAddress))
    }

    fileprivate func requestStop() -> DevServerProcess? {
        stopRequested = true
        guard let process else {
            if isActive { phase = .stopped }
            return nil
        }
        phase = .stopping
        return process
    }

    fileprivate func stopFinished() {
        process = nil
        if phase == .stopping { phase = .stopped }
    }
}

/// アプリ全体の開発サーバー。同じサイト（フォルダ）は 1 つだけ動かし、アプリの終了・プロジェクトの削除で止める。
@MainActor
@Observable
final class DevServerStore {
    static let shared = DevServerStore()

    /// サイトのフォルダ（標準化したパス）→ 開発サーバー。
    private(set) var servers: [String: DevServer] = [:]
    @ObservationIgnored private var watchingSettings = false

    static func key(_ root: String) -> String { (root as NSString).standardizingPath }

    func server(for root: String) -> DevServer? { servers[Self.key(root)] }

    /// 押した時だけ起動する。動いていれば何もしない。
    func start(project: ManagedProject, location: SiteLocation) {
        let key = Self.key(location.root)
        if let existing = servers[key], existing.isActive { return }
        startWatchingSettings()
        let server = DevServer(root: key, projectId: project.id)
        servers[key] = server
        if let problem = DevServerRules.readiness(siteRoot: key).problem {
            server.fail(problem)
            return
        }
        do {
            server.process = try DevServerProcess.spawn(
                executable: DevServerRules.shell, arguments: DevServerRules.shellArguments,
                environment: DevServerRules.environment(), directory: key,
                onOutput: { [weak server] data in Task { @MainActor in server?.receive(data) } },
                onExit: { [weak server] exit in Task { @MainActor in server?.exited(exit) } })
        } catch {
            server.fail("開発サーバーを起動できませんでした: \(error)")
        }
    }

    func stop(root: String) {
        guard let server = servers[Self.key(root)], let process = server.requestStop() else { return }
        Task {
            await process.stop()
            server.stopFinished()
        }
    }

    /// アプリの終了時。全部にまとめて SIGTERM を送り、止まるか猶予が尽きるまで待つ。
    func stopAllBlocking() {
        let processes = servers.values.compactMap { $0.requestStop() }
        guard !processes.isEmpty else { return }
        DevServerProcess.stopAllBlocking(processes)
        servers.values.forEach { $0.stopFinished() }
    }

    /// 設定からプロジェクトが消えたら、そのプロジェクトの開発サーバーを止めて外す。
    private func startWatchingSettings() {
        guard !watchingSettings else { return }
        watchingSettings = true
        observeSettings()
    }

    private func observeSettings() {
        let ids = withObservationTracking {
            Set(SettingsStore.shared.projects.map(\.id))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSettings() }
        }
        // 読めない設定（壊れた JSON 等）の間は一覧が空に見えるので止めない。
        guard SettingsStore.shared.problem == nil else { return }
        for (key, server) in servers where !ids.contains(server.projectId) {
            stop(root: key)
            if !server.isActive { servers[key] = nil }
        }
    }
}
