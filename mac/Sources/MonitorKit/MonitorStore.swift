import Foundation
import Observation

/// アプリ内の監視の状態。
public enum MonitorConnectionState: Sendable, Equatable {
    /// `start()` 前、または `stop()` 後。
    case idle
    /// 初回の走査中。
    case starting
    case connected(since: Date)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// セッション・フィード・残量・権限確認を保持する観測可能なストア。
/// データ源はアプリ内の監視（`SessionHub` / `TranscriptStore`）で、フック等の外からの口は `LoopbackHTTPServer` で受ける。
@MainActor
@Observable
public final class MonitorStore {
    public let configuration: MonitorConfiguration
    @ObservationIgnored public let hub: SessionHub
    @ObservationIgnored public let transcripts: TranscriptStore

    public private(set) var connection: MonitorConnectionState = .idle
    /// フック等の受け口（:8766）の状態。使用中なら旧 monitor 等が動いていて、フックはこちらに届かない。
    public private(set) var serverState: LoopbackServerState = .stopped
    public private(set) var sessions: [SessionSnapshot] = []
    public private(set) var feed: [FeedItem] = []
    public private(set) var usage: UsageSnapshot?
    /// 保留中の権限確認。
    public private(set) var permissions: [PendingPermission] = []
    /// 監視を始めるたびに増える。取りこぼしを埋める取得（transcript 等）をやり直す合図に使う。
    public private(set) var connectionEpoch = 0
    public private(set) var lastEventAt: Date?
    public private(set) var transcriptSubscription: TranscriptSubscription = .none
    /// アプリが PTY でホストしている claude の pid → sessionId。
    public private(set) var hostedSessionIds: [Int32: String] = [:]

    /// フィードを何件まで持つか。
    public var feedLimit = 500

    /// 会話の追記の受け口（チャット画面が使う）。
    @ObservationIgnored public var onTranscript: ((TranscriptEvent) -> Void)?

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var continuation: AsyncStream<MonitorEvent>.Continuation?
    @ObservationIgnored private var transcriptSubscriberId: Int?
    @ObservationIgnored private var server: LoopbackHTTPServer?
    @ObservationIgnored private var serverRetry: Task<Void, Never>?
    @ObservationIgnored private let registry: ClaudeSessionRegistry
    @ObservationIgnored private var hostedPids: Set<Int32> = []
    @ObservationIgnored private var lastLoggedSessions = ""
    @ObservationIgnored private var running = false
    /// 開始・停止のたびに増える。止めた後に終わった開始処理が「接続済み」にしないようにする。
    @ObservationIgnored private var runGeneration = 0
    /// 監視の開始・停止を順に流す（停止の後始末が次の開始の受け口を外さないように）。
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    /// 購読の張り替えを順に流す（連続して呼ばれても購読を二重に持たない・取りこぼさない）。
    @ObservationIgnored private var subscriptionChain: Task<Void, Never>?

    public init(configuration: MonitorConfiguration = .fromEnvironment(), registry: ClaudeSessionRegistry? = nil) {
        self.configuration = configuration
        self.registry = registry ?? ClaudeSessionRegistry(directory: configuration.claudeHome.sessionsDirectory)
        transcripts = TranscriptStore(home: configuration.claudeHome)
        hub = SessionHub(home: configuration.claudeHome, usageFile: configuration.usageFile,
                         legacyUsageFile: configuration.legacyUsageFile, transcripts: transcripts)
    }

    public var isRunning: Bool { running }

    // MARK: - 開始・停止

    public func start() {
        guard !running else { return }
        running = true
        runGeneration += 1
        let generation = runGeneration
        connection = .starting
        let (stream, continuation) = AsyncStream<MonitorEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        tasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        })
        let hub = hub
        let previous = lifecycle
        lifecycle = Task { [weak self] in
            await previous?.value
            guard self?.runGeneration == generation else { return }
            await hub.setSink { continuation.yield($0) }
            await hub.start()
            guard let self, self.running, self.runGeneration == generation else { return }
            self.connection = .connected(since: Date())
            self.connectionEpoch += 1
            self.log("監視を開始しました（\(self.configuration.claudeHome.root.path)）")
            // 会話の購読は接続の後に張る（全件の読み込みで入力欄を待たせないため）。
            self.resubscribeTranscripts()
        }
        startServer()
    }

    public func stop() {
        guard running else { return }
        running = false
        runGeneration += 1
        tasks.forEach { $0.cancel() }
        tasks = []
        continuation?.finish()
        continuation = nil
        let hub = hub
        let previous = lifecycle
        let subscriptions = subscriptionChain
        lifecycle = Task { [weak self] in
            await previous?.value
            await subscriptions?.value
            await hub.stop()
            await hub.setSink(nil)
            if let self, let subscriber = self.transcriptSubscriberId {
                self.transcriptSubscriberId = nil
                await self.transcripts.unsubscribe(subscriber)
            }
        }
        serverRetry?.cancel()
        serverRetry = nil
        server?.stop()
        server = nil
        serverState = .stopped
        connection = .idle
        permissions = []
    }

    /// 開始・停止の処理が終わるまで待つ（試験用）。
    func settle() async {
        await lifecycle?.value
        await subscriptionChain?.value
    }

    /// 会話の追記を流してもらう対象を変える。
    public func setTranscriptSubscription(_ subscription: TranscriptSubscription) {
        guard subscription != transcriptSubscription else { return }
        transcriptSubscription = subscription
        guard running, connection.isConnected else { return }
        resubscribeTranscripts()
    }

    /// 対象を変え、張り替え終わるまで待つ。この後に取得すれば、取得と追記の間に隙間ができない。
    public func watchTranscripts(_ sessionIds: Set<String>) async {
        setTranscriptSubscription(sessionIds.isEmpty ? .none : .sessions(sessionIds))
        await subscriptionChain?.value
    }

    private func resubscribeTranscripts() {
        let previous = subscriptionChain
        let generation = runGeneration
        subscriptionChain = Task { [weak self] in
            await previous?.value
            guard let self, self.running, self.runGeneration == generation else { return }
            await self.subscribeTranscripts()
        }
    }

    private func subscribeTranscripts() async {
        guard let continuation else { return }
        let old = transcriptSubscriberId
        transcriptSubscriberId = await transcripts.subscribe(transcriptSubscription, replacing: old) { continuation.yield(.transcript($0)) }
    }

    // MARK: - アプリ内サーバー

    private func startServer() {
        guard let port = configuration.serverPort else {
            serverState = .stopped
            return
        }
        let hub = hub
        let server = LoopbackHTTPServer { request in await MonitorHTTPRoutes.handle(request, hub: hub) }
        self.server = server
        listen(server, port: port)
    }

    private func listen(_ server: LoopbackHTTPServer, port: Int) {
        serverState = .starting
        server.start(port: port) { [weak self] state in
            Task { @MainActor in self?.serverChanged(state, server: server, port: port) }
        }
    }

    private func serverChanged(_ state: LoopbackServerState, server: LoopbackHTTPServer, port: Int) {
        guard running, server === self.server else { return }
        serverState = state
        switch state {
        case .listening(let bound):
            log("受け口を開きました: http://127.0.0.1:\(bound)")
        case .portInUse, .failed:
            log("受け口を開けません（\(state)）。\(configuration.serverRetryInterval) 秒後に取り直します")
            // 自分の起動したものではないので止めない。空いたら引き継ぐ。
            serverRetry?.cancel()
            let interval = configuration.serverRetryInterval
            serverRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, self.running, server === self.server else { return }
                self.listen(server, port: port)
            }
        case .starting, .stopped:
            break
        }
    }

    // MARK: - 参照

    public func session(id: String) -> SessionSnapshot? {
        sessions.first { $0.sessionId == id }
    }

    public func permissions(forSessionId id: String) -> [PendingPermission] {
        permissions.filter { $0.sessionId == id }
    }

    /// 会話履歴。ログが見つからなければ nil（最初の発話前はまだ無い）。
    public func fetchTranscript(sessionId: String, after: String? = nil) async -> TranscriptResponse? {
        await transcripts.get(sessionId, after: after)
    }

    /// 発話に添えられた画像の本体（`TranscriptItem.images` の `index`）。どのスレッドからでも呼べる。
    public nonisolated var imageSource: @Sendable (String, String, Int) async -> Data? {
        let transcripts = transcripts
        return { sessionId, itemId, index in
            await transcripts.image(sessionId: sessionId, itemId: itemId, index: index)?.data
        }
    }

    // MARK: - アプリがホストするセッションとの対応付け

    /// PTY で起動した claude の pid を登録する。sessionId は `~/.claude/sessions/<pid>.json` から引く。
    public func registerHostedProcess(pid: Int32) {
        guard pid > 0 else { return }
        hostedPids.insert(pid)
        resolveHostedSessions()
    }

    public func unregisterHostedProcess(pid: Int32) {
        hostedPids.remove(pid)
        hostedSessionIds[pid] = nil
    }

    /// レジストリを読み直す。claude の起動直後はまだファイルが無く、`/clear` で sessionId が替わるので繰り返し呼ぶ。
    public func resolveHostedSessions() {
        var resolved: [Int32: String] = [:]
        for pid in hostedPids {
            if let id = registry.sessionId(forPid: pid) {
                resolved[pid] = id
            } else if let match = sessions.first(where: { $0.pid == pid && $0.alive }) {
                resolved[pid] = match.sessionId
            }
        }
        if resolved != hostedSessionIds {
            hostedSessionIds = resolved
            log("ホスト中の対応: \(resolved.map { "\($0.key)→\($0.value)" }.sorted().joined(separator: ", "))")
        }
    }

    public func sessionId(forHostedPid pid: Int32) -> String? {
        hostedSessionIds[pid]
    }

    public func session(forHostedPid pid: Int32) -> SessionSnapshot? {
        guard let id = hostedSessionIds[pid] else { return nil }
        return session(id: id)
    }

    /// アプリの外（VSCode・別ターミナル等）で動いているセッション。
    public var externalSessions: [SessionSnapshot] {
        let hosted = Set(hostedSessionIds.values)
        return sessions.filter { !hosted.contains($0.sessionId) }
    }

    // MARK: - 書き込み

    /// そのセッションの受信箱へ伝言を送る。失敗は `HubFailure`。
    public func sendMessage(to sessionId: String, text: String) async throws {
        try await hub.sendMessage(sessionId: sessionId, text: text)
    }

    /// 答えた確認は次の `permissions` を待たずに消す（二度押しさせないため）。
    public func decide(_ permission: PendingPermission, _ decision: PermissionDecision) async throws {
        let pending = await hub.decidePermission(key: permission.key, decision: decision)
        permissions.removeAll { $0.key == permission.key }
        // 端末側で先に答えられた・期限切れ。もう待っていないので消してから知らせる。
        if pending == nil { throw HubFailure(code: "not_found", message: "この確認はもう待っていません") }
    }

    public func open(sessionId: String, in app: OpenApp) async throws {
        try await hub.openInApp(sessionId: sessionId, app: app)
    }

    public func close(sessionId: String, in app: CloseApp = .xcode) async throws -> CloseState {
        try await hub.closeInApp(sessionId: sessionId, app: app)
    }

    // MARK: - 反映

    func apply(_ event: MonitorEvent) {
        lastEventAt = Date()
        switch event {
        case .sessions(let list):
            if list != sessions { sessions = list }
            resolveHostedSessions()
            logSessionsIfChanged()
        case .feedBatch(let items):
            feed = Array(items.sorted { $0.id < $1.id }.suffix(feedLimit))
        case .feed(let item):
            guard !feed.contains(where: { $0.id == item.id }) else { return }
            feed.append(item)
            if feed.count > feedLimit { feed.removeFirst(feed.count - feedLimit) }
        case .usage(let snapshot):
            usage = snapshot
            log("残量: \(Self.describe(snapshot))")
        case .permissions(let list):
            permissions = list
            log("権限確認 \(list.count) 件: \(list.map { "\($0.toolName)@\($0.project ?? "?")" }.joined(separator: ", "))")
        case .transcript(let transcript):
            onTranscript?(transcript)
        }
    }

    // MARK: - デバッグ出力

    private func logSessionsIfChanged() {
        guard configuration.debugLogging else { return }
        let summary = sessions.map { "\($0.name)[pid \($0.pid)] \($0.status.rawValue)" }.joined(separator: ", ")
        guard summary != lastLoggedSessions else { return }
        lastLoggedSessions = summary
        log("セッション \(sessions.count) 件: \(summary)")
    }

    private func log(_ message: @autoclosure () -> String) {
        guard configuration.debugLogging else { return }
        FileHandle.standardError.write(Data("[monitor] \(message())\n".utf8))
    }

    private static func describe(_ usage: UsageSnapshot?) -> String {
        guard let usage else { return "未取得（statusLine 未設定）" }
        func fmt(_ w: UsageWindow?) -> String { w.map { String(format: "残り %.0f%%", $0.remainingPercentage) } ?? "-" }
        return "5h \(fmt(usage.fiveHour)) / 週 \(fmt(usage.sevenDay))"
    }
}
