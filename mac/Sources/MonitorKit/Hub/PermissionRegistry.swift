import Foundation

/// 待ち受けの終わり方。timeout はチャネルが取り直す、dropped は諦める合図。
public enum PermissionOutcome: String, Sendable, Codable, Equatable {
    case allow, deny, timeout, dropped

    init(_ decision: PermissionDecision) {
        self = decision == .allow ? .allow : .deny
    }
}

/// チャネル（claude-deck-channel）から預かる申請。
public struct PermissionRequestInput: Sendable, Equatable {
    public var requestId: String
    public var toolName: String
    public var description: String
    public var inputPreview: String
    /// チャネルを起動した Claude Code のプロセス ID（チャネルの親）。
    public var pid: Int32?
    public var cwd: String?

    public init(requestId: String, toolName: String, description: String, inputPreview: String, pid: Int32?, cwd: String?) {
        self.requestId = requestId
        self.toolName = toolName
        self.description = description
        self.inputPreview = inputPreview
        self.pid = pid
        self.cwd = cwd
    }

    /// 保留の鍵。request_id はセッション内でしか一意でないので、申請元の PID と対で持つ。
    public var key: String { PermissionRelay.pendingKey(pid: pid, requestId: requestId) }
}

/// 権限確認の中継の判定。
public enum PermissionRelay {
    /// チャネルが取りに来なくなったら保留を消す。長ポーリングの一巡より十分長くする。
    public static let pendingTTL: Double = 90_000
    /// 端末側で答えられたことに気づけない場合の保険。ここまで来たら諦めて消す。
    public static let pendingMaxAge: Double = 30 * 60_000
    /// 判断が出た後の取り置き。取り直しの谷間（待ち手が居ない瞬間）に押された分を渡すため。
    public static let decidedTTL: Double = 120_000
    /// 暴走したチャネルで画面が埋まらないための上限。超えたら古いものから捨てる。
    public static let maxPending = 50
    /// 判断が出るまでチャネルを待たせる 1 巡分。切れてもチャネルが取り直すので保留は消えない。
    public static let waitMillis: Double = 60_000

    static let maxToolName = 80
    static let maxDescription = 600
    static let maxInputPreview = 4_000

    public static func pendingKey(pid: Int32?, requestId: String) -> String {
        "\(pid.map(String.init) ?? "x")-\(requestId)"
    }

    /// Claude Code が出すのは 5 文字だが、形が変わっても通るよう緩めに見る。
    static func isValidRequestId(_ id: String) -> Bool {
        guard (1...64).contains(id.utf8.count) else { return false }
        return id.unicodeScalars.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "_" || $0 == "-" }
    }

    /// 受け口の本体を検証して読む。形が合わなければ nil（＝400）。
    public static func parseRequest(_ body: Any?) -> PermissionRequestInput? {
        guard let o = body as? [String: Any] else { return nil }
        let requestId = JSONLoose.string(o["requestId"]) ?? ""
        guard isValidRequestId(requestId) else { return nil }
        let toolName = (JSONLoose.string(o["toolName"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty else { return nil }
        var pid: Int32?
        if let n = JSONLoose.number(o["pid"]), n > 0, n == n.rounded(), n <= Double(Int32.max) { pid = Int32(n) }
        let cwd = JSONLoose.string(o["cwd"]).flatMap { $0.isEmpty ? nil : $0 }
        return PermissionRequestInput(
            requestId: requestId,
            // 表示だけに使う文字列なので、画面を守れる長さで切る。
            toolName: HubText.clip(toolName, maxToolName),
            description: HubText.clip(JSONLoose.string(o["description"]) ?? "", maxDescription),
            inputPreview: HubText.clip(JSONLoose.string(o["inputPreview"]) ?? "", maxInputPreview),
            pid: pid,
            cwd: cwd
        )
    }

    /// 申請元のセッションは親 PID で引く（cwd で引くと同じ場所の別セッションに付け替わり、見ていない確認を許可させる）。
    public static func matchSession(pid: Int32?, sessions: [RawSession]) -> String? {
        guard let pid else { return nil }
        return sessions.first { $0.alive && $0.pid == pid }?.sessionId
    }
}

/// 保留中の権限確認。判断が決まるか、端末側で答えられるまで持つ。待ち手の呼び出しは持ち主（SessionHub）の中で完結する。
final class PermissionRegistry {
    typealias Waiter = (PermissionOutcome) -> Void

    private struct Entry {
        var pending: PendingPermission
        /// チャネルが最後に取りに来た時刻。
        var seenAt: Double
        var waiters: [(id: Int, fn: Waiter)]
    }

    private struct Decided {
        var decision: PermissionDecision
        var at: Double
        var toolName: String
        var inputPreview: String
    }

    private var entries: [String: Entry] = [:]
    private var decided: [String: Decided] = [:]
    private var waiterSeq = 0

    struct Registration {
        var pending: PendingPermission
        var created: Bool
        var changed: Bool
        /// 今回はじめてセッションに紐付いた。
        var linked: Bool
        /// 上限を超えて捨てた分。
        var evicted: [PendingPermission]
    }

    /// すでに判断が出ている申請なら、それを渡して忘れる。同じ鍵でも中身が違えば別の確認なので渡さない。
    func takeDecision(_ key: String, toolName: String, inputPreview: String, now: Double) -> PermissionDecision? {
        guard let hit = decided.removeValue(forKey: key) else { return nil }
        guard hit.toolName == toolName, hit.inputPreview == inputPreview else { return nil }
        return now - hit.at < PermissionRelay.decidedTTL ? hit.decision : nil
    }

    /// 申請を預かる（同じ鍵の取り直しなら生存を延ばすだけ）。
    func register(_ input: PermissionRequestInput, sessionId: String?, project: String?, now: Double) -> Registration {
        let key = input.key
        if var existing = entries[key] {
            existing.seenAt = now
            // セッションは後から在庫に載ることがあるので、引けた分だけ上書きする。
            let newSession = sessionId ?? existing.pending.sessionId
            let newProject = project ?? existing.pending.project
            let linked = existing.pending.sessionId == nil && newSession != nil
            var changed = newSession != existing.pending.sessionId || newProject != existing.pending.project
            existing.pending.sessionId = newSession
            existing.pending.project = newProject
            // 鍵が同じでも中身が違えば別の確認。古い表示のまま答えさせない。
            if existing.pending.toolName != input.toolName || existing.pending.inputPreview != input.inputPreview {
                existing.pending.toolName = input.toolName
                existing.pending.description = input.description
                existing.pending.inputPreview = input.inputPreview
                existing.pending.askedAt = now
                changed = true
            }
            entries[key] = existing
            return Registration(pending: existing.pending, created: false, changed: changed, linked: linked, evicted: [])
        }
        let pending = PendingPermission(key: key, requestId: input.requestId, sessionId: sessionId, project: project,
                                        toolName: input.toolName, description: input.description,
                                        inputPreview: input.inputPreview, askedAt: now)
        entries[key] = Entry(pending: pending, seenAt: now, waiters: [])
        return Registration(pending: pending, created: true, changed: true, linked: sessionId != nil, evicted: evictOverflow())
    }

    private func evictOverflow() -> [PendingPermission] {
        guard entries.count > PermissionRelay.maxPending else { return [] }
        let oldest = entries.sorted { $0.value.pending.askedAt < $1.value.pending.askedAt }
        return drop(oldest.prefix(entries.count - PermissionRelay.maxPending).map(\.key))
    }

    /// 保留を外し、残っている待ち手には dropped を返す（並びは `keys` のまま）。
    private func drop(_ keys: [String]) -> [PendingPermission] {
        keys.compactMap { key in
            guard let entry = entries.removeValue(forKey: key) else { return nil }
            entry.waiters.forEach { $0.fn(.dropped) }
            return entry.pending
        }
    }

    /// 待ち手を登録する。保留が無ければ nil（呼び出し側は dropped を返す）。
    func addWaiter(_ key: String, _ fn: @escaping Waiter) -> Int? {
        guard entries[key] != nil else { return nil }
        waiterSeq += 1
        entries[key]?.waiters.append((waiterSeq, fn))
        return waiterSeq
    }

    /// 時間切れの待ち手を外す。まだ居れば timeout を返す。
    func expireWaiter(_ key: String, id: Int) {
        guard var entry = entries[key], let index = entry.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = entry.waiters.remove(at: index)
        entries[key] = entry
        waiter.fn(.timeout)
    }

    func waiterCount(_ key: String) -> Int {
        entries[key]?.waiters.count ?? 0
    }

    /// 画面からの判断。知らない鍵なら nil（＝404）。
    func decide(_ key: String, _ decision: PermissionDecision, now: Double) -> PendingPermission? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        // 待ち手が居ない時だけ取り置く。配れた分まで残すと、次に来た別の確認に適用されかねない。
        if entry.waiters.isEmpty {
            decided[key] = Decided(decision: decision, at: now, toolName: entry.pending.toolName,
                                   inputPreview: entry.pending.inputPreview)
        }
        entry.waiters.forEach { $0.fn(PermissionOutcome(decision)) }
        return entry.pending
    }

    /// 端末側で先に答えられた分を落とす。預かった後に書かれたログ行があれば、その確認はもう終わっている。
    func dropResolved(sessionId: String, lastActivityAt: Double) -> [PendingPermission] {
        drop(entries.filter { $0.value.pending.sessionId == sessionId && lastActivityAt > $0.value.pending.askedAt }.map(\.key))
    }

    /// 取りに来なくなった分と、古すぎる分を捨てる。
    func sweep(now: Double) -> [PendingPermission] {
        let dropped = drop(entries.filter { _, entry in
            now - entry.seenAt >= PermissionRelay.pendingTTL || now - entry.pending.askedAt >= PermissionRelay.pendingMaxAge
        }.map(\.key))
        for (key, hit) in decided where now - hit.at >= PermissionRelay.decidedTTL { decided[key] = nil }
        return dropped
    }

    /// 古いものから並べる。先に来た確認ほど上に出す。
    func list() -> [PendingPermission] {
        entries.values.map(\.pending).sorted { $0.askedAt < $1.askedAt || ($0.askedAt == $1.askedAt && $0.key < $1.key) }
    }

    var count: Int { entries.count }
}
