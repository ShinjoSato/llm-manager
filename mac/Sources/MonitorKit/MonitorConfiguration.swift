import Foundation

/// アプリ内の監視の設定。
public struct MonitorConfiguration: Sendable, Equatable {
    /// 読み取り元の `~/.claude`。
    public var claudeHome: ClaudeHome
    /// statusLine が書く使用量のファイル。無ければ使用量は nil。
    public var usageFile: URL?
    /// 移行前の statusLine が書く旧ファイル（`data/claude-usage.json`）。取得時刻の新しい方を使う。
    public var legacyUsageFile: URL?
    /// フック等を受けるアプリ内サーバーのポート。nil なら待ち受けない。
    public var serverPort: Int?
    /// 使用中だった時に取り直す間隔（秒）。旧 monitor を止めれば自動で引き継ぐ。
    public var serverRetryInterval: TimeInterval
    /// true なら状態とイベントの要約を標準エラーに出す。
    public var debugLogging: Bool

    public init(claudeHome: ClaudeHome = .fromEnvironment(),
                usageFile: URL? = nil,
                legacyUsageFile: URL? = nil,
                serverPort: Int? = MonitorHTTPRoutes.defaultPort,
                serverRetryInterval: TimeInterval = 5,
                debugLogging: Bool = false) {
        self.claudeHome = claudeHome
        self.usageFile = usageFile
        self.legacyUsageFile = legacyUsageFile
        self.serverPort = serverPort
        self.serverRetryInterval = serverRetryInterval
        self.debugLogging = debugLogging
    }

    /// 環境変数から組み立てる。
    /// `CLAUDE_HOME`（読み取り元）・`CLAUDE_DECK_SERVER_PORT`（待ち受け。`off` で待ち受けない）・
    /// `CLAUDE_DECK_USAGE_FILE`（使用量ファイル。旧名 `MONITOR_USAGE_FILE`）・`CLAUDE_DECK_MONITOR_DEBUG=1`（デバッグ出力）。
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                       legacyUsageFile: URL? = nil) -> MonitorConfiguration {
        var config = MonitorConfiguration(claudeHome: .fromEnvironment(env), usageFile: UsageReader.defaultFile(env),
                                          legacyUsageFile: legacyUsageFile)
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
