import AppKit
import ImageIO
import MonitorKit
import Observation

/// 「iPhone のプレビュー」の 1 件（プロジェクトと描く指定）。
struct IOSPreviewItemKey: Hashable, Sendable {
    let projectId: UUID
    let request: PreviewRenderRequest
}

/// 描き終えた 1 件（写した絵の場所と添え書き）。
struct IOSPreviewRendered: Equatable, Sendable {
    let image: URL
    let info: PreviewSnapshotInfo
}

/// 描くのに要る、プロジェクトとファイルの手がかり。
struct IOSPreviewTarget: Sendable {
    let projectId: UUID
    let projectName: String
    /// 開く `.xcworkspace` / `.xcodeproj`。
    let xcodeProject: String
    let file: SwiftPreviewFile
    let preview: SwiftPreviewDefinition

    var label: String { preview.name ?? "\(file.name)（\(preview.line) 行）" }
}

/// mcpbridge を 1 本だけ持ち、プレビューを 1 件ずつ描いてキャッシュへ写す。節が閉じて数分使わなければ止める。
@MainActor
@Observable
final class IOSPreviewService {
    static let shared = IOSPreviewService()

    enum ItemState: Equatable {
        case queued
        case rendering
        case failed(String)
    }

    /// 今していること（節の上に出す）。
    enum Activity: Equatable {
        case starting
        case opening(String)
        case rendering(String)
        case stopping

        var text: String {
            switch self {
            case .starting: return "Xcode につないでいます…"
            case .opening(let name):
                return "Xcode で \(name) を開いています…（初めての時はメニューバーの Xcode の MCP のアイコンから claude-deck を許可してください）"
            case .rendering(let name): return "\(name) を描いています…（初回はビルドを含むので数分かかります）"
            case .stopping: return "取りやめています（描いている 1 件が終わるまで）"
            }
        }
    }

    /// 1 件の描画の時間切れ（秒）。初回はビルドを含むので長めに。
    static let renderTimeout = 300
    /// 節が閉じてから mcpbridge を止めるまで。
    static let idleTimeout: Duration = .seconds(180)
    static let xcodeBundleId = "com.apple.dt.Xcode"
    static let sourceChangedMessage = "描いている間にソースが書き換わりました。「再読み込み」で一覧を読み直すと出ます"

    private(set) var states: [IOSPreviewItemKey: ItemState] = [:]
    private(set) var rendered: [IOSPreviewItemKey: IOSPreviewRendered] = [:]
    private(set) var activity: Activity?
    /// プロジェクトごとの、続けても同じ失敗になる理由（Xcode が無い・許可が無い・ビルド失敗）。
    private(set) var problems: [UUID: String] = [:]
    /// 描いている・待っている件のあるプロジェクト。
    private(set) var busyProjects: Set<UUID> = []
    /// どの Xcode につなぐか決められなかった時の案内。
    private(set) var xcodeNotice: String?

    private struct Job {
        let key: IOSPreviewItemKey
        let target: IOSPreviewTarget
    }

    private struct OpenedWorkspace {
        let projectId: UUID
        let xcodeProject: String
        let identifier: String
        /// 利用者が自分で開いていたものは閉じない。
        let openedByUs: Bool
        /// ファイルの絶対パス → Xcode のプロジェクトの中のパス。
        var paths: [String: String] = [:]
    }

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var current: Job?
    @ObservationIgnored private var client: XcodeBridgeClient?
    /// 今の client がつないでいる Xcode（変わったら client を作り直す）。
    @ObservationIgnored private var clientTarget: XcodeBridgeTarget?
    @ObservationIgnored private var workspace: OpenedWorkspace?
    /// 自分で開いてまだ閉じていないワークスペース（mcpbridge を起動し直しても自分のものとして閉じるため）。
    @ObservationIgnored private var ownedWorkspaces: Set<String> = []
    @ObservationIgnored private var sections = PreviewSectionPresence()
    @ObservationIgnored private var stalls = PreviewStallCounter()
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    /// 開いているプロジェクトが設定から消えた。描いている 1 件が終わったら止める。
    @ObservationIgnored private var shutdownWhenIdle = false
    @ObservationIgnored private var cancelling: Set<UUID> = []
    @ObservationIgnored private let processes = BridgeProcesses()
    @ObservationIgnored private var watchingSettings = false
    @ObservationIgnored private var knownProjects: Set<UUID> = []

    // MARK: - 頼まれること

    /// 1 件を待ち行列に足す（同じものが待っている・描いている間は足さない）。
    func render(_ target: IOSPreviewTarget, request: PreviewRenderRequest) {
        let key = IOSPreviewItemKey(projectId: target.projectId, request: request)
        if let state = states[key], state == .queued || state == .rendering { return }
        startWatchingSettings()
        cancelling.remove(target.projectId)
        problems[target.projectId] = nil
        states[key] = .queued
        queue.append(Job(key: key, target: target))
        refreshBusy()
        runNext()
    }

    /// 既定の指定で、まだ描いていない（今のソースの絵がキャッシュにも無い）ものを順に足す。
    func renderAll(_ targets: [IOSPreviewTarget]) {
        Task {
            let missing = await Task.detached(priority: .utility) {
                targets.filter { target in
                    let key = PreviewCacheKey(projectId: target.projectId, request: Self.defaultRequest(target),
                                              sourceModified: target.file.modified)
                    return PreviewSnapshotCache.lookup(key) == nil
                }
            }.value
            for target in missing {
                let key = IOSPreviewItemKey(projectId: target.projectId, request: Self.defaultRequest(target))
                // 待つ間に節を閉じたプロジェクトの分は足さない。
                guard sections.isOpen(target.projectId), current(key, sourceModified: target.file.modified) == nil else { continue }
                render(target, request: Self.defaultRequest(target))
            }
        }
    }

    nonisolated static func defaultRequest(_ target: IOSPreviewTarget) -> PreviewRenderRequest {
        PreviewRenderRequest(relativePath: target.file.relativePath, index: target.preview.index)
    }

    /// 描いた絵のうち、今のソース（走査した時の更新時刻）を描いたものだけ。書き換えた後の古い絵は出さない。
    func current(_ key: IOSPreviewItemKey, sourceModified: Date?) -> IOSPreviewRendered? {
        guard let shown = rendered[key], shown.info.isCurrent(sourceModified: sourceModified) else { return nil }
        return shown
    }

    /// 待っている分を外す。描いている 1 件は止められないので、終わるまで待つ。
    func cancel(projectId: UUID) {
        let dropped = queue.filter { $0.key.projectId == projectId }
        queue.removeAll { $0.key.projectId == projectId }
        dropped.forEach { states[$0.key] = nil }
        if current?.key.projectId == projectId {
            cancelling.insert(projectId)
            activity = .stopping
        }
        refreshBusy()
    }

    func isCancelling(_ projectId: UUID) -> Bool { cancelling.contains(projectId) && current?.key.projectId == projectId }

    func clearProblem(_ projectId: UUID) {
        problems[projectId] = nil
    }

    /// 節が開いている間は止めない。
    func sectionOpened(_ projectId: UUID) {
        sections.open(projectId)
        idleTask?.cancel()
        idleTask = nil
    }

    /// そのプロジェクトの節がどこにも開いていなくなったら待っている分を取りやめ、どこにも無ければ数分後に止める。
    func sectionClosed(_ projectId: UUID) {
        if sections.close(projectId) { cancel(projectId: projectId) }
        scheduleIdleStop()
    }

    /// キャッシュから描いた絵を探す（無ければ nil）。ソースの更新時刻が変われば別物として見つからない。
    nonisolated static func cached(_ key: PreviewCacheKey) async -> IOSPreviewRendered? {
        await Task.detached(priority: .utility) {
            PreviewSnapshotCache.lookup(key).map { IOSPreviewRendered(image: $0.image, info: $0.info) }
        }.value
    }

    /// 起動時に、設定から消えたプロジェクトのキャッシュを片付ける（設定が読めない間は消さない）。
    static func pruneCacheOnLaunch() {
        let settings = SettingsStore.shared
        guard settings.problem == nil else { return }
        let keep = Set(settings.projects.map(\.id))
        Task.detached(priority: .utility) { PreviewSnapshotCache.prune(keeping: keep) }
    }

    /// アプリの終了時。mcpbridge をグループごと止め切ってから終える。
    func stopAllBlocking() {
        queue.removeAll()
        XcodeBridgeProcess.stopAllBlocking(processes.all())
    }

    static func xcodeIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: xcodeBundleId).isEmpty
    }

    // MARK: - 描く

    private func runNext() {
        guard current == nil else { return }
        guard !queue.isEmpty else {
            activity = nil
            refreshBusy()
            if shutdownWhenIdle {
                shutdownWhenIdle = false
                shutdownBridge()
            } else {
                scheduleIdleStop()
            }
            return
        }
        let job = queue.removeFirst()
        current = job
        states[job.key] = .rendering
        refreshBusy()
        idleTask?.cancel()
        idleTask = nil
        Task {
            await perform(job)
            current = nil
            cancelling.remove(job.key.projectId)
            runNext()
        }
    }

    private func perform(_ job: Job) async {
        do {
            let target = try await xcodeTarget()
            // 別の Xcode（起動し直した・別の版）に替わったら、前の mcpbridge は使わない。
            if let clientTarget, !clientTarget.sameConnection(as: target) { shutdownBridge() }
            // 止めている途中の mcpbridge と重ねて起動しない（同時に 1 本）。
            await shutdownTask?.value
            let client = bridge(target)
            if !(await client.isRunning) {
                // 起動し直した mcpbridge では前に開いた ID は使えない。
                workspace = nil
                activity = .starting
                try await client.start()
            }
            let identifier = try await open(job.target, client: client)
            let projectPath = try await resolve(job.target.file, workspace: identifier, client: client)
            activity = .rendering(job.target.label)
            let modified = (try? FileManager.default.attributesOfItem(atPath: job.target.file.path))?[.modificationDate] as? Date
            let request = job.key.request
            let result = try await client.renderPreview(RenderPreviewArguments(
                workspaceIdentifier: identifier, sourceFilePath: projectPath, index: request.index,
                variants: request.variants, locale: request.locale, timeout: Self.renderTimeout))
            let snapshot = try result.snapshot()
            _ = stalls.record(nil)
            // 描いている間に設定から消えたプロジェクトの分は残さない。
            guard !watchingSettings || knownProjects.contains(job.key.projectId) else {
                states[job.key] = nil
                return
            }
            let info = PreviewSnapshotInfo(result: result, renderedAt: Date(), sourceModified: modified)
            let cacheKey = PreviewCacheKey(projectId: job.key.projectId, request: request, sourceModified: modified)
            let image = try await Task.detached(priority: .utility) {
                try PreviewSnapshotCache.store(snapshotPath: snapshot, info: info, key: cacheKey)
            }.value
            rendered[job.key] = IOSPreviewRendered(image: image, info: info)
            // 走査の後に書き換わったソースの絵は、一覧を読み直すまで出さない（古い行・番号と混ぜないため）。
            states[job.key] = info.isCurrent(sourceModified: job.target.file.modified) ? nil : .failed(Self.sourceChangedMessage)
        } catch let failure as XcodeBridgeFailure {
            fail(job, failure)
        } catch let rejection as PreviewSnapshotCache.SnapshotRejection {
            fail(job, .renderFailed("Xcode の返した絵を写しませんでした（\(rejection.description)）"))
        } catch {
            fail(job, .renderFailed("描いた絵を保存できませんでした（\(error.localizedDescription)）"))
        }
        if current?.key == job.key, activity != .stopping { activity = nil }
    }

    /// 動いている Xcode を数え直して、つなぐ先を決める。
    private func xcodeTarget() async throws -> XcodeBridgeTarget {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeBundleId)
            .filter { !$0.isTerminated }
            .compactMap { app in app.bundleURL.map { RunningXcode(pid: app.processIdentifier, bundlePath: $0.path) } }
        // xcode-select を読むのは、どれにつなぐか選ぶ必要がある時だけ。
        let selected: String? = running.count > 1
            ? await Task.detached(priority: .utility) { XcodeSelection.selectedDeveloperDir() }.value
            : nil
        guard let target = XcodeSelection.target(running: running, selectedDeveloperDir: selected) else {
            xcodeNotice = nil
            throw XcodeBridgeFailure.xcodeNotRunning
        }
        xcodeNotice = target.notice
        return target
    }

    private func fail(_ job: Job, _ failure: XcodeBridgeFailure) {
        states[job.key] = .failed(failure.message)
        // Xcode が終わった・mcpbridge が使えない時は、次は動いている Xcode を数え直して作り直す。
        switch failure {
        case .xcodeNotRunning, .bridgeUnavailable: shutdownBridge()
        default: break
        }
        if stalls.record(failure) {
            dropQueue(global: true, message: PreviewStallCounter.message(failure), projectId: job.key.projectId)
            return
        }
        guard failure.stopsQueue else { return }
        // 続けても同じ失敗になるので、待っている分は描かずに戻す（Xcode が無い・許可が無い時は全部）。
        let global: Bool = switch failure {
        case .buildFailed: false
        default: true
        }
        dropQueue(global: global, message: failure.message, projectId: job.key.projectId)
    }

    private func dropQueue(global: Bool, message: String, projectId: UUID) {
        problems[projectId] = message
        let dropped = queue.filter { global || $0.key.projectId == projectId }
        queue.removeAll { global || $0.key.projectId == projectId }
        dropped.forEach { states[$0.key] = nil }
        if global { dropped.forEach { problems[$0.key.projectId] = message } }
        refreshBusy()
    }

    private func bridge(_ target: XcodeBridgeTarget) -> XcodeBridgeClient {
        if let client { return client }
        // mcpbridge と xcrun をつなぐ Xcode の版にそろえ、その Xcode の PID を渡す。
        let environment = target.environment(base: ChildEnvironment.sanitized(ProcessInfo.processInfo.environment))
        let launch = XcodeBridgeProcess.launcher(environment: environment, directory: NSHomeDirectory())
        let processes = processes
        let client = XcodeBridgeClient { events in
            let transport = try launch(events)
            if let process = transport as? XcodeBridgeProcess { processes.add(process) }
            return transport
        }
        self.client = client
        clientTarget = target
        return client
    }

    /// 別のプロジェクトなら前のを（自分で開いたものだけ）閉じてから開く。開いた ID は mcpbridge が動いている間だけ使い回す。
    private func open(_ target: IOSPreviewTarget, client: XcodeBridgeClient) async throws -> String {
        if let workspace, workspace.xcodeProject == target.xcodeProject, await client.isRunning { return workspace.identifier }
        if let previous = workspace {
            workspace = nil
            await close(previous, client: client)
        }
        activity = .opening(target.projectName)
        let opened = try await client.openOwnedWorkspace(path: target.xcodeProject)
        let ours = opened.openedByUs || ownedWorkspaces.contains(target.xcodeProject)
        if ours { ownedWorkspaces.insert(target.xcodeProject) }
        workspace = OpenedWorkspace(projectId: target.projectId, xcodeProject: target.xcodeProject,
                                    identifier: opened.identifier, openedByUs: ours)
        return opened.identifier
    }

    /// 閉じられた時だけ自分のものから外す（閉じ損ねたら次に開いた時も自分のものとして閉じるため）。
    private func close(_ opened: OpenedWorkspace, client: XcodeBridgeClient) async {
        guard opened.openedByUs, (try? await client.closeWorkspace(opened.identifier)) != nil else { return }
        ownedWorkspaces.remove(opened.xcodeProject)
    }

    private func resolve(_ file: SwiftPreviewFile, workspace identifier: String, client: XcodeBridgeClient) async throws -> String {
        if let known = workspace?.paths[file.path] { return known }
        let found = try await client.glob(workspace: identifier, pattern: XcodeProjectPaths.globPattern(forFileName: file.name))
        switch XcodeProjectPaths.match(found.matches, truncated: found.truncated ?? false, relativePath: file.relativePath) {
        case .found(let path):
            workspace?.paths[file.path] = path
            return path
        case .notFound:
            throw XcodeBridgeFailure.notInProject(file.relativePath)
        case .ambiguous:
            throw XcodeBridgeFailure.ambiguousInProject(file.relativePath)
        }
    }

    private func refreshBusy() {
        var ids = Set(queue.map(\.key.projectId))
        if let current { ids.insert(current.key.projectId) }
        if ids != busyProjects { busyProjects = ids }
    }

    // MARK: - 止める

    private func scheduleIdleStop() {
        guard !sections.anyOpen, current == nil, queue.isEmpty, client != nil else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, !sections.anyOpen, current == nil, queue.isEmpty else { return }
            shutdownBridge()
        }
    }

    /// 自分で開いたプロジェクトを閉じ、mcpbridge を止める。
    private func shutdownBridge() {
        guard let client else { return }
        self.client = nil
        clientTarget = nil
        let opened = workspace
        workspace = nil
        let previous = shutdownTask
        let processes = processes
        shutdownTask = Task {
            await previous?.value
            if let opened, await client.isRunning { await close(opened, client: client) }
            await client.stop()
            processes.prune()
        }
    }

    // MARK: - 設定からの削除

    private func startWatchingSettings() {
        guard !watchingSettings else { return }
        watchingSettings = true
        knownProjects = Set(SettingsStore.shared.projects.map(\.id))
        observeSettings()
    }

    private func observeSettings() {
        let ids = withObservationTracking {
            Set(SettingsStore.shared.projects.map(\.id))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeSettings() }
        }
        // 読めない設定（壊れた JSON 等）の間は一覧が空に見えるので何もしない。
        guard SettingsStore.shared.problem == nil else { return }
        let removed = knownProjects.subtracting(ids)
        knownProjects = ids
        guard !removed.isEmpty else { return }
        for id in removed { cancel(projectId: id) }
        states = states.filter { !removed.contains($0.key.projectId) }
        rendered = rendered.filter { !removed.contains($0.key.projectId) }
        removed.forEach { problems[$0] = nil }
        Task.detached(priority: .utility) {
            for id in removed { PreviewSnapshotCache.removeProject(id) }
        }
        // 開いているのが消えたプロジェクトなら閉じて止める（描いている 1 件があれば終わってから）。
        guard let workspace, removed.contains(workspace.projectId) else { return }
        if current == nil {
            shutdownBridge()
        } else {
            shutdownWhenIdle = true
        }
    }
}

/// 起動した mcpbridge（アプリの終了時に止め切るため）。
private final class BridgeProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [XcodeBridgeProcess] = []

    func add(_ process: XcodeBridgeProcess) {
        lock.withLock { processes.append(process) }
    }

    func all() -> [XcodeBridgeProcess] {
        lock.withLock { processes.filter { !$0.isFinished } }
    }

    func prune() {
        lock.withLock { processes.removeAll { $0.isFinished } }
    }
}


/// 描いた PNG のサムネイルと拡大の読み込み（縮小はバックグラウンドで・NSCache に持つ）。
@MainActor
final class IOSPreviewImages {
    static let shared = IOSPreviewImages()
    static let thumbnailPixels = 520
    static let previewPixels = 1600

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    /// 同じ指定を描き直すと同じ名前に書くので、描いた時刻も鍵に含める。
    private static func key(_ rendered: IOSPreviewRendered, maxPixels: Int) -> NSString {
        "\(rendered.image.path)|\(rendered.info.renderedAt.timeIntervalSince1970)|\(maxPixels)" as NSString
    }

    func cached(_ rendered: IOSPreviewRendered, maxPixels: Int) -> NSImage? {
        cache.object(forKey: Self.key(rendered, maxPixels: maxPixels))
    }

    func load(_ rendered: IOSPreviewRendered, maxPixels: Int) async -> NSImage? {
        let key = Self.key(rendered, maxPixels: maxPixels)
        let url = rendered.image
        if let image = cache.object(forKey: key) { return image }
        let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedPreview? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = ImageDecoding.thumbnail(of: source, maxPixels: maxPixels) else { return nil }
            return DecodedPreview(image: image)
        }.value
        guard let decoded else { return nil }
        let image = NSImage(pixelSized: decoded.image)
        cache.setObject(image, forKey: key)
        return image
    }
}

private struct DecodedPreview: @unchecked Sendable {
    let image: CGImage
}

/// 節ごとの `#Preview` の一覧（走査はバックグラウンドで・取り消せる）。
@MainActor
@Observable
final class IOSPreviewList {
    private(set) var scan: SwiftPreviewScan?
    private(set) var scanning = false
    @ObservationIgnored private var generation = 0

    /// 走り切って反映した時だけ true。
    @discardableResult
    func reload(root: String) async -> Bool {
        generation += 1
        let current = generation
        scanning = true
        let task = Task.detached(priority: .userInitiated) {
            SwiftPreviews.scan(root: root, isCancelled: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == current else { return false }
        scanning = false
        guard !Task.isCancelled else { return false }
        scan = result
        return true
    }
}
