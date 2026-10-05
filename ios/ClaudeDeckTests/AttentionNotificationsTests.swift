import CloudKit
import DeckCore
import XCTest
@testable import ClaudeDeck

private final class FakeSubscriptionService: AttentionSubscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var problem: String?
    var subscribeError: Error?
    var unsubscribeError: Error?

    var calls: [String] { lock.withLock { _calls } }
    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func accountProblem() async -> String? {
        record("account")
        return problem
    }

    func subscribe() async throws {
        record("subscribe")
        if let subscribeError { throw subscribeError }
    }

    func unsubscribe() async throws {
        record("unsubscribe")
        if let unsubscribeError { throw unsubscribeError }
    }
}

private struct FakeAuthorizer: NotificationAuthorizing {
    var granted = true
    var denied = false
    func requestAuthorization() async throws -> Bool { granted }
    func isDenied() async -> Bool { denied }
}

@MainActor
final class AttentionNotificationsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var pushRegistrations = 0

    override func setUp() {
        suite = "claude-deck.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        pushRegistrations = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ service: FakeSubscriptionService, authorizer: FakeAuthorizer = FakeAuthorizer()) -> AttentionNotifications {
        AttentionNotifications(service: service, authorizer: authorizer, defaults: defaults) { [weak self] in
            self?.pushRegistrations += 1
        }
    }

    func testStartsOffAndDoesNothingOnRefresh() async {
        let service = FakeSubscriptionService()
        let notifications = make(service)
        XCTAssertFalse(notifications.enabled)
        XCTAssertEqual(notifications.state, .off)
        await notifications.refresh()
        XCTAssertEqual(service.calls, [])
        XCTAssertEqual(pushRegistrations, 0)
    }

    func testTurningOnSubscribesAndRemembers() async {
        let service = FakeSubscriptionService()
        let notifications = make(service)
        await notifications.setEnabled(true)
        XCTAssertEqual(notifications.state, .on)
        XCTAssertEqual(service.calls, ["account", "subscribe"])
        XCTAssertEqual(pushRegistrations, 1)
        XCTAssertTrue(defaults.bool(forKey: AttentionNotifications.enabledKey))
        // 次の起動では入ったまま始まり、前に出た時に購読を作り直す。
        let next = make(service)
        XCTAssertTrue(next.enabled)
        await next.refresh()
        XCTAssertEqual(next.state, .on)
    }

    func testDeniedPermissionLeadsToSettings() async {
        let service = FakeSubscriptionService()
        let notifications = make(service, authorizer: FakeAuthorizer(granted: false))
        await notifications.setEnabled(true)
        guard case .problem(_, let needsSettings) = notifications.state else { return XCTFail("\(notifications.state)") }
        XCTAssertTrue(needsSettings)
        XCTAssertEqual(service.calls, [])
    }

    func testICloudAccountProblemIsShown() async {
        let service = FakeSubscriptionService()
        service.problem = "サインインしていません"
        let notifications = make(service)
        await notifications.setEnabled(true)
        XCTAssertEqual(notifications.state, .problem("サインインしていません", needsSettings: false))
        XCTAssertEqual(service.calls, ["account"])
    }

    func testSubscribeFailureIsShown() async {
        let service = FakeSubscriptionService()
        service.subscribeError = CKError(.serverRejectedRequest)
        let notifications = make(service)
        await notifications.setEnabled(true)
        guard case .problem(let text, false) = notifications.state else { return XCTFail("\(notifications.state)") }
        XCTAssertTrue(text.contains("購読を作れません"), text)
        XCTAssertTrue(notifications.enabled)
    }

    func testTurningOffRemovesTheSubscription() async {
        let service = FakeSubscriptionService()
        let notifications = make(service)
        await notifications.setEnabled(true)
        await notifications.setEnabled(false)
        XCTAssertEqual(notifications.state, .off)
        XCTAssertEqual(service.calls.last, "unsubscribe")
        XCTAssertFalse(defaults.bool(forKey: AttentionNotifications.enabledKey))
    }

    func testTurningOffFailureSaysNoticesMayContinue() async {
        let service = FakeSubscriptionService()
        service.unsubscribeError = CKError(.networkUnavailable)
        let notifications = make(service)
        await notifications.setEnabled(false)
        guard case .problem(let text, _) = notifications.state else { return XCTFail("\(notifications.state)") }
        XCTAssertTrue(text.contains("もう一度切って"), text)
    }

    func testSubscriptionFiresOnCreationWithRecordText() {
        let subscription = CloudKitAttentionSubscription.makeSubscription()
        XCTAssertEqual(subscription.subscriptionID, AttentionNoticeSchema.subscriptionID)
        XCTAssertEqual(subscription.recordType, AttentionNoticeSchema.recordType)
        XCTAssertEqual(subscription.querySubscriptionOptions, [.firesOnRecordCreation])
        let info = try? XCTUnwrap(subscription.notificationInfo)
        XCTAssertEqual(info?.titleLocalizationKey, "ATTENTION_TITLE")
        XCTAssertEqual(info?.titleLocalizationArgs, ["title"])
        XCTAssertEqual(info?.alertLocalizationKey, "ATTENTION_BODY")
        XCTAssertEqual(info?.alertLocalizationArgs, ["body"])
        XCTAssertEqual(info?.desiredKeys, ["roomId", "sessionId", "macName"])
        XCTAssertEqual(info?.collapseIDKey, "roomId")
        XCTAssertEqual(info?.shouldSendContentAvailable, false)
    }

    /// 通知の見出し・本文のキーがアプリに入っていて、値をそのまま出すこと。
    func testLocalizationKeysPassTheTextThrough() {
        let title = Bundle.main.localizedString(forKey: AttentionNoticeSchema.titleLocalizationKey, value: "missing", table: nil)
        let body = Bundle.main.localizedString(forKey: AttentionNoticeSchema.bodyLocalizationKey, value: "missing", table: nil)
        XCTAssertEqual(title, "%@")
        XCTAssertEqual(body, "%@")
    }

    func testRouteFromRawCloudKitPayload() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title-loc-key": "ATTENTION_TITLE", "title-loc-args": ["mirio"]]],
            "ck": ["ce": 2, "cid": AttentionNoticeSchema.containerIdentifier, "nid": UUID().uuidString,
                   "qry": ["af": ["roomId": "e:s1", "sessionId": "s1", "macName": "Mac"], "dbs": 1, "fo": 1,
                           "rid": "attn-e_s1-1", "sid": AttentionNoticeSchema.subscriptionID, "zid": "_defaultZone", "zoid": "_defaultOwner"]]
        ]
        XCTAssertEqual(DeckAppDelegate.route(from: userInfo)?.roomId, "e:s1")
        XCTAssertEqual(DeckAppDelegate.route(from: userInfo)?.sessionId, "s1")
        XCTAssertNil(DeckAppDelegate.route(from: ["aps": ["alert": "x"]]))
    }
}

@MainActor
final class AppModelNoticeTests: XCTestCase {
    private func notifications() -> AttentionNotifications {
        AttentionNotifications(service: FakeSubscriptionService(), authorizer: FakeAuthorizer(),
                               defaults: UserDefaults(suiteName: "claude-deck.tests.\(UUID().uuidString)")!) {}
    }

    func testUnpairedKeepsTheNoticeAndExplains() {
        let keychain = PairingKeychain(service: "com.shinjosato.claude-deck.ios.tests.\(UUID().uuidString)")
        let model = AppModel(keychain: keychain, startMonitoring: false, notifications: notifications())
        model.openFromNotice(AttentionNoticeRoute(roomId: "h:1", sessionId: "s1", macName: "Mac"))
        XCTAssertNil(model.requestedRoomId)
        XCTAssertEqual(model.pendingNotice?.roomId, "h:1")
        XCTAssertTrue(model.noticeHint?.contains("ペアリング") == true)
    }

    #if DEBUG
    private func room(_ id: String, session: String?) -> RemoteRoom {
        RemoteRoom(id: id, kind: .hosted, phase: .attention, name: id, branch: nil, status: .permission, line: "", activityAt: nil,
                   sessionId: session, cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                   unreadableMenu: nil, busy: false, send: RemoteSendState(mode: .input, disabledReason: nil))
    }

    private func connectedModel(_ rooms: [RemoteRoom], open: String? = nil) -> AppModel {
        let pairing = RemotePairing(host: "192.168.1.5", port: 8767, localHostName: nil, fingerprint: String(repeating: "ab", count: 32),
                                    serverName: "Mac", deviceId: "d", deviceToken: "t", pairedAt: 0)
        return AppModel(demo: RemoteState(rooms: rooms, usage: nil, monitoring: true), pairing: pairing, transcripts: [:], open: open,
                        notifications: notifications())
    }

    func testOpensTheRoomDirectlyOrBySession() {
        let model = connectedModel([room("h:new", session: "s1"), room("e:s2", session: "s2")])
        model.openFromNotice(AttentionNoticeRoute(roomId: "e:s2", sessionId: "s2", macName: nil))
        XCTAssertEqual(model.requestedRoomId, "e:s2")
        model.requestedRoomId = nil
        model.openFromNotice(AttentionNoticeRoute(roomId: "h:old", sessionId: "s1", macName: nil))
        XCTAssertEqual(model.requestedRoomId, "h:new")
        XCTAssertNil(model.pendingNotice)
        XCTAssertNil(model.noticeHint)
    }

    func testMissingRoomWhileConnectedSaysItIsGone() {
        let model = connectedModel([room("h:1", session: "s1")])
        model.openFromNotice(AttentionNoticeRoute(roomId: "h:9", sessionId: "s9", macName: nil))
        XCTAssertNil(model.requestedRoomId)
        XCTAssertNil(model.pendingNotice)
        XCTAssertTrue(model.noticeHint?.contains("見つかりません") == true)
    }

    func testOpenRoomIdFollowsTheOpenConversation() {
        let model = connectedModel([room("h:1", session: "s1")], open: "s1")
        XCTAssertEqual(model.openRoomId, "h:1")
    }
    #endif
}
