import Foundation

/// 長ポーリングの待ち手の番号。登録（actor 上）と取り消し（任意のスレッド）の間で受け渡す。
final class WaiterTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    var id: Int? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// 権限の待ち合わせ。チャネルから預かった確認の保留・待ち手の登録と期限切れ・画面からの判断を扱う。
/// 呼び出しはすべて SessionHub の actor の上で行い、待ち手を起こす continuation と時間切れの予約は SessionHub が持つ。
/// フィードは配らずに返す。
final class PermissionWaiters {
    private let registry = PermissionRegistry()

    /// 預かった結果。
    struct Admission {
        /// 取り置きの判断。あれば待たずにこれを返す。
        var settled: PermissionOutcome?
        var feed: [(sessionId: String, line: FeedLine)] = []
        /// 保留の一覧が変わった。
        var listChanged = false
    }

    /// 画面からの判断の結果。
    struct Decision {
        var pending: PendingPermission
        var feed: (sessionId: String, line: FeedLine)?
    }

    /// 確認を預かる。取り直しの谷間に押された判断は取り置きにあるので、先に渡さないと確認が出直す。
    func admit(_ input: PermissionRequestInput, sessions: [RawSession], now: Double) -> Admission {
        let key = input.key
        if let settled = registry.takeDecision(key, toolName: input.toolName, inputPreview: input.inputPreview, now: now) {
            return Admission(settled: PermissionOutcome(settled))
        }
        let sessionId = PermissionRelay.matchSession(pid: input.pid, sessions: sessions)
        // セッションを引けなくても、どのリポジトリの確認かは申請元の cwd から出す。
        let cwd = sessionId.flatMap { id in sessions.first { $0.sessionId == id }?.cwd } ?? input.cwd
        let reg = registry.register(input, sessionId: sessionId, project: cwd.map(HubText.basename), now: now)
        var admission = Admission()
        if reg.linked, let sessionId {
            admission.feed.append((sessionId, FeedLine(kind: .status, text: "権限の確認が届きました: \(reg.pending.toolName)", local: true)))
        }
        for gone in reg.evicted {
            if let sid = gone.sessionId {
                admission.feed.append((sid, FeedLine(kind: .status, text: "保留が多すぎるので捨てました: \(gone.toolName)", local: true)))
            }
        }
        admission.listChanged = reg.created || reg.changed
        return admission
    }

    /// 待ち手を登録する。保留が無ければ nil。
    func addWaiter(_ key: String, _ fn: @escaping (PermissionOutcome) -> Void) -> Int? {
        registry.addWaiter(key, fn)
    }

    /// 時間切れの待ち手を外す。まだ居れば timeout を返す。
    func expireWaiter(_ key: String, id: Int) {
        registry.expireWaiter(key, id: id)
    }

    func expireWaiter(_ key: String, ticket: WaiterTicket) {
        if let id = ticket.id { registry.expireWaiter(key, id: id) }
    }

    func waiterCount(_ key: String) -> Int {
        registry.waiterCount(key)
    }

    /// 画面からの判断。知らない鍵なら nil。
    func decide(_ key: String, _ decision: PermissionDecision, now: Double) -> Decision? {
        guard let pending = registry.decide(key, decision, now: now) else { return nil }
        let feed = pending.sessionId.map {
            ($0, FeedLine(kind: .status, text: "\(decision == .allow ? "許可" : "拒否")しました: \(pending.toolName)", local: true))
        }
        return Decision(pending: pending, feed: feed)
    }

    /// 預かった後に書かれたログ行があれば、その確認は端末側で答えられている。落とした分のフィードを返す。
    func dropResolved(sessionId: String, lastActivityAt: Double) -> [FeedLine] {
        registry.dropResolved(sessionId: sessionId, lastActivityAt: lastActivityAt).map {
            FeedLine(kind: .status, text: "権限の確認は端末側で答えられたようです: \($0.toolName)", local: true)
        }
    }

    /// チャネルが取りに来なくなった保留（セッション終了・取りこぼし）を捨てる。捨てたものがあれば true。
    func sweep(now: Double) -> Bool {
        !registry.sweep(now: now).isEmpty
    }

    func list() -> [PendingPermission] {
        registry.list()
    }

    var count: Int { registry.count }
}
