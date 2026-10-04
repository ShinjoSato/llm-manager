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

final class SSEParserTests: XCTestCase {
    private func run(_ text: String) throws -> [SSEParser.Output] {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var out: [SSEParser.Output] = []
        for byte in Array(text.utf8) {
            if let line = try splitter.feed(byte), let output = parser.feed(line) { out.append(output) }
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
        XCTAssertTrue(unreachable.retryable)
        XCTAssertFalse(RemoteIssue.from(RemoteClientError.pinMismatch).retryable)
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
        XCTAssertTrue(newer.problem(now: 0)!.contains("iPhone アプリを更新"))
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
