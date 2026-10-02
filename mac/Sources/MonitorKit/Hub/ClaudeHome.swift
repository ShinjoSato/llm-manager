import Foundation

/// `~/.claude` 配下のパス（移植元: monitor/src/paths.ts）。試験では一時ディレクトリを差し込む。
public struct ClaudeHome: Sendable, Equatable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `CLAUDE_HOME` があればそれ、無ければ `~/.claude`。
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeHome {
        if let raw = env["CLAUDE_HOME"], !raw.isEmpty { return ClaudeHome(root: URL(fileURLWithPath: raw)) }
        return ClaudeHome(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
    }

    public var sessionsDirectory: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var projectsDirectory: URL { root.appendingPathComponent("projects", isDirectory: true) }

    /// cwd からプロジェクトディレクトリ名を推測する（/Users/x/p → -Users-x-p）。JS と同じく UTF-16 単位で置き換える。
    public static func slug(forCwd cwd: String) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(cwd.utf16.count)
        for u in cwd.utf16 {
            let ok = (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
            units.append(ok ? u : 0x2D)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// サブエージェントの transcript ディレクトリ。
    public static func subagentDirectory(forTranscript path: String) -> String {
        (path.hasSuffix(".jsonl") ? String(path.dropLast(".jsonl".count)) : path) + "/subagents"
    }
}

/// セッションの transcript（jsonl）の場所を引く。スラッグ規則は Claude Code 側の実装依存なので、外れたら projects/ を走査する。
struct TranscriptLocator {
    let home: ClaudeHome
    private var resolved: [String: String] = [:]

    init(home: ClaudeHome) {
        self.home = home
    }

    mutating func resolve(sessionId: String, cwd: String) -> String? {
        let fm = FileManager.default
        if let cached = resolved[sessionId], fm.fileExists(atPath: cached) { return cached }
        let projects = home.projectsDirectory.path
        let guess = "\(projects)/\(ClaudeHome.slug(forCwd: cwd))/\(sessionId).jsonl"
        if fm.fileExists(atPath: guess) {
            resolved[sessionId] = guess
            return guess
        }
        guard let dirs = try? fm.contentsOfDirectory(atPath: projects) else { return nil }
        for dir in dirs {
            let candidate = "\(projects)/\(dir)/\(sessionId).jsonl"
            if fm.fileExists(atPath: candidate) {
                resolved[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }
}
