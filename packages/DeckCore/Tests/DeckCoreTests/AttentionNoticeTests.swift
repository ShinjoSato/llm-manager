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

    func testToolNameFromDetailOnlyReadsThePermissionMessage() {
        XCTAssertEqual(AttentionNoticeText.toolName(fromDetail: "Claude needs your permission to use Write"), "Write")
        XCTAssertEqual(AttentionNoticeText.toolName(fromDetail: "Claude needs your permission to use Bash."), "Bash")
        XCTAssertEqual(AttentionNoticeText.toolName(fromDetail: "Claude needs your permission to use Bash: git push"), "Bash")
        XCTAssertEqual(AttentionNoticeText.toolName(fromDetail: "Claude needs your permission to use mcp__gh__create_issue"),
                       "mcp__gh__create_issue")
        // 頭の語がツール名の形をしていても、通知文の形でなければ拾わない。
        XCTAssertNil(AttentionNoticeText.toolName(fromDetail: "Bash: secret-token を使って deploy"))
        XCTAssertNil(AttentionNoticeText.toolName(fromDetail: "Error: rate limited"))
        XCTAssertNil(AttentionNoticeText.toolName(fromDetail: "foo.env"))
        XCTAssertNil(AttentionNoticeText.toolName(fromDetail: "Claude needs your permission to use Bash to read foo.env"))
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
        // 解消は少し続いてから決める。
        XCTAssertTrue(planner.update([], now: 121 * s).isEmpty)
        XCTAssertEqual(deletes(planner.update([], now: 124 * s)), [written[0].recordName])
        XCTAssertTrue(planner.update([], now: 125 * s).isEmpty)
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

    func testSimultaneousAttentionIsGroupedUnderTheNewestSettled() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        _ = planner.update([candidate("h:a", name: "alpha")], now: 0)
        _ = planner.update([candidate("h:a", name: "alpha"), candidate("e:b", .waiting, name: "beta")], now: 1 * s)
        let all = [candidate("h:a", name: "alpha"), candidate("e:b", .waiting, name: "beta"), candidate("h:c", .error, name: "gamma")]
        _ = planner.update(all, now: 2 * s)
        XCTAssertTrue(planner.update(all, now: 4 * s).isEmpty)
        let written = saves(planner.update(all, now: 6 * s))
        XCTAssertEqual(written.count, 1)
        // beta まで続いたので見出しは beta。まだ続いていない gamma は「ほか」に回す。
        XCTAssertEqual(written[0].roomId, "e:b")
        XCTAssertEqual(written[0].kind, .waiting)
        XCTAssertEqual(written[0].since, 1 * s)
        XCTAssertEqual(written[0].title, "beta ほか 2 件")
        XCTAssertEqual(written[0].body, "入力を待っています。gamma、alpha も対応を待っています")
        XCTAssertEqual(written[0].roomIds, ["e:b", "h:c", "h:a"])
    }

    func testHeadlineIsNeverARoomThatHasNotSettled() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        _ = planner.update([candidate("h:a", name: "alpha")], now: 0)
        let both = [candidate("h:a", name: "alpha"), candidate("h:b", .waiting, name: "beta", session: "sb")]
        _ = planner.update(both, now: 4 * s)
        let written = saves(planner.update(both, now: 5 * s))
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].roomId, "h:a")
        XCTAssertNil(written[0].sessionId)
        XCTAssertEqual(written[0].kind, .permission)
        XCTAssertEqual(written[0].title, "alpha ほか 1 件")
        XCTAssertEqual(written[0].roomIds, ["h:a", "h:b"])
    }

    func testFlappingWithinResolveKeepsTheSameEpisode() {
        var planner = AttentionNoticePlanner(config: .init(settle: 5, cooldown: 30, resolve: 3), macName: "Mac")
        _ = planner.update([candidate("h:a")], now: 0)
        let first = saves(planner.update([candidate("h:a")], now: 5 * s))
        XCTAssertEqual(first.count, 1)
        // 要対応と作業中を行き来しても、3 秒続けて外れない限り同じ要対応（消しも出し直しもしない）。
        var t = 6 * s
        for _ in 0..<30 {
            XCTAssertTrue(planner.update([], now: t).isEmpty)
            XCTAssertTrue(planner.update([], now: t + 2 * s).isEmpty)
            XCTAssertTrue(planner.update([candidate("h:a")], now: t + 2.5 * s).isEmpty)
            t += 3 * s
        }
        XCTAssertTrue(planner.update([], now: t).isEmpty)
        XCTAssertEqual(deletes(planner.update([], now: t + 3 * s)), [first[0].recordName])
    }

    func testFlappingBeforeSettleStillCountsFromTheFirstStart() {
        var planner = AttentionNoticePlanner(macName: "Mac")
        _ = planner.update([candidate("h:a")], now: 0)
        _ = planner.update([], now: 2 * s)
        XCTAssertTrue(planner.update([candidate("h:a")], now: 4 * s).isEmpty)
        let written = saves(planner.update([candidate("h:a")], now: 5 * s))
        XCTAssertEqual(written.first?.since, 0)
    }

    func testPendingResolveIsNotAHeadline() {
        var planner = AttentionNoticePlanner(config: .init(settle: 5, cooldown: 0, resolve: 3), macName: "Mac")
        _ = planner.update([candidate("h:a")], now: 0)
        // 外れたばかり（解消を待っている）のルームでは知らせない。
        XCTAssertTrue(planner.update([], now: 5 * s).isEmpty)
        XCTAssertTrue(planner.update([], now: 9 * s).isEmpty)
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
        XCTAssertTrue(planner.update([candidate("h:b")], now: 9 * s).isEmpty)
        XCTAssertTrue(planner.update([], now: 10 * s).isEmpty)
        XCTAssertEqual(deletes(planner.update([], now: 13 * s)), [written[0].recordName])
    }

    func testReturningAttentionIsANewNoticeAfterCooldown() {
        var planner = AttentionNoticePlanner(config: .init(settle: 5, cooldown: 30), macName: "Mac")
        _ = planner.update([candidate("h:a")], now: 0)
        let first = saves(planner.update([candidate("h:a")], now: 5 * s))
        _ = planner.update([], now: 8 * s)
        XCTAssertEqual(deletes(planner.update([], now: 11 * s)), [first[0].recordName])
        _ = planner.update([candidate("h:a")], now: 12 * s)
        XCTAssertTrue(planner.update([candidate("h:a")], now: 20 * s).isEmpty)
        let second = saves(planner.update([candidate("h:a")], now: 40 * s))
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(second[0].recordName, first[0].recordName)
        XCTAssertEqual(second[0].since, 12 * s)
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
    /// 書けたのに失敗が返る（タイムアウト等）回数。
    var lostRepliesLeft = 0

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
            if lostRepliesLeft > 0 { lostRepliesLeft -= 1; throw Failure() }
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

/// 保存の途中で止まったままの置き場（送っている最中に終了したのと同じ）。
final class StalledNoticeStore: AttentionNoticeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    var isSaving: Bool { lock.withLock { continuation != nil } }

    func save(_ notice: AttentionNotice) async throws {
        await withCheckedContinuation { c in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                continuation = c
                return false
            }
            if resumeNow { c.resume() }
        }
        throw FakeNoticeStore.Failure()
    }

    func delete(recordName: String) async throws {}

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
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

    func testDeleteAfterAFailedSaveIsStillSent() async {
        let store = FakeNoticeStore()
        store.failuresLeft = 1
        let ledger = MemoryNoticeLedger()
        let sync = AttentionNoticeSync(store: store, ledger: ledger)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        sync.submit([.save(notice("a"))])
        await sync.tick(now: t0)
        XCTAssertEqual(ledger.names, ["a"])
        // 届いたか分からないので、解消したら消しに行く。
        sync.submit([.delete(recordName: "a")])
        await sync.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(store.calls, ["save a", "delete a"])
        XCTAssertEqual(ledger.names, [])
    }

    func testDeleteAfterATimedOutSaveRemovesTheRecord() async {
        let store = FakeNoticeStore()
        store.lostRepliesLeft = 1
        let ledger = MemoryNoticeLedger()
        let sync = AttentionNoticeSync(store: store, ledger: ledger)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        sync.submit([.save(notice("a"))])
        await sync.tick(now: t0)
        XCTAssertEqual(Array(store.records.keys), ["a"])
        sync.submit([.delete(recordName: "a")])
        await sync.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(store.calls, ["save a", "delete a"])
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(ledger.names, [])
        if case .synced = sync.status {} else { XCTFail("\(sync.status)") }
    }

    func testSaveInterruptedByQuitIsCleanedUpOnTheNextRun() async {
        let stalled = StalledNoticeStore()
        let ledger = MemoryNoticeLedger()
        let sync = AttentionNoticeSync(store: stalled, ledger: ledger)
        sync.submit([.save(notice("a"))])
        let sending = Task { await sync.tick() }
        for _ in 0..<1000 where !stalled.isSaving { await Task.yield() }
        XCTAssertTrue(stalled.isSaving)
        XCTAssertEqual(ledger.names, ["a"])

        // 送っている最中に終了した、次の起動。
        let store = FakeNoticeStore()
        let next = AttentionNoticeSync(store: store, ledger: ledger)
        await next.tick()
        XCTAssertEqual(store.calls, ["delete a"])
        XCTAssertEqual(ledger.names, [])

        stalled.release()
        await sending.value
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

    func testWithdrawAllDeletesWrittenAndDropsUnsent() async {
        let store = FakeNoticeStore()
        let ledger = MemoryNoticeLedger()
        let sync = AttentionNoticeSync(store: store, ledger: ledger)
        sync.submit([.save(notice("a"))])
        await sync.tick()
        sync.submit([.save(notice("b"))])
        sync.withdrawAll()
        await sync.tick()
        XCTAssertEqual(store.calls, ["save a", "delete a"])
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(ledger.names, [])
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
        sync.submit(planner.update([], now: 14_000))
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
