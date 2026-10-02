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

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
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
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        default: return "Status"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
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

/// 127.0.0.1 だけで待ち受ける最小の HTTP/1.1 サーバー（1 接続 1 リクエスト・Content-Length のみ）。外部ライブラリは使わない。
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    /// 本文の上限。フックの JSON は最後の応答文などを含むので小さすぎないようにする。
    public static let maxBodyBytes = 8 * 1024 * 1024
    static let maxHeaderBytes = 64 * 1024
    /// 送り切らない相手で接続を握られ続けないための締め切り。
    static let readTimeout: TimeInterval = 15

    private let queue = DispatchQueue(label: "claude-deck.http-server")
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stateHandler: (@Sendable (LoopbackServerState) -> Void)?
    private var requestedPort: Int = 0
    private(set) public var boundPort: Int?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// 待ち受けを始める（既に待ち受けていれば閉じてから）。`port` が 0 なら OS が割り当てる。結果は `onState` に届く（キュー上で呼ぶ）。
    public func start(port: Int, onState: @escaping @Sendable (LoopbackServerState) -> Void) {
        queue.async { [self] in
            stopLocked()
            stateHandler = onState
            requestedPort = port
            let params = NWParameters.tcp
            // 閉じた直後の TIME_WAIT で取り直しに失敗しないため（待ち受け中の別プロセスとは重ならないことを試験で確かめている）。
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
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
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        boundPort = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
        stateHandler = nil
    }

    private func listenerChanged(_ listener: NWListener, _ state: NWListener.State) {
        guard listener === self.listener else { return }
        switch state {
        case .ready:
            let port = Int(listener.port?.rawValue ?? UInt16(requestedPort))
            boundPort = port
            stateHandler?(.listening(port: port))
        case .failed(let error), .waiting(let error):
            // 待たせても空かないことが多いので、閉じて呼び出し側に再試行を任せる。
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil
            boundPort = nil
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
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let session = ConnectionSession(connection: connection, queue: queue, handler: handler,
                                        boundPort: { [weak self] in self?.boundPort ?? 0 }) { [weak self] in
            self?.connections[id] = nil
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

/// 1 接続ぶんの読み取りと応答。キュー上でだけ触る。
private final class ConnectionSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: LoopbackHTTPServer.Handler
    private let boundPort: () -> Int
    private let onFinish: () -> Void
    private var buffer = Data()
    private var head: (method: String, target: String, headers: [String: String], bodyStart: Int, length: Int)?
    private var finished = false
    private var sentContinue = false

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping LoopbackHTTPServer.Handler,
         boundPort: @escaping () -> Int, onFinish: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.boundPort = boundPort
        self.onFinish = onFinish
    }

    func begin() {
        queue.asyncAfter(deadline: .now() + LoopbackHTTPServer.readTimeout) { [weak self] in
            guard let self, !self.finished, !self.dispatched else { return }
            self.respond(.json(408, ["ok": false, "error": "request timeout"]))
        }
        receive()
    }

    private var dispatched = false

    func finish() {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFinish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished, !self.dispatched else { return }
            if let data { self.buffer.append(data) }
            if self.process() { return }
            if isComplete || error != nil { return self.finish() }
            self.receive()
        }
    }

    /// 揃っていれば応答まで進めて true。まだ足りなければ false。
    private func process() -> Bool {
        if head == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > LoopbackHTTPServer.maxHeaderBytes {
                    respond(.json(431, ["ok": false, "error": "headers too large"]))
                    return true
                }
                return false
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
                guard let n = Int(raw.trimmingCharacters(in: .whitespaces)), n >= 0 else {
                    respond(.json(400, ["ok": false, "error": "invalid content-length"]))
                    return true
                }
                length = n
            }
            if length > LoopbackHTTPServer.maxBodyBytes {
                respond(.json(413, ["ok": false, "error": "payload too large"]))
                return true
            }
            head = (parsed.method, parsed.target, parsed.headers, end.upperBound - buffer.startIndex, length)
            // curl は大きめの本文で `Expect: 100-continue` を付け、返事を待ってから本文を送る。
            if length > 0, parsed.headers["expect"]?.lowercased() == "100-continue", !sentContinue {
                sentContinue = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
            }
        }
        guard let head, buffer.count >= head.bodyStart + head.length else { return false }
        let start = buffer.startIndex + head.bodyStart
        let body = buffer.subdata(in: start..<(start + head.length))
        let (path, query) = Self.splitTarget(head.target)
        let request = HTTPRequest(method: head.method, path: path, query: query, headers: head.headers, body: body,
                                  remoteAddress: Self.address(of: connection.endpoint))
        dispatched = true
        let handler = handler
        let port = boundPort()
        let queue = queue
        weak let weakSelf = self
        Task {
            let response = await MonitorHTTPRoutes.guarded(request, port: port, handler: handler)
            queue.async { weakSelf?.respond(response) }
        }
        return true
    }

    private func respond(_ response: HTTPResponse) {
        guard !finished else { return }
        dispatched = true
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() })
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
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
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
