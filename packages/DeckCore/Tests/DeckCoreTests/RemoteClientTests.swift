import Security
import XCTest
@testable import DeckCore

/// 自己署名の P-256 証明書（試験用・鍵は捨ててある）。
enum TestCertificate {
    static let der = Data(base64Encoded: "MIIBizCCATGgAwIBAgIUVKlT6tsFpcpwJiwUUv2dSijYLBYwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQY2xhdWRlLWRlY2sgdGVzdDAeFw0yNjEwMDQxNDUxMjFaFw00NjA5MjkxNDUxMjFaMBsxGTAXBgNVBAMMEGNsYXVkZS1kZWNrIHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS0Ly7JnNTwszCb4Ya5Njb6RelOHiu7NEPnl8xKLBc1pZrMHWJUGi4E/eWzQJdru5yANa2aHQbYarc0J8Uyr8wNo1MwUTAdBgNVHQ4EFgQUOn8ZFMyfdUPCEPIRh60aFNEE80QwHwYDVR0jBBgwFoAUOn8ZFMyfdUPCEPIRh60aFNEE80QwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAgG3ig74ofIWXM8+8CLbhvDIDl3eCY2N2H5TufLO5lXkCIFTcpNNnY/k2DtDXBzIFyEJAHjOM8J+lQQsjDSONXttT")!
    static let fingerprint = "fe23391bbc2e3fbe7d3deb5e88a700c840462100a98fc52bbd175ba524787fce"

    static func trust() throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "192.168.1.5" as CFString), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }
}

final class RemotePinningVerdictTests: XCTestCase {
    func testFingerprintOfDER() {
        XCTAssertEqual(RemotePinning.fingerprint(of: TestCertificate.der), TestCertificate.fingerprint)
    }

    func testOnlyMatchingFingerprintIsTrusted() throws {
        let trust = try TestCertificate.trust()
        let method = NSURLAuthenticationMethodServerTrust
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: method, serverTrust: trust, pin: TestCertificate.fingerprint), .trusted)
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: method, serverTrust: trust,
                                                           pin: RemotePinning.display(TestCertificate.fingerprint)), .trusted,
                       "表示用の AB:CD 形式でも同じ")
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: method, serverTrust: trust,
                                                           pin: String(repeating: "0", count: 64)), .mismatch)
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: method, serverTrust: trust, pin: ""), .mismatch)
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: method, serverTrust: nil, pin: TestCertificate.fingerprint), .mismatch)
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: NSURLAuthenticationMethodHTTPBasic, serverTrust: nil,
                                                           pin: TestCertificate.fingerprint), .notServerTrust)
    }

    func testCAEvaluationWouldFailButPinStillDecides() throws {
        // 自己署名なので通常の検証は通らない（ピン留めはそれに頼らない）。
        let trust = try TestCertificate.trust()
        XCTAssertFalse(SecTrustEvaluateWithError(trust, nil))
        XCTAssertTrue(RemotePinning.matches(trust, pinned: TestCertificate.fingerprint))
    }
}

final class RemoteRequestBuilderTests: XCTestCase {
    let builder = RemoteRequestBuilder(host: "192.168.1.5", port: 8767, token: "tok")

    func testPairHasNoBearerAndJSONBody() throws {
        let req = try builder.pair(token: "one-time", deviceName: "iPhone")
        XCTAssertEqual(req.url?.absoluteString, "https://192.168.1.5:8767/v1/pair")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try JSONDecoder().decode(RemotePairRequest.self, from: XCTUnwrap(req.httpBody)),
                       RemotePairRequest(token: "one-time", deviceName: "iPhone"))
    }

    func testAuthorizedGets() throws {
        let rooms = try builder.rooms()
        XCTAssertEqual(rooms.url?.absoluteString, "https://192.168.1.5:8767/v1/rooms")
        XCTAssertEqual(rooms.httpMethod, "GET")
        XCTAssertEqual(rooms.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let events = try builder.events(transcripts: ["*"])
        XCTAssertEqual(events.url?.absoluteString, "https://192.168.1.5:8767/v1/events?transcripts=*")
        XCTAssertEqual(events.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(try builder.events(transcripts: nil).url?.query, nil)
        XCTAssertEqual(try builder.events(transcripts: ["a", "b"]).url?.query, "transcripts=a,b")

        let sid = "11111111-2222-3333-4444-555555555555"
        XCTAssertEqual(try builder.transcript(sessionId: sid, after: nil).url?.path, "/v1/sessions/\(sid)/transcript")
        XCTAssertEqual(try builder.transcript(sessionId: sid, after: "a:3").url?.query, "after=a:3")
        XCTAssertEqual(try builder.image(sessionId: sid, itemId: "u:0", index: 2).url?.absoluteString,
                       "https://192.168.1.5:8767/v1/sessions/\(sid)/items/u:0/images/2")
    }

    func testRoomActions() throws {
        let room = "h:6F1C0C9E-0000-4000-8000-000000000000"
        let send = try builder.message(roomId: room, text: "こんにちは")
        XCTAssertEqual(send.url?.absoluteString, "https://192.168.1.5:8767/v1/rooms/\(room)/messages")
        XCTAssertEqual(try JSONDecoder().decode(RemoteMessageRequest.self, from: XCTUnwrap(send.httpBody)).text, "こんにちは")
        XCTAssertEqual(try builder.menu(roomId: room, RemoteMenuAnswerRequest(menuId: "m", choice: 1)).url?.path, "/v1/rooms/\(room)/menu")
        XCTAssertEqual(try builder.menuTab(roomId: room, RemoteMenuTabRequest(menuId: "m", direction: .next)).url?.path, "/v1/rooms/\(room)/menu/tab")
        XCTAssertEqual(try builder.menuDismiss(roomId: room, RemoteMenuDismissRequest(menuId: "m")).url?.path, "/v1/rooms/\(room)/menu/dismiss")
        let permission = try builder.terminalPermission(roomId: room, promptId: "p", decision: .deny)
        XCTAssertEqual(permission.url?.path, "/v1/rooms/\(room)/permission")
        XCTAssertEqual(try JSONDecoder().decode(RemoteTerminalPermissionRequest.self, from: XCTUnwrap(permission.httpBody)).decision, .deny)
        let decide = try builder.decide(key: "k", decision: .allow)
        XCTAssertEqual(decide.url?.path, "/v1/permissions/decision")
        XCTAssertGreaterThan(decide.timeoutInterval, 30, "mac は操作を最大 30 秒待つ")
    }

    func testTerminalScreenAndKey() throws {
        let room = "h:6F1C0C9E-0000-4000-8000-000000000000"
        let screen = try builder.terminalScreen(roomId: room)
        XCTAssertEqual(screen.url?.absoluteString, "https://192.168.1.5:8767/v1/rooms/\(room)/terminal")
        XCTAssertEqual(screen.httpMethod, "GET")
        XCTAssertEqual(screen.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let key = try builder.terminalKey(roomId: room, RemoteTerminalKeyRequest(key: .digit3))
        XCTAssertEqual(key.url?.path, "/v1/rooms/\(room)/terminal/key")
        XCTAssertEqual(key.httpMethod, "POST")
        let body = try XCTUnwrap(key.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["key": "3"], "確認が要らなければ confirmExit は省く")
        let escape = try builder.terminalKey(roomId: room, RemoteTerminalKeyRequest(key: .escape, confirmExit: true))
        XCTAssertEqual(try JSONDecoder().decode(RemoteTerminalKeyRequest.self, from: XCTUnwrap(escape.httpBody)),
                       RemoteTerminalKeyRequest(rawKey: "escape", confirmExit: true))
    }

    func testMessageWithImagesKeepsTheOldShapeWhenThereAreNone() throws {
        let room = "h:6F1C0C9E-0000-4000-8000-000000000000"
        let plain = try XCTUnwrap(builder.message(roomId: room, text: "a").httpBody)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), #"{"text":"a"}"#, "画像が無ければ前と同じ本文")
        XCTAssertEqual(try JSONDecoder().decode(RemoteMessageRequest.self, from: Data(#"{"text":"old"}"#.utf8)),
                       RemoteMessageRequest(text: "old"), "画像の無い古い要求も読める")

        // `/` を含む base64 になる中身（0xff 0xff 0xff → "////"）。
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0xff, 0xff, 0xff])
        let req = try builder.message(roomId: room, text: "", images: [RemoteMessageImage(mediaType: "image/png", data: png)])
        let body = try XCTUnwrap(req.httpBody)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(#"\/"#), "base64 の / はそのまま")
        let decoded = try JSONDecoder().decode(RemoteMessageRequest.self, from: body)
        XCTAssertEqual(decoded.images, [RemoteMessageImage(mediaType: "image/png", data: png)])
        XCTAssertEqual(decoded.text, "")
        XCTAssertGreaterThan(req.timeoutInterval, try builder.message(roomId: room, text: "a").timeoutInterval, "画像付きは長めに待つ")
    }

    func testImageLimits() {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0])
        XCTAssertEqual(RemoteImageLimits.sniffedMediaType(png), "image/png")
        XCTAssertEqual(RemoteImageLimits.sniffedMediaType(jpeg), "image/jpeg")
        XCTAssertNil(RemoteImageLimits.sniffedMediaType(Data("GIF89a".utf8)))
        XCTAssertNil(RemoteImageLimits.sniffedMediaType(Data()))

        XCTAssertNil(RemoteImageLimits.problem([]))
        XCTAssertNil(RemoteImageLimits.problem([.init(mediaType: "image/png", data: png), .init(mediaType: "IMAGE/JPEG", data: jpeg)]))
        let five = Array(repeating: RemoteMessageImage(mediaType: "image/png", data: png), count: RemoteImageLimits.maxCount + 1)
        XCTAssertEqual(RemoteImageLimits.problem(five)?.code, "too_many_images")
        XCTAssertEqual(RemoteImageLimits.problem([.init(mediaType: "image/gif", data: Data("GIF89a".utf8))])?.code, "unsupported_image")
        XCTAssertEqual(RemoteImageLimits.problem([.init(mediaType: "image/heic", data: png)])?.code, "unsupported_image")
        XCTAssertEqual(RemoteImageLimits.problem([.init(mediaType: "image/png", data: jpeg)])?.code, "unsupported_image", "宣言と中身が違う")

        var big = png
        big.append(Data(count: RemoteImageLimits.maxBytes))
        XCTAssertEqual(RemoteImageLimits.problem([.init(mediaType: "image/png", data: big)])?.code, "image_too_large", "1 枚の上限")
        var under = png
        under.append(Data(count: RemoteImageLimits.maxBytes - png.count))
        XCTAssertNil(RemoteImageLimits.problem([.init(mediaType: "image/png", data: under)]))
        let overTotal = Array(repeating: RemoteMessageImage(mediaType: "image/png", data: under), count: 3)
        XCTAssertEqual(RemoteImageLimits.problem(overTotal)?.code, "image_too_large", "合計の上限")

        XCTAssertLessThanOrEqual(RemoteImageLimits.budgetBytes * RemoteImageLimits.maxCount, RemoteImageLimits.maxTotalBytes)
        XCTAssertGreaterThan(RemoteImageLimits.maxEncodedBytes, RemoteImageLimits.maxTotalBytes * 4 / 3)
        for code in ["too_many_images", "image_too_large", "unsupported_image", "images_not_accepted", "images_busy", "image_store_failed"] {
            XCTAssertNotNil(RemoteResultText.text(for: .failure(code, "x"), operation: .message), code)
            XCTAssertNotEqual(RemoteResultText.text(for: .failure(code, "x"), operation: .message), "x", "日本語の文言を持つ")
        }
    }

    func testRelayUnavailableDoesNotMentionImages() {
        let text = RemoteResultText.text(for: .failure("unavailable", "x"), operation: .relay) ?? ""
        XCTAssertFalse(text.contains("画像"), "画像の拒否は専用のコードで伝える")
        XCTAssertNotEqual(RemoteResultText.text(for: .failure("image_store_failed", "x"), operation: .message),
                          RemoteResultText.text(for: .failure("failed", "x"), operation: .message), "保存の失敗は「答えを届けられない」に化けない")
    }

    func testSlashInIdDoesNotBreakPath() throws {
        let req = try builder.message(roomId: "e:a/b?c", text: "x")
        XCTAssertEqual(req.url?.absoluteString, "https://192.168.1.5:8767/v1/rooms/e:a%2Fb%3Fc/messages")
    }

    func testLocalHostName() throws {
        let local = RemoteRequestBuilder(host: "shinjo-mac.local", port: 9000, token: nil)
        XCTAssertEqual(try local.info().url?.absoluteString, "https://shinjo-mac.local:9000/v1/info")
        XCTAssertNil(try local.info().value(forHTTPHeaderField: "Authorization"))
    }
}

final class RemotePinnedDelegateTests: XCTestCase {
    func testRedirectIsNotFollowed() {
        let delegate = RemotePinnedSessionDelegate(pin: TestCertificate.fingerprint)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://192.168.1.5:8767/v1/rooms")!)
        let response = HTTPURLResponse(url: URL(string: "https://192.168.1.5:8767/v1/rooms")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.com/"])!
        let called = expectation(description: "答える")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://example.com/")!)) { next in
            XCTAssertNil(next, "追わずに 30x をそのまま返す")
            called.fulfill()
        }
        wait(for: [called], timeout: 1)
        XCTAssertFalse(delegate.hasMismatched)
    }
}

final class PairingAddressTests: XCTestCase {
    private func payload(host: String, local: String? = nil) -> RemotePairingPayload {
        RemotePairingPayload(host: host, port: 8767, token: "t", fingerprint: TestCertificate.fingerprint, name: "mac", expiresAt: 0,
                             localHostName: local)
    }

    func testOnlyLocalNetworkHostsAreAccepted() {
        for host in ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.254", "192.168.1.5", "169.254.10.20",
                     "shinjo-mac.local", "Shinjo-MacBook.LOCAL", "a.b.local"] {
            XCTAssertTrue(RemotePairingPayload.isLocalNetworkHost(host), host)
            XCTAssertNil(payload(host: host).addressProblem, host)
        }
        for host in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "127.0.0.1", "0.0.0.0", "100.64.0.1", "example.com",
                     "evil.local.example.com", ".local", "local", "mac.local.", "010.0.0.1", "10.0.0", "10.0.0.1.2", "256.1.1.1",
                     "::1", "fe80::1", "", "a_b.local", "-a.local", "mac.local:80", "10.0.0.1/x", "１０.0.0.1"] {
            XCTAssertFalse(RemotePairingPayload.isLocalNetworkHost(host), host)
            XCTAssertNotNil(payload(host: host).addressProblem, host)
        }
    }

    func testBackupNameMustBeDotLocal() {
        XCTAssertNil(payload(host: "192.168.1.5", local: "mac.local").addressProblem)
        XCTAssertNil(payload(host: "192.168.1.5", local: nil).addressProblem)
        XCTAssertNotNil(payload(host: "192.168.1.5", local: "10.0.0.2").addressProblem, "予備は名前だけ")
        XCTAssertNotNil(payload(host: "192.168.1.5", local: "example.com").addressProblem)
        XCTAssertNotNil(payload(host: "192.168.1.5", local: "").addressProblem)
    }
}

final class SSEParserTests: XCTestCase {
    private func run(_ text: String) throws -> [SSEParser.Output] {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var out: [SSEParser.Output] = []
        for byte in Array(text.utf8) {
            if let line = try splitter.feed(byte), let output = try parser.feed(line) { out.append(output) }
        }
        return out
    }

    func testEventsAreSeparatedByBlankLines() throws {
        let out = try run("event: state\ndata: {\"a\":1}\n\n: ping\n\nevent: transcript\ndata: x\ndata: y\n\n")
        XCTAssertEqual(out, [.message(.init(event: "state", data: "{\"a\":1}")), .comment,
                             .message(.init(event: "transcript", data: "x\ny"))])
    }

    func testCRLFAndNoSpaceAfterColon() throws {
        let out = try run("event:state\r\ndata:{}\r\n\r\n")
        XCTAssertEqual(out, [.message(.init(event: "state", data: "{}"))])
    }

    func testIncompleteEventIsNotEmitted() throws {
        XCTAssertEqual(try run("event: state\ndata: {}\n"), [])
    }

    func testDecodesStateAndTranscript() throws {
        let state = RemoteState(rooms: [], usage: nil, monitoring: true)
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertEqual(try SSEParser.decode(.init(event: "state", data: json)), .state(state))
        let event = TranscriptEvent(sessionId: "s", items: [TestItem.user("u", "hi", at: 1)])
        let tjson = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertEqual(try SSEParser.decode(.init(event: "transcript", data: tjson)), .transcript(event))
        XCTAssertNil(try SSEParser.decode(.init(event: "future", data: "{}")), "知らないイベントは捨てる")
        XCTAssertThrowsError(try SSEParser.decode(.init(event: "state", data: "{")))
    }

    func testEventDataIsCapped() throws {
        var parser = SSEParser()
        parser.maxEventBytes = 8
        XCTAssertNil(try parser.feed("event: state"))
        XCTAssertNil(try parser.feed("data: 1234"))
        XCTAssertThrowsError(try parser.feed("data: 5678"), "区切りの無いまま積み上がる相手は打ち切る") { error in
            XCTAssertTrue(error is SSEParser.Overflow)
        }
        // 打ち切った分は捨て、次の 1 件からは読める。
        XCTAssertNil(try parser.feed("data: ok"))
        XCTAssertEqual(try parser.feed(""), .message(.init(event: "message", data: "ok")))
        XCTAssertEqual(SSEParser().maxEventBytes, 16 << 20)
        XCTAssertFalse(RemoteIssue.from(RemoteClientError.streamOverflow).needsPairing, "張り直しへ回す")
    }

    func testLineSplitterRejectsHugeLines() {
        var splitter = LineSplitter()
        splitter.maxLineBytes = 4
        XCTAssertThrowsError(try (0..<10).forEach { _ in _ = try splitter.feed(0x41) })
    }
}

final class RemoteMessagesTests: XCTestCase {
    func testResultCodesHaveHumanText() {
        for code in ["gone", "changed", "busy", "timeout", "ended", "app_unavailable", "failed", "not_found", "invalid",
                     "unavailable", "confirm_required", "blocked_permission", "blocked_menu", "leftover", "aborted", "stuck",
                     "vanished", "settling"] {
            let text = RemoteResultText.text(for: .failure(code, "server"), operation: .menu)
            XCTAssertNotNil(text, code)
            XCTAssertFalse(text!.contains(code), "コードをそのまま見せない: \(code)")
        }
        XCTAssertTrue(RemoteResultText.text(for: .failure("timeout", "x"), operation: .permission)!.contains("後から反映"))
        XCTAssertTrue(RemoteResultText.text(for: .failure("gone", "x"), operation: .message)!.contains("セッション"))
        XCTAssertEqual(RemoteResultText.text(for: .failure("weird", "サーバーの説明"), operation: .menu), "サーバーの説明",
                       "知らないコードは mac の文言")
        XCTAssertEqual(RemoteResultText.text(for: RemoteActionResult(ok: false, code: "weird"), operation: .menu), "うまくいきませんでした（weird）。")
    }

    func testTerminalKeyResultsHaveHumanText() {
        for code in ["busy", "navigating", "sending", "ended", "unsupported_key", "confirm_required", "unavailable", "not_found"] {
            let text = RemoteResultText.text(for: .failure(code, "server"), operation: .terminalKey)
            XCTAssertNotNil(text, code)
            XCTAssertFalse(text!.contains(code), code)
        }
        XCTAssertTrue(RemoteResultText.text(for: .failure("confirm_required", "x"), operation: .terminalKey)!.contains("Esc"))
        XCTAssertTrue(RemoteResultText.text(for: .failure("unavailable", "x"), operation: .terminalKey)!.contains("ホスト"))
        XCTAssertEqual(RemoteResultText.text(for: .success("sent"), operation: .terminalKey), "送りました。")
        XCTAssertNil(RemoteResultText.text(for: .success("sent"), operation: .message), "他の操作の成功は黙ったまま")
    }

    func testTerminalScreenProblems() {
        XCTAssertTrue(RemoteResultText.terminalScreenProblem(RemoteClientError.http(status: 409, error: "ended", message: "x")).contains("動いていない"))
        XCTAssertTrue(RemoteResultText.terminalScreenProblem(RemoteClientError.http(status: 409, error: "unavailable", message: "x")).contains("ホスト"))
        XCTAssertEqual(RemoteResultText.terminalScreenProblem(RemoteClientError.http(status: 409, error: "weird", message: "mac の説明")), "mac の説明")
        XCTAssertEqual(RemoteResultText.terminalScreenProblem(RemoteClientError.http(status: 401, error: "unauthorized", message: "")),
                       RemoteIssue.from(RemoteClientError.http(status: 401, error: "unauthorized", message: "")).title)
    }

    func testOldMacWithoutTheTerminalRouteAsksForAnUpdate() {
        let getOnOldMac = RemoteClientError.http(status: 405, error: "method_not_allowed", message: "method not allowed")
        let postOnOldMac = RemoteClientError.http(status: 404, error: "not_found", message: "not found")
        XCTAssertEqual(RemoteResultText.terminalScreenProblem(getOnOldMac), RemoteResultText.outdatedMac)
        XCTAssertEqual(RemoteResultText.terminalKeyProblem(getOnOldMac), RemoteResultText.outdatedMac)
        XCTAssertEqual(RemoteResultText.terminalKeyProblem(postOnOldMac), RemoteResultText.outdatedMac)
        XCTAssertFalse(RemoteResultText.outdatedMac.contains("method"), "英語のまま出さない")
        XCTAssertEqual(RemoteResultText.terminalScreenProblem(RemoteClientError.http(status: 404, error: "not_found", message: "ルームが見つかりません")),
                       "このルームはもうありません。", "新しい mac の 404 はルームが無いこと")
        XCTAssertTrue(RemoteResultText.terminalKeyProblem(RemoteClientError.transport(.timedOut)).contains("届いたかどうか"))
    }

    func testSuccessIsMostlySilent() {
        XCTAssertNil(RemoteResultText.text(for: .success("decided"), operation: .permission))
        XCTAssertNil(RemoteResultText.text(for: .success("submitted"), operation: .message))
        XCTAssertNotNil(RemoteResultText.text(for: .success("answered"), operation: .menu))
        XCTAssertNotNil(RemoteResultText.text(for: .success("toggled"), operation: .menu))
    }

    func testIssues() {
        XCTAssertEqual(RemoteIssue.from(RemoteClientError.pinMismatch).kind, .pinMismatch)
        XCTAssertTrue(RemoteIssue.from(RemoteClientError.pinMismatch).needsPairing)
        XCTAssertEqual(RemoteIssue.from(RemoteClientError.http(status: 401, error: "unauthorized", message: nil)).kind, .revoked)
        XCTAssertEqual(RemoteIssue.from(RemoteClientError.http(status: 401, error: "pairing_rejected", message: nil)).kind, .other)
        XCTAssertEqual(RemoteIssue.from(RemoteClientError.http(status: 429, error: "too_many_failures", message: nil)).kind, .throttled)
        let unreachable = RemoteIssue.from(RemoteClientError.transport(.timedOut))
        XCTAssertEqual(unreachable.kind, .unreachable)
        XCTAssertTrue(unreachable.detail.contains("Wi-Fi") && unreachable.detail.contains("スリープ") && unreachable.detail.contains("iPhone 連携"))
        XCTAssertTrue(RemoteIssue.from(RemoteClientError.transport(.networkConnectionLost)).detail.contains("一時的"))
    }

    func testOfflineErrorIsSplitByPathCheck() {
        let offline = RemoteClientError.transport(.notConnectedToInternet)
        XCTAssertTrue(RemoteIssue.needsPathCheck(offline))
        XCTAssertTrue(RemoteIssue.needsPathCheck(RemoteClientError.transport(.dataNotAllowed)))
        XCTAssertFalse(RemoteIssue.needsPathCheck(RemoteClientError.transport(.timedOut)))
        XCTAssertFalse(RemoteIssue.needsPathCheck(RemoteClientError.pinMismatch))
        XCTAssertFalse(RemoteIssue.needsPathCheck(URLError(.notConnectedToInternet)), "RemoteClient を通ったものだけ")

        // 許可が無いと確かめられた時は、Wi-Fi の判定に関わらず許可を案内する。
        for wifi in [true, false, nil] as [Bool?] {
            let denied = RemoteIssue.diagnose(offline, path: .localNetworkDenied, onWiFi: wifi)
            XCTAssertEqual(denied, .localNetworkDenied)
            XCTAssertTrue(denied.needsSettings)
            XCTAssertFalse(denied.needsPairing)
        }
        // 経路が無い・Wi-Fi でないと分かっている時は Wi-Fi。
        XCTAssertEqual(RemoteIssue.diagnose(offline, path: .notAvailable, onWiFi: true), .offline)
        XCTAssertEqual(RemoteIssue.diagnose(offline, path: .inconclusive, onWiFi: false), .offline)
        XCTAssertEqual(RemoteIssue.diagnose(offline, path: nil, onWiFi: false), .offline)
        XCTAssertFalse(RemoteIssue.offline.needsSettings)
        // 確かめられなければ言い切らない。
        XCTAssertEqual(RemoteIssue.diagnose(offline, path: .inconclusive, onWiFi: true), .ambiguousOffline)
        XCTAssertEqual(RemoteIssue.diagnose(offline, path: nil, onWiFi: nil), .ambiguousOffline)
        XCTAssertEqual(RemoteIssue.from(offline), .ambiguousOffline)
        XCTAssertFalse(RemoteIssue.ambiguousOffline.needsSettings)
        // 他のエラーは経路の判定に左右されない。
        let timedOut = RemoteClientError.transport(.timedOut)
        XCTAssertEqual(RemoteIssue.diagnose(timedOut, path: .localNetworkDenied, onWiFi: false), RemoteIssue.from(timedOut))
        XCTAssertEqual(RemoteIssue.diagnose(RemoteClientError.pinMismatch, path: .notAvailable, onWiFi: false).kind, .pinMismatch)
    }

    func testOfflineTexts() {
        XCTAssertEqual(RemoteIssue.localNetworkDenied.title, "ローカルネットワークの使用が許可されていません")
        XCTAssertEqual(RemoteIssue.localNetworkDenied.detail, "設定 → アプリ → claude-deck →『ローカルネットワーク』をオンにして、アプリに戻ってください。")
        XCTAssertFalse(RemoteIssue.localNetworkDenied.title.contains("Wi-Fi"), "許可が原因の時に Wi-Fi のせいにしない")
        XCTAssertEqual(RemoteIssue.offline.title, "Wi-Fi につながっていません")
        XCTAssertEqual(RemoteIssue.offline.detail, "この端末を Mac と同じ Wi-Fi につないでください。")
        XCTAssertFalse(RemoteIssue.offline.title.contains("許可"))
        let ambiguous = RemoteIssue.ambiguousOffline
        XCTAssertTrue(ambiguous.title.contains("ローカルネットワークの許可") && ambiguous.title.contains("Wi-Fi"), "両方を挙げる")
        XCTAssertTrue(ambiguous.detail.contains("ローカルネットワーク") && ambiguous.detail.contains("同じ Wi-Fi"))
        XCTAssertNotEqual(ambiguous.title, RemoteIssue.offline.title)
        // 張り直しの途中で切れたのか最初からつながらないのか分からないので、片方に言い切らない。
        XCTAssertTrue(RemoteIssue.from(RemoteClientError.transport(.secureConnectionFailed)).title.contains("か、"))
    }

    func testBackoffGrowsAndCaps() {
        var backoff = RemoteBackoff(base: 1, cap: 30)
        let delays = (0..<8).map { _ in backoff.next(jitter: 0.5) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        backoff.reset()
        XCTAssertEqual(backoff.next(jitter: 0.5), 1)
        XCTAssertEqual(backoff.next(jitter: 0), 1.6, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(RemoteBackoff.throttledDelay(jitter: 0), 60)
    }
}

final class RemotePairingTests: XCTestCase {
    let payload = RemotePairingPayload(host: "192.168.1.5", port: 8767, token: "t", fingerprint: TestCertificate.fingerprint,
                                       name: "Mac", expiresAt: 2_000, localHostName: "mac.local")

    func testProblems() {
        XCTAssertNil(payload.problem(now: 1_000))
        XCTAssertNotNil(payload.problem(now: 2_000), "期限切れ")
        var newer = payload
        newer.apiVersion = RemoteAPI.version + 1
        XCTAssertTrue(newer.problem(now: 0)!.contains("iPhone・iPad のアプリを更新"))
    }

    func testPairingKeepsFallbackHost() {
        let pairing = RemotePairing(payload: payload, response: RemotePairResponse(deviceId: "d", deviceToken: "dt", serverName: ""),
                                    pairedAt: 1)
        XCTAssertEqual(pairing.serverName, "Mac", "名前が無ければ QR の名前")
        XCTAssertEqual(pairing.hosts, ["192.168.1.5", "mac.local"])
        var noLocal = pairing
        noLocal.localHostName = nil
        XCTAssertEqual(noLocal.hosts, ["192.168.1.5"])
        let data = try! JSONEncoder().encode(pairing)
        XCTAssertEqual(try JSONDecoder().decode(RemotePairing.self, from: data), pairing)
    }
}

final class RemoteTerminalTests: XCTestCase {
    func testKeysAreTheSheetTable() {
        XCTAssertEqual(RemoteTerminalKey.allCases.map(\.rawValue),
                       ["left", "up", "down", "right", "enter", "escape", "tab", "space", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertEqual(RemoteTerminalKey.allCases.map(\.label),
                       ["←", "↑", "↓", "→", "Enter", "Esc", "Tab", "Space", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertNil(RemoteTerminalKey(rawValue: "0"))
    }

    func testLimitedKeepsTheBottomAndMovesTheCursor() {
        let lines = (0..<(RemoteTerminalScreen.maxLines + 5)).map { "line \($0)" }
        let screen = RemoteTerminalScreen.limited(lines: lines, cursor: RemoteTerminalCursor(row: 10, column: 2), columns: 80, rows: 24,
                                                  capturedAt: 1, escapeExits: false)
        XCTAssertEqual(screen.lines.count, RemoteTerminalScreen.maxLines)
        XCTAssertEqual(screen.lines.first, "line 5", "端末と同じく下を残す")
        XCTAssertEqual(screen.cursor, RemoteTerminalCursor(row: 5, column: 2))
        let cut = RemoteTerminalScreen.limited(lines: lines, cursor: RemoteTerminalCursor(row: 2, column: 0), columns: 80, rows: 24,
                                               capturedAt: 1, escapeExits: false)
        XCTAssertNil(cut.cursor, "切った行にあるカーソルは落とす")
        let long = RemoteTerminalScreen.limited(lines: [String(repeating: "a", count: RemoteTerminalScreen.maxLineLength + 10)], cursor: nil,
                                                columns: 80, rows: 24, capturedAt: 1, escapeExits: true)
        XCTAssertEqual(long.lines[0].count, RemoteTerminalScreen.maxLineLength)
        XCTAssertTrue(long.escapeExits)
        let below = RemoteTerminalScreen.limited(lines: ["a", "b"], cursor: RemoteTerminalCursor(row: 5, column: 0), columns: 80, rows: 24,
                                                 capturedAt: 1, escapeExits: false)
        XCTAssertNil(below.cursor, "末尾の空行を落として lines の外になったカーソルは送らない")
        XCTAssertEqual(RemoteTerminalScreen.limited(lines: ["a", "b"], cursor: RemoteTerminalCursor(row: 1, column: 3), columns: 80, rows: 24,
                                                    capturedAt: 1, escapeExits: false).cursor, RemoteTerminalCursor(row: 1, column: 3))
    }

    func testSameContentIgnoresTheCaptureTime() {
        let a = RemoteTerminalScreen(lines: ["x"], cursor: nil, columns: 80, rows: 24, capturedAt: 1, escapeExits: false)
        var b = a
        b.capturedAt = 2
        XCTAssertTrue(a.sameContent(as: b))
        b.lines = ["y"]
        XCTAssertFalse(a.sameContent(as: b))
        var c = a
        c.escapeExits = true
        XCTAssertFalse(a.sameContent(as: c))
    }

    func testStaleResponsesAreDropped() {
        var order = RemoteResponseOrder()
        let poll = order.issue()
        let later = order.issue()
        XCTAssertTrue(order.accept(later))
        XCTAssertFalse(order.accept(poll), "後に出した要求の応答を使った後は、先の要求の遅れた応答を捨てる")

        let beforeKey = order.issue()
        order.invalidateIssued()
        let afterKey = order.issue()
        XCTAssertFalse(order.accept(beforeKey), "キーを送る前に出した取り直しの応答は捨てる")
        XCTAssertTrue(order.accept(afterKey))
        XCTAssertFalse(order.accept(afterKey), "同じ応答は二度使わない")
    }
}
