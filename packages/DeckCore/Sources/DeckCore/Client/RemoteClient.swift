import Foundation

/// 通信の失敗。画面には `RemoteIssue` で人の言葉にして出す。
public enum RemoteClientError: Error, Equatable, Sendable {
    case invalidAddress
    /// 証明書の指紋がピン留めしたものと違う（mac で作り直された・別の相手）。
    case pinMismatch
    /// HTTP の失敗（`error` は `RemoteErrorBody.error`）。
    case http(status: Int, error: String?, message: String?)
    case transport(URLError.Code)
    case decoding
    case streamOverflow
}

/// mac アプリの LAN の口を叩く。ピン留めは `RemotePinnedSessionDelegate`。
public final class RemoteClient: Sendable {
    public let builder: RemoteRequestBuilder
    public let pin: String
    private let delegate: RemotePinnedSessionDelegate
    private let session: URLSession

    public init(host: String, port: Int, pin: String, token: String?, configuration: URLSessionConfiguration = .ephemeral) {
        builder = RemoteRequestBuilder(host: host, port: port, token: token)
        self.pin = pin
        delegate = RemotePinnedSessionDelegate(pin: pin)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        // ストリーム（端末あたり 4 本まで）と操作が詰まらないだけの本数。
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public convenience init(pairing: RemotePairing, host: String? = nil) {
        self.init(host: host ?? pairing.host, port: pairing.port, pin: pairing.fingerprint, token: pairing.deviceToken)
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: - 口

    public func pair(token: String, deviceName: String) async throws -> RemotePairResponse {
        try await json(builder.pair(token: token, deviceName: deviceName))
    }

    public func info() async throws -> RemoteInfo { try await json(builder.info()) }

    public func rooms() async throws -> RemoteState { try await json(builder.rooms()) }

    public func unpair() async throws -> RemoteActionResult { try await action(builder.unpair()) }

    public func transcript(sessionId: String, after: String? = nil) async throws -> TranscriptResponse {
        try await json(builder.transcript(sessionId: sessionId, after: after))
    }

    public func image(sessionId: String, itemId: String, index: Int) async throws -> Data {
        let (data, _) = try await send(builder.image(sessionId: sessionId, itemId: itemId, index: index))
        return data
    }

    public func decide(key: String, decision: PermissionDecision) async throws -> RemoteActionResult {
        try await action(builder.decide(key: key, decision: decision))
    }

    public func answerTerminalPermission(roomId: String, promptId: String, decision: PermissionDecision) async throws -> RemoteActionResult {
        try await action(builder.terminalPermission(roomId: roomId, promptId: promptId, decision: decision))
    }

    public func answerMenu(roomId: String, _ body: RemoteMenuAnswerRequest) async throws -> RemoteActionResult {
        try await action(builder.menu(roomId: roomId, body))
    }

    public func moveMenuTab(roomId: String, _ body: RemoteMenuTabRequest) async throws -> RemoteActionResult {
        try await action(builder.menuTab(roomId: roomId, body))
    }

    public func dismissMenu(roomId: String, _ body: RemoteMenuDismissRequest) async throws -> RemoteActionResult {
        try await action(builder.menuDismiss(roomId: roomId, body))
    }

    public func sendMessage(roomId: String, text: String) async throws -> RemoteActionResult {
        try await action(builder.message(roomId: roomId, text: text))
    }

    /// `/v1/events` を張る。相手が閉じたら（取り消し・口を閉じた・古いストリームとして切られた）終わる。
    public func events(transcripts: [String]?) -> AsyncThrowingStream<RemoteStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let probe = self.probe()
                do {
                    let request = try self.builder.events(transcripts: transcripts)
                    let (bytes, response) = try await self.session.bytes(for: request, delegate: probe)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64 * 1024 { break }
                        }
                        throw Self.httpError(status: status, body: body)
                    }
                    var lines = LineSplitter()
                    var parser = SSEParser()
                    for try await byte in bytes {
                        guard let line = try lines.feed(byte) else { continue }
                        switch try parser.feed(line) {
                        case .comment?:
                            continuation.yield(.ping)
                        case .message(let message)?:
                            let event: RemoteStreamEvent?
                            do { event = try SSEParser.decode(message) } catch { throw RemoteClientError.decoding }
                            if let event { continuation.yield(event) }
                        case nil:
                            break
                        }
                    }
                    continuation.finish()
                } catch is LineSplitter.Overflow, is SSEParser.Overflow {
                    continuation.finish(throwing: RemoteClientError.streamOverflow)
                } catch {
                    continuation.finish(throwing: self.classify(error, probe: probe))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 補助

    private func json<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RemoteClientError.decoding
        }
    }

    /// 操作は失敗でも `RemoteActionResult` の本文が返る（409 等）。本文が読めない時だけ投げる。
    private func action(_ request: URLRequest) async throws -> RemoteActionResult {
        let (data, response) = try await load { try await session.data(for: request, delegate: $0) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let result = try? JSONDecoder().decode(RemoteActionResult.self, from: data) { return result }
        throw Self.httpError(status: status, body: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await load { try await session.data(for: request, delegate: $0) }
        guard let http = response as? HTTPURLResponse else { throw RemoteClientError.transport(.badServerResponse) }
        guard http.statusCode == 200 else { throw Self.httpError(status: http.statusCode, body: data) }
        return (data, http)
    }

    /// 要求ごとに指紋を確かめる delegate を付けて送り、失敗を `RemoteClientError` に読み替える。
    private func load<T>(_ body: (RemotePinnedSessionDelegate) async throws -> T) async throws -> T {
        let probe = probe()
        do {
            return try await body(probe)
        } catch {
            throw classify(error, probe: probe)
        }
    }

    private func probe() -> RemotePinnedSessionDelegate {
        RemotePinnedSessionDelegate(pin: pin, reportingTo: delegate)
    }

    private func classify(_ error: Error, probe: RemotePinnedSessionDelegate) -> Error {
        if error is RemoteClientError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        // 呼び出し側の取り消しを指紋違いと取り違えない。
        if urlError.code == .cancelled, Task.isCancelled { return CancellationError() }
        let tlsFailure = urlError.code == .secureConnectionFailed || Self.certificateErrors.contains(urlError.code)
        // 不一致は delegate が取り消すので、この要求で不一致を見たかで見分ける。
        if probe.hasMismatched, urlError.code == .cancelled || tlsFailure { return RemoteClientError.pinMismatch }
        // URLSession が不一致を覚えて delegate を呼ばずに TLS で落とすことがあるので、同じ相手で見た不一致も使う。
        if delegate.hasMismatched, tlsFailure { return RemoteClientError.pinMismatch }
        return RemoteClientError.transport(urlError.code)
    }

    static let certificateErrors: Set<URLError.Code> = [.serverCertificateUntrusted, .serverCertificateHasBadDate,
                                                        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot]

    static func httpError(status: Int, body: Data) -> RemoteClientError {
        let decoded = try? JSONDecoder().decode(RemoteErrorBody.self, from: body)
        return .http(status: status, error: decoded?.error, message: decoded?.message)
    }
}
