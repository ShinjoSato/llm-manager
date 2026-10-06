import Foundation

/// フック受け口が受け取るペイロード（Claude Code のフック JSON のうち使う分）。
public struct HookPayload: Sendable, Equatable {
    public var sessionId: String?
    public var hookEventName: String?
    public var toolName: String?
    public var notificationType: String?
    public var notificationMessage: String?
    public var errorType: String?
    public var errorMessage: String?
    public var agentType: String?

    public init(sessionId: String? = nil, hookEventName: String? = nil, toolName: String? = nil,
                notificationType: String? = nil, notificationMessage: String? = nil, errorType: String? = nil,
                errorMessage: String? = nil, agentType: String? = nil) {
        self.sessionId = sessionId
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.notificationType = notificationType
        self.notificationMessage = notificationMessage
        self.errorType = errorType
        self.errorMessage = errorMessage
        self.agentType = agentType
    }

    /// JSON のオブジェクトから読む。文字列でない値は無いものとして扱う。
    public init(json o: [String: Any]) {
        self.init(sessionId: JSONLoose.string(o["session_id"]),
                  hookEventName: JSONLoose.string(o["hook_event_name"]),
                  toolName: JSONLoose.string(o["tool_name"]),
                  notificationType: JSONLoose.string(o["notification_type"]),
                  notificationMessage: JSONLoose.string(o["notification_message"]),
                  errorType: JSONLoose.string(o["error_type"]),
                  errorMessage: JSONLoose.string(o["error_message"]),
                  agentType: JSONLoose.string(o["agent_type"]))
    }
}

/// 伝言・エディタ操作の失敗。`code` は画面の言い換えに使う（not_found / not_alive / no_socket / unreachable / no_project / failed）。
public struct HubFailure: Error, Sendable, Equatable, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 長ポーリングの待ち手の番号。登録（actor 上）と取り消し（任意のスレッド）の間で受け渡す。
final class WaiterTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    var id: Int? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 待ち行列から溢れて捨てたフックの数。積む側（任意のスレッド）と流す側の間で受け渡す。
final class HookDropCounter: @unchecked Sendable {
    private let lock = NSLock()
    /// セッションごとの件数。どのルームの状態が古いままかを知らせるため。
    private var counts: [String: Int] = [:]
    /// セッションの分からない分。どのルームにも出せないので合計にだけ数える。
    private var unattributed = 0

    func add(sessionId: String?) {
        lock.withLock {
            if let sessionId, !sessionId.isEmpty { counts[sessionId, default: 0] += 1 } else { unattributed += 1 }
        }
    }

    var total: Int { lock.withLock { counts.values.reduce(unattributed, +) } }

    /// 溜まった分を取り出して空に戻す。
    func take() -> (bySession: [String: Int], total: Int) {
        lock.withLock {
            defer { counts = [:]; unattributed = 0 }
            return (counts, counts.values.reduce(unattributed, +))
        }
    }
}

/// 在庫層・実況層・フック層を 1 つの状態に束ね、変化を `MonitorEvent` の流れとして受け手へ渡す。
public actor SessionHub {
    /// ログが「モデルの番」で終わったまま、この時間を超えて無音なら稼働中とみなさない（中断やクラッシュの保険）。
    static let staleBusy: Double = 10 * 60_000
    public static let inventoryInterval: Duration = .seconds(3)
    public static let transcriptInterval: Duration = .milliseconds(250)
    /// 経過時間だけで状態が変わる分（稼働中 → 待機など）も配るための間隔。
    public static let snapshotInterval: Duration = .seconds(1)

    public let home: ClaudeHome
    private let now: @Sendable () -> Double
    private let transcripts: TranscriptStore?
    public typealias MetaResult = (meta: (title: String?, lastPrompt: String?)?, xcodeProject: String?)
    private let metaLoader: @Sendable (_ cwd: String, _ transcriptPath: String?) -> MetaResult

    /// セッションの辞書。出し入れはこの actor の中だけで行い、各層には State を渡して書かせる。
    private var sessions: [String: SessionState] = [:]
    private var scanner: InventoryScanner
    private var poller: TranscriptPoller
    private var permissions = PermissionRegistry()
    private var feedSeq = 0
    private var usagePoller: UsagePoller
    private var tasks: [Task<Void, Never>] = []
    /// `start` の途中（初回走査の await 中）に再び呼ばれても二重に回さないため。
    private var starting = false
    /// 最後に呼ばれたのが start か stop か。初回走査の後にループを立てるかはこれで決める。
    private var wantsRunning = false
    private var sink: (@Sendable (MonitorEvent) -> Void)?

    private enum HookMessage: Sendable {
        /// `receivedAt` は受け口に届いた時刻。反映が遅れてもログ行との前後はこれで比べる。
        case hook(HookPayload, receivedAt: Double)
        case flush(CheckedContinuation<Void, Never>)
    }
    /// フックは届いた順に 1 本の流れで反映する。HTTP の応答は反映を待たない。
    private nonisolated let hookInbox: AsyncStream<HookMessage>.Continuation
    private nonisolated let droppedHooks = HookDropCounter()
    /// 受信時刻の取得と積むことを一続きにする（待ち行列の順を時刻の順にそろえる）。
    private nonisolated let hookOrder = NSLock()
    public static let hookBufferLimit = 4096

    public init(home: ClaudeHome,
                usageFile: URL?,
                transcripts: TranscriptStore? = nil,
                now: @escaping @Sendable () -> Double = epochMillisNow,
                isAlive: @escaping @Sendable (Int32) -> Bool = SessionInventory.processAlive,
                hookBufferLimit: Int = SessionHub.hookBufferLimit,
                metaLoader: @escaping @Sendable (_ cwd: String, _ transcriptPath: String?) -> MetaResult = SessionHub.loadMetaFromDisk) {
        self.home = home
        usagePoller = UsagePoller(file: usageFile)
        self.transcripts = transcripts
        self.now = now
        scanner = InventoryScanner(directory: home.sessionsDirectory, isAlive: isAlive)
        self.metaLoader = metaLoader
        poller = TranscriptPoller(home: home, startedAt: now())
        let (stream, inbox) = AsyncStream<HookMessage>.makeStream(bufferingPolicy: .bufferingNewest(max(1, hookBufferLimit)))
        hookInbox = inbox
        let dropped = droppedHooks
        Task { [weak self] in
            for await message in stream {
                let lost = dropped.take()
                if lost.total > 0 { await self?.reportDroppedHooks(lost.bySession, total: lost.total) }
                switch message {
                case .hook(let payload, let receivedAt): await self?.applyHook(payload, receivedAt: receivedAt)
                case .flush(let done): done.resume()
                }
            }
        }
    }

    /// 既定のメタ読み込み（ログの遡り読みと Xcode プロジェクトの走査）。
    @Sendable
    public static func loadMetaFromDisk(cwd: String, transcriptPath: String?) -> MetaResult {
        (transcriptPath.map(TranscriptTail.primeMeta(path:)), XcodeFinder.find(in: cwd))
    }

    deinit {
        hookInbox.finish()
    }

    /// フックを反映の待ち行列に積む。届いた順に `applyHook` へ流す。
    public nonisolated func enqueueHook(_ payload: HookPayload) {
        hookOrder.withLock { offer(.hook(payload, receivedAt: now())) }
    }

    /// それまでに積んだフックが反映し終わるまで待つ（溢れて押し出された時は待たずに戻る）。
    public nonisolated func flushHooks() async {
        await withCheckedContinuation { done in hookOrder.withLock { offer(.flush(done)) } }
    }

    /// 溢れて押し出された古い方を黙って捨てない（待ち手は起こし、フックは数えて後で知らせる）。
    private nonisolated func offer(_ message: HookMessage) {
        switch hookInbox.yield(message) {
        case .dropped(.flush(let done)): done.resume()
        case .dropped(.hook(let payload, _)): droppedHooks.add(sessionId: payload.sessionId)
        case .terminated:
            if case .flush(let done) = message { done.resume() }
        default: break
        }
    }

    private func reportDroppedHooks(_ lost: [String: Int], total: Int) {
        NSLog("claude-deck: フックの待ち行列が溢れ、%d 件を捨てました", total)
        for (sessionId, count) in lost.sorted(by: { $0.key < $1.key }) {
            push(sessionId, .status, "フックの反映が追い付かず \(count) 件を取りこぼしました", local: true)
        }
    }

    /// 試験用: 押し出されてまだ知らせていないフックの数。
    nonisolated var pendingDroppedHookCount: Int { droppedHooks.total }

    /// 変化の受け口を差し替える（`start` 前に呼ぶ）。
    public func setSink(_ sink: (@Sendable (MonitorEvent) -> Void)?) {
        self.sink = sink
    }

    // MARK: - ループ

    public func start() async {
        wantsRunning = true
        guard tasks.isEmpty, !starting else { return }
        starting = true
        await scanInventory()
        starting = false
        // 初回走査の間に止められ、その後に start されていない。
        guard wantsRunning, tasks.isEmpty else { return }
        pollTranscripts()
        pollUsage()
        emitUpdate()
        tasks.append(loop(every: Self.inventoryInterval) { hub in
            await hub.scanInventory()
            await hub.pollUsage()
        })
        tasks.append(loop(every: Self.transcriptInterval) { hub in await hub.pollTranscripts() })
        tasks.append(loop(every: Self.snapshotInterval) { hub in await hub.emitUpdate() })
    }

    /// 試験用: 回っているループの数。
    var loopCount: Int { tasks.count }

    public func stop() {
        wantsRunning = false
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func loop(every interval: Duration, _ body: @escaping @Sendable (SessionHub) async -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await body(self)
            }
        }
    }

    // MARK: - 在庫層

    /// `waitForMeta` が false なら、新しいセッションのメタ情報は後から埋める（フックの反映を待たせないため）。
    func scanInventory(waitForMeta: Bool = true) async {
        let now = now()
        let outcome = scanner.scan(known: sessions, now: now)
        for state in outcome.created {
            poller.attach(state)
            sessions[state.raw.sessionId] = state
        }
        for state in outcome.expired {
            poller.forget(state)
            sessions[state.raw.sessionId] = nil
        }
        for (sessionId, line) in outcome.feed { push(sessionId, line) }

        // チャネルが取りに来なくなった保留（セッション終了・取りこぼし）を捨てる。
        if !permissions.sweep(now: now).isEmpty { emitPermissions() }

        if outcome.changed {
            emitUpdate()
            await transcripts?.setKnown(sessions.values.map { TranscriptStore.Known(sessionId: $0.raw.sessionId, cwd: $0.raw.cwd) })
        }
        guard !outcome.created.isEmpty else { return }
        let created = outcome.created.map(\.raw.sessionId)
        let task = Task<Void, Never> { [weak self] in await self?.loadMeta(created) }
        if waitForMeta { await task.value }
    }

    /// 新しく見つけたセッションのメタ情報と Xcode プロジェクトを actor の外で調べ、結果だけ戻す（その間もフック等を受けられるように）。
    private func loadMeta(_ ids: [String]) async {
        let jobs = ids.compactMap { id -> (id: String, cwd: String, path: String?)? in
            guard let state = sessions[id] else { return nil }
            return (id, state.raw.cwd, state.transcriptPath)
        }
        let loader = metaLoader
        let results = await Task.detached(priority: .utility) {
            jobs.map { job in
                let loaded = loader(job.cwd, job.path)
                return (job.id, job.path, loaded.meta, loaded.xcodeProject)
            }
        }.value
        for (id, path, meta, xcode) in results {
            guard let state = sessions[id] else { continue }
            state.xcodeProject = xcode
            if let meta, path == state.transcriptPath { poller.absorbMeta(meta, into: state) }
        }
        emitUpdate()
    }

    /// 後から見つかったログのメタ情報を読む。結果を待たない（実況のポーリングを止めないため）。
    private func loadTranscriptMeta(_ id: String, path: String) {
        Task.detached(priority: .utility) { [weak self] in
            let meta = TranscriptTail.primeMeta(path: path)
            await self?.receiveTranscriptMeta(id, path: path, meta: meta)
        }
    }

    private func receiveTranscriptMeta(_ id: String, path: String, meta: (title: String?, lastPrompt: String?)) {
        guard let state = sessions[id], state.transcriptPath == path else { return }
        if poller.absorbMeta(meta, into: state) { emitUpdate() }
    }

    // MARK: - 実況層

    func pollTranscripts() {
        let now = now()
        var changed = false

        for (id, state) in sessions {
            let outcome = poller.poll(state, now: now)
            if let path = outcome.metaRequest { loadTranscriptMeta(id, path: path) }
            for line in outcome.feed { push(id, line) }
            if outcome.changed { changed = true }

            // 預かった後に書かれたログ行があれば、その確認は端末側で答えられている。
            if outcome.readLines && permissions.count > 0 {
                let dropped = permissions.dropResolved(sessionId: id, lastActivityAt: state.lastActivityAt ?? 0)
                for pending in dropped {
                    push(id, .status, "権限の確認は端末側で答えられたようです: \(pending.toolName)", local: true)
                }
                if !dropped.isEmpty { emitPermissions() }
            }
        }

        if changed { emitUpdate() }
    }

    // MARK: - 使用量

    /// 内容が変わった時だけ配る。
    func pollUsage() {
        if let change = usagePoller.poll() { sink?(.usage(change.usage)) }
    }

    // MARK: - フック層

    /// Claude Code のフックから届いた状態遷移を反映する。ログには残らない情報はここでしか取れない。
    /// `receivedAt` は受け口に届いた時刻（省略時は今）。
    @discardableResult
    public func applyHook(_ payload: HookPayload, receivedAt: Double? = nil) async -> Bool {
        guard let id = payload.sessionId, !id.isEmpty else { return false }
        var found = sessions[id]
        if found == nil {
            // 在庫スキャンより先に hook が来ることがある。取り込んでから拾い直す（メタ情報は待たない）。
            await scanInventory(waitForMeta: false)
            found = sessions[id]
        }
        guard let state = found else { return false }

        let now = receivedAt ?? now()
        var status: SessionStatus?
        var detail: String?
        var tool: String?
        var message: String?
        var feedLine: (FeedKind, String)?

        switch payload.hookEventName ?? "" {
        case "UserPromptSubmit":
            status = .working
            feedLine = (.status, "指示を受け取りました")
        case "Stop":
            status = .idle
            feedLine = (.status, "応答完了")
        case "Notification":
            let type = payload.notificationType ?? ""
            if type == "permission_prompt" {
                status = .permission
                tool = payload.toolName
                message = payload.notificationMessage
                detail = Attention.permissionDetail(toolName: tool, message: message,
                                                    currentTool: state.currentTool, currentAction: state.currentAction)
                feedLine = (.status, "権限の確認待ち" + (detail.map { ": \($0)" } ?? ""))
            } else if type == "idle_prompt" || type == "agent_needs_input" {
                status = .waiting
                detail = payload.notificationMessage
                feedLine = (.status, "入力待ちで停止中")
            } else {
                // 未知の種別を握り潰すと、フック層が効いていないことに気づけない。
                feedLine = (.status, "通知: \(type.isEmpty ? "(種別なし)" : type)")
            }
        case "StopFailure":
            status = .error
            detail = payload.errorType ?? payload.errorMessage
            feedLine = (.status, "停止: \(detail ?? "APIエラー")")
        case "SubagentStart":
            feedLine = (.agent, "サブエージェント開始: \(payload.agentType ?? "?")")
        case "SubagentStop":
            feedLine = (.agent, "サブエージェント完了: \(payload.agentType ?? "?")")
        case "PreToolUse":
            status = .working
            if let name = payload.toolName, !name.isEmpty, name != state.currentTool {
                state.currentTool = name
                state.currentAction = nil
            }
        default:
            break
        }

        // 届いた後のログ活動を先に読んでいれば、その待ちには既に答えが出ている。
        if let candidate = status, Attention.needsAttention(candidate), state.lastActivity > now { status = nil }
        if let status {
            let prev = Attention.heldStatus(state.hookStatus, hookAt: state.hookAt, lastActivityAt: state.lastActivity)
            state.attentionSince = Attention.nextAttentionSince(prevStatus: prev, prevSince: state.attentionSince,
                                                                nextStatus: status, now: now)
            state.hookStatus = status
            state.hookDetail = detail
            state.hookTool = tool
            state.hookMessage = message
            state.hookAt = max(state.hookAt, now)
            if status == .working { state.lastActivityAt = max(state.lastActivityAt ?? 0, now) }
        }
        if let (kind, text) = feedLine { push(id, kind, text) }
        emitUpdate()
        return true
    }

    // MARK: - 配信

    private func push(_ sessionId: String, _ kind: FeedKind, _ text: String, tool: String? = nil, local: Bool = false) {
        push(sessionId, FeedLine(kind: kind, text: text, tool: tool, local: local))
    }

    private func push(_ sessionId: String, _ line: FeedLine) {
        feedSeq += 1
        let item = FeedItem(id: feedSeq, sessionId: sessionId,
                            project: sessions[sessionId].map { HubText.basename($0.raw.cwd) } ?? "?",
                            at: now(), kind: line.kind, text: line.text, tool: line.tool, local: line.local ? true : nil)
        sink?(.feed(item))
    }

    func emitUpdate() {
        sink?(.sessions(snapshot()))
    }

    private func emitPermissions() {
        sink?(.permissions(permissions.list()))
    }

    // MARK: - 権限確認の中継

    /// チャネルから届いた確認を預かり、判断が出るまで待つ。timeout ならチャネルが取り直す。
    public func awaitPermission(_ input: PermissionRequestInput, waitMillis: Double = PermissionRelay.waitMillis) async -> PermissionOutcome {
        let key = input.key
        let now = now()
        // 取り直しの谷間に押された判断は取り置きにある。先に渡さないと確認が出直す。
        if let settled = permissions.takeDecision(key, toolName: input.toolName, inputPreview: input.inputPreview, now: now) {
            return PermissionOutcome(settled)
        }
        let sessionId = PermissionRelay.matchSession(pid: input.pid, sessions: sessions.values.map(\.raw))
        let state = sessionId.flatMap { sessions[$0] }
        // セッションを引けなくても、どのリポジトリの確認かは申請元の cwd から出す。
        let cwd = state?.raw.cwd ?? input.cwd
        let reg = permissions.register(input, sessionId: sessionId, project: cwd.map(HubText.basename), now: now)
        if reg.linked, let sessionId {
            push(sessionId, .status, "権限の確認が届きました: \(reg.pending.toolName)", local: true)
        }
        for gone in reg.evicted {
            if let sid = gone.sessionId { push(sid, .status, "保留が多すぎるので捨てました: \(gone.toolName)", local: true) }
        }
        if reg.created || reg.changed { emitPermissions() }

        let ticket = WaiterTicket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // 切断済みの申請に待ち手を残すと、判断が取り置かれずに捨てられる。
                guard !Task.isCancelled,
                      let waiterId = permissions.addWaiter(key, { continuation.resume(returning: $0) }) else {
                    continuation.resume(returning: Task.isCancelled ? .timeout : .dropped)
                    return
                }
                ticket.id = waiterId
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(JSONLoose.clampedInt(waitMillis)))
                    await self?.expireWaiter(key, id: waiterId)
                }
            }
        } onCancel: {
            // 登録はこの actor の上で同期に済むので、ここから後に回せば必ず id が入っている。
            Task { [weak self] in await self?.expireWaiter(key, ticket: ticket) }
        }
    }

    private func expireWaiter(_ key: String, id: Int) {
        permissions.expireWaiter(key, id: id)
    }

    private func expireWaiter(_ key: String, ticket: WaiterTicket) {
        if let id = ticket.id { permissions.expireWaiter(key, id: id) }
    }

    /// 試験用: その申請に残っている待ち手の数。
    func waiterCount(_ key: String) -> Int {
        permissions.waiterCount(key)
    }

    /// 画面からの判断。知らない鍵なら nil。
    @discardableResult
    public func decidePermission(key: String, decision: PermissionDecision) -> PendingPermission? {
        guard let pending = permissions.decide(key, decision, now: now()) else { return nil }
        if let sid = pending.sessionId {
            push(sid, .status, "\(decision == .allow ? "許可" : "拒否")しました: \(pending.toolName)", local: true)
        }
        emitPermissions()
        return pending
    }

    public func pendingPermissions() -> [PendingPermission] {
        permissions.list()
    }

    // MARK: - 状態の合成

    private func statusOf(_ state: SessionState) -> (SessionStatus, StatusSource) {
        guard state.raw.alive else { return (.stopped, .inventory) }
        // Agent 実行中は親ログが無音になるので、サブエージェント側の更新も活動として数える。
        let last = state.lastActivity
        let since = last == 0 ? Double.infinity : now() - last
        // 親が応答を終えていても、裏でサブエージェントが動いていれば作業は進んでいる。
        let busy = !state.agents.isEmpty || (state.turnState == .busy && since < Self.staleBusy)
        // ログ側の活動がフックより新しければ、実際には動いている。
        if busy && last > state.hookAt { return (.working, .transcript) }
        if let hook = state.hookStatus { return (hook, .hook) }
        return (busy ? .working : .idle, .transcript)
    }

    public func snapshot() -> [SessionSnapshot] {
        var out: [SessionSnapshot] = []
        for state in sessions.values {
            let (status, source) = statusOf(state)
            let working = status == .working
            let detail: String? = status == .permission && state.hookStatus == .permission
                ? Attention.permissionDetail(toolName: state.hookTool, message: state.hookMessage,
                                             currentTool: state.currentTool, currentAction: state.currentAction)
                : state.hookDetail
            let last = state.lastActivity
            out.append(SessionSnapshot(
                sessionId: state.raw.sessionId,
                pid: state.raw.pid,
                alive: state.raw.alive,
                name: state.raw.name ?? HubText.basename(state.raw.cwd),
                project: HubText.basename(state.raw.cwd),
                cwd: state.raw.cwd,
                branch: state.branch,
                title: state.title,
                lastPrompt: state.lastPrompt,
                status: status,
                statusSource: source,
                statusDetail: detail,
                attentionSince: Attention.needsAttention(status) ? (state.attentionSince ?? state.hookAt) : nil,
                permissionTool: status == .permission && state.hookStatus == .permission && state.hookTool?.isEmpty == false
                    ? state.hookTool : nil,
                entrypoint: state.raw.entrypoint,
                version: state.raw.version,
                startedAt: state.raw.startedAt,
                lastActivityAt: last == 0 ? nil : last,
                currentTool: working ? state.currentTool : nil,
                currentSkill: working ? state.currentSkill : nil,
                currentAction: working ? state.currentAction : nil,
                tokens: state.tokens,
                // 権限待ちの裏で子が回っていることは隠さない。終了したセッションだけ空にする。
                agents: status == .stopped ? [] : state.agents,
                canReceive: state.raw.alive && state.socketPath != nil,
                xcodeProject: state.xcodeProject
            ))
        }
        return out.sorted {
            let (ra, rb) = (Self.rank($0.status), Self.rank($1.status))
            if ra != rb { return ra < rb }
            return $0.project.localizedCompare($1.project) == .orderedAscending
        }
    }

    /// 目を引かせたい状態ほど上に出す。
    static func rank(_ status: SessionStatus) -> Int {
        switch status {
        case .permission: return 0
        case .waiting: return 1
        case .error: return 2
        case .working: return 3
        case .idle: return 4
        case .stopped: return 5
        case .unknown: return 6
        }
    }

    // MARK: - 伝言・エディタ

    /// 指定セッションへ 1 通送る。届いたテキストは「別セッションからのメッセージ」として扱われる。
    public func sendMessage(sessionId: String, text: String) async throws {
        guard let state = sessions[sessionId] else { throw HubFailure(code: "not_found", message: "セッションが見つかりません") }
        guard state.raw.alive else { throw HubFailure(code: "not_alive", message: "セッションは終了しています") }
        guard let socket = state.socketPath ?? InventoryScanner.socketFor(state.raw) else {
            throw HubFailure(code: "no_socket", message: "受信箱ソケットが見つかりません")
        }
        let error = await SessionMessaging.send(socketPath: socket, text: text)
        // 受理されたかまでは分からないので、送ったことだけを記録する。
        push(sessionId, .status, error == nil ? "伝言を送信: \(HubText.truncate(text, 60))" : "送信失敗: \(error!)")
        if let error { throw HubFailure(code: "unreachable", message: error) }
    }
}
