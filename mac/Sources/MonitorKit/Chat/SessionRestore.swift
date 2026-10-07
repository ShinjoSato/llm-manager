import Foundation

/// アプリでホストしていたセッション 1 つ分の記録（次の起動で `claude --resume` し直すため）。
public struct HostedSessionRecord: Codable, Sendable, Equatable {
    public var name: String
    public var cwd: String
    public var sessionId: String
    /// 記録した時点の状態。
    public var status: SessionStatus
    /// 入力欄の書きかけ（無ければ nil）。
    public var draft: String?

    public init(name: String, cwd: String, sessionId: String, status: SessionStatus, draft: String? = nil) {
        self.name = name
        self.cwd = cwd
        self.sessionId = sessionId
        self.status = status
        self.draft = draft
    }
}

/// `hosted-sessions.json` の中身。
public struct HostedSessionsSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// 書いた時刻（epoch ミリ秒）。
    public var savedAt: Double
    public var sessions: [HostedSessionRecord]
    /// 自動で再開した時刻（epoch ミリ秒）。正常に終われば消すので、残っていれば再開の直後に落ちたとみなせる。
    public var restoredAt: Double?

    public init(version: Int = Self.currentVersion, savedAt: Double, sessions: [HostedSessionRecord], restoredAt: Double? = nil) {
        self.version = version
        self.savedAt = savedAt
        self.sessions = sessions
        self.restoredAt = restoredAt
    }

    public var restoredDate: Date? { restoredAt.map(Date.init(epochMillis:)) }
}

/// `hosted-sessions.json` の読み書き。強制終了・クラッシュでも直前の記録が残るよう、置き換えで書く。
public struct HostedSessionsFile: Sendable {
    public static let environmentKey = "CLAUDE_DECK_HOSTED_SESSIONS"

    public let url: URL
    /// 置き場所のディレクトリを 0700 に締めるか（既定の Application Support の時だけ）。
    public let restrictsDirectory: Bool

    public init(url: URL, restrictsDirectory: Bool? = nil) {
        self.url = url
        self.restrictsDirectory = restrictsDirectory ?? DeckPaths.isInApplicationSupport(url)
    }

    /// 既定の場所（`CLAUDE_DECK_HOSTED_SESSIONS` があればそちら）。
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        DeckPaths.file("hosted-sessions.json", overriddenBy: environmentKey, environment: environment)
    }

    /// 記録を読む。無い・壊れた・知らない版は nil（再開できないだけで、次の保存で書き直す）。
    public func loadSnapshot() -> HostedSessionsSnapshot? {
        guard let snapshot = JSONFile.read(HostedSessionsSnapshot.self, from: url),
              snapshot.version == HostedSessionsSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func load() -> [HostedSessionRecord] {
        loadSnapshot()?.sessions ?? []
    }

    public func save(_ sessions: [HostedSessionRecord], restoredAt: Date? = nil, now: Date = Date()) throws {
        let snapshot = HostedSessionsSnapshot(savedAt: now.timeIntervalSince1970 * 1000, sessions: sessions,
                                              restoredAt: restoredAt.map { $0.timeIntervalSince1970 * 1000 })
        try SecureFile.writeJSON(snapshot, to: url, restrictDirectory: restrictsDirectory)
    }
}

/// `hosted-sessions.json` を 1 つのアプリだけが扱うための排他ロック（隣の `.lock` を flock で持ち続ける）。
public final class HostedSessionsLock: @unchecked Sendable {
    public let url: URL
    private var fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { release() }

    /// 取れなければ nil（別のアプリが持っている・作れない）。子の claude にロックが残らないよう exec で閉じる。
    public static func acquire(for file: HostedSessionsFile) -> HostedSessionsLock? {
        let lockURL = file.url.appendingPathExtension("lock")
        let dir = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: file.restrictsDirectory ? [.posixPermissions: 0o700] : nil)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return HostedSessionsLock(url: lockURL, fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

/// 起動時に前回のセッションを再開するかの判定。
public enum SessionRestore {
    /// 作業の途中で止まったセッションに、再開後に送る頼み。
    public static let continueMessage = "前回はアプリの終了で作業の途中で止まりました。続きを進めてください。"

    public enum Decision: Sendable, Equatable {
        /// `--resume` で起動する。`nudge` なら起動後に続きを頼む。
        case launch(nudge: Bool)
        /// 上限到達中なので今は起動しない（一覧に残して、解除後に再開できるようにする）。
        case deferredByLimit
        /// 同じ会話が別の claude で動いている（前回の claude の終了途中もある）。二重に動かさず、記録は見送りに残す。
        case runningElsewhere(Int32)
        /// 再開できない（sessionId の形が想定外・フォルダが無い・同じ会話を既にホストしている）。
        case skipped(String)
    }

    public struct Plan: Sendable, Equatable {
        public var record: HostedSessionRecord
        public var decision: Decision

        public init(record: HostedSessionRecord, decision: Decision) {
            self.record = record
            self.decision = decision
        }
    }

    /// 前回の記録それぞれをどう扱うか。同じ sessionId の重複は先のものだけを見る。
    public static func plan(records: [HostedSessionRecord], limitReached: Bool, askToContinue: Bool,
                            hostedSessionIds: Set<String>, directoryExists: (String) -> Bool,
                            liveDuplicate: (String) -> Int32?) -> [Plan] {
        var seen: Set<String> = []
        var plans: [Plan] = []
        for record in records where seen.insert(record.sessionId).inserted {
            plans.append(Plan(record: record, decision: decide(record, limitReached: limitReached, askToContinue: askToContinue,
                                                               hostedSessionIds: hostedSessionIds,
                                                               directoryExists: directoryExists, liveDuplicate: liveDuplicate)))
        }
        return plans
    }

    static func decide(_ record: HostedSessionRecord, limitReached: Bool, askToContinue: Bool, hostedSessionIds: Set<String>,
                       directoryExists: (String) -> Bool, liveDuplicate: (String) -> Int32?) -> Decision {
        guard SessionHandover.isResumableSessionId(record.sessionId) else { return .skipped("sessionId の形式が想定外です") }
        if hostedSessionIds.contains(record.sessionId) { return .skipped("すでにこのアプリで動いています") }
        guard directoryExists(record.cwd) else { return .skipped("フォルダが見つかりません（\(record.cwd)）") }
        if let other = liveDuplicate(record.sessionId) { return .runningElsewhere(other) }
        if limitReached { return .deferredByLimit }
        return .launch(nudge: askToContinue && needsNudge(record.status))
    }

    /// 自動で再開してからこの時間内に再び起動したら、再開が原因で落ちた疑いがあるので自動では再開しない。
    public static let crashLoopWindow: TimeInterval = 120

    public static func isCrashLoop(restoredAt: Date?, now: Date) -> Bool {
        guard let restoredAt else { return false }
        let elapsed = now.timeIntervalSince(restoredAt)
        return elapsed >= -60 && elapsed < crashLoopWindow
    }

    /// 作業の途中で止まったものだけに続きを頼む。権限待ち・入力待ちは人の答えを待っていたので起動だけ。
    public static func needsNudge(_ status: SessionStatus) -> Bool {
        status == .working
    }

    /// 再開を見送った理由。見送った記録は残し、帯の［再開する］か次の起動で再開する。
    public enum DeferReason: Sendable, Equatable {
        case limit
        /// 前回の自動再開の直後にアプリが落ちた。
        case crashLoop
        /// 同じ会話の claude がまだ動いている（前回の claude の終了途中を含む）。
        case runningElsewhere
    }

    /// 見送った分の帯の文。
    public static func deferredSummary(_ reasons: [DeferReason]) -> String? {
        guard !reasons.isEmpty else { return nil }
        let parts: [(DeferReason, String)] = [(.limit, "上限"), (.crashLoop, "再開の直後に落ちた"), (.runningElsewhere, "同じ会話が動いている")]
        let detail = parts.compactMap { reason, label -> String? in
            let count = reasons.filter { $0 == reason }.count
            return count > 0 ? "\(label) \(count) 件" : nil
        }.joined(separator: "・")
        return "再開を見送ったセッション \(reasons.count) 件（\(detail)）"
    }

    /// 再開したことを一覧の上に出す文。
    public static func summary(launched: Int, nudged: Int, deferred: Int, elsewhere: Int, skipped: Int) -> String? {
        var parts: [String] = []
        if launched > 0 {
            parts.append(nudged > 0 ? "前回のセッションを \(launched) 件再開しました（うち \(nudged) 件に続きを頼みます）"
                                    : "前回のセッションを \(launched) 件再開しました")
        }
        if deferred > 0 { parts.append("Max 枠の上限に達しているため \(deferred) 件は再開していません") }
        if elsewhere > 0 { parts.append("\(elsewhere) 件は同じ会話の claude がまだ動いているため見送りました") }
        if skipped > 0 { parts.append("\(skipped) 件は再開できませんでした") }
        return parts.isEmpty ? nil : parts.joined(separator: "。")
    }
}

/// 再開したセッションへ続きを頼む時機。起動直後は trust 確認やメニュー・入力欄の準備があるので、入力欄が落ち着くまで待つ。
public struct ResumeNudgeGate: Sendable, Equatable {
    /// 送れる状態がこの時間続いたら送る（起動中の描画の揺れで送らないため）。
    public static let settle: TimeInterval = 2
    /// これを過ぎても送れなければ入力欄の下書きに回す。
    public static let timeout: TimeInterval = 120

    public enum Step: Sendable, Equatable {
        case wait
        case send
        /// 送れなかった（時間切れ）。下書きに回す。
        case giveUp
        /// 利用者が先に頼んだ・もう動き出した。頼む必要が無いので何もせずやめる。
        case cancel
    }

    /// その時点のセッションの様子。
    public struct Observation: Sendable, Equatable {
        /// 動いていて、選択待ちでなく、送信中でもなく、端末の入力欄が空で見えている。
        public var ready: Bool
        /// 稼働中になった（利用者の指示や伝言で作業を始めた）。
        public var working: Bool
        /// 再開の後に利用者がこのルームから送った。
        public var userSent: Bool
        /// 終了の確認中・終了の保留中（終わるつもりの時に新しい作業を始めさせない）。
        public var holding: Bool

        public init(ready: Bool, working: Bool = false, userSent: Bool = false, holding: Bool = false) {
            self.ready = ready
            self.working = working
            self.userSent = userSent
            self.holding = holding
        }
    }

    public let startedAt: Date
    private var readySince: Date?

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }

    public mutating func step(_ observation: Observation, now: Date) -> Step {
        if observation.userSent || observation.working { return .cancel }
        if observation.holding {
            readySince = nil
            return .wait
        }
        return step(ready: observation.ready, now: now)
    }

    /// `ready` は「動いていて、選択待ちでなく、送信中でもなく、端末の入力欄が空で見えている」。
    public mutating func step(ready: Bool, now: Date) -> Step {
        guard ready else {
            readySince = nil
            return now.timeIntervalSince(startedAt) >= Self.timeout ? .giveUp : .wait
        }
        let since = readySince ?? now
        readySince = since
        if now.timeIntervalSince(since) >= Self.settle { return .send }
        return now.timeIntervalSince(startedAt) >= Self.timeout ? .giveUp : .wait
    }

    /// 送ろうとして止められた（選択待ちが出た等）。もう一度落ち着くのを待つ。
    public mutating func refused() {
        readySince = nil
    }
}

/// 終了時に確認を出すかと、その文言。
public enum QuitConfirmation {
    /// 確認の対象（動いているホスト中のルーム）。
    public struct Room: Sendable, Equatable {
        public var name: String
        public var status: SessionStatus

        public init(name: String, status: SessionStatus) {
            self.name = name
            self.status = status
        }
    }

    /// 中断すると失うものがあるルーム（稼働中・権限待ち）。応答の後の入力待ちは待機と同じく数えない。
    public static func busy(_ rooms: [Room]) -> [Room] {
        rooms.filter { $0.status == .working || $0.status == .permission }
    }

    /// 稼働中のルーム。「作業が終わったら終了」はこれだけを待つ。
    public static func working(_ rooms: [Room]) -> [Room] {
        rooms.filter { $0.status == .working }
    }

    /// 稼働中が無くなったか。「作業が終わったら終了」の待ちを解く条件（権限待ち・入力待ちは人の答えが要るので待たない）。
    public static func isSettled(_ rooms: [Room]) -> Bool {
        working(rooms).isEmpty
    }

    /// 稼働中と権限待ちを分けて名前を 3 件まで並べ、待ちの扱いも書く。
    public static func message(busy rooms: [Room], resumesOnLaunch: Bool) -> String {
        var groups: [String] = []
        let working = rooms.filter { $0.status == .working }
        let permission = rooms.filter { $0.status == .permission }
        if !working.isEmpty { groups.append("稼働中 \(working.count) 件（\(names(working))）") }
        if !permission.isEmpty { groups.append("権限待ち \(permission.count) 件（\(names(permission))）") }
        let tail = resumesOnLaunch ? "終了すると中断し、次の起動時に再開します。" : "終了すると中断します。"
        return groups.joined(separator: "・") + "。" + tail
            + "「作業が終わったら終了」は稼働中の作業が終わるのを待ちます（権限待ち・入力待ちのルームは待たずに中断します）。"
    }

    private static func names(_ rooms: [Room]) -> String {
        var list = rooms.prefix(3).map(\.name).joined(separator: "、")
        if rooms.count > 3 { list += " ほか \(rooms.count - 3) 件" }
        return list
    }

    /// Apple Event の quit に付く終了の理由（`kAEQuitReason`）。ログアウト・再起動・シャットダウンの時だけ付く。
    public static let systemQuitReasons: Set<UInt32> = [
        fourCharCode("logo"), fourCharCode("rlgo"), fourCharCode("rrst"),
        fourCharCode("rsdn"), fourCharCode("rest"), fourCharCode("shut"),
    ]

    /// OS の終了に伴う quit か（確認を出すと OS の終了を止めてしまうので出さない）。
    public static func isSystemQuit(reason: UInt32?) -> Bool {
        reason.map(systemQuitReasons.contains) ?? false
    }

    static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

/// 「作業が終わったら終了」の待ち。ツールの合間に一瞬だけ稼働中が消えても終えないよう、稼働中が無い状態が続いてから終える。
public struct QuitWait: Sendable, Equatable {
    public static let settle: TimeInterval = 3

    private var settledSince: Date?

    public init() {}

    /// 終えてよければ true。
    public mutating func step(_ rooms: [QuitConfirmation.Room], now: Date) -> Bool {
        guard QuitConfirmation.isSettled(rooms) else {
            settledSince = nil
            return false
        }
        let since = settledSince ?? now
        settledSince = since
        return now.timeIntervalSince(since) >= Self.settle
    }
}
