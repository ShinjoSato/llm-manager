import Foundation
import Observation

/// 同じ Wi-Fi の iPhone 向けの口（TLS・端末トークン）。既定では開かず、`start` を呼んだ時だけ LAN のアドレスで待ち受ける。
/// フック・チャネルの口（127.0.0.1:8766）とは別のサーバー・別のポート。
@MainActor
@Observable
public final class RemoteAccessService {
    public private(set) var state: LoopbackServerState = .stopped
    /// 待ち受けているアドレス（LAN の IPv4）。
    public private(set) var listeningAddress: String?
    public private(set) var devices: [RemoteDevice] = []
    /// 端末 id → 開いているストリームの数（接続中の端末）。
    public private(set) var connections: [String: Int] = [:]
    /// 表示中の QR の中身。期限が来るかペアリングが済んだら nil。
    public private(set) var pairingOffer: RemotePairingPayload?
    /// サーバー証明書の指紋（SHA-256・小文字 16 進）。
    public private(set) var fingerprint: String?

    @ObservationIgnored public let pairing: RemotePairingStore
    @ObservationIgnored public let throttle: RemoteAuthThrottle
    @ObservationIgnored public let events: RemoteEventHub
    @ObservationIgnored private let controlRef: RemoteControlRef
    @ObservationIgnored private let identityFiles: TLSIdentityFiles
    @ObservationIgnored private let transcripts: RemoteTranscriptSource
    @ObservationIgnored private let serverName: String
    @ObservationIgnored private let localHostName: String?
    @ObservationIgnored private var server: LoopbackHTTPServer?
    @ObservationIgnored private var identity: TLSIdentityFiles.Loaded?
    @ObservationIgnored private var offerExpiry: Task<Void, Never>?

    /// `directory` に証明書・鍵・端末一覧を置く（0700 / 0600）。
    public init(directory: URL, transcripts: RemoteTranscriptSource, control: RemoteControl?, serverName: String,
                localHostName: String? = nil, throttle: RemoteAuthThrottle = RemoteAuthThrottle()) {
        identityFiles = TLSIdentityFiles(directory: directory)
        pairing = RemotePairingStore(directory: directory)
        self.throttle = throttle
        self.transcripts = transcripts
        self.serverName = serverName
        self.localHostName = localHostName
        controlRef = RemoteControlRef(control)
        events = RemoteEventHub(controlRef: controlRef, transcripts: transcripts)
        devices = pairing.devices()
        pairing.setChangeHandler { [weak self] in
            Task { @MainActor [weak self] in self?.pairingChanged() }
        }
        events.onConnectionsChanged = { [weak self] in self?.connections = $0 }
    }

    public func setControl(_ control: RemoteControl?) {
        controlRef.control = control
    }

    public var isRunning: Bool { server != nil }

    public var boundPort: Int? {
        if case .listening(let port) = state { return port }
        return nil
    }

    /// `address`（LAN の IPv4）の `port` で待ち受ける。既に開いていれば閉じてから。
    public func start(address: String, port: Int) {
        stopServer()
        guard let host = NWEndpointHostValue(ipv4: address) else {
            state = .failed("待ち受けるアドレスが不正です: \(address)")
            return
        }
        do {
            let loaded = try identity ?? identityFiles.loadOrCreate(commonName: "claude-deck \(serverName)")
            identity = loaded
            fingerprint = loaded.fingerprint
        } catch {
            state = .failed("証明書を用意できません: \(error)")
            return
        }
        let routes = RemoteRoutes(pairing: pairing, throttle: throttle, transcripts: transcripts, events: events,
                                  controlRef: controlRef, serverName: serverName)
        let server = LoopbackHTTPServer(options: routes.serverOptions(bindHost: host, tls: identity!.serverIdentity)) { request in
            await routes.handle(request)
        }
        self.server = server
        listeningAddress = address
        state = .starting
        server.start(port: port) { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.server === server else { return }
                self.state = state
            }
        }
    }

    /// 閉じる。開いているストリームも切り、表示中の QR も無効にする。
    public func stop() {
        stopServer()
        state = .stopped
        listeningAddress = nil
        pairing.flush()
    }

    private func stopServer() {
        cancelPairing()
        events.closeAll()
        server?.stop()
        server = nil
    }

    /// QR に出す中身を作る（待ち受け中だけ）。前の QR は使えなくなる。
    @discardableResult
    public func beginPairing() -> RemotePairingPayload? {
        guard let port = boundPort, let address = listeningAddress, let fingerprint else { return nil }
        let ticket = pairing.startPairing()
        let offer = RemotePairingPayload(host: address, port: port, token: ticket.token, fingerprint: fingerprint, name: serverName,
                                         expiresAt: ticket.expiresAt.timeIntervalSince1970 * 1000, localHostName: localHostName)
        pairingOffer = offer
        offerExpiry?.cancel()
        let token = ticket.token
        offerExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, ticket.expiresAt.timeIntervalSinceNow) + 0.5))
            guard let self, !Task.isCancelled, self.pairingOffer?.token == token else { return }
            self.pairingOffer = nil
        }
        return offer
    }

    public func cancelPairing() {
        offerExpiry?.cancel()
        offerExpiry = nil
        pairing.cancelPairing()
        pairingOffer = nil
    }

    /// 端末を取り消し、開いているストリームも切る。
    public func revoke(_ id: String) {
        pairing.revoke(id: id)
        events.close(deviceId: id)
        devices = pairing.devices()
    }

    private func pairingChanged() {
        devices = pairing.devices()
        // QR が使われたら閉じる。
        if pairingOffer != nil, !pairing.isPairingOpen {
            offerExpiry?.cancel()
            pairingOffer = nil
        }
    }
}
