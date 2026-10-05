import XCTest
@testable import DeckCore

final class AttentionNoticeTextTests: XCTestCase {
    func testToolNameAcceptsOnlyIdentifierShapes() {
        XCTAssertEqual(AttentionNoticeText.toolName("Bash"), "Bash")
        XCTAssertEqual(AttentionNoticeText.toolName("mcp__github__create_issue"), "mcp__github__create_issue")
        XCTAssertNil(AttentionNoticeText.toolName("rm -rf /"))
        XCTAssertNil(AttentionNoticeText.toolName("Bash: git push"))
        XCTAssertNil(AttentionNoticeText.toolName(""))
        XCTAssertNil(AttentionNoticeText.toolName(String(repeating: "a", count: 65)))
    }

    func testToolNameFromDetailDropsTheDescription() {
        XCTAssertEqual(AttentionNoticeText.toolName(fromDetail: "Bash: secret-token を使って deploy"), "Bash")
        XCTAssertEqual(AttentionNoticeText.toolName(fromDetail: "Claude needs your permission to use Write"), "Write")
        XCTAssertNil(AttentionNoticeText.toolName(fromDetail: "ファイルを消してよいですか: x"))
        XCTAssertNil(AttentionNoticeText.toolName(fromDetail: nil))
    }

    func testSummaryIsFixedText() {
        XCTAssertEqual(AttentionNoticeText.summary(kind: .permission, toolName: "Bash"), "権限の確認を待っています（Bash）")
        XCTAssertEqual(AttentionNoticeText.summary(kind: .permission, toolName: "echo hi && rm x"), "権限の確認を待っています")
        XCTAssertEqual(AttentionNoticeText.summary(kind: .waiting, toolName: "Bash"), "入力を待っています")
        XCTAssertEqual(AttentionNoticeText.summary(kind: .error, toolName: nil), "エラーで止まっています")
    }

    func testNameIsCleanedAndClipped() {
        XCTAssertEqual(AttentionNoticeText.name("  sandora\n"), "sandora")
        XCTAssertEqual(AttentionNoticeText.name(""), "Claude Code")
        let long = AttentionNoticeText.name(String(repeating: "あ", count: 80))
        XCTAssertEqual(long.count, AttentionNoticeText.maxNameLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testTitleAndBodyForGroupedNotices() {
        XCTAssertEqual(AttentionNoticeText.title(roomName: "mirio", others: 0), "mirio")
        XCTAssertEqual(AttentionNoticeText.title(roomName: "mirio", others: 2), "mirio ほか 2 件")
        XCTAssertEqual(AttentionNoticeText.body(summary: "入力を待っています", otherNames: []), "入力を待っています")
        XCTAssertEqual(AttentionNoticeText.body(summary: "入力を待っています", otherNames: ["a", "b"]),
                       "入力を待っています。a、b も対応を待っています")
        XCTAssertEqual(AttentionNoticeText.body(summary: "S", otherNames: ["a", "b", "c", "d", "e"]),
                       "S。a、b、c ほか 2 件 も対応を待っています")
    }

    func testKindFromStatus() {
        XCTAssertEqual(AttentionKind(status: .permission), .permission)
        XCTAssertEqual(AttentionKind(status: .waiting), .waiting)
        XCTAssertEqual(AttentionKind(status: .error), .error)
        XCTAssertNil(AttentionKind(status: .working))
        XCTAssertNil(AttentionKind(status: .idle))
        XCTAssertNil(AttentionKind(status: .stopped))
    }
}

final class AttentionNoticeSchemaTests: XCTestCase {
    private func notice(sessionId: String? = "s1") -> AttentionNotice {
        AttentionNotice(recordName: "attn-h_1-1000", roomId: "h:1", sessionId: sessionId, roomName: "mirio", kind: .permission,
                        summary: "権限の確認を待っています（Bash）", title: "mirio", body: "権限の確認を待っています（Bash）",
                        since: 1000, roomIds: ["h:1"], macName: "Mac")
    }

    func testFieldsAreOnlyTheDeclaredOnes() {
        let fields = AttentionNoticeSchema.fields(of: notice())
        XCTAssertEqual(Set(fields.keys), AttentionNoticeSchema.allFields)
        XCTAssertEqual(fields[AttentionNoticeSchema.Field.since], .int(1000))
        XCTAssertEqual(fields[AttentionNoticeSchema.Field.version], .int(AttentionNoticeSchema.version))
        XCTAssertNil(AttentionNoticeSchema.fields(of: notice(sessionId: nil))[AttentionNoticeSchema.Field.sessionId])
    }

    func testDesiredKeysAreWrittenFields() {
        XCTAssertTrue(Set(AttentionNoticeSchema.desiredKeys).isSubset(of: AttentionNoticeSchema.allFields))
        XCTAssertTrue(AttentionNoticeSchema.allFields.contains(AttentionNoticeSchema.collapseIDKey))
    }
}

final class AttentionNoticePlannerTests: XCTestCase {
    private let s: Double = 1000

    private func candidate(_ room: String, _ kind: AttentionKind = .permission, name: String? = nil, tool: String? = nil,
                           session: String? = nil) -> AttentionCandidate {
        AttentionCandidate(roomId: room, sessionId: session, roomName: name ?? room, kind: kind, toolName: tool)
    }

    private func saves(_ changes: [AttentionNoticePlanner.Change]) -> [AttentionNotice] {
        changes.compactMap { if case .save(let n) = $0 { return n } else { return nil } }
    }

    private func deletes(_ changes: [AttentionNoticePlanner.Change]) -> [String] {
        changes.compactMap { if case .delete(let n) = $0 { return n } else { return nil } }
    }

    func testWritesOnceAfterSettleAndDeletesWhenResolved() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        let c = candidate("h:1", tool: "Bash", session: "s1")
        XCTAssertTrue(planner.update([c], now: 0).isEmpty)
        XCTAssertTrue(planner.update([c], now: 4 * s).isEmpty)
        let written = saves(planner.update([c], now: 5 * s))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.roomId, "h:1")
        XCTAssertEqual(written.first?.sessionId, "s1")
        XCTAssertEqual(written.first?.summary, "権限の確認を待っています（Bash）")
        XCTAssertEqual(written.first?.since, 0)
        XCTAssertEqual(written.first?.macName, "Mac")
        // 続いている間は書き直さない（同じ要対応は 1 回）。
        XCTAssertTrue(planner.update([c], now: 60 * s).isEmpty)
        XCTAssertTrue(planner.update([c], now: 120 * s).isEmpty)
        XCTAssertEqual(deletes(planner.update([], now: 121 * s)), [written[0].recordName])
        XCTAssertTrue(planner.update([], now: 122 * s).isEmpty)
    }

    func testAnsweredBeforeSettleIsNeverWritten() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        XCTAssertTrue(planner.update([candidate("h:1")], now: 0).isEmpty)
        XCTAssertTrue(planner.update([], now: 3 * s).isEmpty)
        XCTAssertTrue(planner.update([], now: 10 * s).isEmpty)
    }

    func testKindChangeWithinTheSameEpisodeIsNotANewNotice() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        _ = planner.update([candidate("h:1", .permission)], now: 0)
        XCTAssertEqual(saves(planner.update([candidate("h:1", .permission)], now: 5 * s)).count, 1)
        XCTAssertTrue(planner.update([candidate("h:1", .waiting)], now: 100 * s).isEmpty)
    }

    func testDuplicateCandidatesForTheSameRoomCountOnce() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        _ = planner.update([candidate("h:1"), candidate("h:1", .waiting)], now: 0)
        let written = saves(planner.update([candidate("h:1"), candidate("h:1")], now: 5 * s))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].roomIds, ["h:1"])
    }

    func testSimultaneousAttentionIsGroupedUnderTheNewest() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        _ = planner.update([candidate("h:a", name: "alpha")], now: 0)
        _ = planner.update([candidate("h:a", name: "alpha"), candidate("e:b", .waiting, name: "beta")], now: 1 * s)
        let all = [candidate("h:a", name: "alpha"), candidate("e:b", .waiting, name: "beta"), candidate("h:c", .error, name: "gamma")]
        _ = planner.update(all, now: 2 * s)
        XCTAssertTrue(planner.update(all, now: 4 * s).isEmpty)
        let written = saves(planner.update(all, now: 5 * s))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].roomId, "h:c")
        XCTAssertEqual(written[0].title, "gamma ほか 2 件")
        XCTAssertEqual(written[0].body, "エラーで止まっています。beta、alpha も対応を待っています")
        XCTAssertEqual(written[0].roomIds, ["h:c", "e:b", "h:a"])
    }

    func testCooldownDefersAndThenGroupsLaterAttention() {
        var planner = AttentionNoticePlanner(config: .init(settle: 5, cooldown: 30), macName: "Mac")
        _ = planner.update([candidate("h:a")], now: 0)
        let first = saves(planner.update([candidate("h:a")], now: 5 * s))
        XCTAssertEqual(first.count, 1)
        // 知らせた直後に別のルームが 2 つ要対応になっても、明けるまでは出さない。
        _ = planner.update([candidate("h:a"), candidate("h:b")], now: 10 * s)
        _ = planner.update([candidate("h:a"), candidate("h:b"), candidate("h:c")], now: 12 * s)
        XCTAssertTrue(planner.update([candidate("h:a"), candidate("h:b"), candidate("h:c")], now: 20 * s).isEmpty)
        let second = saves(planner.update([candidate("h:a"), candidate("h:b"), candidate("h:c")], now: 35 * s))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].roomId, "h:c")
        XCTAssertEqual(Set(second[0].roomIds), ["h:b", "h:c"])
    }

    func testGroupedNoticeIsDeletedOnlyWhenAllItsRoomsAreResolved() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        let both = [candidate("h:a"), candidate("h:b")]
        _ = planner.update(both, now: 0)
        let written = saves(planner.update(both, now: 5 * s))
        XCTAssertEqual(written.count, 1)
        XCTAssertTrue(planner.update([candidate("h:b")], now: 6 * s).isEmpty)
        XCTAssertEqual(deletes(planner.update([], now: 7 * s)), [written[0].recordName])
    }

    func testReturningAttentionIsANewNoticeAfterCooldown() {
        var planner = AttentionNoticePlanner(config: .init(settle: 5, cooldown: 30), macName: "Mac")
        _ = planner.update([candidate("h:a")], now: 0)
        let first = saves(planner.update([candidate("h:a")], now: 5 * s))
        _ = planner.update([], now: 8 * s)
        _ = planner.update([candidate("h:a")], now: 9 * s)
        XCTAssertTrue(planner.update([candidate("h:a")], now: 20 * s).isEmpty)
        let second = saves(planner.update([candidate("h:a")], now: 40 * s))
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(second[0].recordName, first[0].recordName)
        XCTAssertEqual(second[0].since, 9 * s)
    }

    func testNoticeCarriesNoFreeTextFromTheSession() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        let secret = "curl -H 'Authorization: Bearer abc' https://example.com"
        let c = candidate("h:1", .permission, name: "repo", tool: secret, session: "s1")
        _ = planner.update([c], now: 0)
        let notice = saves(planner.update([c], now: 5 * s))[0]
        for case .string(let value) in AttentionNoticeSchema.fields(of: notice).values {
            XCTAssertFalse(value.contains("Bearer"), value)
            XCTAssertFalse(value.contains("curl"), value)
        }
    }

    func testRecordNameUsesSafeCharacters() {
        let name = AttentionNoticePlanner.recordName(roomId: "h:6F0B/..ü", now: 1234.5)
        XCTAssertEqual(name, "attn-h_6F0B____-1234")
    }
}

/// 試験用の置き場。失敗させる回数を決められる。
final class FakeNoticeStore: AttentionNoticeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [String: AttentionNotice] = [:]
    private var _calls: [String] = []
    var failuresLeft = 0

    var records: [String: AttentionNotice] { lock.withLock { _records } }
    var calls: [String] { lock.withLock { _calls } }

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "iCloud に届きません" }
    }

    func save(_ notice: AttentionNotice) async throws {
        try lock.withLock {
            _calls.append("save \(notice.recordName)")
            if failuresLeft > 0 { failuresLeft -= 1; throw Failure() }
            _records[notice.recordName] = notice
        }
    }

    func delete(recordName: String) async throws {
        try lock.withLock {
            _calls.append("delete \(recordName)")
            if failuresLeft > 0 { failuresLeft -= 1; throw Failure() }
            _records[recordName] = nil
        }
    }
}

final class MemoryNoticeLedger: AttentionNoticeLedger, @unchecked Sendable {
    var names: [String]
    init(_ names: [String] = []) { self.names = names }
    func load() -> [String] { names }
    func store(_ names: [String]) { self.names = names }
}

@MainActor
final class AttentionNoticeSyncTests: XCTestCase {
    private func notice(_ name: String) -> AttentionNotice {
        AttentionNotice(recordName: name, roomId: "h:1", sessionId: nil, roomName: "r", kind: .waiting, summary: "入力を待っています",
                        title: "r", body: "入力を待っています", since: 0, roomIds: ["h:1"], macName: "Mac")
    }

    func testSavesAndDeletesAndRemembersWhatWasWritten() async {
        let store = FakeNoticeStore()
        let ledger = MemoryNoticeLedger()
        let sync = AttentionNoticeSync(store: store, ledger: ledger)
        sync.submit([.save(notice("a"))])
        await sync.tick()
        XCTAssertEqual(Array(store.records.keys), ["a"])
        XCTAssertEqual(ledger.names, ["a"])
        sync.submit([.delete(recordName: "a")])
        await sync.tick()
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(ledger.names, [])
        if case .synced = sync.status {} else { XCTFail("\(sync.status)") }
    }

    func testDeleteBeforeSendingSkipsBothWrites() async {
        let store = FakeNoticeStore()
        let sync = AttentionNoticeSync(store: store, ledger: MemoryNoticeLedger())
        sync.submit([.save(notice("a"))])
        sync.submit([.delete(recordName: "a")])
        await sync.tick()
        XCTAssertEqual(store.calls, [])
        XCTAssertEqual(sync.pendingCount, 0)
    }

    func testFailureIsRetriedQuietlyWithBackoff() async {
        let store = FakeNoticeStore()
        store.failuresLeft = 2
        let sync = AttentionNoticeSync(store: store, ledger: MemoryNoticeLedger())
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        sync.submit([.save(notice("a"))])
        await sync.tick(now: t0)
        guard case .retrying(let failures, let retryAt, let message) = sync.status else { return XCTFail("\(sync.status)") }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(retryAt, t0.addingTimeInterval(2))
        XCTAssertEqual(message, "iCloud に届きません")
        // 待ちが明けるまでは送らない。
        await sync.tick(now: t0.addingTimeInterval(1))
        XCTAssertEqual(store.calls.count, 1)
        await sync.tick(now: t0.addingTimeInterval(2))
        guard case .retrying(2, let second, _) = sync.status else { return XCTFail("\(sync.status)") }
        XCTAssertEqual(second, t0.addingTimeInterval(6))
        await sync.tick(now: t0.addingTimeInterval(6))
        XCTAssertEqual(Array(store.records.keys), ["a"])
        XCTAssertEqual(store.calls, ["save a", "save a", "save a"])
        if case .synced = sync.status {} else { XCTFail("\(sync.status)") }
    }

    func testBackoffIsCapped() {
        XCTAssertEqual(AttentionNoticeSync.backoff(1), 2)
        XCTAssertEqual(AttentionNoticeSync.backoff(3), 8)
        XCTAssertEqual(AttentionNoticeSync.backoff(50), 300)
    }

    func testLeftoversFromThePreviousRunAreDeletedFirst() async {
        let store = FakeNoticeStore()
        let ledger = MemoryNoticeLedger(["old1", "old2"])
        let sync = AttentionNoticeSync(store: store, ledger: ledger)
        sync.submit([.save(notice("new"))])
        await sync.tick()
        XCTAssertEqual(store.calls, ["delete old1", "delete old2", "save new"])
        XCTAssertEqual(ledger.names, ["new"])
    }

    func testResaveOfTheSameNameKeepsOnlyTheLatest() async {
        let store = FakeNoticeStore()
        let sync = AttentionNoticeSync(store: store, ledger: MemoryNoticeLedger())
        var first = notice("a")
        first.summary = "1"
        var second = notice("a")
        second.summary = "2"
        sync.submit([.save(first), .save(second)])
        await sync.tick()
        XCTAssertEqual(store.calls, ["save a"])
        XCTAssertEqual(store.records["a"]?.summary, "2")
    }

    func testPlannerAndSyncTogether() async {
        let store = FakeNoticeStore()
        let sync = AttentionNoticeSync(store: store, ledger: MemoryNoticeLedger())
        var planner = AttentionNoticePlanner(macName: "Mac")
        let c = AttentionCandidate(roomId: "h:1", sessionId: "s", roomName: "mirio", kind: .permission, toolName: "Edit")
        for t in stride(from: 0.0, through: 10_000, by: 1000) {
            sync.submit(planner.update([c], now: t))
            await sync.tick()
        }
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.values.first?.summary, "権限の確認を待っています（Edit）")
        sync.submit(planner.update([], now: 11_000))
        await sync.tick()
        XCTAssertTrue(store.records.isEmpty)
    }
}

final class AttentionNoticeRouteTests: XCTestCase {
    private func room(_ id: String, session: String?) -> RemoteRoom {
        RemoteRoom(id: id, kind: .hosted, phase: .attention, name: id, branch: nil, status: .permission, line: "", activityAt: nil,
                   sessionId: session, cwd: "/", ended: nil, session: nil, permissions: [], terminalPermission: nil, menu: nil,
                   unreadableMenu: nil, busy: false, send: RemoteSendState(mode: .input, disabledReason: nil))
    }

    func testParsesCloudKitPayload() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title-loc-key": "ATTENTION_TITLE"]],
            "ck": ["qry": ["af": ["roomId": "h:1", "sessionId": "s1", "macName": "Mac"], "sid": "attention-notice-created"]]
        ]
        XCTAssertEqual(AttentionNoticeRoute(userInfo: userInfo), AttentionNoticeRoute(roomId: "h:1", sessionId: "s1", macName: "Mac"))
        XCTAssertNil(AttentionNoticeRoute(userInfo: ["aps": [:]]))
        XCTAssertNil(AttentionNoticeRoute(fields: ["roomId": ""]))
        XCTAssertNil(AttentionNoticeRoute(fields: ["roomId": "h:1", "sessionId": ""])?.sessionId)
    }

    func testResolvesByRoomThenBySession() {
        let rooms = [room("h:new", session: "s1"), room("e:s2", session: "s2")]
        XCTAssertEqual(AttentionNoticeRoute(roomId: "e:s2", sessionId: "s2", macName: nil).resolve(in: rooms)?.id, "e:s2")
        // mac を起動し直してホスト中のルームの id が替わっても、セッションで辿る。
        XCTAssertEqual(AttentionNoticeRoute(roomId: "h:old", sessionId: "s1", macName: nil).resolve(in: rooms)?.id, "h:new")
        XCTAssertNil(AttentionNoticeRoute(roomId: "h:old", sessionId: nil, macName: nil).resolve(in: rooms))
        XCTAssertNil(AttentionNoticeRoute(roomId: "h:old", sessionId: "gone", macName: nil).resolve(in: rooms))
    }

    func testForegroundPresentation() {
        let route = AttentionNoticeRoute(roomId: "h:1", sessionId: nil, macName: nil)
        XCTAssertTrue(AttentionNoticePresentation.shouldPresent(enabled: true, route: route, openRoomId: nil))
        XCTAssertTrue(AttentionNoticePresentation.shouldPresent(enabled: true, route: route, openRoomId: "h:2"))
        XCTAssertFalse(AttentionNoticePresentation.shouldPresent(enabled: true, route: route, openRoomId: "h:1"))
        XCTAssertFalse(AttentionNoticePresentation.shouldPresent(enabled: false, route: route, openRoomId: nil))
    }
}
