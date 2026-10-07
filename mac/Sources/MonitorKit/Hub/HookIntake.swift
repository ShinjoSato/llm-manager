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

    var total: Int { lock.withLock { sumLocked() } }

    /// 溜まった分を取り出して空に戻す。
    func take() -> (bySession: [String: Int], total: Int) {
        lock.withLock {
            defer { counts = [:]; unattributed = 0 }
            return (counts, sumLocked())
        }
    }

    private func sumLocked() -> Int { counts.values.reduce(unattributed, +) }
}

/// フックの待ち行列。受け口（任意のスレッド）から積み、持ち主（SessionHub）が届いた順に 1 本の流れで取り出す。HTTP の応答は反映を待たない。
final class HookInbox: Sendable {
    enum Message: Sendable {
        /// `receivedAt` は受け口に届いた時刻。反映が遅れてもログ行との前後はこれで比べる。
        case hook(HookPayload, receivedAt: Double)
        case flush(CheckedContinuation<Void, Never>)
    }

    /// 取り出す側は 1 つだけ。
    let stream: AsyncStream<Message>
    private let inbox: AsyncStream<Message>.Continuation
    private let dropped = HookDropCounter()
    /// 受信時刻の取得と積むことを一続きにする（待ち行列の順を時刻の順にそろえる）。
    private let order = NSLock()
    private let now: @Sendable () -> Double

    init(limit: Int, now: @escaping @Sendable () -> Double) {
        self.now = now
        (stream, inbox) = AsyncStream<Message>.makeStream(bufferingPolicy: .bufferingNewest(max(1, limit)))
    }

    /// 届いた時刻を付けて積む。
    func enqueue(_ payload: HookPayload) {
        order.withLock { offer(.hook(payload, receivedAt: now())) }
    }

    /// それまでに積んだフックが取り出され終わるまで待つ（溢れて押し出された時は待たずに戻る）。
    func flush() async {
        await withCheckedContinuation { done in order.withLock { offer(.flush(done)) } }
    }

    func finish() {
        inbox.finish()
    }

    /// 溢れて押し出された古い方を黙って捨てない（待ち手は起こし、フックは数えて後で知らせる）。
    private func offer(_ message: Message) {
        switch inbox.yield(message) {
        case .dropped(.flush(let done)): done.resume()
        case .dropped(.hook(let payload, _)): dropped.add(sessionId: payload.sessionId)
        case .terminated:
            if case .flush(let done) = message { done.resume() }
        default: break
        }
    }

    /// 押し出してまだ知らせていない分を取り出して空に戻す。
    func takeDropped() -> (bySession: [String: Int], total: Int) {
        dropped.take()
    }

    /// 試験用: 押し出されてまだ知らせていないフックの数。
    var pendingDroppedCount: Int { dropped.total }
}

/// フック層。Claude Code のフックの payload を State に映す。ログには残らない「なぜ止まっているか」はここでしか取れない。
enum HookIntake {
    /// 反映してフィードの 1 行を返す（無ければ nil）。`now` は受け口に届いた時刻。
    static func apply(_ payload: HookPayload, to state: SessionState, now: Double) -> FeedLine? {
        var status: SessionStatus?
        var detail: String?
        var tool: String?
        var message: String?
        var feedLine: FeedLine?

        switch payload.hookEventName ?? "" {
        case "UserPromptSubmit":
            status = .working
            feedLine = FeedLine(kind: .status, text: "指示を受け取りました")
        case "Stop":
            status = .idle
            feedLine = FeedLine(kind: .status, text: "応答完了")
        case "Notification":
            let type = payload.notificationType ?? ""
            if type == "permission_prompt" {
                status = .permission
                tool = payload.toolName
                message = payload.notificationMessage
                detail = Attention.permissionDetail(toolName: tool, message: message,
                                                    currentTool: state.currentTool, currentAction: state.currentAction)
                feedLine = FeedLine(kind: .status, text: "権限の確認待ち" + (detail.map { ": \($0)" } ?? ""))
            } else if type == "idle_prompt" || type == "agent_needs_input" {
                status = .waiting
                detail = payload.notificationMessage
                feedLine = FeedLine(kind: .status, text: "入力待ちで停止中")
            } else {
                // 未知の種別を握り潰すと、フック層が効いていないことに気づけない。
                feedLine = FeedLine(kind: .status, text: "通知: \(type.isEmpty ? "(種別なし)" : type)")
            }
        case "StopFailure":
            status = .error
            detail = payload.errorType ?? payload.errorMessage
            feedLine = FeedLine(kind: .status, text: "停止: \(detail ?? "APIエラー")")
        case "SubagentStart":
            feedLine = FeedLine(kind: .agent, text: "サブエージェント開始: \(payload.agentType ?? "?")")
        case "SubagentStop":
            feedLine = FeedLine(kind: .agent, text: "サブエージェント完了: \(payload.agentType ?? "?")")
        case "PreToolUse":
            status = .working
            if let name = payload.toolName, !name.isEmpty, name != state.currentTool {
                state.currentTool = name
                state.currentAction = nil
            }
        default:
            break
        }

        // 届いた後の親ログの活動を先に読んでいれば、その待ちには既に答えが出ている（親が止まっていても書き続けるサブエージェントの活動は数えず、状態に出さない待ちはフィードにも告げない）。
        let parentActivity = state.lastActivityAt ?? 0
        if let candidate = status, Attention.needsAttention(candidate), parentActivity > now { return nil }
        if let status {
            let prev = Attention.heldStatus(state.hookStatus, hookAt: state.hookAt, lastActivityAt: parentActivity)
            state.attentionSince = Attention.nextAttentionSince(prevStatus: prev, prevSince: state.attentionSince,
                                                                nextStatus: status, now: now)
            state.hookStatus = status
            state.hookDetail = detail
            state.hookTool = tool
            state.hookMessage = message
            state.hookAt = max(state.hookAt, now)
            if status == .working { state.lastActivityAt = max(state.lastActivityAt ?? 0, now) }
        }
        return feedLine
    }
}
