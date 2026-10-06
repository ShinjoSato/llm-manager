import XCTest
@testable import MonitorKit

final class HostedSessionsFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hosted-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let sessionA = "acb12868-4061-4d7e-987c-0522878e518d"

    func testSaveAndLoadRoundTripWithOwnerOnlyPermissions() throws {
        let file = HostedSessionsFile(url: dir.appendingPathComponent("hosted-sessions.json"))
        let records = [HostedSessionRecord(name: "app", cwd: "/tmp/app", sessionId: sessionA, status: .working, draft: "書きかけ")]
        try file.save(records)
        XCTAssertEqual(file.load(), records)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // 置き換えで書くので一時ファイルを残さない。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testMissingBrokenOrUnknownVersionIsEmpty() throws {
        let url = dir.appendingPathComponent("hosted-sessions.json")
        let file = HostedSessionsFile(url: url)
        XCTAssertEqual(file.load(), [])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: url)
        XCTAssertEqual(file.load(), [])
        try Data(#"{"version": 99, "savedAt": 0, "sessions": []}"#.utf8).write(to: url)
        XCTAssertEqual(file.load(), [])
    }

    func testUnknownStatusIsReadLeniently() throws {
        let url = dir.appendingPathComponent("hosted-sessions.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"version":1,"savedAt":0,"sessions":[{"name":"a","cwd":"/a","sessionId":"\#(sessionA)","status":"新しい状態"}]}"#
        try Data(json.utf8).write(to: url)
        XCTAssertEqual(HostedSessionsFile(url: url).load().first?.status, .unknown)
    }

    func testEnvironmentOverridesDefaultLocation() {
        XCTAssertEqual(HostedSessionsFile.defaultURL(environment: [HostedSessionsFile.environmentKey: "/tmp/x/hosted.json"]).path,
                       "/tmp/x/hosted.json")
        XCTAssertEqual(HostedSessionsFile.defaultURL(environment: [:]).lastPathComponent, "hosted-sessions.json")
        XCTAssertEqual(HostedSessionsFile.defaultURL(environment: [:]).deletingLastPathComponent().path,
                       DeckPaths.applicationSupport.path)
    }
}

final class SessionRestorePlanTests: XCTestCase {
    private let a = "acb12868-4061-4d7e-987c-0522878e518d"
    private let b = "bcb12868-4061-4d7e-987c-0522878e518d"

    private func record(_ id: String, _ status: SessionStatus, cwd: String = "/p") -> HostedSessionRecord {
        HostedSessionRecord(name: "p", cwd: cwd, sessionId: id, status: status)
    }

    private func plan(_ records: [HostedSessionRecord], limit: Bool = false, ask: Bool = true, hosted: Set<String> = [],
                      exists: @escaping (String) -> Bool = { _ in true },
                      duplicate: @escaping (String) -> Int32? = { _ in nil }) -> [SessionRestore.Decision] {
        SessionRestore.plan(records: records, limitReached: limit, askToContinue: ask, hostedSessionIds: hosted,
                            directoryExists: exists, liveDuplicate: duplicate).map(\.decision)
    }

    func testOnlyWorkingSessionsAreAskedToContinue() {
        let statuses: [SessionStatus] = [.working, .permission, .waiting, .idle, .error, .unknown]
        let ids = (0..<statuses.count).map { String(format: "acb12868-4061-4d7e-987c-%012d", $0) }
        let decisions = plan(zip(ids, statuses).map { record($0, $1) })
        XCTAssertEqual(decisions, [.launch(nudge: true), .launch(nudge: false), .launch(nudge: false),
                                   .launch(nudge: false), .launch(nudge: false), .launch(nudge: false)])
    }

    func testAskToContinueOffOnlyLaunches() {
        XCTAssertEqual(plan([record(a, .working)], ask: false), [.launch(nudge: false)])
    }

    func testLimitDefersInsteadOfLaunching() {
        XCTAssertEqual(plan([record(a, .working), record(b, .idle)], limit: true), [.deferredByLimit, .deferredByLimit])
    }

    func testRunningElsewhereIsNotLaunchedEvenUnderLimit() {
        XCTAssertEqual(plan([record(a, .working)], limit: true, duplicate: { $0 == self.a ? 4321 : nil }), [.runningElsewhere(4321)])
    }

    func testInvalidIdMissingFolderAndAlreadyHostedAreSkipped() {
        let decisions = plan([record("-p", .working), record(a, .idle, cwd: "/gone"), record(b, .idle)],
                             hosted: [b], exists: { $0 != "/gone" })
        XCTAssertEqual(decisions.count, 3)
        for decision in decisions {
            guard case .skipped = decision else { return XCTFail("\(decision)") }
        }
    }

    func testDuplicateSessionIdsAreResumedOnce() {
        XCTAssertEqual(plan([record(a, .working), record(a, .idle)]), [.launch(nudge: true)])
    }

    func testSummary() {
        XCTAssertEqual(SessionRestore.summary(launched: 2, nudged: 1, deferred: 0, elsewhere: 0, skipped: 0),
                       "前回のセッションを 2 件再開しました（うち 1 件に続きを頼みます）")
        XCTAssertEqual(SessionRestore.summary(launched: 0, nudged: 0, deferred: 3, elsewhere: 1, skipped: 0),
                       "Max 枠の上限に達しているため 3 件は再開していません。1 件は別の claude で動いているため再開していません")
        XCTAssertNil(SessionRestore.summary(launched: 0, nudged: 0, deferred: 0, elsewhere: 0, skipped: 0))
    }
}

final class ResumeNudgeGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testSendsOnlyAfterReadyForSettleTime() {
        var gate = ResumeNudgeGate(startedAt: start)
        XCTAssertEqual(gate.step(ready: false, now: start), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 1), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 2), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 1 + ResumeNudgeGate.settle), .send)
    }

    func testMenuInBetweenRestartsSettling() {
        var gate = ResumeNudgeGate(startedAt: start)
        XCTAssertEqual(gate.step(ready: true, now: start), .wait)
        // trust 確認などのメニューが出たら数え直す。
        XCTAssertEqual(gate.step(ready: false, now: start + 1.5), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 2), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 3.9), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 4), .send)
    }

    func testRefusedSendWaitsAgain() {
        var gate = ResumeNudgeGate(startedAt: start)
        _ = gate.step(ready: true, now: start)
        XCTAssertEqual(gate.step(ready: true, now: start + 3), .send)
        gate.refused()
        XCTAssertEqual(gate.step(ready: true, now: start + 3.5), .wait)
        XCTAssertEqual(gate.step(ready: true, now: start + 5.5), .send)
    }

    func testGivesUpAfterTimeout() {
        var gate = ResumeNudgeGate(startedAt: start)
        XCTAssertEqual(gate.step(ready: false, now: start + ResumeNudgeGate.timeout - 1), .wait)
        XCTAssertEqual(gate.step(ready: false, now: start + ResumeNudgeGate.timeout), .giveUp)
    }
}

final class QuitConfirmationTests: XCTestCase {
    private func room(_ name: String, _ status: SessionStatus) -> QuitConfirmation.Room {
        QuitConfirmation.Room(name: name, status: status)
    }

    func testIdleOnlyNeedsNoConfirmation() {
        let rooms = [room("a", .idle), room("b", .stopped), room("c", .error)]
        XCTAssertEqual(QuitConfirmation.busy(rooms), [])
        XCTAssertTrue(QuitConfirmation.isSettled(rooms))
        XCTAssertTrue(QuitConfirmation.isSettled([]))
    }

    func testWorkingAndAttentionNeedConfirmation() {
        let rooms = [room("a", .working), room("b", .idle), room("c", .permission), room("d", .waiting)]
        XCTAssertEqual(QuitConfirmation.busy(rooms).map(\.name), ["a", "c", "d"])
        XCTAssertFalse(QuitConfirmation.isSettled(rooms))
    }

    func testMessageListsUpToThreeNames() {
        let rooms = ["a", "b", "c", "d", "e"].map { room($0, .working) }
        XCTAssertEqual(QuitConfirmation.message(busy: rooms, resumesOnLaunch: true),
                       "作業中 5 件（a、b、c ほか 2 件）。終了すると中断し、次の起動時に再開します。")
        XCTAssertEqual(QuitConfirmation.message(busy: [room("x", .permission)], resumesOnLaunch: false),
                       "作業中 1 件（x）。終了すると中断します。")
    }

    func testQuitWaitNeedsSettledForAWhile() {
        let start = Date(timeIntervalSince1970: 0)
        var wait = QuitWait()
        XCTAssertFalse(wait.step([room("a", .working)], now: start))
        XCTAssertFalse(wait.step([room("a", .idle)], now: start + 1))
        // ツールの合間に稼働中へ戻ったら数え直す。
        XCTAssertFalse(wait.step([room("a", .working)], now: start + 2))
        XCTAssertFalse(wait.step([room("a", .idle)], now: start + 3))
        XCTAssertFalse(wait.step([room("a", .idle)], now: start + 3 + QuitWait.settle - 0.5))
        XCTAssertTrue(wait.step([room("a", .idle)], now: start + 3 + QuitWait.settle))
    }
}
