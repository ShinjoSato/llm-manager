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

    let projectId: UUID
    private(set) var phase: Phase = .starting
    private(set) var lines: [String] = []
    /// 動いている、または止め切る（孫まで片付ける）前のプロセス。片付くまでは同じサイトをもう一度起動しない。
    fileprivate private(set) var process: DevServerProcess?

    @ObservationIgnored private var log = DevServerLog()
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var address: DevServerAddress?
    @ObservationIgnored private var linesRefreshScheduled = false
    /// 出力の画面への反映の間隔（出力が多くても描き直しを詰まらせない）。
    private static let linesRefreshInterval: Duration = .milliseconds(200)

    init(projectId: UUID) {
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

    /// 自然に終わった後、グループに残ったものを片付けている間。
    var isCleaningUp: Bool { !isActive && process != nil }

    /// 起動してよいか（動いておらず、前のプロセスの片付けも済んでいる）。
    var canStart: Bool { !isActive && process == nil }

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

    fileprivate func attach(_ process: DevServerProcess) {
        self.process = process
    }

    fileprivate func fail(_ reason: String) {
        phase = .failed(reason)
    }

    fileprivate func receive(_ data: Data) {
        let completed = log.append(data)
        if isActive, phase != .stopping, let next = DevServerRules.nextAddress(current: address, newLines: completed), next != address {
            address = next
            phase = .running(next.url)
        }
        scheduleLinesRefresh()
    }

    private func scheduleLinesRefresh() {
        guard !linesRefreshScheduled else { return }
        linesRefreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.linesRefreshInterval)
            guard let self else { return }
            linesRefreshScheduled = false
            lines = log.tail
        }
    }

    /// 先頭のプロセスが終わった。止めている途中なら止め切るまで「停止中」のまま、自然に終わったなら理由を出す。
    fileprivate func exited(_ exit: DevServerExit) {
        log.finish()
        lines = log.tail
        guard !stopRequested else { return }
        phase = .failed(DevServerRules.failureReason(exit: exit, log: log.lines, foundAddress: address != nil))
    }

    fileprivate func requestStop() -> DevServerProcess? {
        stopRequested = true
        guard let process else {
            if isActive { phase = .stopped }
            return nil
        }
        if isActive { phase = .stopping }
        return process
    }

    /// グループを止め切った（または片付け終えた）。
    fileprivate func stopFinished(_ finished: DevServerProcess) {
        guard process === finished else { return }
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

    /// 押した時だけ起動する。動いている・前のプロセスを片付けている間は何もしない。
    func start(project: ManagedProject, location: SiteLocation) {
        let key = Self.key(location.root)
        if let existing = servers[key], !existing.canStart { return }
        startWatchingSettings()
        let server = DevServer(projectId: project.id)
        servers[key] = server
        if let problem = DevServerRules.readiness(siteRoot: key).problem {
            server.fail(problem)
            return
        }
        do {
            // 出力と終了はメインのキューで届いた順に受ける。
            let process = try DevServerProcess.spawn(
                executable: DevServerRules.shell, arguments: DevServerRules.shellArguments,
                environment: DevServerRules.environment(), directory: key, deliveryQueue: .main,
                onOutput: { [weak server] data in MainActor.assumeIsolated { server?.receive(data) } },
                onExit: { [weak server] exit in
                    MainActor.assumeIsolated {
                        guard let server else { return }
                        server.exited(exit)
                        // 自然に終わった時も、グループに残った孫を止め切るまでは片付け中として持つ。
                        guard let process = server.process else { return }
                        Task {
                            await process.stop()
                            server.stopFinished(process)
                        }
                    }
                })
            server.attach(process)
        } catch {
            server.fail("開発サーバーを起動できませんでした: \(error)")
        }
    }

    /// 止める。止め切った（孫まで片付けた）後に `completion` を呼ぶ。
    func stop(root: String, completion: (@MainActor () -> Void)? = nil) {
        guard let server = servers[Self.key(root)], let process = server.requestStop() else {
            completion?()
            return
        }
        Task {
            await process.stop()
            server.stopFinished(process)
            completion?()
        }
    }

    /// アプリの終了時。片付け中のものも含めて全部にまとめて SIGTERM を送り、止まるか猶予が尽きるまで待つ。
    func stopAllBlocking() {
        let pairs = servers.values.compactMap { server in server.requestStop().map { (server, $0) } }
        guard !pairs.isEmpty else { return }
        DevServerProcess.stopAllBlocking(pairs.map(\.1))
        pairs.forEach { $0.0.stopFinished($0.1) }
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
            // 止め切ってから外す（外した後に同じサイトを起動しても、前のプロセスと重ならないように）。
            stop(root: key) { [weak self] in
                if self?.servers[key] === server { self?.servers[key] = nil }
            }
        }
    }
}
