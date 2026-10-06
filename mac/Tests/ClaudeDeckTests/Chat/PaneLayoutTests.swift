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
        // つかんだ時の中央に 500pt あれば 80pt まで広げられる。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 50, centerWidth: 500), 362)
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 150, centerWidth: 500), 392)
        // 中央が最小幅なら広げない。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 40, centerWidth: 420), 312)
        // 広いウィンドウでも最大を超えない。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: 400, centerWidth: 2000), 480)
        // 数でない移動量はつかんだ時の幅のまま。
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: .nan, centerWidth: 500), 312)
    }

    func testDragNarrowsDownToMinimum() {
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: -40, centerWidth: 420), 272)
        XCTAssertEqual(ListPaneWidth.dragged(start: 312, translation: -200, centerWidth: 420), 240)
        // 中央が最小幅を割っていても狭める方向は通す。
        XCTAssertEqual(ListPaneWidth.dragged(start: 400, translation: -30, centerWidth: 300), 370)
    }

    func testDragStateKeepsStageWidthUntilReleased() {
        var drag = ListPaneDrag(startWidth: 312, centerWidth: 500)
        for translation in stride(from: -100.0, through: 200, by: 10) {
            drag.move(translation: translation)
            XCTAssertEqual(drag.widthForStage, 312)
        }
        // 最後の移動量で決まり、広げる上限はつかんだ時の中央の余りで決まる。
        XCTAssertEqual(drag.width, 392)
        drag.move(translation: -20)
        XCTAssertEqual(drag.width, 292)
    }

    func testStageDoesNotFlipWhileDraggingAndStaysOpenAfterWidestDrag() {
        // パネルを開いたまま中央に少し余りがあるウィンドウ。
        let window: CGFloat = 1180
        let start: Double = 312
        let center = Double(window - StageLogic.chromeWidth) - start + ListPaneWidth.centerMinimum
        var drag = ListPaneDrag(startWidth: start, centerWidth: center)
        for translation in stride(from: -80.0, through: 300, by: 5) {
            drag.move(translation: translation)
            XCTAssertTrue(StageLogic.isExpanded(preference: true, windowWidth: window,
                                                listWidth: CGFloat(drag.widthForStage), openedWhileNarrow: false))
        }
        // いちばん広げて離しても、畳む幅の判定と広げる上限が揃っているのでパネルは開いたまま。
        drag.move(translation: 300)
        XCTAssertEqual(drag.width, Double(window - StageLogic.chromeWidth))
        XCTAssertTrue(StageLogic.isExpanded(preference: true, windowWidth: window,
                                            listWidth: CGFloat(drag.width), openedWhileNarrow: false))
    }

    func testResetReturnsToStandardWithinCenterSlack() {
        XCTAssertEqual(ListPaneWidth.reset(from: 400, centerWidth: 420), 312)
        XCTAssertEqual(ListPaneWidth.reset(from: 260, centerWidth: 1000), 312)
        // 中央に余りが 20pt しか無ければそこまで。
        XCTAssertEqual(ListPaneWidth.reset(from: 260, centerWidth: 440), 280)
        XCTAssertEqual(ListPaneWidth.reset(from: 260, centerWidth: 420), 260)
    }

    func testWindowMinimumKeepsCenterMinimum() {
        XCTAssertEqual(ListPaneWidth.minimumWindowWidth(listWidth: 312), 87 + 312 + 420)
        XCTAssertEqual(ListPaneWidth.minimumWindowWidth(listWidth: 900), 87 + 480 + 420)
    }

    func testFittedShrinksOnlyForNarrowWindow() {
        XCTAssertEqual(ListPaneWidth.fitted(400, windowWidth: nil), 400)
        XCTAssertEqual(ListPaneWidth.fitted(400, windowWidth: 1400), 400)
        // 狭いウィンドウでは中央 420 を保てる幅まで縮め、一覧の最小は割らない。
        XCTAssertEqual(ListPaneWidth.fitted(400, windowWidth: 800), 800 - 87 - 420)
        XCTAssertEqual(ListPaneWidth.fitted(400, windowWidth: 600), 240)
        XCTAssertEqual(ListPaneWidth.fitted(.nan, windowWidth: .infinity), 312)
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
