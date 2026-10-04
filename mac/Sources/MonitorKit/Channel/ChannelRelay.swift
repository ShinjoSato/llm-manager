import Foundation

/// 受け口に 1 回預けた結果。
public enum ChannelAskResult: String, Sendable, Equatable {
    case allow, deny, timeout, dropped, unreachable
}

/// 権限確認を claude-deck の受け口（`POST /api/channel/permissions`）へ中継し、判断が出るまで取り直す。
public struct ChannelRelay: Sendable {
    /// 1 回の長ポーリングの上限。受け口側の待ち時間より長くして、応答を取りこぼさない。
    public static let pollTimeout: TimeInterval = 90
    /// 受け口が落ちている時の再試行間隔。端末のダイアログは開いたままなので急がない。
    public static let retryDelay: TimeInterval = 5
    /// 受け口が戻らないまま待ち続けない。ここを過ぎたら端末のダイアログに任せる。
    public static let giveUpAfter: TimeInterval = 30 * 60
    public static let defaultBaseURL = "http://127.0.0.1:8766"

    public var ask: @Sendable () async -> ChannelAskResult
    public var sleep: @Sendable (TimeInterval) async -> Void
    /// 秒。
    public var now: @Sendable () -> TimeInterval
    public var log: @Sendable (String) -> Void

    public init(ask: @escaping @Sendable () async -> ChannelAskResult,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
                log: @escaping @Sendable (String) -> Void) {
        self.ask = ask
        self.sleep = sleep
        self.now = now
        self.log = log
    }

    /// 判断が出れば返す。端末側で答えられた・諦めた時は nil（端末のダイアログに任せる）。
    public func run(toolName: String, baseURL: String) async -> PermissionDecision? {
        let startedAt = now()
        var unreachable = 0
        // timeout は 1 巡の区切りで、保留は受け口側に残っている。
        while true {
            switch await ask() {
            case .allow: return .allow
            case .deny: return .deny
            case .dropped: return nil
            case .timeout:
                unreachable = 0
                continue
            case .unreachable:
                break
            }
            unreachable += 1
            // 繋がらない間のログは間引く（初回と、以後およそ 1 分ごと）。
            if unreachable == 1 || unreachable % 12 == 0 {
                log("claude-deck に繋がりません（\(baseURL)）。\(Int(Self.retryDelay)) 秒後に取り直します")
            }
            if now() - startedAt >= Self.giveUpAfter {
                log("claude-deck が戻らないので中継を諦めます: \(toolName)")
                return nil
            }
            await sleep(Self.retryDelay)
        }
    }

    /// 宛先。`CLAUDE_DECK_URL` を優先し、旧名 `MONITOR_URL` も読む。
    public static func baseURL(_ env: [String: String]) -> String {
        let raw = [env["CLAUDE_DECK_URL"], env["MONITOR_URL"]].compactMap { $0 }.first { !$0.isEmpty } ?? defaultBaseURL
        var url = Substring(raw)
        while url.hasSuffix("/") { url = url.dropLast() }
        return String(url)
    }

    /// 受け口に渡す本文。チャネルは Claude Code の子プロセスなので、親 PID がそのままセッションの PID になる。
    public static func requestBody(_ request: ChannelPermissionRequest, pid: Int32, cwd: String) -> Data {
        let object: [String: Any] = [
            "requestId": request.requestId,
            "toolName": request.toolName,
            "description": request.description,
            "inputPreview": request.inputPreview,
            "pid": Int(pid),
            "cwd": cwd,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// 受け口の応答を読む。ログに残すべき理由があれば併せて返す。
    public static func classify(status: Int, body: Data) -> (ChannelAskResult, String?) {
        guard (200..<300).contains(status) else {
            // 400 系は形が悪いので、取り直しても同じ。諦めて端末のダイアログに任せる。
            return (status >= 500 ? .unreachable : .dropped, "claude-deck が申請を受け付けません（HTTP \(status)）")
        }
        switch JSONLoose.string(JSONLoose.dict(JSONLoose.object(body))?["outcome"]) {
        case "allow": return (.allow, nil)
        case "deny": return (.deny, nil)
        case "dropped": return (.dropped, nil)
        default: return (.timeout, nil)
        }
    }

    /// 実際に HTTP で預ける。届かなければ unreachable（呼び出し側がログを間引く）。
    public static func httpAsk(baseURL: String, body: Data, session: URLSession = .shared,
                               log: @escaping @Sendable (String) -> Void) -> @Sendable () async -> ChannelAskResult {
        {
            guard let url = URL(string: baseURL + "/api/channel/permissions") else { return .dropped }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = pollTimeout
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { return .unreachable }
            let (outcome, message) = classify(status: http.statusCode, body: data)
            if let message { log(message) }
            return outcome
        }
    }
}
