import Foundation

/// `~/.claude/sessions/<pid>.json` の必要な部分だけ。
public struct ClaudeSessionRecord: Codable, Sendable, Hashable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String?
    public var startedAt: Double?
    /// プロセスの起動時刻（`ps -o lstart` と同じ形・UTC）。pid の再利用を見分けるのに使う。
    public var procStart: String?
    /// 起動元（`cli` = ターミナル、`claude-vscode` = VS Code 拡張 など）。
    public var entrypoint: String?
    /// `interactive` など。
    public var kind: String?
    /// `busy` / `idle` / `waiting`。
    public var status: String?
    /// 返事待ちの中身（`dialog open` 等）。
    public var waitingFor: String?
    /// status を書いた時刻（Unix ミリ秒）。
    public var statusUpdatedAt: Double?

    public init(pid: Int32, sessionId: String, cwd: String? = nil, startedAt: Double? = nil, procStart: String? = nil,
                entrypoint: String? = nil, kind: String? = nil, status: String? = nil, waitingFor: String? = nil,
                statusUpdatedAt: Double? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.entrypoint = entrypoint
        self.kind = kind
        self.status = status
        self.waitingFor = waitingFor
        self.statusUpdatedAt = statusUpdatedAt
    }

    // 返事待ちの欄は送信の判定にしか使わないので、型が変わってもレコード（引き継ぎ等で使う）ごと落とさない。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
        procStart = try c.decodeIfPresent(String.self, forKey: .procStart)
        entrypoint = try c.decodeIfPresent(String.self, forKey: .entrypoint)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        waitingFor = (try? c.decodeIfPresent(String.self, forKey: .waitingFor)) ?? nil
        statusUpdatedAt = (try? c.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)) ?? nil
    }

    public var waiting: SessionWaiting {
        SessionWaiting(status: status, waitingFor: waitingFor, statusUpdatedAt: statusUpdatedAt)
    }
}

/// セッションレジストリを pid から引く（PTY で起動した claude は `exec` で zsh を置き換えるので、子 pid がそのまま claude の pid）。
public struct ClaudeSessionRegistry: Sendable {
    public var directory: URL

    public static var defaultDirectory: URL {
        ClaudeHome.fromEnvironment().sessionsDirectory
    }

    public init(directory: URL = ClaudeSessionRegistry.defaultDirectory) {
        self.directory = directory
    }

    /// pid のレコードを読む。`/clear` 等で sessionId は差し替わるので、キャッシュせず毎回読む。
    public func record(forPid pid: Int32) -> ClaudeSessionRecord? {
        guard let record = JSONFile.read(ClaudeSessionRecord.self, from: directory.appendingPathComponent("\(pid).json")),
              record.pid == pid, !record.sessionId.isEmpty else { return nil }
        return record
    }

    /// 置かれている全レコード（終了済みの残骸も含む。生存は呼び出し側で確かめる）。
    public func allRecords() -> [ClaudeSessionRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let record = JSONFile.read(ClaudeSessionRecord.self, from: url), !record.sessionId.isEmpty else { return nil }
            return record
        }
    }

    public func sessionId(forPid pid: Int32) -> String? {
        record(forPid: pid)?.sessionId
    }
}
