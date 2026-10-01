import Foundation
import Observation

/// monitor との接続状態。
public enum MonitorConnectionState: Sendable, Equatable {
    /// `start()` 前、または `stop()` 後。
    case idle
    case connecting(attempt: Int)
    case connected(since: Date)
    /// 繋がらない・切れた。`retryAt` に自動で張り直す。
    case disconnected(reason: String, retryAt: Date)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// monitor の SSE を購読し、セッション・フィード・残量・権限確認を保持する観測可能なストア。
/// 切れている間も sessions / usage / feed は最後に受け取った値を残す（鮮度は `connection` で判断する）。
@MainActor
@Observable
public final class MonitorStore {
    public let client: MonitorClient

    public private(set) var connection: MonitorConnectionState = .idle
    public private(set) var sessions: [SessionSnapshot] = []
    public private(set) var feed: [FeedItem] = []
    public private(set) var usage: UsageSnapshot?
    /// 保留中の権限確認。切れている間は答えられないので空にする。
    public private(set) var permissions: [PendingPermission] = []
    /// 繋がるたびに増える。取りこぼしを埋める GET（transcript 等）をやり直す合図に使う。
    public private(set) var connectionEpoch = 0
    public private(set) var lastEventAt: Date?
    public private(set) var transcriptSubscription: TranscriptSubscription = .none
    /// アプリが PTY でホストしている claude の pid → sessionId。
    public private(set) var hostedSessionIds: [Int32: String] = [:]

    /// フィードを何件まで持つか。
    public var feedLimit = 500

    /// SSE `transcript` の受け口（チャット画面が使う）。
    @ObservationIgnored public var onTranscript: ((TranscriptEvent) -> Void)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let registry: ClaudeSessionRegistry
    @ObservationIgnored private var hostedPids: Set<Int32> = []
    @ObservationIgnored private var lastLoggedSessions = ""

    public init(client: MonitorClient = MonitorClient(), registry: ClaudeSessionRegistry = ClaudeSessionRegistry()) {
        self.client = client
        self.registry = registry
    }

    public var isRunning: Bool { task != nil }

    // MARK: - 接続

    public func start() {
        guard task == nil else { return }
        let stream = client.events(transcripts: transcriptSubscription)
        log("接続開始: \(client.eventsURL(transcripts: transcriptSubscription).absoluteString)")
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        connection = .idle
        permissions = []
    }

    /// transcript を流してもらう対象を変える。購読中なら張り直す。
    public func setTranscriptSubscription(_ subscription: TranscriptSubscription) {
        guard subscription != transcriptSubscription else { return }
        transcriptSubscription = subscription
        guard task != nil else { return }
        stop()
        start()
    }

    // MARK: - 参照

    public func session(id: String) -> SessionSnapshot? {
        sessions.first { $0.sessionId == id }
    }

    public func permissions(forSessionId id: String) -> [PendingPermission] {
        permissions.filter { $0.sessionId == id }
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

    public func sendMessage(to sessionId: String, text: String) async throws {
        try await client.sendMessage(sessionId: sessionId, text: text)
    }

    /// 答えた確認は次の `permissions` を待たずに消す（二度押しさせないため）。
    public func decide(_ permission: PendingPermission, _ decision: PermissionDecision) async throws {
        do {
            try await client.decidePermission(key: permission.key, decision: decision)
            permissions.removeAll { $0.key == permission.key }
        } catch MonitorError.http(status: 404, _, _) {
            // 端末側で先に答えられた・期限切れ。もう待っていないので消してから知らせる。
            permissions.removeAll { $0.key == permission.key }
            throw MonitorError.http(status: 404, code: nil, message: "この確認はもう待っていません")
        }
    }

    public func open(sessionId: String, in app: OpenApp) async throws {
        try await client.open(sessionId: sessionId, app: app)
    }

    public func close(sessionId: String, in app: CloseApp = .xcode) async throws -> CloseState {
        try await client.close(sessionId: sessionId, app: app)
    }

    // MARK: - 反映

    func apply(_ event: MonitorClientEvent) {
        switch event {
        case .connecting(let attempt):
            connection = .connecting(attempt: attempt)
            if attempt == 0 { log("接続中…") }
        case .connected:
            connection = .connected(since: Date())
            connectionEpoch += 1
            log("接続しました（epoch \(connectionEpoch)）")
        case .disconnected(let reason, let retryIn):
            connection = .disconnected(reason: reason, retryAt: Date().addingTimeInterval(retryIn))
            permissions = []
            log("未接続: \(reason)（\(String(format: "%.1f", retryIn)) 秒後に再接続）")
        case .decodingFailed(let name, let message):
            log("デコード失敗 \(name): \(message)")
        case .event(let monitorEvent):
            lastEventAt = Date()
            apply(monitorEvent)
        }
    }

    private func apply(_ event: MonitorEvent) {
        switch event {
        case .sessions(let list):
            if list != sessions { sessions = list }
            resolveHostedSessions()
            logSessionsIfChanged()
        case .feedBatch(let items):
            // monitor の再起動で id は振り直されるので、手元の分とは混ぜずに置き換える。
            feed = Array(items.sorted { $0.id < $1.id }.suffix(feedLimit))
            log("フィード \(items.count) 件を受信")
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
        case .unknown(let name):
            log("未知のイベント: \(name)")
        }
    }

    // MARK: - デバッグ出力

    private func logSessionsIfChanged() {
        guard client.configuration.debugLogging else { return }
        let summary = sessions.map { "\($0.name)[pid \($0.pid)] \($0.status.rawValue)" }.joined(separator: ", ")
        guard summary != lastLoggedSessions else { return }
        lastLoggedSessions = summary
        log("セッション \(sessions.count) 件: \(summary)")
    }

    private func log(_ message: @autoclosure () -> String) {
        guard client.configuration.debugLogging else { return }
        FileHandle.standardError.write(Data("[monitor] \(message())\n".utf8))
    }

    private static func describe(_ usage: UsageSnapshot?) -> String {
        guard let usage else { return "未取得（statusLine 未設定）" }
        func fmt(_ w: UsageWindow?) -> String { w.map { String(format: "残り %.0f%%", $0.remainingPercentage) } ?? "-" }
        return "5h \(fmt(usage.fiveHour)) / 週 \(fmt(usage.sevenDay))"
    }
}
