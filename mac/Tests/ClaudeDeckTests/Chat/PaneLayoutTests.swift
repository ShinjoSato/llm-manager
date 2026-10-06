import XCTest
@testable import MonitorKit

final class ListPaneWidthTests: XCTestCase {
    func testClampsSavedValue() {
        XCTAssertEqual(ListPaneWidth.clamped(312), 312)
        XCTAssertEqual(ListPaneWidth.clamped(100), 240)
        XCTAssertEqual(ListPaneWidth.clamped(900), 480)
        XCTAssertEqual(ListPaneWidth.clamped(.nan), 312)
        XCTAssertEqual(ListPaneWidth.clamped(.infinity), 312)
    }

    func testDragWidensOnlyWhileCenterKeepsMinimum() {
        // 中央に 500pt あれば 80pt まで広げられる。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 50, current: 312, centerWidth: 500), 362)
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 150, current: 312, centerWidth: 500), 392)
        // 中央が最小幅なら広げない。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 40, current: 312, centerWidth: 420), 312)
        // 広いウィンドウでも最大を超えない。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 400, current: 312, centerWidth: 2000), 480)
    }

    func testDragNarrowsDownToMinimum() {
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: -40, current: 312, centerWidth: 420), 272)
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: -200, current: 312, centerWidth: 420), 240)
        // 中央が最小幅を割っていても狭める方向は通す。
        XCTAssertEqual(ListPaneWidth.dragged(start: 400, translation: -30, current: 400, centerWidth: 300), 370)
    }

    func testDragFollowsCurrentWidthDuringGesture() {
        // ドラッグの途中で中央の余りが減っても、今の幅から先へは広げない。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 120, current: 380, centerWidth: 430), 390)
    }
}

final class HeaderOverflowTests: XCTestCase {
    func testHidesLowestPriorityFirstAndKeepsOrder() {
        let priorities = [5, 2, 4, 1, 3]
        XCTAssertEqual(HeaderOverflow.visibleIndices(priorities: priorities, hiddenCount: 0), [0, 1, 2, 3, 4])
        XCTAssertEqual(HeaderOverflow.hiddenIndices(priorities: priorities, hiddenCount: 1), [3])
        XCTAssertEqual(HeaderOverflow.hiddenIndices(priorities: priorities, hiddenCount: 3), [1, 3, 4])
        XCTAssertEqual(HeaderOverflow.visibleIndices(priorities: priorities, hiddenCount: 3), [0, 2])
        XCTAssertEqual(HeaderOverflow.visibleIndices(priorities: priorities, hiddenCount: 5), [])
    }

    func testSamePriorityHidesRightmostFirst() {
        XCTAssertEqual(HeaderOverflow.hiddenIndices(priorities: [1, 1, 1], hiddenCount: 1), [2])
        XCTAssertEqual(HeaderOverflow.hiddenIndices(priorities: [1, 1, 1], hiddenCount: 2), [1, 2])
    }

    func testOutOfRangeCountsAreClamped() {
        XCTAssertEqual(HeaderOverflow.hiddenIndices(priorities: [1, 2], hiddenCount: -1), [])
        XCTAssertEqual(HeaderOverflow.hiddenIndices(priorities: [1, 2], hiddenCount: 9), [0, 1])
        XCTAssertEqual(HeaderOverflow.visibleIndices(priorities: [], hiddenCount: 1), [])
    }
}
