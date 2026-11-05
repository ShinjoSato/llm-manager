import XCTest
@testable import MonitorKit

final class ClosedConversationsTests: XCTestCase {
    private func snapshot(_ sessionId: String, pid: Int32, alive: Bool, startedAt: Double = 1_000) -> SessionSnapshot {
        SessionSnapshot(sessionId: sessionId, pid: pid, alive: alive, name: "app", project: "app", cwd: "/tmp/app", branch: nil,
                        title: nil, lastPrompt: nil, status: alive ? .idle : .stopped, statusSource: .inventory,
                        statusDetail: nil, entrypoint: nil, version: nil, startedAt: startedAt, lastActivityAt: nil,
                        currentTool: nil, currentSkill: nil, currentAction: nil, tokens: nil, agents: [],
                        canReceive: alive, xcodeProject: nil)
    }

    private func closed(sessionId: String? = "a", pid: Int32? = 100, at closedAt: Double = 10_000,
                        endedAt: Double? = nil) -> ClosedConversations {
        var closed = ClosedConversations()
        closed.remember(sessionId: sessionId, pid: pid, closedAt: closedAt, endedAt: endedAt)
        return closed
    }

    private let soon: Double = 11_000

    func testHidesStoppedTombstoneOfClosedConversation() {
        XCTAssertTrue(closed().hides(snapshot("a", pid: 100, alive: false), now: soon))
    }

    func testHidesClosedProcessWhileItIsStillExiting() {
        XCTAssertTrue(closed().hides(snapshot("a", pid: 100, alive: true), now: soon))
    }

    func testHidesConversationBeforeClearByPid() {
        XCTAssertTrue(closed().hides(snapshot("before-clear", pid: 100, alive: false), now: soon))
    }

    func testShowsConversationResumedElsewhere() {
        XCTAssertFalse(closed().hides(snapshot("a", pid: 200, alive: true, startedAt: 20_000), now: soon))
    }

    func testShowsTombstoneOfConversationResumedElsewhereAfterClosing() {
        XCTAssertFalse(closed().hides(snapshot("a", pid: 200, alive: false, startedAt: 20_000), now: soon))
    }

    func testPidReusedAfterEarlierExitIsAnotherProcess() {
        let closed = closed(at: 10_000, endedAt: 5_000)
        XCTAssertFalse(closed.hides(snapshot("other", pid: 100, alive: true, startedAt: 7_000), now: soon))
        XCTAssertTrue(closed.hides(snapshot("a", pid: 100, alive: false, startedAt: 1_000), now: soon))
    }

    func testUnknownStartTimeIsNotMatchedByPid() {
        XCTAssertFalse(closed().hides(snapshot("other", pid: 100, alive: true, startedAt: 0), now: soon))
        XCTAssertTrue(closed().hides(snapshot("a", pid: 100, alive: false, startedAt: 0), now: soon))
    }

    func testShowsClosedProcessThatOutlivesGrace() {
        let later = 10_000 + ClosedConversations.grace + 1
        XCTAssertFalse(closed().hides(snapshot("a", pid: 100, alive: true), now: later))
        XCTAssertTrue(closed().hides(snapshot("a", pid: 100, alive: false), now: later))
    }

    func testReusedPidAfterClosingIsAnotherProcess() {
        XCTAssertFalse(closed().hides(snapshot("other", pid: 100, alive: true, startedAt: 20_000), now: soon))
        XCTAssertFalse(closed().hides(snapshot("other", pid: 100, alive: false, startedAt: 20_000), now: soon))
    }

    func testUnrelatedSessionsAreShown() {
        XCTAssertFalse(closed().hides(snapshot("b", pid: 300, alive: false), now: soon))
        XCTAssertFalse(ClosedConversations().hides(snapshot("a", pid: 100, alive: false), now: soon))
    }

    func testSessionIdOnlyStillHidesTombstone() {
        let closed = closed(pid: nil)
        XCTAssertTrue(closed.hides(snapshot("a", pid: 100, alive: false), now: soon))
        XCTAssertFalse(closed.hides(snapshot("a", pid: 100, alive: true), now: soon))
    }

    func testNothingToRememberWithoutSessionIdOrPid() {
        XCTAssertTrue(closed(sessionId: nil, pid: nil).isEmpty)
    }

    func testPruneKeepsWhileTombstoneRemains() {
        var closed = closed()
        closed.prune(sessions: [snapshot("a", pid: 100, alive: false)], now: 10_000 + ClosedConversations.grace + 1)
        XCTAssertFalse(closed.isEmpty)
    }

    func testPruneForgetsAfterTombstoneExpires() {
        var closed = closed()
        closed.prune(sessions: [snapshot("b", pid: 300, alive: true)], now: 10_000 + ClosedConversations.grace + 1)
        XCTAssertTrue(closed.isEmpty)
    }

    func testPruneWaitsForGraceBeforeTombstoneAppears() {
        var closed = closed()
        closed.prune(sessions: [], now: 10_000 + ClosedConversations.grace)
        XCTAssertFalse(closed.isEmpty)
    }
}
