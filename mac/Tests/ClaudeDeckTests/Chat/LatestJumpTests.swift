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

    func testShowsOnlyAfterGoingFarAndHidesBackAtBottom() {
        var jump = LatestJump()
        XCTAssertFalse(jump.showsButton)
        jump.enter(.near, ids: ["a"])
        XCTAssertFalse(jump.showsButton)
        jump.enter(.far, ids: ["a"])
        XCTAssertTrue(jump.showsButton)
        jump.enter(.bottom, ids: ["a"])
        XCTAssertFalse(jump.showsButton)
        XCTAssertNil(jump.baseline)
    }

    func testStaysShownWhileWobblingInTheNearBand() {
        var jump = LatestJump()
        jump.enter(.far, ids: ["a"])
        jump.enter(.near, ids: ["a"])
        XCTAssertTrue(jump.showsButton)
        jump.enter(.far, ids: ["a"])
        jump.enter(.near, ids: ["a"])
        XCTAssertTrue(jump.showsButton)
    }

    // MARK: - 新着の数

    func testCountsItemsAddedAfterLeavingTheBottom() {
        var jump = LatestJump()
        jump.enter(.near, ids: ["a", "b"])
        // 離れた時点より後に増えた分は、遠くへ行く前に届いても数える。
        jump.enter(.far, ids: ["a", "b", "c"])
        XCTAssertEqual(jump.newCount(ids: ["a", "b", "c", "d"]), 2)
    }

    func testCountIsZeroWhileTheButtonIsHidden() {
        var jump = LatestJump()
        jump.enter(.near, ids: ["a"])
        XCTAssertEqual(jump.newCount(ids: ["a", "b"]), 0)
    }

    func testReturningToBottomResetsTheCount() {
        var jump = LatestJump()
        jump.enter(.far, ids: ["a"])
        XCTAssertEqual(jump.newCount(ids: ["a", "b"]), 1)
        jump.enter(.bottom, ids: ["a", "b"])
        jump.enter(.far, ids: ["a", "b"])
        XCTAssertEqual(jump.newCount(ids: ["a", "b"]), 0)
        XCTAssertEqual(jump.newCount(ids: ["a", "b", "c"]), 1)
    }

    func testResetHidesAndClears() {
        var jump = LatestJump()
        jump.enter(.far, ids: ["a"])
        jump.reset()
        XCTAssertFalse(jump.showsButton)
        XCTAssertEqual(jump.newCount(ids: ["a", "b"]), 0)
    }

    func testReplacedItemIsNotCountedTwice() {
        var jump = LatestJump()
        jump.enter(.far, ids: ["a"])
        XCTAssertEqual(jump.newCount(ids: ["a", "outgoing:1"]), 1)
        // 送信中の発話が記録に載って差し替わっても 1 件のまま。
        XCTAssertEqual(jump.newCount(ids: ["a", "u1"]), 1)
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
