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
    var imagesDir: URL { dir.appendingPathComponent("images", isDirectory: true) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-client-\(UUID().uuidString)")
        control = FakeRemoteControl()
        transcripts = FakeTranscriptSource()
        service = RemoteAccessService(directory: dir, transcripts: transcripts, control: control, serverName: "test-mac",
                                      throttle: RemoteAuthThrottle(window: 60, maxFailures: 50))
        control.imageStore = AttachmentStore(directory: imagesDir)
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

    /// 終了になる選択肢の印が iPhone のクライアントまで届き、確認付きで送り直せる。
    func testExitingChoiceMarkReachesClient() async throws {
        let trust = MenuPrompt(context: [], question: "Is this a project you created or one you trust?",
                               options: [.init(number: nil, label: "No, exit"), .init(number: nil, label: "Yes, I trust this folder")],
                               cursor: 0, footer: "Enter to confirm · Esc to cancel", tabs: nil)
        var state = FakeRemoteControl.sampleState()
        state.rooms[0].menu = RemoteMenu(trust, generation: 0)
        control.state = state
        let pairing = try await pairFromQR()
        let client = RemoteClient(pairing: pairing)
        defer { client.invalidate() }

        let rooms = try await client.rooms()
        let room = try XCTUnwrap(rooms.rooms.first)
        let menu = try XCTUnwrap(room.menu)
        XCTAssertTrue(menu.choiceExits(0))
        XCTAssertFalse(menu.choiceExits(1))
        XCTAssertEqual(menu.label(of: 0), "No, exit")

        control.result = .success("confirmed")
        _ = try await client.answerMenu(roomId: room.id, RemoteMenuAnswerRequest(menuId: menu.menuId, choice: 0, confirmExit: true))
        XCTAssertEqual(control.calls.last, "menu \(room.id) \(menu.menuId) choice=0 cancel=false exit=true")
    }

    // MARK: - 端末の画面

    /// iPhone と同じクライアントで端末の表示を取り、キーを送ると、差し替えた端末に 1 回ずつ届いて次の表示に出る。
    func testTerminalScreenAndKeysRoundTrip() async throws {
        let pairing = try await pairFromQR()
        let client = RemoteClient(pairing: pairing)
        defer { client.invalidate() }
        let room = "h:\(UUID().uuidString)"
        let options = ["1. Yes", "2. No"]
        var cursor = 0
        func draw() {
            control.terminalScreen = RemoteTerminalScreen(
                lines: ["Do you want to proceed?"] + options.enumerated().map { ($0.offset == cursor ? "❯ " : "  ") + $0.element },
                cursor: RemoteTerminalCursor(row: cursor + 1, column: 0), columns: 100, rows: 30, capturedAt: Double(cursor), escapeExits: true)
        }
        draw()
        control.keyHandler = { key in
            if key == .down { cursor = min(cursor + 1, options.count - 1) }
            if key == .up { cursor = max(cursor - 1, 0) }
            draw()
        }

        let first = try await client.terminalScreen(roomId: room)
        XCTAssertEqual(first.lines, ["Do you want to proceed?", "❯ 1. Yes", "  2. No"])
        XCTAssertEqual(first.columns, 100)
        XCTAssertTrue(first.escapeExits)

        let sent = try await client.sendTerminalKey(roomId: room, key: .down)
        XCTAssertEqual(sent, .success("sent"))
        XCTAssertEqual(RemoteResultText.text(for: sent, operation: .terminalKey), "送りました。")
        let second = try await client.terminalScreen(roomId: room)
        XCTAssertEqual(second.lines[2], "❯ 2. No")
        XCTAssertEqual(second.cursor, RemoteTerminalCursor(row: 2, column: 0))

        let refused = try await client.sendTerminalKey(roomId: room, key: .escape)
        XCTAssertEqual(refused.code, "confirm_required", "Esc で終わるメニューには確認が要る")
        XCTAssertNotNil(RemoteResultText.text(for: refused, operation: .terminalKey))
        let confirmed = try await client.sendTerminalKey(roomId: room, key: .escape, confirmExit: true)
        XCTAssertTrue(confirmed.ok)
        XCTAssertEqual(control.sentKeys, [.down, .escape])

        control.keyResult = .failure("navigating", "動かしている")
        let busy = try await client.sendTerminalKey(roomId: room, key: .enter)
        XCTAssertEqual(busy.code, "navigating")
        XCTAssertEqual(control.sentKeys, [.down, .escape], "断られたキーは端末に届かない")

        control.endedRooms = [room]
        do {
            _ = try await client.terminalScreen(roomId: room)
            XCTFail("claude が動いていないルームの表示は出さない")
        } catch {
            XCTAssertEqual(error as? RemoteClientError, .http(status: 409, error: "ended", message: "claude が動いていません。"))
            XCTAssertEqual(RemoteResultText.terminalScreenProblem(error), "claude が動いていないため、端末の画面は出せません。")
        }
        do {
            _ = try await client.terminalScreen(roomId: "e:\(FakeTranscriptSource.sessionId)")
            XCTFail("外部セッションの表示は出さない")
        } catch {
            XCTAssertEqual(RemoteResultText.terminalScreenProblem(error), "このルームは Mac でホストしていないため、端末の画面は出せません。")
        }
    }

    // MARK: - 画像付きの送信

    private func storedImageFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? []).sorted()
    }

    /// iPhone と同じクライアントで画像を付けて送ると、mac の入力欄の添付と同じ形（一時保存先の画像ファイル）で受け手に渡る。
    func testImagesReachTheAttachmentPath() async throws {
        let client = RemoteClient(pairing: try await pairFromQR())
        defer { client.invalidate() }
        let room = "h:\(UUID().uuidString)"
        let png = TestImages.png(width: 40, height: 30)
        let jpeg = TestImages.jpeg(width: 20, height: 10)
        control.result = .success("submitted")
        let result = try await client.sendMessage(roomId: room, text: "この画面を見て", images: [
            RemoteMessageImage(mediaType: "image/png", data: png), RemoteMessageImage(mediaType: "image/jpeg", data: jpeg),
        ])
        XCTAssertEqual(result, .success("submitted"))
        XCTAssertEqual(control.calls.last, "send \(room) この画面を見て images=2")
        let images = try XCTUnwrap(control.receivedImages.last)
        XCTAssertEqual(images.map(\.kind), [.image, .image])
        XCTAssertEqual(images.map { ($0.path as NSString).pathExtension }, ["png", "jpg"])
        XCTAssertEqual(try images.map { try Data(contentsOf: URL(fileURLWithPath: $0.path)) }, [png, jpeg], "届いた中身のまま書く")
        for image in images {
            XCTAssertEqual(URL(fileURLWithPath: image.path).deletingLastPathComponent().standardizedFileURL.path,
                           imagesDir.standardizedFileURL.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "本人だけが読める")
        }
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: imagesDir.path)
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        // PTY に貼る手前: 入力欄の添付と同じ組み立てで、画像のパスだけを先に貼り、本文は別に貼る。
        let outgoing = AttachmentFormat.outgoing(text: "この画面を見て", attachments: images, pasteImages: true)
        XCTAssertEqual(outgoing.imageCount, 2)
        XCTAssertEqual(outgoing.imagePaths, images.map(\.path))
        XCTAssertEqual(outgoing.imagePaste, images.map(\.path).joined(separator: " "))
        XCTAssertEqual(outgoing.body, "この画面を見て")

        // 本文が空でも画像だけで送れる。
        let only = try await client.sendMessage(roomId: room, text: "", images: [RemoteMessageImage(mediaType: "image/png", data: png)])
        XCTAssertEqual(only, .success("submitted"))
        XCTAssertEqual(control.calls.last, "send \(room)  images=1")
        let onlyOutgoing = AttachmentFormat.outgoing(text: "", attachments: try XCTUnwrap(control.receivedImages.last), pasteImages: true)
        XCTAssertEqual(onlyOutgoing.imageCount, 1)
        XCTAssertEqual(onlyOutgoing.body, "")

        // 画像の無い送信は今までどおり（受け手に画像は渡らない）。
        _ = try await client.sendMessage(roomId: room, text: "続けて")
        XCTAssertEqual(control.calls.last, "send \(room) 続けて")
        XCTAssertEqual(control.receivedImages.last, [])
    }

    /// 上限・型違い・読めない画像・外部セッションは mac の操作に渡さず、ファイルも残さずに断る。
    func testImagesAreRefusedBeforeReachingTheApp() async throws {
        let client = RemoteClient(pairing: try await pairFromQR())
        defer { client.invalidate() }
        let room = "h:\(UUID().uuidString)"
        let png = RemoteMessageImage(mediaType: "image/png", data: TestImages.png())
        let missing = "h:\(UUID().uuidString)"
        control.missingRooms = [missing]
        var truncated = TestImages.png(width: 64, height: 64)
        truncated = truncated.prefix(truncated.count / 2)

        let cases: [(String, [RemoteMessageImage], String, String)] = [
            ("枚数", Array(repeating: png, count: RemoteImageLimits.maxCount + 1), room, "too_many_images"),
            ("宣言と中身が違う", [RemoteMessageImage(mediaType: "image/png", data: TestImages.jpeg())], room, "unsupported_image"),
            ("PNG / JPEG 以外", [RemoteMessageImage(mediaType: "image/gif", data: Data("GIF89a".utf8))], room, "unsupported_image"),
            ("見出しだけの PNG", [RemoteMessageImage(mediaType: "image/png", data: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]))],
             room, "unsupported_image"),
            ("途中で切れた PNG", [RemoteMessageImage(mediaType: "image/png", data: truncated)], room, "unsupported_image"),
            ("一辺が長すぎる", [RemoteMessageImage(mediaType: "image/png", data: TestImages.png(width: RemoteImageLimits.maxPixelSide + 1, height: 1))],
             room, "image_too_large"),
            ("外部セッションへの伝言", [png], "e:\(FakeTranscriptSource.sessionId)", "images_not_accepted"),
            // 送り先を先に確かめる（壊れた画像でも読み込む前に断る）。
            ("外部セッションへの壊れた画像", [RemoteMessageImage(mediaType: "image/png", data: truncated)], "e:\(FakeTranscriptSource.sessionId)",
             "images_not_accepted"),
            ("無いルーム", [png], missing, "not_found"),
        ]
        for (label, images, target, code) in cases {
            let result = try await client.sendMessage(roomId: target, text: "見て", images: images)
            XCTAssertFalse(result.ok, label)
            XCTAssertEqual(result.code, code, label)
            XCTAssertNotNil(RemoteResultText.text(for: result, operation: .message), label)
        }
        XCTAssertEqual(control.calls, [], "断った要求は mac の操作に届かない")
        XCTAssertEqual(storedImageFiles(), [], "一時ファイルを残さない")

        // 外部セッションでも文字だけの伝言は今までどおり渡る。
        let relay = try await client.sendMessage(roomId: "e:\(FakeTranscriptSource.sessionId)", text: "伝言")
        XCTAssertTrue(relay.ok)
        XCTAssertEqual(control.calls, ["send e:\(FakeTranscriptSource.sessionId) 伝言"])
    }

    /// 256KB を超える本文（画像付き）は、送り先を確かめてから枠の中で読み込み、同じ形で渡す。
    func testLargeImageBodies() async throws {
        let client = RemoteClient(pairing: try await pairFromQR())
        defer { client.invalidate() }
        let noisy = TestImages.png(width: 320, height: 320, noise: true)
        XCTAssertGreaterThan(noisy.count * 4 / 3, RemoteRoutes.maxBodyBytes, "大きな本文の経路を通る")
        let image = RemoteMessageImage(mediaType: "image/png", data: noisy)
        control.result = .success("submitted")
        let room = "h:\(UUID().uuidString)"
        let sent = try await client.sendMessage(roomId: room, text: "大きい", images: [image])
        XCTAssertEqual(sent, .success("submitted"))
        let stored = try XCTUnwrap(control.receivedImages.last)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(stored.first).path)), noisy)

        let external = try await client.sendMessage(roomId: "e:\(FakeTranscriptSource.sessionId)", text: "", images: [image])
        XCTAssertEqual(external.code, "images_not_accepted")
        let missing = "h:\(UUID().uuidString)"
        control.missingRooms = [missing]
        let gone = try await client.sendMessage(roomId: missing, text: "", images: [image])
        XCTAssertEqual(gone.code, "not_found")
        XCTAssertEqual(control.calls.count, 1, "断った要求は mac の操作に届かない")
        XCTAssertEqual(storedImageFiles().count, 1, "断った分は書かない")
    }

    /// 取り込みの枠が埋まっていれば、画像付きは待たせずに断る（文字だけの送信は通す）。
    func testImageIntakeIsRefusedWhenBusy() async throws {
        await service.stopAndWait()
        service = RemoteAccessService(directory: dir, transcripts: transcripts, control: control, serverName: "test-mac",
                                      throttle: RemoteAuthThrottle(window: 60, maxFailures: 50),
                                      imageIntake: RemoteImageIntakeQueue(limit: 0))
        service.start(address: "127.0.0.1", port: 0)
        try await waitUntil { self.service.boundPort != nil }
        let client = RemoteClient(pairing: try await pairFromQR())
        defer { client.invalidate() }
        let room = "h:\(UUID().uuidString)"
        let small = try await client.sendMessage(roomId: room, text: "", images: [RemoteMessageImage(mediaType: "image/png", data: TestImages.png())])
        XCTAssertEqual(small.code, "images_busy")
        let large = try await client.sendMessage(roomId: room, text: "", images: [
            RemoteMessageImage(mediaType: "image/png", data: TestImages.png(width: 320, height: 320, noise: true)),
        ])
        XCTAssertEqual(large.code, "images_busy")
        XCTAssertNotNil(RemoteResultText.text(for: large, operation: .message))
        XCTAssertEqual(storedImageFiles(), [])
        let text = try await client.sendMessage(roomId: room, text: "文字だけ")
        XCTAssertTrue(text.ok)
        XCTAssertEqual(control.calls, ["send \(room) 文字だけ"])
    }

    /// mac の画面の受け手が無い時は、書いた画像を片付けて断る。
    func testImagesAreDiscardedWhenTheAppIsNotReady() async throws {
        let client = RemoteClient(pairing: try await pairFromQR())
        defer { client.invalidate() }
        service.setControl(nil)
        let result = try await client.sendMessage(roomId: "h:\(UUID().uuidString)", text: "",
                                                  images: [RemoteMessageImage(mediaType: "image/png", data: TestImages.png())])
        XCTAssertEqual(result.code, "app_unavailable")
        XCTAssertEqual(storedImageFiles(), [])
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
