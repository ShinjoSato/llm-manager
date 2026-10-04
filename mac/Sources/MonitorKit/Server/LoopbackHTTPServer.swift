import Foundation
import Network

/// 受け取った 1 リクエスト。
public struct HTTPRequest: Sendable {
    public var method: String
    /// クエリを除いたパス。
    public var path: String
    public var query: String?
    /// 名前は小文字にそろえる。
    public var headers: [String: String]
    public var body: Data
    /// 接続元のアドレス（`127.0.0.1` / `::1` 等）。
    public var remoteAddress: String?

    public init(method: String, path: String, query: String? = nil, headers: [String: String] = [:],
                body: Data = Data(), remoteAddress: String? = "127.0.0.1") {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// 送り続ける応答の本文（Server-Sent Events 等）。流し終えるか相手が切れば接続を閉じる。
public final class HTTPBodyStream: Sendable {
    public let chunks: AsyncStream<Data>

    public init(_ chunks: AsyncStream<Data>) {
        self.chunks = chunks
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data
    /// あれば `body` の代わりに chunked で流す。
    public var stream: HTTPBodyStream?

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data(), stream: HTTPBodyStream? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = stream
    }

    /// JSON の応答。キャッシュさせない。
    public static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")],
                            body: data)
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
            && a.stream === b.stream
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        if stream != nil {
            head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            return Data(head.utf8)
        }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func chunk(_ data: Data) -> Data {
        var framed = Data((String(data.count, radix: 16) + "\r\n").utf8)
        framed.append(data)
        framed.append(Data("\r\n".utf8))
        return framed
    }

    static let lastChunk = Data("0\r\n\r\n".utf8)
}

/// 待ち受けの状態。
public enum LoopbackServerState: Sendable, Equatable {
    case stopped
    case starting
    case listening(port: Int)
    /// 別のプロセス（旧 monitor 等）がポートを使っている。
    case portInUse(port: Int)
    case failed(String)
}

/// TLS の自分の証明書と鍵。CF の型は Sendable ではないが、作った後は書き換えない。
public struct TLSServerIdentity: @unchecked Sendable {
    public let identity: SecIdentity

    public init(_ identity: SecIdentity) {
        self.identity = identity
    }
}

/// 待ち受けの設定。既定はフック・チャネル用の口（ループバック・平文・Host / Origin / 接続元の検査）。
public struct HTTPServerOptions: Sendable {
    public typealias Rejection = @Sendable (HTTPRequest, Int) -> HTTPResponse?

    /// 待ち受けるアドレス。全インターフェース（0.0.0.0）にはしない。
    public var bindHost: NWEndpoint.Host
    /// あれば TLS だけで待ち受ける（平文の口は出さない）。
    public var tls: TLSServerIdentity?
    public var maxConnections: Int
    public var maxBodyBytes: Int
    public var maxHeaderBytes: Int
    public var readTimeout: TimeInterval
    /// 流し続ける応答で、相手が受け取らずに溜まってよい量。超えたら切る。
    public var maxPendingStreamBytes: Int
    /// 本文を読む前にも掛ける検査（引数はリクエストと待ち受けのポート）。通れば nil。
    public var rejection: Rejection
    /// 接続元のアドレスごとの同時接続の上限（nil は全体の上限だけ）。
    public var maxConnectionsPerAddress: Int?
    /// true を返す接続元は受け入れた時点で切る（TLS の握手もさせない）。
    public var refuseAddress: (@Sendable (String) -> Bool)?
    /// 黙って消えた相手（Wi-Fi から外れた端末等）の接続を早めに見つけて片付ける。
    public var keepalive: Bool

    public init(bindHost: NWEndpoint.Host = .ipv4(.loopback),
                tls: TLSServerIdentity? = nil,
                maxConnections: Int = LoopbackHTTPServer.maxConnections,
                maxBodyBytes: Int = LoopbackHTTPServer.maxBodyBytes,
                maxHeaderBytes: Int = LoopbackHTTPServer.maxHeaderBytes,
                readTimeout: TimeInterval = LoopbackHTTPServer.readTimeout,
                maxPendingStreamBytes: Int = 4 * 1024 * 1024,
                maxConnectionsPerAddress: Int? = nil,
                refuseAddress: (@Sendable (String) -> Bool)? = nil,
                keepalive: Bool = false,
                rejection: @escaping Rejection = { MonitorHTTPRoutes.rejection($0, port: $1) }) {
        self.bindHost = bindHost
        self.tls = tls
        self.maxConnections = maxConnections
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderBytes = maxHeaderBytes
        self.readTimeout = readTimeout
        self.maxPendingStreamBytes = maxPendingStreamBytes
        self.maxConnectionsPerAddress = maxConnectionsPerAddress
        self.refuseAddress = refuseAddress
        self.keepalive = keepalive
        self.rejection = rejection
    }

    /// フック・チャネル用の口（127.0.0.1・平文）。
    public static let loopback = HTTPServerOptions()
}

/// 最小の HTTP/1.1 サーバー（1 接続 1 リクエスト・Content-Length のみ）。外部ライブラリは使わない。
/// 既定は 127.0.0.1 だけで待ち受ける。`HTTPServerOptions` で待ち受けるアドレス・TLS・検査・上限を変えられる。
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// 本文の上限。フックの JSON は最後の応答文などを含むので小さすぎないようにする。
    public static let maxBodyBytes = 8 * 1024 * 1024
    public static let maxHeaderBytes = 64 * 1024
    /// 送り切らない相手で接続を握られ続けないための締め切り。
    public static let readTimeout: TimeInterval = 15
    /// 同時に持つ接続の上限（長ポーリングで待たせている分も数える）。ローカルの暴走で資源を食い尽くさせない。
    public static let maxConnections = 64
    /// 閉じた待ち受けがポートを手放すまで待つ上限。取り消しは非同期で、直後に開き直すと塞がっていることがある。
    static let cancelTimeout: TimeInterval = 2

    private let queue = DispatchQueue(label: "claude-deck.http-server")
    private let handler: Handler
    public let options: HTTPServerOptions
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionsPerAddress: [String: Int] = [:]
    private var stateHandler: (@Sendable (LoopbackServerState) -> Void)?
    private var requestedPort: Int = 0
    /// キュー上でだけ触る。
    private var currentPort: Int?
    /// start / stop のたびに進める。前の待ち受けの片付けを待つ間に呼び直されたら、古い開き直しを捨てる。
    private var generation = 0

    public init(options: HTTPServerOptions = .loopback, handler: @escaping Handler) {
        self.options = options
        self.handler = handler
    }

    /// 待ち受け中のポート。
    public var boundPort: Int? {
        queue.sync { currentPort }
    }

    /// 試験用: 持っている接続の数。
    var connectionCount: Int {
        queue.sync { connections.count }
    }

    /// 待ち受けを始める（既に待ち受けていれば閉じてから）。`port` が 0 なら OS が割り当てる。結果は `onState` に届く（キュー上で呼ぶ）。
    public func start(port: Int, onState: @escaping @Sendable (LoopbackServerState) -> Void) {
        queue.async { [self] in
            generation &+= 1
            let gen = generation
            let once = Once()
            let open: @Sendable () -> Void = { [weak self] in
                guard let self, self.generation == gen, once.claim() else { return }
                self.openLocked(port: port, onState: onState)
            }
            if stopLocked(onCancelled: open) {
                queue.asyncAfter(deadline: .now() + Self.cancelTimeout, execute: open)
            } else {
                open()
            }
        }
    }

    private func openLocked(port: Int, onState: @escaping @Sendable (LoopbackServerState) -> Void) {
        stateHandler = onState
        requestedPort = port
        guard let params = Self.parameters(tls: options.tls, keepalive: options.keepalive) else {
            // TLS を求められて組めない時に平文で開かない。
            onState(.failed("TLS の設定を組めません"))
            return
        }
        // 閉じた直後の TIME_WAIT で取り直しに失敗しないため（待ち受け中の別プロセスとは重ならないことを試験で確かめている）。
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: options.bindHost, port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            onState(Self.state(for: error, port: port))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.listenerChanged(listener, state)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    /// 待ち受けの設定。TLS を求められて組めなければ nil（平文には落とさない）。
    static func parameters(tls identity: TLSServerIdentity?, keepalive: Bool = false,
                           makeIdentity: (SecIdentity) -> sec_identity_t? = { sec_identity_create($0) }) -> NWParameters? {
        let tcp = NWProtocolTCP.Options()
        if keepalive {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
        }
        guard let identity else { return NWParameters(tls: nil, tcp: tcp) }
        guard let secIdentity = makeIdentity(identity.identity) else { return nil }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// 待ち受けを閉じ、ポートを手放すまで（上限 `cancelTimeout`）待ってから戻る。キューの上から呼ばない。
    public func stop() {
        let released = DispatchSemaphore(value: 0)
        let waiting = queue.sync {
            generation &+= 1
            return stopLocked(onCancelled: { released.signal() })
        }
        if waiting { _ = released.wait(timeout: .now() + Self.cancelTimeout) }
    }

    /// `stop` と同じだが、スレッドを塞がずに待つ（画面のスレッドから閉じる時）。
    public func stopAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                generation &+= 1
                let once = Once()
                let resume: @Sendable () -> Void = { if once.claim() { continuation.resume() } }
                if stopLocked(onCancelled: resume) {
                    queue.asyncAfter(deadline: .now() + Self.cancelTimeout, execute: resume)
                } else {
                    resume()
                }
            }
        }
    }

    /// 待ち受けていれば閉じて true（`onCancelled` は手放し終えた時にキュー上で呼ぶ）。
    @discardableResult
    private func stopLocked(onCancelled: (@Sendable () -> Void)? = nil) -> Bool {
        let closing = listener
        closing?.stateUpdateHandler = { state in
            if case .cancelled = state { onCancelled?() }
        }
        closing?.cancel()
        listener = nil
        currentPort = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
        connectionsPerAddress = [:]
        stateHandler = nil
        return closing != nil
    }

    private func listenerChanged(_ listener: NWListener, _ state: NWListener.State) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            let port = Int(listener.port?.rawValue ?? UInt16(requestedPort))
            currentPort = port
            stateHandler?(.listening(port: port))
        case .failed(let error), .waiting(let error):
            // 待たせても空かないことが多いので、閉じて呼び出し側に再試行を任せる。
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil
            currentPort = nil
            stateHandler?(Self.state(for: error, port: requestedPort))
        default:
            break
        }
    }

    static func state(for error: Error, port: Int) -> LoopbackServerState {
        if case NWError.posix(let code) = error, code == .EADDRINUSE { return .portInUse(port: port) }
        return .failed(String(describing: error))
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < options.maxConnections else {
            connection.cancel()
            return
        }
        let address = ConnectionSession.address(of: connection.endpoint) ?? "?"
        if let refuse = options.refuseAddress, refuse(address) {
            connection.cancel()
            return
        }
        if let limit = options.maxConnectionsPerAddress, (connectionsPerAddress[address] ?? 0) >= limit {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connectionsPerAddress[address, default: 0] += 1
        let session = ConnectionSession(connection: connection, queue: queue, handler: handler, options: options,
                                        boundPort: { [weak self] in self?.currentPort ?? 0 }) { [weak self] in
            guard let self, self.connections.removeValue(forKey: id) != nil else { return }
            let left = (self.connectionsPerAddress[address] ?? 1) - 1
            self.connectionsPerAddress[address] = left > 0 ? left : nil
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: session.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        session.begin()
    }
}

/// 一度だけ通す印（タイムアウトと取り消し完了のどちらが先でも 1 回だけ開き直すため）。
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
}

/// 1 接続ぶんの読み取りと応答。キュー上でだけ触る。
private final class ConnectionSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: LoopbackHTTPServer.Handler
    private let options: HTTPServerOptions
    private let boundPort: () -> Int
    private let onFinish: () -> Void
    private var buffer = Data()
    private var head: (method: String, target: String, headers: [String: String], bodyStart: Int, length: Int)?
    private var finished = false
    private var sentContinue = false
    private var dispatched = false
    /// 応答を作っている途中の処理（流し続ける応答ならその送り手）。相手が切ったら止める（長ポーリングの待ち手を残さないため）。
    private var work: Task<Void, Never>?
    /// 流し続ける応答で、送ったがまだ相手に渡っていない量。
    private var pendingStreamBytes = 0

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping LoopbackHTTPServer.Handler,
         options: HTTPServerOptions, boundPort: @escaping () -> Int, onFinish: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.options = options
        self.boundPort = boundPort
        self.onFinish = onFinish
    }

    func begin() {
        queue.asyncAfter(deadline: .now() + options.readTimeout) { [weak self] in
            guard let self, !self.finished, !self.dispatched else { return }
            self.respond(.json(408, ["ok": false, "error": "request timeout"]))
        }
        receive()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        work?.cancel()
        work = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFinish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if self.dispatched {
                // 振り分け後に届く分は読み捨て、切断だけを見張る。
                if error != nil { return self.finish() }
                if isComplete {
                    // 送り終えて片側だけ閉じた相手も応答は待っている。長ポーリングは取り消して早めに返させる（全閉じなら送信の失敗で閉じる）。
                    self.work?.cancel()
                    return
                }
                return self.receive()
            }
            if let data { self.buffer.append(data) }
            if self.process() { return self.receive() }
            if isComplete || error != nil { return self.finish() }
            self.receive()
        }
    }

    /// 揃っていれば応答まで進めて true。まだ足りなければ false。
    private func process() -> Bool {
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > options.maxHeaderBytes {
                    respond(.json(431, ["ok": false, "error": "headers too large"]))
                    return true
                }
                return false
            }
            // 1 回の受信で本文ごと届くと、終端の手前が上限を超えていても上の検査をすり抜ける。
            if end.lowerBound - buffer.startIndex > options.maxHeaderBytes {
                respond(.json(431, ["ok": false, "error": "headers too large"]))
                return true
            }
            guard let parsed = Self.parseHead(buffer[buffer.startIndex..<end.lowerBound]) else {
                respond(.json(400, ["ok": false, "error": "bad request"]))
                return true
            }
            if parsed.headers["transfer-encoding"] != nil {
                respond(.json(501, ["ok": false, "error": "chunked body is not supported"]))
                return true
            }
            var length = 0
            if let raw = parsed.headers["content-length"] {
                guard let n = Self.contentLength(raw) else {
                    respond(.json(400, ["ok": false, "error": "invalid content-length"]))
                    return true
                }
                length = n
            }
            if length > options.maxBodyBytes {
                respond(.json(413, ["ok": false, "error": "payload too large"]))
                return true
            }
            head = (parsed.method, parsed.target, parsed.headers, end.upperBound - buffer.startIndex, length)
            // curl は大きめの本文で `Expect: 100-continue` を付け、返事を待ってから本文を送る。弾く相手には本文を送らせない。
            if length > 0, parsed.headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                if let rejected = options.rejection(request(body: Data()), boundPort()) {
                    respond(rejected)
                    return true
                }
                sentContinue = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
        }
        guard let head, buffer.count >= head.bodyStart + head.length else { return false }
        let start = buffer.startIndex + head.bodyStart
        let request = request(body: buffer.subdata(in: start..<(start + head.length)))
        dispatched = true
        buffer = Data()
        let handler = handler
        let rejection = options.rejection
        let port = boundPort()
        let queue = queue
        weak let weakSelf = self
        work = Task {
            let response: HTTPResponse
            if let rejected = rejection(request, port) {
                response = rejected
            } else {
                response = await handler(request)
            }
            queue.async { weakSelf?.respond(response) }
        }
        return true
    }

    private func request(body: Data) -> HTTPRequest {
        let head = head!
        let (path, query) = Self.splitTarget(head.target)
        return HTTPRequest(method: head.method, path: path, query: query, headers: head.headers, body: body,
                           remoteAddress: Self.address(of: connection.endpoint))
    }

    private func respond(_ response: HTTPResponse) {
        guard !finished else { return }
        dispatched = true
        work = nil
        if let stream = response.stream {
            connection.send(content: response.serialized(), completion: .idempotent)
            pump(stream)
            return
        }
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    /// 流し続ける応答を chunked で送る。流し終えたら終端を送って閉じ、相手が切れば（finish で取り消し）止める。
    private func pump(_ stream: HTTPBodyStream) {
        let queue = queue
        weak let weakSelf = self
        work = Task {
            for await chunk in stream.chunks {
                queue.async { weakSelf?.sendChunk(chunk) }
            }
            queue.async { weakSelf?.endStream() }
        }
    }

    private func sendChunk(_ chunk: Data) {
        guard !finished, !chunk.isEmpty else { return }
        // 受け取らない相手に溜め込ませない。
        guard pendingStreamBytes + chunk.count <= options.maxPendingStreamBytes else { return finish() }
        let framed = HTTPResponse.chunk(chunk)
        pendingStreamBytes += framed.count
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingStreamBytes -= framed.count
            if error != nil { self.finish() }
        })
    }

    private func endStream() {
        guard !finished else { return }
        connection.send(content: HTTPResponse.lastChunk, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    /// 数字だけを通す（`Int("+5")` は通ってしまう）。
    static func contentLength(_ raw: String) -> Int? {
        let digits = raw.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(digits)
    }

    static func parseHead(_ data: Data) -> (method: String, target: String, headers: [String: String])? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            // 名前の前後の空白（継続行を含む）は経路によって解釈が分かれるので受け付けない。
            let rawName = line[..<colon]
            guard !rawName.isEmpty, !rawName.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
            let name = rawName.lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // 同名が重なるのは詐称の手口になりうるので、Host 等は最初の 1 つだけでなく食い違いを弾く。
            if let existing = headers[name], existing != value, ["host", "origin", "content-length", "content-type"].contains(name) {
                return nil
            }
            headers[name] = value
        }
        return (String(requestLine[0]), String(requestLine[1]), headers)
    }

    static func splitTarget(_ target: String) -> (String, String?) {
        guard let q = target.firstIndex(of: "?") else { return (target, nil) }
        return (String(target[..<q]), String(target[target.index(after: q)...]))
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return a.isLoopback ? "127.0.0.1" : "\(a)"
        case .ipv6(let a):
            if let v4 = a.asIPv4 { return v4.isLoopback ? "127.0.0.1" : "\(v4)" }
            return a.isLoopback ? "::1" : "\(a)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }
}
