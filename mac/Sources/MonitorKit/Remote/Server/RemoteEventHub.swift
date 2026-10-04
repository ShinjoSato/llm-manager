import Foundation

/// 会話の読み出し元（アプリでは `TranscriptStore`）。
public protocol RemoteTranscriptSource: Sendable {
    func remoteTranscript(sessionId: String, after: String?) async -> TranscriptResponse?
    func remoteImage(sessionId: String, itemId: String, index: Int) async -> TranscriptImageData?
    func remoteSubscribe(_ subscription: TranscriptSubscription, _ fn: @escaping @Sendable (TranscriptEvent) -> Void) async -> Int?
    func remoteUnsubscribe(_ id: Int) async
}

extension TranscriptStore: RemoteTranscriptSource {
    public func remoteTranscript(sessionId: String, after: String?) async -> TranscriptResponse? {
        get(sessionId, after: after)
    }

    public func remoteImage(sessionId: String, itemId: String, index: Int) async -> TranscriptImageData? {
        await image(sessionId: sessionId, itemId: itemId, index: index)
    }

    public func remoteSubscribe(_ subscription: TranscriptSubscription, _ fn: @escaping @Sendable (TranscriptEvent) -> Void) async -> Int? {
        subscribe(subscription, fn)
    }

    public func remoteUnsubscribe(_ id: Int) async {
        unsubscribe(id)
    }
}

/// mac アプリの操作口を弱く持つ（アプリが先に片付いても口は残るため）。
@MainActor
public final class RemoteControlRef {
    public weak var control: RemoteControl?

    public init(_ control: RemoteControl? = nil) {
        self.control = control
    }

    func state() -> RemoteState? { control?.remoteState() }

    func run(_ body: @MainActor @Sendable (RemoteControl) async -> RemoteActionResult) async -> RemoteActionResult {
        guard let control else { return .failure("app_unavailable", "mac アプリの準備ができていません。") }
        return await body(control)
    }
}

/// `/v1/events`（Server-Sent Events）の配信。状態は変わった時だけ全体を送り、会話は購読したセッションの追記を送る。
@MainActor
public final class RemoteEventHub {
    /// 同時に持つストリームの上限（全体・端末ごと）。
    public static let maxStreams = 16
    public static let maxStreamsPerDevice = 4

    private struct Client {
        let deviceId: String
        let continuation: AsyncStream<Data>.Continuation
        var transcriptSubscription: Int?
    }

    private let controlRef: RemoteControlRef
    private let transcripts: RemoteTranscriptSource
    private let pollInterval: Duration
    private let heartbeatInterval: TimeInterval
    private let isDeviceActive: @Sendable (String) -> Bool
    private var clients: [Int: Client] = [:]
    private var seq = 0
    private var lastState: RemoteState?
    private var lastSentAt = Date()
    private var loop: Task<Void, Never>?
    /// 端末 id → 開いているストリームの数。
    public private(set) var connections: [String: Int] = [:]
    public var onConnectionsChanged: (([String: Int]) -> Void)?

    /// `isDeviceActive` は開く直前に端末がまだ有効か（取り消し済みでないか）を確かめる。
    public init(controlRef: RemoteControlRef, transcripts: RemoteTranscriptSource,
                pollInterval: Duration = .milliseconds(300), heartbeatInterval: TimeInterval = 15,
                isDeviceActive: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.controlRef = controlRef
        self.transcripts = transcripts
        self.pollInterval = pollInterval
        self.heartbeatInterval = heartbeatInterval
        self.isDeviceActive = isDeviceActive
    }

    public enum OpenResult: Sendable {
        case opened(HTTPBodyStream)
        /// 認証の後、開くまでの間に取り消された。
        case revoked
        /// 全体の上限に達している。
        case tooMany
    }

    /// ストリームを開く。端末ごとの上限に達していれば、その端末の最も古いストリームを閉じて受ける（黙って切れた分が枠を塞ぐため）。
    public func open(deviceId: String, transcripts subscription: TranscriptSubscription) -> OpenResult {
        // 取り消しも MainActor の上で行うので、ここで有効なら取り消しの後の `close` で必ず閉じられる。
        guard isDeviceActive(deviceId) else { return .revoked }
        if (connections[deviceId] ?? 0) >= Self.maxStreamsPerDevice,
           let oldest = clients.filter({ $0.value.deviceId == deviceId }).keys.min() {
            closeClient(oldest)
        }
        guard clients.count < Self.maxStreams else { return .tooMany }
        seq += 1
        let id = seq
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        clients[id] = Client(deviceId: deviceId, continuation: continuation, transcriptSubscription: nil)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in self?.remove(id) }
        }
        if let state = controlRef.state() {
            continuation.yield(Self.event(.state, state))
            // 他の相手が受け取っていない変化は次の周回で全員へ送る。
            if lastState == nil { lastState = state }
        }
        if subscription != .none {
            let transcripts = transcripts
            Task { [weak self] in
                let token = await transcripts.remoteSubscribe(subscription) { event in
                    continuation.yield(Self.event(.transcript, event))
                }
                guard let token else { return }
                // 張り終える前に切れていたら外す。
                if let self, self.clients[id] != nil {
                    self.clients[id]?.transcriptSubscription = token
                } else {
                    await transcripts.remoteUnsubscribe(token)
                }
            }
        }
        updateConnections()
        startLoop()
        return .opened(HTTPBodyStream(stream))
    }

    /// その端末のストリームを閉じる（取り消した時）。
    public func close(deviceId: String) {
        for (id, client) in clients where client.deviceId == deviceId { closeClient(id) }
    }

    public func closeAll() {
        for id in Array(clients.keys) { closeClient(id) }
    }

    /// 終わらせて、枠もすぐに空ける（`onTermination` からの片付けを待たない）。
    private func closeClient(_ id: Int) {
        guard let client = clients[id] else { return }
        client.continuation.finish()
        remove(id)
    }

    public var streamCount: Int { clients.count }

    private func remove(_ id: Int) {
        guard let client = clients.removeValue(forKey: id) else { return }
        if let token = client.transcriptSubscription {
            let transcripts = transcripts
            Task { await transcripts.remoteUnsubscribe(token) }
        }
        updateConnections()
        if clients.isEmpty {
            loop?.cancel()
            loop = nil
            lastState = nil
        }
    }

    private func updateConnections() {
        var counts: [String: Int] = [:]
        for client in clients.values { counts[client.deviceId, default: 0] += 1 }
        guard counts != connections else { return }
        connections = counts
        onConnectionsChanged?(counts)
    }

    private func startLoop() {
        guard loop == nil else { return }
        let interval = pollInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 状態が変わっていれば全員へ送る。しばらく何も送っていなければ生存確認のコメントを送る（切れた相手を早く見つけるため）。
    func tick() {
        guard !clients.isEmpty else { return }
        if let state = controlRef.state(), state != lastState {
            lastState = state
            broadcast(Self.event(.state, state))
        } else if Date().timeIntervalSince(lastSentAt) >= heartbeatInterval {
            broadcast(Data(": ping\n\n".utf8))
        }
    }

    private func broadcast(_ data: Data) {
        lastSentAt = Date()
        for client in clients.values { client.continuation.yield(data) }
    }

    nonisolated static func event<T: Encodable>(_ name: RemoteEventName, _ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var data = Data("event: \(name.rawValue)\ndata: ".utf8)
        data.append(json)
        data.append(Data("\n\n".utf8))
        return data
    }
}
