import Foundation
import Network

/// iPhone 向けの口（`/v1/...`）の振り分け。仕様は mac/docs/remote-api.md。
/// フック・チャネルの口（`/hook` 等）はここには無い（LAN に出さない）。
public struct RemoteRoutes: Sendable {
    public let pairing: RemotePairingStore
    public let throttle: RemoteAuthThrottle
    public let transcripts: RemoteTranscriptSource
    public let events: RemoteEventHub
    public let controlRef: RemoteControlRef
    public let serverName: String

    /// 本文の上限（添付は受けないので小さく）。
    public static let maxBodyBytes = 256 * 1024
    /// 同時接続の上限（ストリームの上限より余裕を持たせる）。
    public static let maxConnections = 32
    /// 接続元ごとの同時接続の上限（端末あたりのストリーム 4 本 + 操作の分）。未認証の相手 1 つで口を塞がせない。
    public static let maxConnectionsPerAddress = 8
    /// 送り切らない相手の締め切り（LAN の口は短く）。
    public static let readTimeout: TimeInterval = 5
    /// 一度に購読できるセッションの数。
    static let maxTranscriptSubscriptions = 32

    public init(pairing: RemotePairingStore, throttle: RemoteAuthThrottle, transcripts: RemoteTranscriptSource,
                events: RemoteEventHub, controlRef: RemoteControlRef, serverName: String) {
        self.pairing = pairing
        self.throttle = throttle
        self.transcripts = transcripts
        self.events = events
        self.controlRef = controlRef
        self.serverName = serverName
    }

    /// 待ち受けの設定（TLS 必須・LAN のアドレスに限る）。
    public func serverOptions(bindHost: NWEndpointHostValue, tls: TLSServerIdentity) -> HTTPServerOptions {
        let routes = self
        let throttle = throttle
        return HTTPServerOptions(bindHost: bindHost.host, tls: tls, maxConnections: Self.maxConnections,
                                 maxBodyBytes: Self.maxBodyBytes, readTimeout: Self.readTimeout,
                                 maxConnectionsPerAddress: Self.maxConnectionsPerAddress,
                                 refuseAddress: { throttle.isBlocked($0) }, keepalive: true,
                                 rejection: { request, _ in routes.rejection(request) })
    }

    // MARK: - 先に掛ける検査

    /// 本文を読む前にも掛ける検査。通れば nil。
    public func rejection(_ request: HTTPRequest) -> HTTPResponse? {
        // ブラウザのページからは呼ばせない（iPhone アプリは Origin を付けない）。
        if request.header("origin") != nil { return Self.error(403, "forbidden", "Origin 付きのリクエストは受け付けません") }
        let address = request.remoteAddress ?? "?"
        if throttle.isBlocked(address) { return Self.error(429, "too_many_failures", "失敗が続いたため、しばらく受け付けません") }
        guard request.path.hasPrefix("/v1/") else { return Self.error(404, "not_found", "not found") }
        if request.path == "/v1/pair" { return nil }
        guard authenticate(request) != nil else {
            throttle.recordFailure(address)
            var response = Self.error(401, "unauthorized", "端末のトークンが無いか、取り消されています")
            response.headers.append(("WWW-Authenticate", "Bearer"))
            return response
        }
        return nil
    }

    func authenticate(_ request: HTTPRequest) -> RemoteDevice? {
        guard let raw = request.header("authorization"), raw.count > 7, raw.prefix(7).lowercased() == "bearer " else { return nil }
        return pairing.authenticate(token: String(raw.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - 振り分け

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.path == "/v1/pair" {
            guard request.method == "POST" else { return Self.methodNotAllowed }
            return pair(request)
        }
        guard let device = authenticate(request) else { return Self.error(401, "unauthorized", "端末のトークンが無いか、取り消されています") }
        let segments = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2).map {
            String($0).removingPercentEncoding ?? String($0)
        }
        switch (request.method, segments) {
        case ("GET", ["info"]):
            return Self.encoded(200, RemoteInfo(serverName: serverName, device: device))
        case ("POST", ["unpair"]):
            // 書き出しに失敗してもメモリ上は取り消し済み（mac の画面に出して書き直しを続ける）。
            _ = try? pairing.revoke(id: device.id)
            await events.close(deviceId: device.id)
            return Self.encoded(200, RemoteActionResult.success("unpaired"))
        case ("GET", ["rooms"]):
            guard let state = await controlRef.state() else { return Self.error(503, "unavailable", "mac アプリの準備ができていません") }
            return Self.encoded(200, state)
        case ("GET", ["events"]):
            return await openEvents(request, device: device)
        case ("GET", let path) where path.count == 3 && path[0] == "sessions" && path[2] == "transcript":
            let after = Self.query(request)["after"].flatMap { $0.isEmpty ? nil : $0 }
            guard let response = await transcripts.remoteTranscript(sessionId: path[1], after: after) else {
                return Self.error(404, "not_found", "会話が見つかりません")
            }
            return Self.encoded(200, response)
        case ("GET", let path) where path.count == 6 && path[0] == "sessions" && path[2] == "items" && path[4] == "images":
            return await image(sessionId: path[1], itemId: path[3], index: path[5])
        case ("POST", ["permissions", "decision"]):
            return await action(request, RemotePermissionDecisionRequest.self) { body, control in
                await control.remoteDecide(key: body.key, decision: body.decision)
            }
        case ("POST", let path) where path.count >= 3 && path[0] == "rooms":
            return await roomAction(request, roomId: path[1], rest: Array(path.dropFirst(2)))
        case (_, let path) where Self.knownPaths.contains(path.first ?? ""):
            return Self.methodNotAllowed
        default:
            return Self.error(404, "not_found", "not found")
        }
    }

    static let knownPaths: Set<String> = ["info", "unpair", "rooms", "events", "sessions", "permissions"]

    private func roomAction(_ request: HTTPRequest, roomId: String, rest: [String]) async -> HTTPResponse {
        guard RemoteRoomID(roomId) != nil else { return Self.error(404, "not_found", "ルームが見つかりません") }
        switch rest {
        case ["permission"]:
            return await action(request, RemoteTerminalPermissionRequest.self) { body, control in
                await control.remoteAnswerTerminalPermission(roomId: roomId, promptId: body.promptId, decision: body.decision)
            }
        case ["menu"]:
            return await action(request, RemoteMenuAnswerRequest.self) { body, control in
                await control.remoteAnswerMenu(roomId: roomId, request: body)
            }
        case ["menu", "tab"]:
            return await action(request, RemoteMenuTabRequest.self) { body, control in
                await control.remoteMoveMenuTab(roomId: roomId, request: body)
            }
        case ["menu", "dismiss"]:
            return await action(request, RemoteMenuDismissRequest.self) { body, control in
                await control.remoteDismissMenu(roomId: roomId, request: body)
            }
        case ["messages"]:
            return await action(request, RemoteMessageRequest.self) { body, control in
                switch RemoteChecks.message(body.text) {
                case .failure(let result): return result
                case .success(let text): return await control.remoteSendMessage(roomId: roomId, text: text)
                }
            }
        default:
            return Self.error(404, "not_found", "not found")
        }
    }

    private func action<Body: Decodable & Sendable>(
        _ request: HTTPRequest, _ type: Body.Type,
        _ perform: @escaping @MainActor @Sendable (Body, RemoteControl) async -> RemoteActionResult
    ) async -> HTTPResponse {
        let body: Body
        switch Self.decode(request, type) {
        case .rejected(let response): return response
        case .value(let value): body = value
        }
        let result = await controlRef.run { control in await perform(body, control) }
        return Self.encoded(Self.status(of: result), result)
    }

    static func status(of result: RemoteActionResult) -> Int {
        if result.ok { return 200 }
        switch result.code {
        case "not_found": return 404
        case "invalid": return 400
        case "app_unavailable": return 503
        case "failed": return 502
        default: return 409
        }
    }

    // MARK: - ペアリング

    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        let address = request.remoteAddress ?? "?"
        let body: RemotePairRequest
        switch Self.decode(request, RemotePairRequest.self) {
        case .rejected(let response): return response
        case .value(let value): body = value
        }
        switch pairing.pair(token: body.token, deviceName: body.deviceName) {
        case .rejected:
            throttle.recordFailure(address)
            return Self.error(401, "pairing_rejected", "ペアリング用のコードが違うか、期限切れか、使用済みです。mac で新しい QR を出してください")
        case .full:
            return Self.error(409, "too_many_devices", "ペアリングできる端末の数を超えています。mac で使っていない端末を取り消してください")
        case .paired(let device, let token):
            throttle.recordSuccess(address)
            return Self.encoded(200, RemotePairResponse(deviceId: device.id, deviceToken: token, serverName: serverName))
        }
    }

    // MARK: - 会話・画像・ストリーム

    private func image(sessionId: String, itemId: String, index raw: String) async -> HTTPResponse {
        guard let index = Int(raw), index >= 0,
              let image = await transcripts.remoteImage(sessionId: sessionId, itemId: itemId, index: index) else {
            return Self.error(404, "not_found", "画像が見つかりません")
        }
        let type = image.mediaType.lowercased().hasPrefix("image/") ? image.mediaType : "application/octet-stream"
        // 同じ発話の同じ位置の画像は変わらない。
        return HTTPResponse(status: 200, headers: [("Content-Type", type), ("Cache-Control", "private, max-age=86400"),
                                                   ("X-Content-Type-Options", "nosniff")], body: image.data)
    }

    private func openEvents(_ request: HTTPRequest, device: RemoteDevice) async -> HTTPResponse {
        let subscription: TranscriptSubscription
        switch Self.query(request)["transcripts"] {
        case nil, "": subscription = .none
        case "*": subscription = .all
        case let list?:
            let ids = Set(list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            guard ids.count <= Self.maxTranscriptSubscriptions, ids.allSatisfy(TranscriptFormat.isValidSessionId) else {
                return Self.error(400, "invalid", "transcripts の指定が不正です")
            }
            subscription = .sessions(ids)
        }
        let stream: HTTPBodyStream
        switch await events.open(deviceId: device.id, transcripts: subscription) {
        case .opened(let opened): stream = opened
        case .revoked: return Self.error(401, "unauthorized", "端末のトークンが無いか、取り消されています")
        case .tooMany: return Self.error(429, "too_many_streams", "開いているストリームが多すぎます")
        }
        return HTTPResponse(status: 200, headers: [("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-store")],
                            stream: stream)
    }

    // MARK: - 補助

    static func query(_ request: HTTPRequest) -> [String: String] {
        guard let raw = request.query else { return [:] }
        var c = URLComponents()
        c.percentEncodedQuery = raw
        var out: [String: String] = [:]
        for item in c.queryItems ?? [] where out[item.name] == nil { out[item.name] = item.value ?? "" }
        return out
    }

    enum Decoded<T> {
        case value(T)
        case rejected(HTTPResponse)
    }

    static func decode<T: Decodable>(_ request: HTTPRequest, _ type: T.Type) -> Decoded<T> {
        guard request.isJSONContentType else {
            return .rejected(error(415, "unsupported_media_type", "content-type must be application/json"))
        }
        guard let value = try? JSONDecoder().decode(type, from: request.body) else {
            return .rejected(error(400, "invalid", "本文の形が不正です"))
        }
        return .value(value)
    }

    static func encoded<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")],
                            body: data)
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        encoded(status, RemoteErrorBody(error: code, message: message))
    }

    static let methodNotAllowed = error(405, "method_not_allowed", "method not allowed")
}

/// 待ち受けるアドレス（Network の型を公開 API に出さないための包み）。
public struct NWEndpointHostValue: Sendable {
    let host: NWEndpoint.Host

    /// IPv4 のアドレス（`192.168.1.5` 等）。読めなければ nil。
    public init?(ipv4 address: String) {
        guard let v4 = IPv4Address(address) else { return nil }
        host = .ipv4(v4)
    }

    public static let loopback = NWEndpointHostValue(host: .ipv4(.loopback))

    init(host: NWEndpoint.Host) {
        self.host = host
    }
}
