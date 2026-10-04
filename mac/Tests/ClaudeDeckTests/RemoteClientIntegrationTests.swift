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

        // ストリームを張ってから会話を全件取る（取りこぼさない順）。
        var events = client.events(transcripts: ["*"]).makeAsyncIterator()
        guard case .state(let first)? = try await events.next() else { return XCTFail("最初は state") }
        XCTAssertEqual(first.rooms.first?.name, "mirio")
        var buffer = TranscriptBuffer()
        buffer.beginFetch()
        let sid = FakeTranscriptSource.sessionId
        buffer.apply(try await client.transcript(sessionId: sid), fullReplace: true)
        XCTAssertEqual(buffer.items.map(\.id), ["u1", "a1"])

        for _ in 0..<200 where await transcripts.subscriberCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await transcripts.emit(TranscriptEvent(sessionId: sid, items: [FakeTranscriptSource.item("a1", .assistant, "はい"),
                                                                       FakeTranscriptSource.item("a2", .assistant, "done")]))
        var appended: TranscriptEvent?
        while appended == nil, let next = try await events.next() {
            if case .transcript(let event) = next { appended = event }
        }
        buffer.append(try XCTUnwrap(appended).items)
        XCTAssertEqual(buffer.items.map(\.id), ["u1", "a1", "a2"], "重複は除く")

        control.state.rooms[0].status = .working
        var changed: RemoteState?
        while changed == nil, let next = try await events.next() {
            if case .state(let state) = next { changed = state }
        }
        XCTAssertEqual(changed?.rooms.first?.status, .working)

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
        while let next = try await events.next() { _ = next }
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
        var stream = client.events(transcripts: nil).makeAsyncIterator()
        do {
            _ = try await stream.next()
            XCTFail("ストリームも同じ")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .pinMismatch)
        }
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
