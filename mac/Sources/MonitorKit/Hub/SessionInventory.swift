import Foundation

/// 在庫層が `~/.claude/sessions/<pid>.json` から読む生の情報。
public struct RawSession: Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String
    public var startedAt: Double
    public var name: String?
    public var version: String?
    public var entrypoint: String?
    public var kind: String?
    /// 受信箱ソケット。ここへ投稿すると、そのセッションにメッセージが届く。
    public var messagingSocketPath: String?
    /// 返事待ちの状態（`status` / `waitingFor`）。
    public var waiting: SessionWaiting?
    public var alive: Bool
}

/// 在庫層。フックが飛ばないセッションでも全体像が取れる唯一の経路。
public enum SessionInventory {
    /// EPERM は他ユーザーのプロセスで、存在はしている。
    @Sendable public static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// レジストリを走査する。壊れた JSON は黙って飛ばす（書き込み途中を掴むことがある）。
    public static func scan(directory: URL, isAlive: (Int32) -> Bool = processAlive) -> [RawSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [RawSession] = []
        for file in files where file.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(file).path),
                  let raw = JSONLoose.dict(JSONLoose.object(data)) else { continue }
            let pidValue = JSONLoose.coerceNumber(raw["pid"])
            let sessionId = JSONLoose.string(raw["sessionId"]) ?? ""
            let cwd = JSONLoose.string(raw["cwd"]) ?? ""
            // 0 以下の pid に kill を送るとプロセスグループ宛てになるので通さない。
            guard pidValue > 0, pidValue <= Double(Int32.max), pidValue == pidValue.rounded(),
                  !sessionId.isEmpty, !cwd.isEmpty else { continue }
            let pid = Int32(pidValue)
            out.append(RawSession(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                startedAt: JSONLoose.coerceNumber(raw["startedAt"]),
                name: JSONLoose.string(raw["name"]),
                version: JSONLoose.string(raw["version"]),
                entrypoint: JSONLoose.string(raw["entrypoint"]),
                kind: JSONLoose.string(raw["kind"]),
                messagingSocketPath: JSONLoose.string(raw["messagingSocketPath"]),
                waiting: Self.waiting(raw),
                alive: isAlive(pid)
            ))
        }
        return out
    }

    static func waiting(_ raw: [String: Any]) -> SessionWaiting? {
        let status = JSONLoose.string(raw["status"])
        let waitingFor = JSONLoose.string(raw["waitingFor"])
        guard status != nil || waitingFor != nil else { return nil }
        return SessionWaiting(status: status, waitingFor: waitingFor)
    }
}
