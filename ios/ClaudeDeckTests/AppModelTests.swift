import DeckCore
import Network
import XCTest
@testable import ClaudeDeck

/// 接続を止めた・忘れた後に、古い接続が状態を書き換えないこと。ペアリングの解除と伝言の後始末。
@MainActor
final class AppModelConnectionTests: XCTestCase {
    private var keychain: PairingKeychain!
    private var listener: NWListener?
    private let accepted = AcceptedConnections()

    override func setUp() {
        keychain = PairingKeychain(service: "com.shinjosato.claude-deck.ios.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        listener?.cancel()
        accepted.cancelAll()
        keychain.delete()
    }

    /// 受け入れるだけで何も返さない相手（TLS の握手の途中で止まり、接続中のままになる）。
    private func startSilentListener() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let accepted = accepted
        listener.newConnectionHandler = { connection in
            accepted.add(connection)
            connection.start(queue: .global())
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        self.listener = listener
        return Int(try XCTUnwrap(listener.port).rawValue)
    }

    /// 使われていないポート（繋ぎに行くとすぐ断られる）。
    private func closedPort() async throws -> Int {
        let port = try await startSilentListener()
        listener?.cancel()
        listener = nil
        return port
    }

    private func pairedModel(port: Int) throws -> AppModel {
        try keychain.save(RemotePairing(host: "127.0.0.1", port: port, localHostName: nil, fingerprint: String(repeating: "ab", count: 32),
                                        serverName: "Mac", deviceId: "d", deviceToken: "t", pairedAt: 0))
        let model = AppModel(keychain: keychain, startMonitoring: false)
        XCTAssertEqual(model.connection, .paused)
        return model
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("時間内に揃いませんでした") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testPauseWhileConnectingStaysPaused() async throws {
        let model = try pairedModel(port: try await startSilentListener())
        model.connect()
        try await waitUntil { self.accepted.count > 0 && model.connection == .connecting }
        model.pause()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.connection, .paused, "止めた接続が待ち（張り直し）で上書きしない")
        XCTAssertEqual(accepted.count, 1, "裏で張り直さない")
    }

    func testForgetWhileConnectingStaysUnpaired() async throws {
        let model = try pairedModel(port: try await startSilentListener())
        model.connect()
        try await waitUntil { self.accepted.count > 0 && model.connection == .connecting }
        model.forget()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.connection, .unpaired)
        XCTAssertNil(model.pairing)
        XCTAssertNil(keychain.load())
        XCTAssertEqual(accepted.count, 1)
    }

    func testPauseWhileWaitingStaysPaused() async throws {
        let model = try pairedModel(port: try await closedPort())
        model.connect()
        try await waitUntil {
            if case .waiting = model.connection { return true }
            return false
        }
        model.pause()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.connection, .paused)
    }

    func testUnpairThatDidNotReachMacAsksToRevokeThere() async throws {
        let model = try pairedModel(port: try await closedPort())
        model.connect()
        try await waitUntil {
            if case .waiting = model.connection { return true }
            return false
        }
        let note = await model.unpair()
        XCTAssertEqual(note, AppModel.unpairNotDeliveredNote, "届かなければ mac 側での取り消しを案内する")
        XCTAssertEqual(model.connection, .unpaired, "手元は消す")
        XCTAssertNil(keychain.load())
    }

    func testUnpairWithoutConnectionAsksToRevokeThere() async throws {
        let model = try pairedModel(port: 1)
        let note = await model.unpair()
        XCTAssertEqual(note, AppModel.unpairNotDeliveredNote)
        XCTAssertNil(model.pairing)
    }

    #if DEBUG
    func testRelayNoteIsSettledWhenItCannotBeSent() throws {
        let send = RemoteSendState(mode: .relay, disabledReason: nil)
        let room = RemoteRoom(id: "e:1", kind: .external, phase: .idle, name: "p", branch: nil, status: .idle, line: "", activityAt: nil,
                              sessionId: "s", cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                              unreadableMenu: nil, busy: false, send: send)
        let pairing = RemotePairing(host: "192.168.1.5", port: 8767, localHostName: nil, fingerprint: String(repeating: "ab", count: 32),
                                    serverName: "Mac", deviceId: "d", deviceToken: "t", pairedAt: 0)
        let model = AppModel(demo: RemoteState(rooms: [room], usage: nil, monitoring: true), pairing: pairing, transcripts: [:], open: nil)
        model.drafts[room.id] = "hello"
        model.send(room)
        let notes = try XCTUnwrap(model.relayNotes["s"])
        XCTAssertEqual(notes.count, 1)
        guard case .failed = notes[0].state else { return XCTFail("送れなかった伝言は送信中のまま残さない: \(notes[0].state)") }
        XCTAssertEqual(model.drafts[room.id], "hello", "送れなければ入力欄は残す")
    }
    #endif
}

/// 受け入れた接続を数え、終わりに閉じる。
private final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    func add(_ connection: NWConnection) { lock.withLock { connections.append(connection) } }
    var count: Int { lock.withLock { connections.count } }
    func cancelAll() { lock.withLock { connections.forEach { $0.cancel() } } }
}

/// 確認画面に出す前に、手元の LAN の外を指すリンクを断る。
final class PairingAddressOnIOSTests: XCTestCase {
    private func link(host: String, local: String? = "mac.local") -> String {
        RemotePairingPayload(host: host, port: 8767, token: "one-time", fingerprint: String(repeating: "ab", count: 32), name: "Mac",
                             expiresAt: 4_000_000_000_000, localHostName: local).url.absoluteString
    }

    func testOutsideAddressesAreRefusedBeforeConfirmation() {
        for source in [PairingOffer.Source.camera, .pasted, .openedURL] {
            for host in ["8.8.8.8", "example.com", "127.0.0.1", "100.64.0.1"] {
                guard case .failure(.notLocal(let reason)) = PairingOffer.parse(link(host: host), source: source) else {
                    XCTFail("\(host) は確認画面に進ませない")
                    continue
                }
                XCTAssertTrue(reason.contains(host))
            }
            guard case .failure(.notLocal) = PairingOffer.parse(link(host: "192.168.1.5", local: "evil.example.com"), source: source) else {
                XCTFail("予備の名前も .local だけ")
                continue
            }
        }
        for host in ["192.168.1.5", "10.0.0.2", "172.20.1.1", "169.254.3.4", "mac.local"] {
            XCTAssertNotNil(try? PairingOffer.parse(link(host: host), source: .camera).get(), host)
        }
    }

    @MainActor
    func testOutsideLinkShowsReasonWithoutOffer() {
        let keychain = PairingKeychain(service: "com.shinjosato.claude-deck.ios.tests.\(UUID().uuidString)")
        defer { keychain.delete() }
        let model = AppModel(keychain: keychain, startMonitoring: false)
        model.offerLink(link(host: "203.0.113.5"), source: .pasted)
        XCTAssertNil(model.pendingOffer)
        XCTAssertTrue(model.pairingError?.text.contains("203.0.113.5") == true)
    }

    func testPastedLinksAreWarnedLikeOpenedOnes() throws {
        XCTAssertNil(try PairingOffer.parse(link(host: "192.168.1.5"), source: .camera).get().originWarning)
        XCTAssertNotNil(try PairingOffer.parse(link(host: "192.168.1.5"), source: .pasted).get().originWarning)
        XCTAssertNotNil(try PairingOffer.parse(link(host: "192.168.1.5"), source: .openedURL).get().originWarning)
    }
}
