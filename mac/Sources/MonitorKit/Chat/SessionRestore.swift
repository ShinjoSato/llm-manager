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

    public init(version: Int = Self.currentVersion, savedAt: Double, sessions: [HostedSessionRecord]) {
        self.version = version
        self.savedAt = savedAt
        self.sessions = sessions
    }
}

/// `hosted-sessions.json` の読み書き。強制終了・クラッシュでも直前の記録が残るよう、置き換えで書く。
public struct HostedSessionsFile: Sendable {
    public static let environmentKey = "CLAUDE_DECK_HOSTED_SESSIONS"

    public let url: URL
    /// 置き場所のディレクトリを 0700 に締めるか（既定の Application Support の時だけ）。
    public let restrictsDirectory: Bool

    public init(url: URL, restrictsDirectory: Bool? = nil) {
        self.url = url
        self.restrictsDirectory = restrictsDirectory
            ?? (url.deletingLastPathComponent().standardizedFileURL.path == DeckPaths.applicationSupport.standardizedFileURL.path)
    }

    /// 既定の場所（`CLAUDE_DECK_HOSTED_SESSIONS` があればそちら）。
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return DeckPaths.applicationSupport.appendingPathComponent("hosted-sessions.json")
    }

    /// 記録を読む。無い・壊れた・知らない版は空とみなす（再開できないだけで、次の保存で書き直す）。
    public func load() -> [HostedSessionRecord] {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(HostedSessionsSnapshot.self, from: data),
              snapshot.version == HostedSessionsSnapshot.currentVersion else { return [] }
        return snapshot.sessions
    }

    public func save(_ sessions: [HostedSessionRecord], now: Date = Date()) throws {
        let snapshot = HostedSessionsSnapshot(savedAt: now.timeIntervalSince1970 * 1000, sessions: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(try encoder.encode(snapshot), to: url, restrictDirectory: restrictsDirectory)
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
        /// 同じ会話が別の claude で動いている（二重に動かさない）。
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

    /// 作業の途中で止まったものだけに続きを頼む。権限待ち・入力待ちは人の答えを待っていたので起動だけ。
    public static func needsNudge(_ status: SessionStatus) -> Bool {
        status == .working
    }

    /// 再開したことを一覧の上に出す文。
    public static func summary(launched: Int, nudged: Int, deferred: Int, elsewhere: Int, skipped: Int) -> String? {
        var parts: [String] = []
        if launched > 0 {
            parts.append(nudged > 0 ? "前回のセッションを \(launched) 件再開しました（うち \(nudged) 件に続きを頼みます）"
                                    : "前回のセッションを \(launched) 件再開しました")
        }
        if deferred > 0 { parts.append("Max 枠の上限に達しているため \(deferred) 件は再開していません") }
        if elsewhere > 0 { parts.append("\(elsewhere) 件は別の claude で動いているため再開していません") }
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
    }

    public let startedAt: Date
    private var readySince: Date?

    public init(startedAt: Date) {
        self.startedAt = startedAt
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

    /// 稼働中・要対応のルーム（待機は中断しても失うものが無いので数えない）。
    public static func busy(_ rooms: [Room]) -> [Room] {
        rooms.filter { RoomPhase(status: $0.status) != .idle }
    }

    /// 全部が待機（または終了）になったか。「作業が終わったら終了」の待ちを解く条件。
    public static func isSettled(_ rooms: [Room]) -> Bool {
        busy(rooms).isEmpty
    }

    /// 名前は 3 件まで並べ、残りは件数で出す。
    public static func message(busy rooms: [Room], resumesOnLaunch: Bool) -> String {
        let names = rooms.map(\.name)
        var list = names.prefix(3).joined(separator: "、")
        if names.count > 3 { list += " ほか \(names.count - 3) 件" }
        let tail = resumesOnLaunch ? "終了すると中断し、次の起動時に再開します。" : "終了すると中断します。"
        return "作業中 \(rooms.count) 件（\(list)）。\(tail)"
    }
}

/// 「作業が終わったら終了」の待ち。ツールの合間に一瞬だけ待機に見えても終えないよう、待機が続いてから終える。
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
