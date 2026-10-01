import Foundation

/// SSE `transcript` を流してもらう対象（`/events?transcripts=`）。
public enum TranscriptSubscription: Sendable, Hashable {
    case none
    case all
    case sessions(Set<String>)

    var queryValue: String? {
        switch self {
        case .none: return nil
        case .all: return "*"
        case .sessions(let ids):
            let joined = ids.sorted().joined(separator: ",")
            return joined.isEmpty ? nil : joined
        }
    }
}

/// `events(...)` が流す、接続状態の変化とイベント。
public enum MonitorClientEvent: Sendable, Equatable {
    /// 接続を試み始めた（`attempt` は直前までの連続失敗回数）。
    case connecting(attempt: Int)
    /// HTTP 200 を受け取り、SSE が流れ始めた。
    case connected
    case event(MonitorEvent)
    /// 1 イベントの形が合わなかった。接続は維持する。
    case decodingFailed(eventName: String, message: String)
    /// 切れた。`retryIn` 秒後に張り直す。
    case disconnected(reason: String, retryIn: TimeInterval)
}

public enum MonitorError: Error, Sendable, Equatable, LocalizedError {
    /// monitor に繋がらない（未起動・ポート違い等）。
    case unreachable(String)
    /// monitor がエラーを返した。`code` は monitor の失敗種別（not_found / no_socket 等）。
    case http(status: Int, code: String?, message: String?)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let m): return "monitor に接続できません: \(m)"
        case .http(let status, _, let message): return message ?? "monitor が HTTP \(status) を返しました"
        case .invalidResponse(let m): return "monitor の応答を読めません: \(m)"
        }
    }
}

/// monitor（:8766）の HTTP / SSE クライアント。状態を持たないので、どのスレッドから呼んでもよい。
public struct MonitorClient: Sendable {
    public let configuration: MonitorConfiguration
    private let session: URLSession

    public init(configuration: MonitorConfiguration = .fromEnvironment(), session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.idleTimeout
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            // 未起動の monitor を待ち続けず、すぐ失敗させてバックオフに回す。
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - SSE

    /// `/events` を購読し続ける。切れたらバックオフして張り直す。止めるには受け手のループを抜ける（Task をキャンセルする）。
    public func events(transcripts: TranscriptSubscription = .none) -> AsyncStream<MonitorClientEvent> {
        let url = eventsURL(transcripts: transcripts)
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task { await runEventLoop(url: url, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func eventsURL(transcripts: TranscriptSubscription) -> URL {
        var components = URLComponents(url: endpoint("/events"), resolvingAgainstBaseURL: false)!
        if let value = transcripts.queryValue {
            components.queryItems = [URLQueryItem(name: "transcripts", value: value)]
        }
        return components.url!
    }

    private func runEventLoop(url: URL, continuation: AsyncStream<MonitorClientEvent>.Continuation) async {
        let decoder = JSONDecoder()
        var attempt = 0
        while !Task.isCancelled {
            continuation.yield(.connecting(attempt: attempt))
            var parser = SSEParser()
            let reason: String
            do {
                var request = URLRequest(url: url)
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = configuration.idleTimeout
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw MonitorError.invalidResponse("HTTP ではない応答") }
                guard http.statusCode == 200 else { throw MonitorError.http(status: http.statusCode, code: nil, message: nil) }
                attempt = 0
                continuation.yield(.connected)

                var line: [UInt8] = []
                for try await byte in bytes {
                    line.append(byte)
                    // 行が揃うまで貯めてから渡す（パーサの呼び出し回数を減らすため）。
                    guard byte == 0x0A || byte == 0x0D else { continue }
                    for sse in parser.feed(line) {
                        do {
                            continuation.yield(.event(try MonitorEvent.decode(sse, decoder: decoder)))
                        } catch {
                            continuation.yield(.decodingFailed(eventName: sse.event, message: String(describing: error)))
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                }
                reason = "monitor が接続を閉じました"
            } catch {
                if Task.isCancelled { break }
                reason = Self.describe(error)
            }
            if Task.isCancelled { break }

            var delay = configuration.backoff.delay(forAttempt: attempt)
            if let retry = parser.retryMillis { delay = max(delay, Double(retry) / 1000) }
            continuation.yield(.disconnected(reason: reason, retryIn: delay))
            attempt += 1
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                break
            }
        }
        continuation.finish()
    }

    // MARK: - 読み取り

    public func health() async throws -> Bool {
        struct Health: Decodable { let ok: Bool }
        return try await get("/api/health", as: Health.self).ok
    }

    public func fetchSessions() async throws -> [SessionSnapshot] {
        try await get("/api/sessions", as: [SessionSnapshot].self)
    }

    public func fetchFeed() async throws -> [FeedItem] {
        try await get("/api/feed", as: [FeedItem].self)
    }

    public func fetchUsage() async throws -> UsageSnapshot? {
        try await get("/api/usage", as: UsageSnapshot?.self)
    }

    /// ループバック以外からは 404 になる（monitor の仕様）。
    public func fetchPermissions() async throws -> [PendingPermission] {
        try await get("/api/permissions", as: [PendingPermission].self)
    }

    /// 会話履歴。取りこぼさないよう「SSE を張る → これを呼ぶ → 以降は SSE（id で重複除去）」の順で使う。
    public func fetchTranscript(sessionId: String, after: String? = nil) async throws -> TranscriptResponse {
        var query: [URLQueryItem] = []
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        return try await get("/api/sessions/\(Self.pathSegment(sessionId))/transcript", query: query, as: TranscriptResponse.self)
    }

    // MARK: - 書き込み

    /// そのセッションの受信箱へ伝言を送る。受信側で「別セッションからのメッセージ」として扱われる。
    public func sendMessage(sessionId: String, text: String) async throws {
        _ = try await post("/api/sessions/\(Self.pathSegment(sessionId))/message", body: ["text": text])
    }

    public func decidePermission(key: String, decision: PermissionDecision) async throws {
        _ = try await post("/api/permissions/\(Self.pathSegment(key))", body: ["decision": decision.rawValue])
    }

    public func open(sessionId: String, app: OpenApp) async throws {
        _ = try await post("/api/sessions/\(Self.pathSegment(sessionId))/open", body: ["app": app.rawValue])
    }

    public func close(sessionId: String, app: CloseApp = .xcode) async throws -> CloseState {
        struct CloseResponse: Decodable { let state: CloseState? }
        let data = try await post("/api/sessions/\(Self.pathSegment(sessionId))/close", body: ["app": app.rawValue])
        return (try? JSONDecoder().decode(CloseResponse.self, from: data))?.state ?? .unknown
    }

    // MARK: - 下請け

    func endpoint(_ path: String) -> URL {
        var base = configuration.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        var url = endpoint(path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MonitorError.invalidResponse(String(describing: error))
        }
    }

    private func post(_ path: String, body: [String: String]) async throws -> Data {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        // monitor は content-type が JSON でない書き込みを 415 で弾く。
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MonitorError.unreachable(Self.describe(error))
        }
        guard let http = response as? HTTPURLResponse else { throw MonitorError.invalidResponse("HTTP ではない応答") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String?; let code: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw MonitorError.http(status: http.statusCode, code: failure?.code, message: failure?.error)
        }
        return data
    }

    /// パスの 1 区間として安全な形にする（`/` や `?` を含む ID でも経路を壊さないため）。
    static func pathSegment(_ raw: String) -> String {
        // alphanumerics は非 ASCII の文字も含むので、RFC 3986 の unreserved を明示する。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? MonitorError { return error.errorDescription ?? String(describing: error) }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost: return "接続を拒否されました（monitor が起動していない可能性）"
            case .timedOut: return "応答がありません（タイムアウト）"
            case .networkConnectionLost: return "接続が切れました"
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
