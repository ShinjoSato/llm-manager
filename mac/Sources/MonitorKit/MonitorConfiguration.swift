import Foundation

/// アプリ内の監視の設定。
public struct MonitorConfiguration: Sendable, Equatable {
    /// 読み取り元の `~/.claude`。
    public var claudeHome: ClaudeHome
    /// statusLine が書く使用量のファイル。無ければ使用量は nil。
    public var usageFile: URL?
    /// フック等を受けるアプリ内サーバーのポート。nil なら待ち受けない。
    public var serverPort: Int?
    /// 使用中だった時に取り直す間隔（秒）。使っていたプロセスが止まれば自動で引き継ぐ。
    public var serverRetryInterval: TimeInterval
    /// true なら状態とイベントの要約を標準エラーに出す。
    public var debugLogging: Bool

    public init(claudeHome: ClaudeHome = .fromEnvironment(),
                usageFile: URL? = nil,
                serverPort: Int? = HookServerRoutes.defaultPort,
                serverRetryInterval: TimeInterval = 5,
                debugLogging: Bool = false) {
        self.claudeHome = claudeHome
        self.usageFile = usageFile
        self.serverPort = serverPort
        self.serverRetryInterval = serverRetryInterval
        self.debugLogging = debugLogging
    }

    /// `CLAUDE_HOME`・`CLAUDE_DECK_SERVER_PORT`（`off` で待ち受けない）・`CLAUDE_DECK_USAGE_FILE`・`CLAUDE_DECK_MONITOR_DEBUG=1` から組み立てる。
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MonitorConfiguration {
        var config = MonitorConfiguration(claudeHome: .fromEnvironment(env), usageFile: UsageReader.defaultFile(env))
        if let raw = env["CLAUDE_DECK_SERVER_PORT"] {
            if raw == "off" {
                config.serverPort = nil
            } else if let port = Int(raw), (1...65535).contains(port) {
                config.serverPort = port
            }
        }
        config.debugLogging = env["CLAUDE_DECK_MONITOR_DEBUG"] == "1"
        return config
    }
}
