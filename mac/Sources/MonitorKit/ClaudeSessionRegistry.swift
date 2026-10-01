import Foundation

/// `~/.claude/sessions/<pid>.json` の必要な部分だけ。
public struct ClaudeSessionRecord: Codable, Sendable, Hashable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String?
    public var startedAt: Double?
    /// プロセスの起動時刻（`ps -o lstart` と同じ形・UTC）。pid の再利用を見分けるのに使う。
    public var procStart: String?

    public init(pid: Int32, sessionId: String, cwd: String? = nil, startedAt: Double? = nil, procStart: String? = nil) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
    }
}

/// Claude Code のセッションレジストリを pid から引く。
/// アプリが PTY で起動した claude は `exec` で zsh を置き換えるので、PTY の子 pid がそのまま claude の pid になる。
public struct ClaudeSessionRegistry: Sendable {
    public var directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    public init(directory: URL = ClaudeSessionRegistry.defaultDirectory) {
        self.directory = directory
    }

    /// pid のレコードを読む。`/clear` 等で sessionId は差し替わるので、キャッシュせず毎回読む。
    public func record(forPid pid: Int32) -> ClaudeSessionRecord? {
        let url = directory.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data),
              record.pid == pid, !record.sessionId.isEmpty else { return nil }
        return record
    }

    public func sessionId(forPid pid: Int32) -> String? {
        record(forPid: pid)?.sessionId
    }
}
