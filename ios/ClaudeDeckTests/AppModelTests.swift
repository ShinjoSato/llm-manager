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
        keychain = PairingKeychain(service: PairingKeychain.serviceName(suffix: "tests.\(UUID().uuidString)"))
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

    private func openModel() -> AppModel {
        let send = RemoteSendState(mode: .input, disabledReason: nil)
        let room = RemoteRoom(id: "h:1", kind: .hosted, phase: .active, name: "p", branch: nil, status: .working, line: "", activityAt: nil,
                              sessionId: "s", cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                              unreadableMenu: nil, busy: false, send: send)
        let pairing = RemotePairing(host: "192.168.1.5", port: 8767, localHostName: nil, fingerprint: String(repeating: "ab", count: 32),
                                    serverName: "Mac", deviceId: "d", deviceToken: "t", pairedAt: 0)
        return AppModel(demo: RemoteState(rooms: [room], usage: nil, monitoring: true), pairing: pairing, transcripts: [:], open: nil)
    }

    private func reply(_ id: String) -> TranscriptEvent {
        TranscriptEvent(sessionId: "s", items: [TranscriptItem(id: id, kind: .assistant, at: 0, text: "x", tool: nil, parentId: nil)])
    }

    func testRebuiltScreenOpeningBeforeOldOneClosesKeepsConversationOpen() {
        let model = openModel()
        let old = UUID(), new = UUID()
        model.open(sessionId: "s", viewer: old)
        model.open(sessionId: "s", viewer: new)
        model.close(viewer: old)
        XCTAssertEqual(model.openSessionId, "s", "作り直した画面が先に開いても、古い画面の閉じるで閉じない")
        XCTAssertEqual(model.openRoomId, "h:1", "開いている会話の知らせはアプリの中で出さない")
        model.simulateReceived(reply("a1"))
        XCTAssertNil(model.unread["s"], "見ている会話の応答を未読に数えない")
        XCTAssertEqual(model.transcriptFetchCount, 1, "同じ会話の開き直しでは取り直さない")
        model.close(viewer: new)
        XCTAssertNil(model.openSessionId)
        model.simulateReceived(reply("a2"))
        XCTAssertEqual(model.unread["s"], 1)
    }

    func testRebuiltScreenClosingBeforeNewOneOpensKeepsConversationOpen() {
        let model = openModel()
        let old = UUID(), new = UUID()
        model.open(sessionId: "s", viewer: old)
        model.close(viewer: old)
        model.open(sessionId: "s", viewer: new)
        XCTAssertEqual(model.openSessionId, "s")
        XCTAssertEqual(model.openRoomId, "h:1")
        model.simulateReceived(reply("a1"))
        XCTAssertNil(model.unread["s"])
    }

    func testSwitchingRoomsInTwoColumnsKeepsTheNewOne() {
        let model = openModel()
        let first = UUID(), second = UUID()
        model.open(sessionId: "other", viewer: first)
        model.open(sessionId: "s", viewer: second)
        model.close(viewer: first)
        XCTAssertEqual(model.openSessionId, "s", "前のルームの画面が後から閉じても、今のルームは開いたまま")
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
        let keychain = PairingKeychain(service: PairingKeychain.serviceName(suffix: "tests.\(UUID().uuidString)"))
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

/// 「端末の画面」の取り直しは開いている間だけ回り、閉じたら止まる。
@MainActor
final class TerminalWatchTests: XCTestCase {
    private var keychain: PairingKeychain!

    override func setUp() {
        keychain = PairingKeychain(service: PairingKeychain.serviceName(suffix: "tests.\(UUID().uuidString)"))
    }

    override func tearDown() {
        keychain.delete()
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("時間内に揃いませんでした") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeModel() -> AppModel {
        let model = AppModel(keychain: keychain, startMonitoring: false)
        model.terminalRefreshInterval = .milliseconds(20)
        return model
    }

    func testRefreshRunsWhileOpenAndStopsWhenClosed() async throws {
        let model = makeModel()
        let viewer = UUID()
        XCTAssertFalse(model.isWatchingTerminal)
        model.watchTerminal(roomId: "h:room", viewer: viewer)
        XCTAssertTrue(model.isWatchingTerminal)
        XCTAssertEqual(model.terminalWatch?.roomId, "h:room")
        try await waitUntil { model.terminalFetchCount >= 3 }
        XCTAssertEqual(model.terminalWatch?.problem, AppModel.terminalDisconnectedProblem, "つながっていない間は理由を出す")
        XCTAssertNil(model.terminalWatch?.screen)

        model.stopWatchingTerminal(viewer: viewer)
        XCTAssertFalse(model.isWatchingTerminal)
        XCTAssertNil(model.terminalWatch)
        let stopped = model.terminalFetchCount
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.terminalFetchCount, stopped, "閉じたら取り直さない")
    }

    func testOnlyTheLastOpenedSheetCanStopIt() async throws {
        let model = makeModel()
        let old = UUID()
        let new = UUID()
        model.watchTerminal(roomId: "h:a", viewer: old)
        model.watchTerminal(roomId: "h:b", viewer: new)
        XCTAssertEqual(model.terminalWatch?.roomId, "h:b", "開き直したら前のシートの分は止める")
        model.stopWatchingTerminal(viewer: old)
        XCTAssertTrue(model.isWatchingTerminal, "古いシートの閉じるでは止めない")
        let before = model.terminalFetchCount
        try await waitUntil { model.terminalFetchCount > before + 2 }
        model.stopWatchingTerminal(viewer: new)
        XCTAssertFalse(model.isWatchingTerminal)
    }

    func testKeyIsNotSentWhileDisconnected() {
        let model = makeModel()
        let viewer = UUID()
        model.watchTerminal(roomId: "h:a", viewer: viewer)
        model.sendTerminalKey(.enter)
        XCTAssertEqual(model.terminalWatch?.notice?.isError, true)
        XCTAssertEqual(model.terminalWatch?.sending, false)
        model.stopWatchingTerminal(viewer: viewer)
    }

    func testConversationUnderTheSheetStaysOpenUntilTheSheetCloses() {
        let model = makeModel()
        let room = RemoteRoom(id: "h:room", kind: .hosted, phase: .attention, name: "mirio", branch: nil, status: .waiting, line: "",
                              activityAt: nil, sessionId: "s1", cwd: "/tmp", ended: nil, session: nil, permissions: [],
                              terminalPermission: nil, menu: nil, unreadableMenu: nil, busy: false,
                              send: RemoteSendState(mode: .input, disabledReason: nil))
        model.simulateReceived(RemoteState(rooms: [room], usage: nil, monitoring: true))
        let conversation = UUID()
        let sheet = UUID()
        model.open(sessionId: "s1", viewer: conversation)
        model.watchTerminal(roomId: room.id, viewer: sheet)
        model.close(viewer: conversation)
        XCTAssertEqual(model.openRoomId, room.id, "シートを重ねている間は会話を閉じた扱いにしない（未読を数えない）")
        model.simulateReceived(TranscriptEvent(sessionId: "s1", items: [TranscriptItem(id: "a1", kind: .assistant, at: 1, text: "はい",
                                                                                        tool: nil, parentId: nil, images: [])]))
        XCTAssertNil(model.unread["s1"])
        model.stopWatchingTerminal(viewer: sheet)
        XCTAssertNil(model.openRoomId, "シートを閉じた時に、待っていた閉じるを済ませる")

        model.open(sessionId: "s1", viewer: conversation)
        model.watchTerminal(roomId: room.id, viewer: sheet)
        model.close(viewer: conversation)
        model.open(sessionId: "s1", viewer: conversation)
        model.stopWatchingTerminal(viewer: sheet)
        XCTAssertEqual(model.openRoomId, room.id, "開き直された会話はシートを閉じても閉じない")
    }

    func testForgettingThePairingStopsIt() {
        let model = makeModel()
        model.watchTerminal(roomId: "h:a", viewer: UUID())
        model.forget()
        XCTAssertFalse(model.isWatchingTerminal)
        XCTAssertNil(model.terminalWatch)
    }
}
