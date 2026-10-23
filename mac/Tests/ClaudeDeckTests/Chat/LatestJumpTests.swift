import XCTest
@testable import MonitorKit

final class LatestJumpTests: XCTestCase {
    private func entry(_ id: String, _ role: ChatEntry.Role = .assistant) -> ChatEntry {
        ChatEntry(id: id, role: role, text: "本文", at: nil, tools: [])
    }

    // MARK: - 段の判定

    func testWithinToleranceIsBottom() {
        XCTAssertEqual(LatestJump.zone(contentHeight: 2000, offsetY: 1400, viewportHeight: 600), .bottom)
        XCTAssertEqual(LatestJump.zone(contentHeight: 2000, offsetY: 1352, viewportHeight: 600), .bottom)
    }

    func testShortContentIsBottom() {
        XCTAssertEqual(LatestJump.zone(contentHeight: 300, offsetY: 0, viewportHeight: 600), .bottom)
    }

    func testShowDistanceIsHalfTheViewportButNeverBelowTheMinimum() {
        XCTAssertEqual(LatestJump.showDistance(viewportHeight: 1000), 500)
        XCTAssertEqual(LatestJump.showDistance(viewportHeight: 200), LatestJump.minimumShowDistance)
    }

    func testBetweenToleranceAndShowDistanceIsNear() {
        // 離れ 300pt・1 画面 800pt の半分 400pt まで届かない。
        XCTAssertEqual(LatestJump.zone(contentHeight: 3000, offsetY: 1900, viewportHeight: 800), .near)
        // 離れ 401pt で出す。
        XCTAssertEqual(LatestJump.zone(contentHeight: 3000, offsetY: 1799, viewportHeight: 800), .far)
    }

    func testSmallViewportUsesTheMinimumDistance() {
        // 1 画面 200pt でも、離れ 150pt では出さない。
        XCTAssertEqual(LatestJump.zone(contentHeight: 2000, offsetY: 1650, viewportHeight: 200), .near)
        XCTAssertEqual(LatestJump.zone(contentHeight: 2000, offsetY: 1500, viewportHeight: 200), .far)
    }

    // MARK: - 出す / 消す

    private func items(_ ids: String...) -> [ChatEntry] {
        ids.map { id in id.hasPrefix("outgoing:") ? entry(id, .outgoing) : entry(id) }
    }

    func testShowsOnlyAfterGoingFarAndHidesBackAtBottom() {
        var jump = LatestJump()
        XCTAssertFalse(jump.showsButton)
        XCTAssertTrue(jump.followsBottom)
        jump.enter(.near, entries: items("a"))
        XCTAssertFalse(jump.showsButton)
        XCTAssertFalse(jump.followsBottom)
        jump.enter(.far, entries: items("a"))
        XCTAssertTrue(jump.showsButton)
        jump.enter(.bottom, entries: items("a"))
        XCTAssertFalse(jump.showsButton)
        XCTAssertTrue(jump.followsBottom)
        XCTAssertNil(jump.baseline)
    }

    func testStaysShownWhileWobblingInTheNearBand() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        jump.enter(.near, entries: items("a"))
        XCTAssertTrue(jump.showsButton)
        jump.enter(.far, entries: items("a"))
        jump.enter(.near, entries: items("a"))
        XCTAssertTrue(jump.showsButton)
    }

    func testEnteringTheSameZoneAgainChangesNothing() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        let before = jump
        jump.enter(.far, entries: items("a", "b"))
        XCTAssertEqual(jump, before)
    }

    // MARK: - 押した後の動き

    func testKeepsFollowingWhileJumpingThroughTheMiddleZones() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        jump.startJump()
        XCTAssertFalse(jump.showsButton)
        XCTAssertTrue(jump.followsBottom)
        jump.enter(.near, entries: items("a", "b"))
        XCTAssertTrue(jump.followsBottom)
        XCTAssertNil(jump.baseline)
        jump.enter(.bottom, entries: items("a", "b"))
        XCTAssertNil(jump.jumping)
        XCTAssertTrue(jump.followsBottom)
    }

    func testTimeoutWithoutReachingTheBottomFallsBackToTheCurrentZone() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        let generation = jump.startJump()
        jump.enter(.far, entries: items("a"))
        XCTAssertFalse(jump.showsButton)
        jump.finishJump(generation, entries: items("a", "b"))
        XCTAssertNil(jump.jumping)
        XCTAssertFalse(jump.followsBottom)
        XCTAssertTrue(jump.showsButton)
        XCTAssertEqual(jump.newCount(entries: items("a", "b", "c")), 1)
    }

    func testStaleTimeoutDoesNotEndANewerJump() {
        var jump = LatestJump()
        let first = jump.startJump()
        let second = jump.startJump()
        jump.finishJump(first, entries: items("a"))
        XCTAssertEqual(jump.jumping, second)
    }

    func testTimeoutAfterArrivingDoesNothing() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        let generation = jump.startJump()
        jump.enter(.bottom, entries: items("a"))
        let arrived = jump
        jump.finishJump(generation, entries: items("a"))
        XCTAssertEqual(jump, arrived)
    }

    func testResetFollowsTheBottomAgain() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        jump.reset()
        XCTAssertFalse(jump.showsButton)
        XCTAssertTrue(jump.followsBottom)
        XCTAssertEqual(jump.newCount(entries: items("a", "b")), 0)
    }

    // MARK: - 新着の数

    func testCountsItemsAddedAfterLeavingTheBottom() {
        var jump = LatestJump()
        jump.enter(.near, entries: items("a", "b"))
        // 離れた時点より後に増えた分は、遠くへ行く前に届いても数える。
        jump.enter(.far, entries: items("a", "b", "c"))
        XCTAssertEqual(jump.newCount(entries: items("a", "b", "c", "d")), 2)
    }

    func testCountIsZeroWhileTheButtonIsHidden() {
        var jump = LatestJump()
        jump.enter(.near, entries: items("a"))
        XCTAssertEqual(jump.newCount(entries: items("a", "b")), 0)
    }

    func testReturningToBottomResetsTheCount() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        XCTAssertEqual(jump.newCount(entries: items("a", "b")), 1)
        jump.enter(.bottom, entries: items("a", "b"))
        jump.enter(.far, entries: items("a", "b"))
        XCTAssertEqual(jump.newCount(entries: items("a", "b")), 0)
        XCTAssertEqual(jump.newCount(entries: items("a", "b", "c")), 1)
    }

    func testOutgoingSentAfterLeavingIsCountedOnceEvenWhenReplaced() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a"))
        XCTAssertEqual(jump.newCount(entries: items("a", "outgoing:1")), 1)
        XCTAssertEqual(jump.newCount(entries: items("a", "u1")), 1)
    }

    func testOutgoingSentBeforeLeavingIsNotCountedWhenReplaced() {
        var jump = LatestJump()
        jump.enter(.far, entries: items("a", "outgoing:1"))
        XCTAssertEqual(jump.newCount(entries: items("a", "outgoing:1")), 0)
        // 記録に載って差し替わっただけなので新着ではない。
        XCTAssertEqual(jump.newCount(entries: items("a", "u1")), 0)
        XCTAssertEqual(jump.newCount(entries: items("a", "u1", "m2")), 1)
    }

    func testToolsOnlyRowsAreNotCounted() {
        let ids = LatestJump.countedIds([entry("t", .toolsOnly), entry("u", .user), entry("m"), entry("r", .relay),
                                         entry("o", .outgoing)])
        XCTAssertEqual(ids, ["u", "m", "r", "o"])
    }

    func testBadge() {
        XCTAssertNil(LatestJump.badge(for: 0))
        XCTAssertEqual(LatestJump.badge(for: 3), "3")
        XCTAssertEqual(LatestJump.badge(for: 100), "99+")
    }
}
