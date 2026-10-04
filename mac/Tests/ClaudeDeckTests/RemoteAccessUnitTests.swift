import CryptoKit
import Network
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
        XCTAssertTrue(try reloaded.revoke(id: device.id))
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

    private func context(_ card: RemoteTerminalCard?, tracker: RemotePromptTracker = RemotePromptTracker(),
                         channels: Bool = false) -> RemoteTerminalContext {
        RemoteTerminalContext(card: card, tracker: tracker, channelsPending: channels)
    }

    private func code<T>(_ r: Result<T, RemoteActionResult>) -> String {
        switch r {
        case .success: return "ok"
        case .failure(let f): return f.code
        }
    }

    func testMenuIdIgnoresCursorButNotContent() {
        XCTAssertEqual(RemoteMenu.menuId(menu(cursor: 0), generation: 0), RemoteMenu.menuId(menu(cursor: 1), generation: 0))
        XCTAssertNotEqual(RemoteMenu.menuId(menu(checked: false), generation: 0), RemoteMenu.menuId(menu(checked: true), generation: 0),
                          "チェックが替われば別物")
        XCTAssertNotEqual(RemoteMenu.menuId(menu(), generation: 0), RemoteMenu.menuId(menu(), generation: 1), "出し直されたら別物")
        let remote = RemoteMenu(menu(cursor: 1), generation: 0)
        XCTAssertEqual(remote.cursor, 1)
        XCTAssertEqual(remote.options.map(\.selectable), [true, true, false], "文字入力の選択肢は押せない")
        XCTAssertEqual(remote.options.map(\.index), [0, 1, 2])
    }

    func testMenuAnswerChecks() {
        let current = menu()
        let id = RemoteMenu.menuId(current, generation: 0)
        let ctx = context(.menu(current))
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 1), in: ctx)), "ok")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 1), in: context(nil))), "gone")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 1),
                                                    in: context(.permission(PermissionPrompt(title: "Bash", lines: ["ls"]))))), "gone",
                       "権限プロンプトが出ている間は選択肢に答えない")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: "other", choice: 1), in: ctx)), "changed")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 2), in: ctx)), "unavailable")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 9), in: ctx)), "invalid")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id), in: ctx)), "invalid", "choice も cancel も無い")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, choice: 0, cancel: true), in: ctx)), "invalid")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: id, cancel: true), in: ctx)), "ok")
        let exiting = menu(footer: "Enter to confirm · Esc to exit")
        let exitId = RemoteMenu.menuId(exiting, generation: 0)
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: exitId, cancel: true), in: context(.menu(exiting)))), "confirm_required",
                       "claude の終了になる取り消しは明示が要る")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: exitId, cancel: true, confirmExit: true), in: context(.menu(exiting)))), "ok")
        XCTAssertEqual(code(RemoteChecks.menuTab(.init(menuId: id, direction: .next), in: ctx)), "ok")
        XCTAssertEqual(code(RemoteChecks.menuTab(.init(menuId: id, direction: .next), in: context(nil))), "gone")
    }

    func testTerminalPermissionAndDismissChecks() {
        let prompt = PermissionPrompt(title: "Bash command", lines: ["ls"])
        let id = RemoteTerminalPermission(prompt, generation: 0).promptId
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: id, in: context(.permission(prompt)))), "ok")
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: id, in: context(.permission(PermissionPrompt(title: "Bash command",
                                                                                                                   lines: ["rm -rf x"]))))),
                       "changed", "別のプロンプトには答えない")
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: id, in: context(nil))), "gone")

        let unreadable = UnreadableMenu(lines: ["?"], cancelExits: true)
        let menuId = RemoteUnreadableMenu(unreadable, generation: 0).menuId
        XCTAssertEqual(code(RemoteChecks.menuDismiss(.init(menuId: menuId), in: context(.unreadable(unreadable)))), "confirm_required")
        XCTAssertEqual(code(RemoteChecks.menuDismiss(.init(menuId: menuId, confirmExit: true), in: context(.unreadable(unreadable)))), "ok")
        XCTAssertEqual(code(RemoteChecks.menuDismiss(.init(menuId: menuId, confirmExit: true), in: context(.menu(menu())))), "gone")
    }

    /// 同じ文面の確認が続いた時、前の表示の ID で次の確認に答えない。
    func testSamePromptShownAgainGetsNewIdAndOldIdIsRejected() {
        let prompt = PermissionPrompt(title: "Bash command", lines: ["rm -rf build"])
        var tracker = RemotePromptTracker()
        tracker.observe(.permission(prompt))
        let firstId = RemoteTerminalPermission(prompt, generation: tracker.generation).promptId
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: firstId, in: context(.permission(prompt), tracker: tracker))), "ok")

        // 答えて消え、同じ文面で次の確認が出た。
        tracker.observe(nil)
        tracker.observe(.permission(prompt))
        let secondId = RemoteTerminalPermission(prompt, generation: tracker.generation).promptId
        XCTAssertNotEqual(firstId, secondId, "出し直された確認は別の ID")
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: firstId, in: context(.permission(prompt), tracker: tracker))), "changed",
                       "古い表示の ID では次の確認に送らない")
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: secondId, in: context(.permission(prompt), tracker: tracker))), "ok")

        // 権限プロンプトから同じ文面の選択肢へ替わっても進む。メニューの ❯ が動いただけでは進まない。
        let before = tracker.generation
        tracker.observe(.menu(menu(cursor: 0)))
        let menuGeneration = tracker.generation
        XCTAssertGreaterThan(menuGeneration, before)
        tracker.observe(.menu(menu(cursor: 1)))
        XCTAssertEqual(tracker.generation, menuGeneration, "❯ の移動では ID は変わらない")
        tracker.observe(.unreadable(UnreadableMenu(lines: ["?"], cancelExits: false)))
        tracker.observe(.menu(menu(cursor: 0)))
        let oldMenuId = RemoteMenu.menuId(menu(), generation: menuGeneration)
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: oldMenuId, choice: 0), in: context(.menu(menu()), tracker: tracker))), "changed",
                       "読めない表示を挟んで出し直された選択肢には古い ID で答えない")
    }

    /// 答えた ID の押し直しは送らず、成功扱いの `answered` を返す。
    func testRepeatedAnswerIsAnsweredWithoutSending() {
        let prompt = PermissionPrompt(title: "Bash command", lines: ["ls"])
        var tracker = RemotePromptTracker()
        tracker.observe(.permission(prompt))
        let id = RemoteTerminalPermission(prompt, generation: tracker.generation).promptId
        tracker.markAnswered(id)
        guard case .failure(let shown) = RemoteChecks.terminalPermission(promptId: id, in: context(.permission(prompt), tracker: tracker)) else {
            return XCTFail("表示が残っていても 2 回目は送らない")
        }
        XCTAssertEqual(shown, RemoteChecks.answered)
        XCTAssertTrue(shown.ok, "押し直しは成功扱い")
        tracker.observe(nil)
        if case .failure(let gone) = RemoteChecks.terminalPermission(promptId: id, in: context(nil, tracker: tracker)) {
            XCTAssertEqual(gone.code, "answered", "消えた後の押し直しも answered")
        } else { XCTFail() }

        let current = menu()
        tracker.observe(.menu(current))
        let menuId = RemoteMenu.menuId(current, generation: tracker.generation)
        tracker.markAnswered(menuId)
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: menuId, choice: 1), in: context(.menu(current), tracker: tracker))), "answered")
        XCTAssertEqual(code(RemoteChecks.menuTab(.init(menuId: menuId, direction: .next), in: context(.menu(current), tracker: tracker))), "answered")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: menuId), in: context(.menu(current), tracker: tracker))), "invalid",
                       "形の不正は先に返す")
    }

    /// Channels の確認が出ている間は、端末の権限・選択肢・読めない選択肢のどれも iPhone から扱わない。
    func testChannelsPendingBlocksTerminalOperations() {
        let prompt = PermissionPrompt(title: "Bash", lines: ["ls"])
        let current = menu()
        let unreadable = UnreadableMenu(lines: ["?"], cancelExits: false)
        XCTAssertEqual(code(RemoteChecks.terminalPermission(promptId: RemoteTerminalPermission.promptId(prompt, generation: 0),
                                                            in: context(.permission(prompt), channels: true))), "changed")
        XCTAssertEqual(code(RemoteChecks.menuAnswer(.init(menuId: RemoteMenu.menuId(current, generation: 0), choice: 0),
                                                    in: context(.menu(current), channels: true))), "changed")
        XCTAssertEqual(code(RemoteChecks.menuTab(.init(menuId: RemoteMenu.menuId(current, generation: 0), direction: .previous),
                                                 in: context(.menu(current), channels: true))), "changed")
        XCTAssertEqual(code(RemoteChecks.menuDismiss(.init(menuId: RemoteUnreadableMenu.menuId(unreadable, generation: 0)),
                                                     in: context(.unreadable(unreadable), channels: true))), "changed")
    }

    /// 一覧のカードは会話末尾と同じ優先順（Channels → 端末の権限 → 選択肢 → 読めない選択肢）。
    func testRoomCardsFollowTheConversationOrder() {
        let prompt = PermissionPrompt(title: "Bash", lines: ["ls"])
        let current = menu()
        let unreadable = UnreadableMenu(lines: ["?"], cancelExits: false)
        XCTAssertEqual(RemoteTerminalCard.current(permissionPrompt: prompt, inputBlock: .menu, menuPrompt: current, unreadableMenu: nil),
                       .permission(prompt))
        XCTAssertEqual(RemoteTerminalCard.current(permissionPrompt: nil, inputBlock: .menu, menuPrompt: current, unreadableMenu: unreadable),
                       .menu(current))
        XCTAssertEqual(RemoteTerminalCard.current(permissionPrompt: nil, inputBlock: .menu, menuPrompt: nil, unreadableMenu: unreadable),
                       .unreadable(unreadable))
        XCTAssertEqual(RemoteTerminalCard.current(permissionPrompt: nil, inputBlock: .menu, menuPrompt: nil, unreadableMenu: nil), .pendingMenu)
        XCTAssertNil(RemoteTerminalCard.current(permissionPrompt: nil, inputBlock: nil, menuPrompt: current, unreadableMenu: nil),
                     "選択待ちでなければ古いメニューは出さない")

        let channels = RemoteRoomCards(channelsPending: true, card: .permission(prompt), generation: 0)
        XCTAssertNil(channels.terminalPermission, "Channels があれば端末のカードは出さない")
        let terminal = RemoteRoomCards(channelsPending: false, card: .permission(prompt), generation: 3)
        XCTAssertEqual(terminal.terminalPermission?.promptId, RemoteTerminalPermission.promptId(prompt, generation: 3))
        XCTAssertNil(terminal.menu)
        let menuCards = RemoteRoomCards(channelsPending: false, card: .menu(current), generation: 1)
        XCTAssertEqual(menuCards.menu?.menuId, RemoteMenu.menuId(current, generation: 1))
        XCTAssertEqual(RemoteRoomCards(channelsPending: false, card: .unreadable(unreadable), generation: 0).unreadableMenu?.lines, ["?"])
        XCTAssertEqual(RemoteRoomCards(channelsPending: false, card: .pendingMenu, generation: 0),
                       RemoteRoomCards(channelsPending: false, card: nil, generation: 0))
    }

    func testSendBlockedCode() {
        XCTAssertEqual(RemoteChecks.sendBlockedCode(ended: true, inputBlock: .menu), "ended")
        XCTAssertEqual(RemoteChecks.sendBlockedCode(ended: false, inputBlock: .permission), "blocked_permission")
        XCTAssertEqual(RemoteChecks.sendBlockedCode(ended: false, inputBlock: .menu), "blocked_menu")
        XCTAssertEqual(RemoteChecks.sendBlockedCode(ended: false, inputBlock: nil), "unavailable")
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

    func testLANInterfaceCandidatesExcludeVirtualAndPointToPoint() {
        let up = Int32(IFF_UP | IFF_RUNNING)
        XCTAssertTrue(LANInterfaces.isCandidate(name: "en0", flags: up, address: "192.168.1.5"))
        XCTAssertFalse(LANInterfaces.isCandidate(name: "en5", flags: up | Int32(IFF_POINTOPOINT), address: "10.8.0.2"), "ポイントツーポイント（VPN）は除く")
        for name in ["bridge100", "vmnet8", "vmenet0", "vnic0", "tun0", "tap0", "feth0", "utun3", "awdl0", "llw0", "anpi0", "lo0"] {
            XCTAssertFalse(LANInterfaces.isCandidate(name: name, flags: up, address: "192.168.64.1"), name)
        }
        XCTAssertFalse(LANInterfaces.isCandidate(name: "en0", flags: up, address: "169.254.3.4"), "リンクローカルは除く")
        XCTAssertFalse(LANInterfaces.isCandidate(name: "en0", flags: Int32(IFF_UP), address: "192.168.1.5"), "動いていない口は除く")
    }

    @MainActor
    func testStartRefusesWildcardMulticastAndBroadcast() {
        for address in ["0.0.0.0", "224.0.0.251", "239.255.255.250", "255.255.255.255", "240.0.0.1", "not-an-ip"] {
            XCTAssertFalse(RemoteAccessService.isUsableBindAddress(address), address)
        }
        XCTAssertTrue(RemoteAccessService.isUsableBindAddress("192.168.1.5"))
        XCTAssertTrue(RemoteAccessService.isUsableBindAddress("127.0.0.1"))
        let service = RemoteAccessService(directory: dir, transcripts: FakeTranscriptSource(), control: nil, serverName: "t")
        service.start(address: "0.0.0.0", port: 0)
        guard case .failed = service.state else { return XCTFail("全インターフェースには開かない: \(service.state)") }
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.fingerprint, "証明書を作る前に弾く")
    }

    // MARK: - ネットワークの見張り

    func testNetworkCIDR() {
        XCTAssertEqual(LANNetwork.cidr(address: "192.168.1.37", netmask: "255.255.255.0"), "192.168.1.0/24")
        XCTAssertEqual(LANNetwork.cidr(address: "10.1.2.3", netmask: "255.255.240.0"), "10.1.0.0/20")
        XCTAssertNil(LANNetwork.cidr(address: "10.1.2.3", netmask: "255.0.255.0"), "連続しないマスクは扱わない")
        XCTAssertNil(LANNetwork.cidr(address: "x", netmask: "255.255.255.0"))
        XCTAssertEqual(LANInterface(name: "en0", address: "172.16.5.9", netmask: "255.255.0.0").network, "172.16.0.0/16")
    }

    func testNetworkDecision() {
        let home = LANNetwork(cidr: "192.168.1.0/24", routerMAC: "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(LANNetwork.decide(saved: nil, current: home), .remember(home), "初めて有効にした時のネットワークを覚える")
        XCTAssertEqual(LANNetwork.decide(saved: home, current: home), .open)
        XCTAssertEqual(LANNetwork.decide(saved: home, current: LANNetwork(cidr: "10.0.0.0/24", routerMAC: nil)), .refuse,
                       "別のアドレス帯では開かない")
        XCTAssertEqual(LANNetwork.decide(saved: home, current: LANNetwork(cidr: "192.168.1.0/24", routerMAC: "11:22:33:44:55:66")), .refuse,
                       "同じアドレス帯でもルーターが違えば別の場所")
        XCTAssertEqual(LANNetwork.decide(saved: home, current: LANNetwork(cidr: "192.168.1.0/24", routerMAC: nil)), .open,
                       "ルーターの MAC が取れない時はアドレス帯で決める")
        let noMAC = LANNetwork(cidr: "192.168.1.0/24", routerMAC: nil)
        XCTAssertEqual(LANNetwork.decide(saved: noMAC, current: home), .remember(home), "取れた MAC は覚え直す")
        XCTAssertEqual(LANNetwork.decide(saved: home, current: nil), .refuse, "今のネットワークが分からなければ開かない")
        XCTAssertEqual(LANNetwork.decide(saved: nil, current: nil), .open)
    }

    // MARK: - ファイル

    func testSecureFileTightensDirectoryAndCreatesPrivateFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let url = dir.appendingPathComponent("secret.bin")
        try SecureFile.write(Data("one".utf8), to: url)
        func mode(_ path: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(try mode(dir.path), 0o700, "既にあった広いディレクトリも締め直す")
        XCTAssertEqual(try mode(url.path), 0o600)
        chmod(dir.path, 0o755)
        try SecureFile.write(Data("two".utf8), to: url)
        XCTAssertEqual(try mode(dir.path), 0o700, "書くたびに締め直す")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "一時ファイルを残さない")
    }

    /// 取り消しを書き出せなくても、メモリ上は取り消したままエラーを返し、書けるようになったら書き直す。
    func testRevokeReportsPersistFailureAndRetries() throws {
        let store = RemotePairingStore(directory: dir)
        let ticket = store.startPairing()
        guard case .paired(let device, let token) = store.pair(token: ticket.token, deviceName: "phone") else { return XCTFail() }
        let file = dir.appendingPathComponent("devices.json")
        // 置き換え先をディレクトリにして書けなくする。
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.appendingPathComponent("block"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.revoke(id: device.id))
        XCTAssertNil(store.authenticate(token: token), "メモリ上は取り消し済み")
        XCTAssertNotNil(store.persistFailure)
        XCTAssertFalse(store.retryPersist(), "書けないうちは失敗のまま")

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.retryPersist())
        XCTAssertNil(store.persistFailure)
        XCTAssertNil(RemotePairingStore(directory: dir).authenticate(token: token), "書き直した取り消しは再起動後も効く")
    }

    @MainActor
    func testServiceShowsPersistFailureAndRetries() async throws {
        let service = RemoteAccessService(directory: dir, transcripts: FakeTranscriptSource(), control: nil, serverName: "t")
        service.persistRetryInterval = .milliseconds(20)
        let ticket = service.pairing.startPairing()
        guard case .paired(let device, _) = service.pairing.pair(token: ticket.token, deviceName: "phone") else { return XCTFail() }
        let file = dir.appendingPathComponent("devices.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file.appendingPathComponent("block"), withIntermediateDirectories: true)
        XCTAssertNotNil(service.revoke(device.id), "書き出しの失敗を画面に返す")
        XCTAssertNotNil(service.storageProblem)
        XCTAssertEqual(service.devices, [], "一覧からは消える")
        try FileManager.default.removeItem(at: file)
        for _ in 0..<200 where service.storageProblem != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(service.storageProblem, "書けるようになったら書き直して消える")
        XCTAssertEqual(RemotePairingStore(directory: dir).devices(), [])
    }

    // MARK: - TLS の設定

    func testTLSParametersNeverFallBackToPlaintext() throws {
        let loaded = try TLSIdentityFiles(directory: dir).loadOrCreate()
        XCTAssertNil(HTTPServer.parameters(tls: loaded.serverIdentity, makeIdentity: { _ in nil }),
                     "TLS を組めなければ平文の設定を返さない")
        let tls = try XCTUnwrap(HTTPServer.parameters(tls: loaded.serverIdentity, keepalive: true))
        XCTAssertTrue(tls.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
        let tcp = try XCTUnwrap(tls.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        XCTAssertTrue(tcp.enableKeepalive, "黙って消えた相手を見つける")
        let plain = try XCTUnwrap(HTTPServer.parameters(tls: nil))
        XCTAssertFalse(plain.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
        XCTAssertFalse((plain.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.enableKeepalive ?? true,
                       "8766 の口の既定は変えない")
    }

    // MARK: - 結果コード

    func testChannelDecisionFailuresAreDistinguished() {
        XCTAssertEqual(MonitorStore.remoteDecideFailure(HubFailure(code: "not_found", message: "x")).code, "gone")
        XCTAssertEqual(MonitorStore.remoteDecideFailure(HubFailure(code: "unavailable", message: "x")).code, "failed",
                       "届けられなかったものは「もう待っていない」とまとめない")
        XCTAssertEqual(MonitorStore.remoteDecideFailure(URLError(.timedOut)).code, "failed")
        XCTAssertEqual(RemoteRoutes.status(of: .failure("failed", "")), 502)
        XCTAssertEqual(RemoteRoutes.status(of: .failure("timeout", "")), 409)
        XCTAssertEqual(RemoteRoutes.status(of: RemoteChecks.answered), 200, "押し直しは成功扱い")
    }

    @MainActor
    func testOperationWaitTimesOutAndIgnoresLateCompletion() async {
        var late: ((RemoteActionResult) -> Void)?
        let timedOut = await RemoteOperation.wait(timeout: .milliseconds(30)) { done in late = done }
        XCTAssertEqual(timedOut, RemoteOperation.timedOut)
        late?(.success("confirmed"))  // 上限の後の完了は捨てる（二重に戻さない）

        let immediate = await RemoteOperation.wait(timeout: .seconds(5)) { done in done(.failure("busy", "b")) }
        XCTAssertEqual(immediate.code, "busy")
        let later = await RemoteOperation.wait(timeout: .seconds(5)) { done in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(20))
                done(.success("confirmed"))
                done(.success("again"))
            }
        }
        XCTAssertEqual(later.code, "confirmed")
    }
}
