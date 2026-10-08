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

    private(set) var states: [IOSPreviewItemKey: ItemState] = [:]
    private(set) var rendered: [IOSPreviewItemKey: IOSPreviewRendered] = [:]
    private(set) var activity: Activity?
    /// プロジェクトごとの、続けても同じ失敗になる理由（Xcode が無い・許可が無い・ビルド失敗）。
    private(set) var problems: [UUID: String] = [:]
    /// 描いている・待っている件のあるプロジェクト。
    private(set) var busyProjects: Set<UUID> = []

    private struct Job {
        let key: IOSPreviewItemKey
        let target: IOSPreviewTarget
    }

    private struct OpenedWorkspace {
        let projectId: UUID
        let xcodeProject: String
        let identifier: String
        /// ファイルの絶対パス → Xcode のプロジェクトの中のパス。
        var paths: [String: String] = [:]
    }

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var current: Job?
    @ObservationIgnored private var client: XcodeBridgeClient?
    @ObservationIgnored private var workspace: OpenedWorkspace?
    @ObservationIgnored private var openSections = 0
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

    /// 既定の指定で、まだ描いていない（キャッシュにも無い）ものを順に足す。
    func renderAll(_ targets: [IOSPreviewTarget]) {
        Task {
            let missing = await Task.detached(priority: .utility) {
                targets.filter { target in
                    let key = PreviewCacheKey(projectId: target.projectId, request: Self.defaultRequest(target),
                                              sourceModified: target.file.modified)
                    return PreviewSnapshotCache.lookup(key) == nil
                }
            }.value
            for target in missing where rendered[IOSPreviewItemKey(projectId: target.projectId, request: Self.defaultRequest(target))] == nil {
                render(target, request: Self.defaultRequest(target))
            }
        }
    }

    nonisolated static func defaultRequest(_ target: IOSPreviewTarget) -> PreviewRenderRequest {
        PreviewRenderRequest(relativePath: target.file.relativePath, index: target.preview.index)
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

    /// 節が開いている間は止めない。閉じたら数分後に止める。
    func sectionOpened() {
        openSections += 1
        idleTask?.cancel()
        idleTask = nil
    }

    func sectionClosed() {
        openSections = max(0, openSections - 1)
        scheduleIdleStop()
    }

    /// キャッシュから描いた絵を探す（無ければ nil）。ソースの更新時刻が変われば別物として見つからない。
    nonisolated static func cached(_ key: PreviewCacheKey) async -> IOSPreviewRendered? {
        await Task.detached(priority: .utility) {
            PreviewSnapshotCache.lookup(key).map { IOSPreviewRendered(image: $0.image, info: $0.info) }
        }.value
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
            guard Self.xcodeIsRunning() else { throw XcodeBridgeFailure.xcodeNotRunning }
            // 止めている途中の mcpbridge と重ねて起動しない（同時に 1 本）。
            await shutdownTask?.value
            let client = bridge()
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
            let snapshot = URL(fileURLWithPath: try result.snapshot())
            // 描いている間に設定から消えたプロジェクトの分は残さない。
            guard !watchingSettings || knownProjects.contains(job.key.projectId) else {
                states[job.key] = nil
                return
            }
            let info = PreviewSnapshotInfo(result: result, renderedAt: Date())
            let cacheKey = PreviewCacheKey(projectId: job.key.projectId, request: request, sourceModified: modified)
            let image = try await Task.detached(priority: .utility) {
                try PreviewSnapshotCache.store(snapshotAt: snapshot, info: info, key: cacheKey)
            }.value
            rendered[job.key] = IOSPreviewRendered(image: image, info: info)
            states[job.key] = nil
        } catch let failure as XcodeBridgeFailure {
            fail(job, failure)
        } catch {
            fail(job, .renderFailed("描いた絵を保存できませんでした（\(error.localizedDescription)）"))
        }
        if current?.key == job.key, activity != .stopping { activity = nil }
    }

    private func fail(_ job: Job, _ failure: XcodeBridgeFailure) {
        states[job.key] = .failed(failure.message)
        guard failure.stopsQueue else { return }
        problems[job.key.projectId] = failure.message
        // 続けても同じ失敗になるので、待っている分は描かずに戻す（Xcode が無い・許可が無い時は全部）。
        let global: Bool = switch failure {
        case .buildFailed: false
        default: true
        }
        let dropped = queue.filter { global || $0.key.projectId == job.key.projectId }
        queue.removeAll { global || $0.key.projectId == job.key.projectId }
        dropped.forEach { states[$0.key] = nil }
        if global { dropped.forEach { problems[$0.key.projectId] = failure.message } }
        if case .bridgeUnavailable = failure { workspace = nil }
    }

    private func bridge() -> XcodeBridgeClient {
        if let client { return client }
        var environment = ChildEnvironment.sanitized(ProcessInfo.processInfo.environment)
        // Xcode が 1 つだけ動いていればそれにつなぐ（xcode-select の Xcode が動いていない時も描けるように）。
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.xcodeBundleId)
        if running.count == 1 { environment["MCP_XCODE_PID"] = String(running[0].processIdentifier) }
        let launch = XcodeBridgeProcess.launcher(environment: environment, directory: NSHomeDirectory())
        let processes = processes
        let client = XcodeBridgeClient { events in
            let transport = try launch(events)
            if let process = transport as? XcodeBridgeProcess { processes.add(process) }
            return transport
        }
        self.client = client
        return client
    }

    /// 別のプロジェクトなら前のを閉じてから開く。開いた ID は mcpbridge が動いている間だけ使い回す。
    private func open(_ target: IOSPreviewTarget, client: XcodeBridgeClient) async throws -> String {
        if let workspace, workspace.xcodeProject == target.xcodeProject, await client.isRunning { return workspace.identifier }
        if let previous = workspace {
            workspace = nil
            try? await client.closeWorkspace(previous.identifier)
        }
        activity = .opening(target.projectName)
        let opened = try await client.openWorkspace(path: target.xcodeProject)
        workspace = OpenedWorkspace(projectId: target.projectId, xcodeProject: target.xcodeProject,
                                    identifier: opened.workspaceIdentifier)
        return opened.workspaceIdentifier
    }

    private func resolve(_ file: SwiftPreviewFile, workspace identifier: String, client: XcodeBridgeClient) async throws -> String {
        if let known = workspace?.paths[file.path] { return known }
        let found = try await client.glob(workspace: identifier, pattern: XcodeProjectPaths.globPattern(forFileName: file.name))
        guard let path = XcodeProjectPaths.bestMatch(found.matches, relativePath: file.relativePath) else {
            throw XcodeBridgeFailure.notInProject(file.relativePath)
        }
        workspace?.paths[file.path] = path
        return path
    }

    private func refreshBusy() {
        var ids = Set(queue.map(\.key.projectId))
        if let current { ids.insert(current.key.projectId) }
        if ids != busyProjects { busyProjects = ids }
    }

    // MARK: - 止める

    private func scheduleIdleStop() {
        guard openSections == 0, current == nil, queue.isEmpty, client != nil else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, openSections == 0, current == nil, queue.isEmpty else { return }
            shutdownBridge()
        }
    }

    /// 開いたプロジェクトを閉じ、mcpbridge を止める。
    private func shutdownBridge() {
        guard let client else { return }
        self.client = nil
        let opened = workspace
        workspace = nil
        let previous = shutdownTask
        let processes = processes
        shutdownTask = Task {
            await previous?.value
            if let opened, await client.isRunning { try? await client.closeWorkspace(opened.identifier) }
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
