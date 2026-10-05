import DeckCore
import Security
import XCTest
@testable import ClaudeDeck

private let fingerprint = String(repeating: "ab", count: 32)

private func pairingURL(exp: Double = 4_000_000_000_000, version: Int = RemoteAPI.version) -> String {
    RemotePairingPayload(host: "192.168.1.5", port: 8767, token: "one-time", fingerprint: fingerprint, name: "Shinjo の Mac",
                         expiresAt: exp, localHostName: "mac.local", apiVersion: version).url.absoluteString
}

/// QR・貼り付け・外部から開かれたリンクの解析と、確認なしには使わないこと。
@MainActor
final class PairingLinkTests: XCTestCase {
    private var keychain: PairingKeychain!

    override func setUp() {
        keychain = PairingKeychain(service: "com.shinjosato.claude-deck.ios.tests.\(UUID().uuidString)")
    }

    override func tearDown() {
        keychain.delete()
    }

    func testParsesPairingURL() throws {
        let offer = try PairingOffer.parse(" \(pairingURL())\n", source: .camera).get()
        XCTAssertEqual(offer.payload.host, "192.168.1.5")
        XCTAssertEqual(offer.payload.port, 8767)
        XCTAssertEqual(offer.payload.fingerprint, fingerprint)
        XCTAssertEqual(offer.payload.localHostName, "mac.local")
        XCTAssertEqual(offer.payload.name, "Shinjo の Mac")
    }

    func testRejectsOtherLinks() {
        XCTAssertEqual(PairingOffer.parse("https://example.com/pair?host=1", source: .camera).failure, .notPairingLink)
        XCTAssertEqual(PairingOffer.parse("ただの文字", source: .pasted).failure, .notPairingLink)
        XCTAssertEqual(PairingOffer.parse("claude-deck://pair?v=1&host=1.2.3.4", source: .camera).failure, .malformed)
        XCTAssertEqual(PairingOffer.parse(pairingURL().replacingOccurrences(of: fingerprint, with: "zz"), source: .camera).failure, .malformed)
    }

    func testOpenedURLWaitsForConfirmation() {
        let model = AppModel(keychain: keychain, startMonitoring: false)
        XCTAssertNil(model.pairing)
        model.offerLink(pairingURL(), source: .openedURL)
        XCTAssertEqual(model.pendingOffer?.source, .openedURL, "確認画面に出すだけ")
        XCTAssertNil(model.pairing, "確認するまでペアリングしない")
        XCTAssertEqual(model.connection, .unpaired)
        XCTAssertNil(keychain.load())
    }

    func testBadLinkShowsReason() {
        let model = AppModel(keychain: keychain, startMonitoring: false)
        model.offerLink("claude-deck://pair?v=1", source: .openedURL)
        XCTAssertNil(model.pendingOffer)
        XCTAssertEqual(model.pairingError?.text, PairingLinkError.malformed.message)
    }

    func testExpiredAndNewerQRAreRefusedBeforeSending() async {
        let model = AppModel(keychain: keychain, startMonitoring: false)
        let expired = try! PairingOffer.parse(pairingURL(exp: 1), source: .camera).get()
        await model.confirmPairing(expired)
        XCTAssertEqual(model.pairingError?.text, "この QR は期限切れです。mac で新しい QR を出してください。")
        let newer = try! PairingOffer.parse(pairingURL(version: RemoteAPI.version + 1), source: .camera).get()
        await model.confirmPairing(newer)
        XCTAssertTrue(model.pairingError?.text.contains("iPhone アプリを更新") == true)
        XCTAssertNil(model.pairing)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

final class PairingKeychainTests: XCTestCase {
    func testSaveLoadReplaceDelete() throws {
        let keychain = PairingKeychain(service: "com.shinjosato.claude-deck.ios.tests.\(UUID().uuidString)")
        defer { keychain.delete() }
        XCTAssertNil(keychain.load())
        var pairing = RemotePairing(host: "192.168.1.5", port: 8767, localHostName: nil, fingerprint: fingerprint, serverName: "Mac",
                                    deviceId: "d1", deviceToken: "secret", pairedAt: 1)
        try keychain.save(pairing)
        XCTAssertEqual(keychain.load(), pairing)
        pairing.deviceToken = "secret2"
        try keychain.save(pairing)
        XCTAssertEqual(keychain.load()?.deviceToken, "secret2", "上書きできる")
        keychain.delete()
        XCTAssertNil(keychain.load())
    }
}

/// 会話の末尾に出すカードの優先順（mac と同じ）。
final class RoomCardTests: XCTestCase {
    private func room(kind: RemoteRoomKind = .hosted, status: SessionStatus = .waiting, permissions: [PendingPermission] = [],
                      prompt: RemoteTerminalPermission? = nil, menu: RemoteMenu? = nil,
                      unreadable: RemoteUnreadableMenu? = nil) -> RemoteRoom {
        RemoteRoom(id: "h:1", kind: kind, phase: .attention, name: "p", branch: nil, status: status, line: "", activityAt: nil,
                   sessionId: "s", cwd: "/", ended: nil, session: nil, permissions: permissions, terminalPermission: prompt, menu: menu,
                   unreadableMenu: unreadable, busy: false, send: RemoteSendState(mode: .input, disabledReason: nil))
    }

    private let permission = PendingPermission(key: "k", requestId: "r", sessionId: "s", project: "p", toolName: "Bash",
                                               description: "", inputPreview: "ls", askedAt: 0)
    private let prompt = RemoteTerminalPermission(promptId: "p1", title: "Bash command", lines: ["ls"])
    private let menu = RemoteMenu(menuId: "m1", context: [], question: "Proceed?", options: [], cursor: 0, footer: "", tabs: nil,
                                  isMultiSelect: false, isReview: false, cancelExits: false)

    func testChannelsWinOverTerminal() {
        XCTAssertEqual(RoomCard.cards(for: room(permissions: [permission], prompt: prompt, menu: menu)), [.channels([permission])])
        XCTAssertEqual(RoomCard.cards(for: room(prompt: prompt, menu: menu)), [.terminalPermission(prompt)])
        XCTAssertEqual(RoomCard.cards(for: room(menu: menu)), [.menu(menu)])
        let unreadable = RemoteUnreadableMenu(menuId: "u", lines: [], cancelExits: true)
        XCTAssertEqual(RoomCard.cards(for: room(unreadable: unreadable)), [.unreadableMenu(unreadable)])
        XCTAssertEqual(RoomCard.cards(for: room()), [])
    }

    func testExternalWithoutChannelsExplainsWhy() {
        XCTAssertEqual(RoomCard.cards(for: room(kind: .external, status: .permission)), [.channelsMissing(toolName: nil)])
        XCTAssertEqual(RoomCard.cards(for: room(kind: .hosted, status: .permission)), [], "ホスト中は端末のプロンプトが読めるまで待つ")
    }

    func testListGroupsKeepServerOrder() {
        func r(_ id: String, _ phase: RemoteRoomPhase) -> RemoteRoom {
            var x = room()
            x = RemoteRoom(id: id, kind: x.kind, phase: phase, name: id, branch: nil, status: .idle, line: "", activityAt: nil,
                           sessionId: nil, cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                           unreadableMenu: nil, busy: false, send: x.send)
            return x
        }
        let groups = RoomListScreen.groups([r("a", .attention), r("b", .active), r("c", .attention), r("d", .unknown)])
        XCTAssertEqual(groups.map(\.phase), [.attention, .active, .idle])
        XCTAssertEqual(groups[0].rooms.map(\.id), ["a", "c"])
        XCTAssertEqual(groups[2].rooms.map(\.id), ["d"], "知らない区分は待機へ")
    }
}

/// 共有パッケージの判定が iOS の上でも同じに動くか（Security・URL の組み立て・文言）。
final class SharedClientOnIOSTests: XCTestCase {
    private static let der = Data(base64Encoded: "MIIBizCCATGgAwIBAgIUVKlT6tsFpcpwJiwUUv2dSijYLBYwCgYIKoZIzj0EAwIwGzEZMBcGA1UEAwwQY2xhdWRlLWRlY2sgdGVzdDAeFw0yNjEwMDQxNDUxMjFaFw00NjA5MjkxNDUxMjFaMBsxGTAXBgNVBAMMEGNsYXVkZS1kZWNrIHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAS0Ly7JnNTwszCb4Ya5Njb6RelOHiu7NEPnl8xKLBc1pZrMHWJUGi4E/eWzQJdru5yANa2aHQbYarc0J8Uyr8wNo1MwUTAdBgNVHQ4EFgQUOn8ZFMyfdUPCEPIRh60aFNEE80QwHwYDVR0jBBgwFoAUOn8ZFMyfdUPCEPIRh60aFNEE80QwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAgG3ig74ofIWXM8+8CLbhvDIDl3eCY2N2H5TufLO5lXkCIFTcpNNnY/k2DtDXBzIFyEJAHjOM8J+lQQsjDSONXttT")!
    private static let pin = "fe23391bbc2e3fbe7d3deb5e88a700c840462100a98fc52bbd175ba524787fce"

    func testPinVerdictOnIOS() throws {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Self.der as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "192.168.1.5" as CFString), &trust)
        let serverTrust = try XCTUnwrap(trust)
        XCTAssertFalse(SecTrustEvaluateWithError(serverTrust, nil), "自己署名は CA の検証を通らない")
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                                           serverTrust: serverTrust, pin: Self.pin), .trusted)
        XCTAssertEqual(RemotePinnedSessionDelegate.verdict(authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                                           serverTrust: serverTrust, pin: fingerprint), .mismatch)
    }

    func testRequestsCarryBearerAndJSON() throws {
        let builder = RemoteRequestBuilder(host: "192.168.1.5", port: 8767, token: "tok")
        let req = try builder.menu(roomId: "h:1", RemoteMenuAnswerRequest(menuId: "m", cancel: true, confirmExit: true))
        XCTAssertEqual(req.url?.absoluteString, "https://192.168.1.5:8767/v1/rooms/h:1/menu")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode(RemoteMenuAnswerRequest.self, from: XCTUnwrap(req.httpBody))
        XCTAssertEqual(body, RemoteMenuAnswerRequest(menuId: "m", cancel: true, confirmExit: true))
    }

    func testResultCodesReadAsJapanese() {
        for code in ["answered", "gone", "changed", "busy", "timeout"] {
            let ok = code == "answered"
            let text = RemoteResultText.text(for: RemoteActionResult(ok: ok, code: code, message: nil), operation: .permission)
            XCTAssertNotNil(text, code)
            XCTAssertFalse(text!.contains(code), code)
        }
    }
}

/// 許可と Wi-Fi のどちらが原因かの言い分けと、その出し方。
@MainActor
final class OfflineDiagnosisTests: XCTestCase {
    func testWiFiNoteDoesNotContradictDiagnosis() {
        XCTAssertEqual(ConnectionBanner.wifiNote(for: .localNetworkDenied, onWiFi: false), "", "許可が無い時に Wi-Fi のせいにしない")
        XCTAssertEqual(ConnectionBanner.wifiNote(for: .offline, onWiFi: false), "", "題と重ねない")
        XCTAssertEqual(ConnectionBanner.wifiNote(for: .ambiguousOffline, onWiFi: true), "")
        XCTAssertEqual(ConnectionBanner.wifiNote(for: .ambiguousOffline, onWiFi: nil), "", "判定が届く前は言わない")
        XCTAssertTrue(ConnectionBanner.wifiNote(for: .ambiguousOffline, onWiFi: false).contains("Wi-Fi"))
    }

    func testPairingErrorKnowsWhenSettingsHelp() {
        let denied = AppModel.PairingError(issue: .localNetworkDenied)
        XCTAssertTrue(denied.needsSettings)
        XCTAssertTrue(denied.text.contains("ローカルネットワーク") && denied.text.contains("設定"))
        XCTAssertFalse(AppModel.PairingError(issue: .offline).needsSettings)
        XCTAssertFalse(AppModel.PairingError(issue: .ambiguousOffline).needsSettings)
        XCTAssertFalse(AppModel.PairingError("この QR は期限切れです。").needsSettings)
    }

    func testProbeDoesNotGuessWhenPathIsUsable() async {
        // 誰も待ち受けていないループバックは拒否されるだけで、経路の理由は無い。
        let reason = await PathProbe.check(host: "127.0.0.1", port: 1, timeout: 2)
        XCTAssertEqual(reason, .inconclusive)
        XCTAssertEqual(PathProbe.reason(nil), .inconclusive)
    }
}
