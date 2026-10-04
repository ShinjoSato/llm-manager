import CryptoKit
import XCTest
@testable import MonitorKit

/// iPhone 向けの口の部品（証明書・ペアリング・回数制限・照合・QR の中身）。
final class RemoteAccessUnitTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-unit-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - DER / 証明書

    func testDEREncodesKnownValues() {
        XCTAssertEqual(DER.oid([1, 2, 840, 10045, 2, 1]), Data([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]))
        XCTAssertEqual(DER.length(0x7f), Data([0x7f]))
        XCTAssertEqual(DER.length(0x80), Data([0x81, 0x80]))
        XCTAssertEqual(DER.length(0x1234), Data([0x82, 0x12, 0x34]))
        XCTAssertEqual(DER.integer(Data([0x80])), Data([0x02, 0x02, 0x00, 0x80]), "先頭ビットが立つ正の数は 0 を足す")
        XCTAssertEqual(DER.integer(2), Data([0x02, 0x01, 0x02]))
        let utc = DER.time(Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(utc.first, 0x17)
        XCTAssertEqual(String(data: utc.dropFirst(2), encoding: .ascii), "231114221320Z")
        let generalized = DER.time(Date(timeIntervalSince1970: 2_600_000_000))
        XCTAssertEqual(generalized.first, 0x18, "2050 年以降は GeneralizedTime")
    }

    func testSelfSignedCertificateParsesAndMatchesKey() throws {
        let key = P256.Signing.PrivateKey()
        let der = try SelfSignedCertificate.make(key: key, commonName: "claude-deck test")
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData), "Security が証明書として読める")
        XCTAssertEqual(SecCertificateCopySubjectSummary(cert) as String?, "claude-deck test")
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(cert))
        XCTAssertEqual(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?, key.publicKey.x963Representation)
        XCTAssertNotNil(TLSIdentityFiles.identity(keyX963: key.x963Representation, certificateDER: der))
        XCTAssertNil(TLSIdentityFiles.identity(keyX963: P256.Signing.PrivateKey().x963Representation, certificateDER: der),
                     "別の鍵とは組めない")
    }

    func testIdentityFilesArePrivateAndStable() throws {
        let files = TLSIdentityFiles(directory: dir)
        let first = try files.loadOrCreate()
        XCTAssertEqual(first.fingerprint.count, 64)
        let attrs = try FileManager.default.attributesOfItem(atPath: files.keyURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try files.loadOrCreate().fingerprint, first.fingerprint, "読み直しても同じ証明書")
        // 壊れていれば作り直す（指紋が変わる）。
        try Data("broken".utf8).write(to: files.keyURL)
        XCTAssertNotEqual(try files.loadOrCreate().fingerprint, first.fingerprint)
    }

    // MARK: - ペアリング

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t = t.addingTimeInterval(s) } }
    }

    func testPairingTicketIsSingleUseAndExpires() {
        let clock = Clock()
        let store = RemotePairingStore(directory: dir, now: { clock.now })
        XCTAssertEqual(store.pair(token: "nothing", deviceName: "x"), .rejected, "QR を出していなければ通らない")
        let ticket = store.startPairing(lifetime: 60)
        XCTAssertEqual(store.pair(token: ticket.token + "x", deviceName: "x"), .rejected)
        XCTAssertTrue(store.isPairingOpen, "外れでは消さない（回数制限は別）")
        guard case .paired(let device, let token) = store.pair(token: ticket.token, deviceName: "  my\u{7}iPhone\n ") else {
            return XCTFail("当たれば引き換えられる")
        }
        XCTAssertEqual(device.name, "myiPhone")
        XCTAssertEqual(token.count, 43, "256 bit の base64url")
        XCTAssertEqual(store.pair(token: ticket.token, deviceName: "y"), .rejected, "使い切り")
        XCTAssertFalse(store.isPairingOpen)

        let later = store.startPairing(lifetime: 60)
        clock.advance(61)
        XCTAssertEqual(store.pair(token: later.token, deviceName: "z"), .rejected, "期限切れ")
        XCTAssertEqual(store.devices().count, 1)
    }

    func testNewTicketInvalidatesPrevious() {
        let store = RemotePairingStore(directory: dir)
        let old = store.startPairing()
        _ = store.startPairing()
        XCTAssertEqual(store.pair(token: old.token, deviceName: "x"), .rejected)
    }

    func testDeviceTokenAuthenticatesUntilRevokedAndOnlyHashIsStored() throws {
        let clock = Clock()
        let store = RemotePairingStore(directory: dir, now: { clock.now })
        let ticket = store.startPairing()
        guard case .paired(let device, let token) = store.pair(token: ticket.token, deviceName: "phone") else { return XCTFail() }
        XCTAssertNil(store.devices().first?.lastUsedAt)
        clock.advance(5)
        XCTAssertEqual(store.authenticate(token: token)?.id, device.id)
        XCTAssertEqual(store.devices().first?.lastUsedAt, clock.now.timeIntervalSince1970 * 1000)
        XCTAssertNil(store.authenticate(token: token + "a"))
        XCTAssertNil(store.authenticate(token: ""))

        let saved = try String(contentsOf: dir.appendingPathComponent("devices.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains(token), "トークンそのものは書かない")
        XCTAssertTrue(saved.contains(RemotePairingStore.hash(token).hexString))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("devices.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let reloaded = RemotePairingStore(directory: dir)
        XCTAssertEqual(reloaded.authenticate(token: token)?.id, device.id, "再起動後も通る")
        XCTAssertTrue(reloaded.revoke(id: device.id))
        XCTAssertNil(reloaded.authenticate(token: token), "取り消した端末は通らない")
        XCTAssertNil(RemotePairingStore(directory: dir).authenticate(token: token), "取り消しも保存される")
    }

    func testDeviceLimit() {
        let store = RemotePairingStore(directory: dir)
        for i in 0..<RemotePairingStore.maxDevices {
            let ticket = store.startPairing()
            guard case .paired = store.pair(token: ticket.token, deviceName: "d\(i)") else { return XCTFail() }
        }
        let ticket = store.startPairing()
        XCTAssertEqual(store.pair(token: ticket.token, deviceName: "over"), .full)
    }

    func testThrottleBlocksAfterRepeatedFailures() {
        let clock = Clock()
        let throttle = RemoteAuthThrottle(window: 60, maxFailures: 3, now: { clock.now })
        throttle.recordFailure("10.0.0.2")
        throttle.recordFailure("10.0.0.2")
        XCTAssertFalse(throttle.isBlocked("10.0.0.2"))
        throttle.recordFailure("10.0.0.2")
        XCTAssertTrue(throttle.isBlocked("10.0.0.2"))
        XCTAssertFalse(throttle.isBlocked("10.0.0.3"), "接続元ごと")
        clock.advance(61)
        XCTAssertFalse(throttle.isBlocked("10.0.0.2"), "時間が経てば戻る")
        throttle.recordFailure("10.0.0.3")
        throttle.recordFailure("10.0.0.3")
        clock.advance(61)
        throttle.recordFailure("10.0.0.3")
        XCTAssertFalse(throttle.isBlocked("10.0.0.3"), "古い失敗は数えない")
    }

    // MARK: - QR の中身

    func testPairingPayloadRoundTripsThroughURL() {
        let payload = RemotePairingPayload(host: "192.168.1.5", port: 8767, token: "abc-_DEF", fingerprint: String(repeating: "ab", count: 32),
                                           name: "Shinjo の MacBook", expiresAt: 1_800_000_000_000, localHostName: "mac.local")
        XCTAssertEqual(payload.url.scheme, "claude-deck")
        XCTAssertEqual(RemotePairingPayload(url: payload.url), payload)
        var bad = URLComponents(url: payload.url, resolvingAgainstBaseURL: false)!
        bad.queryItems = bad.queryItems!.map { $0.name == "fp" ? URLQueryItem(name: "fp", value: "zz") : $0 }
        XCTAssertNil(RemotePairingPayload(url: bad.url!), "指紋の形が違えば読まない")
        XCTAssertNil(RemotePairingPayload(url: URL(string: "https://example.com/pair")!))
        XCTAssertEqual(RemotePinning.display("abcd"), "AB:CD")
        XCTAssertEqual(RemotePinning.normalize("AB:CD"), "abcd")
    }

    func testRoomIdParsing() {
        let uuid = UUID()
        XCTAssertEqual(RemoteRoomID("h:\(uuid.uuidString)"), .hosted(uuid))
        XCTAssertEqual(RemoteRoomID("e:11111111-2222-3333-4444-555555555555"), .external("11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(RemoteRoomID.hosted(uuid).string, "h:\(uuid.uuidString)")
        XCTAssertNil(RemoteRoomID("e:../../etc"))
        XCTAssertNil(RemoteRoomID("x:1"))
    }

    // MARK: - 照合（画面のカードと同じ条件）

    private func menu(cursor: Int = 0, checked: Bool? = nil, footer: String = "Enter to confirm · Esc to cancel") -> MenuPrompt {
        MenuPrompt(context: ["plan"], question: "Proceed?",
                   options: [.init(number: 1, label: "Yes", checked: checked), .init(number: 2, label: "No"),
                             .init(number: 3, label: "Type something.")],
                   cursor: cursor, footer: footer)
    }

    func testMenuIdIgnoresCursorButNotContent() {
        XCTAssertEqual(RemoteMenu.menuId(menu(cursor: 0)), RemoteMenu.menuId(menu(cursor: 1)))
        XCTAssertNotEqual(RemoteMenu.menuId(menu(checked: false)), RemoteMenu.menuId(menu(checked: true)), "チェックが替われば別物")
        let remote = RemoteMenu(menu(cursor: 1))
        XCTAssertEqual(remote.cursor, 1)
        XCTAssertEqual(remote.options.map(\.selectable), [true, true, false], "文字入力の選択肢は押せない")
        XCTAssertEqual(remote.options.map(\.index), [0, 1, 2])
    }

    func testMenuAnswerChecks() {
        let current = menu()
        let id = RemoteMenu.menuId(current)
        func code(_ r: Result<(MenuPrompt, RemoteChecks.MenuAction), RemoteActionResult>) -> String {
            switch r {
            case .success: return "ok"
            case .failure(let f): return f.code
            }
        }
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 1), current: current)), "ok")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 1), current: nil)), "gone")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: "other", choice: 1), current: current)), "changed")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 2), current: current)), "unavailable")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 9), current: current)), "invalid")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id), current: current)), "invalid", "choice も cancel も無い")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 0, cancel: true), current: current)), "invalid")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, cancel: true), current: current)), "ok")
        let exiting = menu(footer: "Enter to confirm · Esc to exit")
        let exitId = RemoteMenu.menuId(exiting)
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: exitId, cancel: true), current: exiting)), "confirm_required",
                       "claude の終了になる取り消しは明示が要る")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: exitId, cancel: true, confirmExit: true), current: exiting)), "ok")
    }

    func testTerminalPermissionAndDismissChecks() {
        let prompt = PermissionPrompt(title: "Bash command", lines: ["ls"])
        let id = RemoteTerminalPermission(prompt).promptId
        if case .failure = RemoteChecks.terminalPermission(promptId: id, current: prompt) { XCTFail() }
        if case .failure(let f) = RemoteChecks.terminalPermission(promptId: id, current: PermissionPrompt(title: "Bash command", lines: ["rm -rf x"])) {
            XCTAssertEqual(f.code, "changed")
        } else { XCTFail("別のプロンプトには答えない") }
        if case .failure(let f) = RemoteChecks.terminalPermission(promptId: id, current: nil) { XCTAssertEqual(f.code, "gone") } else { XCTFail() }

        let unreadable = UnreadableMenu(lines: ["?"], cancelExits: true)
        let menuId = RemoteUnreadableMenu(unreadable).menuId
        if case .failure(let f) = RemoteChecks.menuDismiss(.init(menuId: menuId), current: unreadable) {
            XCTAssertEqual(f.code, "confirm_required")
        } else { XCTFail() }
        if case .failure = RemoteChecks.menuDismiss(.init(menuId: menuId, confirmExit: true), current: unreadable) { XCTFail() }
    }

    func testMessageChecks() {
        if case .failure(let f) = RemoteChecks.message("  \n") { XCTAssertEqual(f.code, "invalid") } else { XCTFail() }
        if case .failure = RemoteChecks.message(String(repeating: "a", count: RemoteChecks.maxMessageBytes + 1)) {} else { XCTFail() }
        if case .failure = RemoteChecks.message("hello") { XCTFail() }
    }

    func testStatusMapping() {
        XCTAssertEqual(RemoteRoutes.status(of: .success("sent")), 200)
        XCTAssertEqual(RemoteRoutes.status(of: .failure("not_found", "")), 404)
        XCTAssertEqual(RemoteRoutes.status(of: .failure("invalid", "")), 400)
        XCTAssertEqual(RemoteRoutes.status(of: .failure("changed", "")), 409)
        XCTAssertEqual(RemoteRoutes.status(of: .failure("app_unavailable", "")), 503)
    }

    func testLANInterfaceChoicePrefersEthernetAndWiFi() {
        let list = LANInterfaces.sort([LANInterface(name: "bridge100", address: "192.168.2.1"), LANInterface(name: "en1", address: "10.0.0.3"),
                                       LANInterface(name: "en0", address: "192.168.1.5")])
        XCTAssertEqual(list.map(\.name), ["en0", "en1", "bridge100"])
        XCTAssertEqual(LANInterfaces.choose(nil, from: list)?.name, "en0")
        XCTAssertEqual(LANInterfaces.choose("en1", from: list)?.address, "10.0.0.3")
        XCTAssertNil(LANInterfaces.choose("en9", from: list), "選んだ口が無ければ勝手に別の口で開かない")
        XCTAssertFalse(LANInterfaces.current().contains { $0.name.hasPrefix("lo") }, "ループバックは候補に出さない")
    }
}
