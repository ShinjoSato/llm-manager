import Foundation

/// 在庫層。レジストリ（`~/.claude/sessions/<pid>.json`）と kill(pid,0) から今の一覧を出し、既知の State に当てる。
/// 辞書は書かず、作った State と捨てる State を返す（辞書の出し入れは SessionHub が行う）。
struct InventoryScanner {
    /// 終了したセッションを一覧に残す時間。消えた理由を追えるようにする。
    static let stoppedRetention: Double = 5 * 60_000

    let directory: URL
    let isAlive: @Sendable (Int32) -> Bool
    /// 一度でも在庫を走査したか。最初の走査で見つけたセッションは起動前から動いていたとみなす。
    private(set) var scanned = false

    struct Outcome {
        /// 新しく見つけたセッション（見つけた順）。
        var created: [SessionState] = []
        /// 墓標の保持期限が切れて捨てるセッション。
        var expired: [SessionState] = []
        /// 配信するフィード（起きた順）。
        var feed: [(sessionId: String, line: FeedLine)] = []
        var changed = false
    }

    init(directory: URL, isAlive: @escaping @Sendable (Int32) -> Bool) {
        self.directory = directory
        self.isAlive = isAlive
    }

    /// レジストリを走査して既知の一覧に当てる。既知の State の在庫の欄（raw・endedAt・socketPath）はここで書く。
    /// `clock` は初めて見つけた時点で止まっていたセッションの終了時刻に使う（走査の頭の `now` ではなく、その場の時刻）。
    mutating func scan(known sessions: [String: SessionState], now: Double, clock: () -> Double) -> Outcome {
        var outcome = Outcome()
        var seen = Set<String>()

        for raw in SessionInventory.scan(directory: directory, isAlive: isAlive) {
            seen.insert(raw.sessionId)
            guard let existing = sessions[raw.sessionId] else {
                let state = SessionState(raw: raw)
                state.knownAtStart = !scanned
                state.socketPath = Self.socketFor(raw)
                state.endedAt = raw.alive ? nil : clock()
                outcome.created.append(state)
                outcome.changed = true
                outcome.feed.append((raw.sessionId, FeedLine(kind: .session, text: "セッション検出: \(HubText.basename(raw.cwd))")))
                continue
            }
            if existing.raw.alive != raw.alive {
                outcome.changed = true
                if !raw.alive { outcome.feed.append((raw.sessionId, FeedLine(kind: .session, text: "セッション終了"))) }
            }
            existing.raw = raw
            existing.endedAt = raw.alive ? nil : (existing.endedAt ?? now)
            existing.socketPath = Self.socketFor(raw)
        }

        // レジストリから消えたセッションは終了済み。しばらく墓標として残してから捨てる。
        for (id, state) in sessions where !seen.contains(id) {
            if state.endedAt == nil {
                state.endedAt = now
                state.raw.alive = false
                outcome.feed.append((id, FeedLine(kind: .session, text: "セッション終了")))
                outcome.changed = true
            } else if let ended = state.endedAt, now - ended > Self.stoppedRetention {
                outcome.expired.append(state)
                outcome.changed = true
            }
        }

        scanned = true
        return outcome
    }

    /// 受信箱ソケットの位置。レジストリの値を優先し、無ければ既定の場所を探す。
    static func socketFor(_ raw: RawSession) -> String? {
        if let declared = raw.messagingSocketPath {
            let path = SessionMessaging.expandHome(declared)
            if SessionMessaging.isOwnSocket(path) { return path }
        }
        return SessionMessaging.defaultSocketPath(pid: raw.pid)
    }
}
