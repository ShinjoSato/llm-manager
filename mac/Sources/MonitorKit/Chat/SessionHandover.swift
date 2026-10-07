import Foundation
import Darwin

/// 外部（ターミナル等）で動いている claude をアプリに引き継ぐための判定と終了処理。
public enum SessionHandover {
    /// シェルのコマンド行に埋め込むので UUID の形だけを通す（`-p` 等のオプションに化けさせない）。
    public static func isResumableSessionId(_ id: String) -> Bool {
        id.wholeMatch(of: #/[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/#) != nil
    }

    /// `claude` に渡す再開の引数。値が次の引数として解釈されないよう `=` でつなぐ。
    public static func resumeArgument(_ id: String) -> String? {
        isResumableSessionId(id) ? "--resume=\(id)" : nil
    }

    /// ターミナルで対話起動した claude 以外は止めると元の画面（VS Code 等）が壊れるので引き継がない。
    public static func unsupportedSourceReason(entrypoint: String?, kind: String?) -> String? {
        if let kind, kind != "interactive" { return "対話セッションではないため引き継げません" }
        switch entrypoint {
        case "cli": return nil
        case nil: return "起動元が分からないため引き継げません"
        default: return "VS Code 等で動いているセッションは引き継げません"
        }
    }

    /// バナーに出す起動元の説明。
    public static func sourceDescription(entrypoint: String?) -> String {
        switch entrypoint {
        case "cli": return "ターミナルで起動したセッションです。"
        case "claude-vscode": return "VS Code の拡張で動いているセッションです。"
        case "claude-desktop": return "Claude デスクトップアプリで動いているセッションです。"
        default: return "このアプリの外で動いているセッションです。"
        }
    }

    /// 終了させてよいかの判定。
    public enum Verdict: Sendable, Equatable {
        case ok
        /// もう動いていない（終了済み・ゾンビ）。
        case notRunning
        /// 別物の可能性がある。理由を添えて撃たない。
        case refused(String)
    }

    /// pid が今も `sessionId` の claude であり、自分のプロセスであることを確かめる。
    public static func verify(pid: Int32, sessionId: String, record: ClaudeSessionRecord?, facts: ProcessFacts?,
                              ownUid: uid_t) -> Verdict {
        guard pid > 1 else { return .refused("pid が不正です") }
        guard let facts, !facts.isZombie else { return .notRunning }
        guard facts.uid == ownUid else { return .refused("他のユーザーのプロセスです") }
        guard facts.looksLikeClaude else { return .refused("pid \(pid) は claude ではありません") }
        guard let record, record.pid == pid else {
            return .refused("~/.claude/sessions/\(pid).json が見つかりません")
        }
        guard record.sessionId == sessionId else {
            return .refused("pid \(pid) は別のセッション（\(record.sessionId)）を動かしています")
        }
        if let reason = unsupportedSourceReason(entrypoint: record.entrypoint, kind: record.kind) { return .refused(reason) }
        guard startMatches(record: record, facts: facts) else {
            return .refused("pid \(pid) は記録と起動時刻が合いません（pid が再利用された可能性）")
        }
        return .ok
    }

    /// レジストリの起動時刻とカーネルの起動時刻が同じプロセスを指しているか。
    static func startMatches(record: ClaudeSessionRecord, facts: ProcessFacts) -> Bool {
        if let procStart = record.procStart {
            guard let recorded = parseProcStart(procStart) else { return false }
            return abs(recorded.timeIntervalSince(facts.startedAt)) <= 1
        }
        // procStart を書かない版では、claude が記録した開始時刻がプロセス起動の直後にあるかで見る。
        guard let startedAt = record.startedAt else { return false }
        let delta = Date(epochMillis: startedAt).timeIntervalSince(facts.startedAt)
        return delta >= -2 && delta <= 600
    }

    /// `Thu Oct  1 10:02:22 2026`（UTC）を読む。日付の桁合わせの空白は詰めてから読む。
    static func parseProcStart(_ text: String) -> Date? {
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: collapsed)
    }

    /// 引き継ぎの結果。
    public enum Outcome: Sendable, Equatable {
        /// 終了を確認できた（最初から動いていなかった場合も含む）。
        case exited
        /// 撃たなかった（別物の可能性）。
        case refused(String)
        /// シグナルを送っても終わらなかった。
        case stillRunning
        /// 同じ会話が別の pid で動いている。
        case runningElsewhere(Int32)
    }

    /// 同じ sessionId を今も動かしている pid（記録と起動時刻が合うものだけ。残骸や再利用された pid は数えない）。
    public static func liveDuplicate(sessionId: String, records: [ClaudeSessionRecord], excluding: Int32? = nil,
                                     inspect: (Int32) -> ProcessFacts?) -> Int32? {
        for record in records where record.sessionId == sessionId && record.pid > 1 && record.pid != excluding {
            guard let facts = inspect(record.pid), !facts.isZombie, startMatches(record: record, facts: facts) else { continue }
            return record.pid
        }
        return nil
    }
}

/// カーネルから読んだプロセスの素性。
public struct ProcessFacts: Sendable, Equatable {
    public var uid: uid_t
    /// プロセスの起動時刻（秒精度）。
    public var startedAt: Date
    public var executablePath: String?
    public var argv0: String?
    public var isZombie: Bool

    public init(uid: uid_t, startedAt: Date, executablePath: String?, argv0: String?, isZombie: Bool) {
        self.uid = uid
        self.startedAt = startedAt
        self.executablePath = executablePath
        self.argv0 = argv0
        self.isZombie = isZombie
    }

    /// ネイティブ版は実体が `~/.local/share/claude/versions/<版>` なので、名前だけでなく置き場所と argv[0] も見る。
    public var looksLikeClaude: Bool {
        if let argv0, (argv0 as NSString).lastPathComponent == "claude" { return true }
        guard let path = executablePath else { return false }
        if (path as NSString).lastPathComponent == "claude" { return true }
        return path.contains("/claude/versions/")
    }

    /// 同じプロセスか（pid の再利用で別物に替わっていないか）。実行パスは取れないことがあるので見ない。
    public func isSameProcess(as other: ProcessFacts) -> Bool {
        uid == other.uid && startedAt == other.startedAt
    }

    /// `pid` の素性を読む。存在しなければ nil。
    public static func inspect(pid: Int32) -> ProcessFacts? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil
        return ProcessFacts(uid: info.pbi_uid,
                            startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)),
                            executablePath: path,
                            argv0: argv0(pid: pid),
                            isZombie: info.pbi_status == UInt32(SZOMB))
    }

    /// KERN_PROCARGS2 から argv[0] を読む（自分のプロセスしか読めない）。
    static func argv0(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArgv0(procArgs: Array(buffer.prefix(size)))
    }

    /// KERN_PROCARGS2 の並び（argc・実行パス・NUL 詰め・argv…）から argv[0] を取り出す。
    static func parseArgv0(procArgs: [UInt8]) -> String? {
        let intSize = MemoryLayout<Int32>.size
        guard procArgs.count > intSize else { return nil }
        var index = intSize
        while index < procArgs.count, procArgs[index] != 0 { index += 1 }
        while index < procArgs.count, procArgs[index] == 0 { index += 1 }
        guard index < procArgs.count else { return nil }
        let start = index
        while index < procArgs.count, procArgs[index] != 0 { index += 1 }
        return String(decoding: procArgs[start..<index], as: UTF8.self)
    }
}

/// 外部の claude を SIGINT → 待機 → SIGTERM の順で止める。依存は差し替えられる（テスト用）。
public struct SessionTerminator: Sendable {
    public var inspect: @Sendable (Int32) -> ProcessFacts?
    public var record: @Sendable (Int32) -> ClaudeSessionRecord?
    public var records: @Sendable () -> [ClaudeSessionRecord]
    public var signal: @Sendable (Int32, Int32) -> Void
    public var sleep: @Sendable (Duration) async -> Void
    public var ownUid: uid_t
    /// SIGINT 後に待つ時間。claude は後片付け（セッションの保存）をしてから抜ける。
    public var interruptGrace: Duration = .seconds(5)
    public var terminateGrace: Duration = .seconds(3)
    public var pollInterval: Duration = .milliseconds(200)

    public init(inspect: @escaping @Sendable (Int32) -> ProcessFacts? = { ProcessFacts.inspect(pid: $0) },
                record: @escaping @Sendable (Int32) -> ClaudeSessionRecord? = { ClaudeSessionRegistry().record(forPid: $0) },
                records: @escaping @Sendable () -> [ClaudeSessionRecord] = { ClaudeSessionRegistry().allRecords() },
                signal: @escaping @Sendable (Int32, Int32) -> Void = { _ = kill($0, $1) },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                ownUid: uid_t = getuid()) {
        self.inspect = inspect
        self.record = record
        self.records = records
        self.signal = signal
        self.sleep = sleep
        self.ownUid = ownUid
    }

    /// `pid` が `sessionId` の claude だと確かめてから止める。止まったと確認でき、同じ会話が他で動いていない時だけ `.exited`。
    public func terminate(pid: Int32, sessionId: String) async -> SessionHandover.Outcome {
        let facts = inspect(pid)
        switch SessionHandover.verify(pid: pid, sessionId: sessionId, record: record(pid), facts: facts, ownUid: ownUid) {
        case .notRunning: return exited(sessionId: sessionId)
        case .refused(let reason): return .refused(reason)
        case .ok: break
        }
        guard let original = facts else { return exited(sessionId: sessionId) }
        // 同じ会話が他でも動いているなら再開しないので、止めること自体をやめる（無用に中断しない）。
        if let other = SessionHandover.liveDuplicate(sessionId: sessionId, records: records(), excluding: pid, inspect: inspect) {
            return .runningElsewhere(other)
        }

        signal(pid, SIGINT)
        if await waitForExit(pid: pid, original: original, within: interruptGrace) { return exited(sessionId: sessionId) }

        // 待つ間に pid が別物へ替わっていないことを確かめてから強める（レジストリは終了処理中に消えうるので素性で見る）。
        guard isStillRunning(pid, original) else { return exited(sessionId: sessionId) }
        signal(pid, SIGTERM)
        if await waitForExit(pid: pid, original: original, within: terminateGrace) { return exited(sessionId: sessionId) }
        return .stillRunning
    }

    /// 再開すると同じ会話を二重に動かすことになるので、他の pid で動いていれば止める。
    private func exited(sessionId: String) -> SessionHandover.Outcome {
        if let other = SessionHandover.liveDuplicate(sessionId: sessionId, records: records(), inspect: inspect) {
            return .runningElsewhere(other)
        }
        return .exited
    }

    private func waitForExit(pid: Int32, original: ProcessFacts, within grace: Duration) async -> Bool {
        var waited: Duration = .zero
        while waited < grace {
            await sleep(pollInterval)
            waited += pollInterval
            guard isStillRunning(pid, original) else { return true }
        }
        return false
    }

    private func isStillRunning(_ pid: Int32, _ original: ProcessFacts) -> Bool {
        guard let current = inspect(pid), !current.isZombie else { return false }
        return current.isSameProcess(as: original)
    }
}
