import Foundation

/// monitor への接続設定。
public struct MonitorConfiguration: Sendable, Equatable {
    /// 既定の待ち受け。monitor は Host をループバック名で検証するので 127.0.0.1 に送る。
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8766")!

    public var baseURL: URL
    /// 無通信がこれを超えたら切れたとみなす。monitor は sessions を 1 秒ごとに送るので短くてよい。
    public var idleTimeout: TimeInterval
    public var backoff: ReconnectBackoff
    /// true なら接続状態とイベントの要約を標準エラーに出す。
    public var debugLogging: Bool

    public init(baseURL: URL = MonitorConfiguration.defaultBaseURL,
                idleTimeout: TimeInterval = 10,
                backoff: ReconnectBackoff = ReconnectBackoff(),
                debugLogging: Bool = false) {
        self.baseURL = baseURL
        self.idleTimeout = idleTimeout
        self.backoff = backoff
        self.debugLogging = debugLogging
    }

    /// 環境変数から組み立てる。
    /// `CLAUDE_DECK_MONITOR_URL`（例 http://127.0.0.1:8799）> `CLAUDE_DECK_MONITOR_PORT` > 既定。
    /// `CLAUDE_DECK_MONITOR_DEBUG=1` でデバッグ出力。
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> MonitorConfiguration {
        var config = MonitorConfiguration()
        if let raw = env["CLAUDE_DECK_MONITOR_URL"], let url = URL(string: raw), url.scheme != nil, url.host != nil {
            config.baseURL = url
        } else if let raw = env["CLAUDE_DECK_MONITOR_PORT"], let port = Int(raw), (1...65535).contains(port) {
            config.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        }
        config.debugLogging = env["CLAUDE_DECK_MONITOR_DEBUG"] == "1"
        return config
    }
}

/// 再接続の待ち時間（指数バックオフ + ジッター）。
public struct ReconnectBackoff: Sendable, Equatable {
    public var initial: TimeInterval
    public var maximum: TimeInterval
    public var multiplier: Double
    /// 0...1。待ち時間をこの割合だけ短い側へ揺らす（複数クライアントの同時再接続を散らすため）。
    public var jitter: Double

    public init(initial: TimeInterval = 0.5, maximum: TimeInterval = 10, multiplier: Double = 2, jitter: Double = 0.2) {
        self.initial = initial
        self.maximum = maximum
        self.multiplier = multiplier
        self.jitter = jitter
    }

    /// `attempt` 回目（0 始まり）の失敗後に待つ秒数。`random` は 0..<1。
    public func delay(forAttempt attempt: Int, random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let exponent = Double(max(0, min(attempt, 30)))
        let base = min(maximum, initial * pow(multiplier, exponent))
        return base * (1 - jitter * random)
    }
}
