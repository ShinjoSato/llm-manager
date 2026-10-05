import DeckCore
import XCTest
@testable import MonitorKit

/// iPhone アプリと同じクライアント（DeckCore の RemoteClient）で、mac の口をループバックに立てて端から端まで通す。
@MainActor
final class RemoteClientIntegrationTests: XCTestCase {
    var dir: URL!
    var control: FakeRemoteControl!
    var transcripts: FakeTranscriptSource!
    var service: RemoteAccessService!
    var port = 0
    var fingerprint = ""

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-client-\(UUID().uuidString)")
        control = FakeRemoteControl()
        transcripts = FakeTranscriptSource()
        service = RemoteAccessService(directory: dir, transcripts: transcripts, control: control, serverName: "test-mac",
                                      throttle: RemoteAuthThrottle(window: 60, maxFailures: 50))
        service.start(address: "127.0.0.1", port: 0)
        for _ in 0..<300 where service.boundPort == nil {
            if case .failed(let reason) = service.state { throw NSError(domain: reason, code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        port = try XCTUnwrap(service.boundPort)
        fingerprint = try XCTUnwrap(service.fingerprint)
    }

    override func tearDown() async throws {
        await service?.stopAndWait()
        try? FileManager.default.removeItem(at: dir)
    }

    /// QR の URL を読んだところから、端末トークンを受け取るまで（iPhone のペアリングと同じ手順）。
    private func pairFromQR() async throws -> RemotePairing {
        let offer = try XCTUnwrap(service.beginPairing())
        let scanned = try XCTUnwrap(RemotePairingPayload(url: offer.url), "QR の URL を読める")
        XCTAssertNil(scanned.problem(now: Date().timeIntervalSince1970 * 1000))
        let client = RemoteClient(host: scanned.host, port: scanned.port, pin: scanned.fingerprint, token: nil)
        defer { client.invalidate() }
        let response = try await client.pair(token: scanned.token, deviceName: "test-iphone")
        return RemotePairing(payload: scanned, response: response, pairedAt: 0)
    }

    func testPairListStreamAndAct() async throws {
        control.state = FakeRemoteControl.sampleState()
        let pairing = try await pairFromQR()
        XCTAssertEqual(pairing.fingerprint, fingerprint)
        XCTAssertEqual(pairing.serverName, "test-mac")

        let client = RemoteClient(pairing: pairing)
        defer { client.invalidate() }
        let info = try await client.info()
        XCTAssertEqual(info.device.name, "test-iphone")
        let rooms = try await client.rooms()
        XCTAssertEqual(rooms, control.state)

        // ストリームを張ってから会話を全件取る（取りこぼさない順）。裏で読み続け、待つ側は期限付きで待つ。
        let stream = StreamRecorder(client.events(transcripts: ["*"]))
        defer { stream.cancel() }
        try await waitUntil { !stream.events.isEmpty }
        guard case .state(let first)? = stream.events.first else { return XCTFail("最初は state") }
        XCTAssertEqual(first.rooms.first?.name, "mirio")
        var buffer = TranscriptBuffer()
        buffer.beginFetch()
        let sid = FakeTranscriptSource.sessionId
        buffer.apply(try await client.transcript(sessionId: sid), fullReplace: true)
        XCTAssertEqual(buffer.items.map(\.id), ["u1", "a1"])

        try await waitUntil { await transcripts.subscriberCount > 0 }
        await transcripts.emit(TranscriptEvent(sessionId: sid, items: [FakeTranscriptSource.item("a1", .assistant, "はい"),
                                                                       FakeTranscriptSource.item("a2", .assistant, "done")]))
        try await waitUntil { stream.transcripts.count == 1 }
        buffer.append(try XCTUnwrap(stream.transcripts.first).items)
        XCTAssertEqual(buffer.items.map(\.id), ["u1", "a1", "a2"], "重複は除く")

        control.state.rooms[0].status = .working
        try await waitUntil { stream.states.last?.rooms.first?.status == .working }

        let image = try await client.image(sessionId: sid, itemId: "u1", index: 0)
        XCTAssertEqual(image, FakeTranscriptSource.png)

        let room = try XCTUnwrap(rooms.rooms.first)
        let menu = try XCTUnwrap(room.menu)
        control.result = .success("confirmed")
        let answered = try await client.answerMenu(roomId: room.id, RemoteMenuAnswerRequest(menuId: menu.menuId, choice: 0))
        XCTAssertEqual(answered.code, "confirmed")
        control.result = .failure("blocked_menu", "選択待ち")
        let blocked = try await client.sendMessage(roomId: room.id, text: "hi")
        XCTAssertEqual(blocked, .failure("blocked_menu", "選択待ち"), "失敗の本文（409）も結果として受け取る")
        XCTAssertNotNil(RemoteResultText.text(for: blocked, operation: .message))
        XCTAssertEqual(control.calls.last, "send \(room.id) hi")

        // 取り消されたらストリームは閉じ、以降は登録の取り消しとして分かる。
        service.revoke(pairing.deviceId)
        try await waitUntil { stream.ended }
        XCTAssertNil(stream.failure, "取り消しは相手が閉じるだけ")
        do {
            _ = try await client.rooms()
            XCTFail("取り消し後は通らない")
        } catch {
            XCTAssertEqual(RemoteIssue.from(error).kind, .revoked)
        }
    }

    func testWrongPinIsReportedAsMismatch() async throws {
        let pairing = try await pairFromQR()
        var tampered = pairing
        tampered.fingerprint = String(repeating: "0", count: 64)
        let client = RemoteClient(pairing: tampered)
        defer { client.invalidate() }
        do {
            _ = try await client.rooms()
            XCTFail("別の指紋では繋がらない")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .pinMismatch)
            XCTAssertTrue(RemoteIssue.from(error).needsPairing)
        }
        let stream = StreamRecorder(client.events(transcripts: nil))
        defer { stream.cancel() }
        try await waitUntil { stream.ended }
        XCTAssertTrue(stream.events.isEmpty)
        XCTAssertEqual(stream.failure as? RemoteClientError, .pinMismatch, "ストリームも同じ")
    }

    func testUsedPairingCodeIsRejected() async throws {
        let offer = try XCTUnwrap(service.beginPairing())
        let client = RemoteClient(host: offer.host, port: offer.port, pin: offer.fingerprint, token: nil)
        defer { client.invalidate() }
        _ = try await client.pair(token: offer.token, deviceName: "a")
        do {
            _ = try await client.pair(token: offer.token, deviceName: "b")
            XCTFail("一時トークンは 1 回限り")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .http(status: 401, error: "pairing_rejected",
                                                               message: (error as? RemoteClientError).flatMap {
                                                                   if case .http(_, _, let m) = $0 { return m } else { return nil }
                                                               }))
            XCTAssertEqual(RemoteIssue.from(error).title, "ペアリングできませんでした")
        }
    }

    /// 30x を返す相手でも追わない（トークンを付けた要求を別の行き先へ運ばせない）。
    func testRedirectsAreNotFollowed() async throws {
        let loaded = try TLSIdentityFiles(directory: dir.appendingPathComponent("redirect")).create()
        let paths = Box<[String]>([])
        let server = HTTPServer(options: HTTPServerOptions(tls: loaded.serverIdentity, rejection: { _, _ in nil })) { request in
            paths.mutate { $0.append(request.path) }
            return HTTPResponse(status: 302, headers: [("Location", "https://127.0.0.1:1/v1/elsewhere")])
        }
        let bound = try await startListening(server)
        defer { server.stop() }
        let client = RemoteClient(host: "127.0.0.1", port: bound, pin: loaded.fingerprint, token: "secret")
        defer { client.invalidate() }
        do {
            _ = try await client.rooms()
            XCTFail("30x は失敗として返る")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .http(status: 302, error: nil, message: nil))
        }
        let action = try? await client.sendMessage(roomId: "r", text: "hi")
        XCTAssertNil(action, "操作も追わない")
        let stream = StreamRecorder(client.events(transcripts: nil))
        defer { stream.cancel() }
        try await waitUntil { stream.ended }
        XCTAssertEqual(stream.failure as? RemoteClientError, .http(status: 302, error: nil, message: nil))
        XCTAssertEqual(paths.value, ["/v1/rooms", "/v1/rooms/r/messages", "/v1/events"])
    }

    func testUnreachablePortIsUnreachable() async throws {
        await service.stopAndWait()
        let client = RemoteClient(host: "127.0.0.1", port: port, pin: fingerprint, token: "x")
        defer { client.invalidate() }
        do {
            _ = try await client.rooms()
            XCTFail("閉じた口には繋がらない")
        } catch {
            XCTAssertEqual(RemoteIssue.from(error).kind, .unreachable)
        }
    }
}

/// ストリームを裏で読み切り、届いたものと終わり方を貯める。
final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [RemoteStreamEvent] = []
    private var finished = false
    private var error: Error?
    private var task: Task<Void, Never>?

    init(_ stream: AsyncThrowingStream<RemoteStreamEvent, Error>) {
        task = Task { [self] in
            do {
                for try await event in stream { lock.withLock { received.append(event) } }
                lock.withLock { finished = true }
            } catch {
                lock.withLock { self.error = error; finished = true }
            }
        }
    }

    var events: [RemoteStreamEvent] { lock.withLock { received } }
    var ended: Bool { lock.withLock { finished } }
    var failure: Error? { lock.withLock { error } }
    var states: [RemoteState] { events.compactMap { if case .state(let s) = $0 { s } else { nil } } }
    var transcripts: [TranscriptEvent] { events.compactMap { if case .transcript(let t) = $0 { t } else { nil } } }

    func cancel() { task?.cancel() }
}
