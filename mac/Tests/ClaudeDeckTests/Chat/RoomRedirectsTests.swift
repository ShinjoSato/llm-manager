import XCTest
@testable import MonitorKit

final class RoomRedirectsTests: XCTestCase {
    private typealias Redirects = RoomRedirects<String, Int>

    func testWithoutRedirectTheResultStaysWhereItArrived() {
        var redirects = Redirects()
        XCTAssertEqual(redirects.resolve(1, arrivedAt: "external"), "external")
        XCTAssertTrue(redirects.isEmpty)
    }

    func testMovedJobsAreDeliveredToTheNewRoomAndForgottenOnceArrived() {
        var redirects = Redirects()
        redirects.redirect([1, 2], to: "hosted")
        XCTAssertEqual(redirects.count, 2)

        XCTAssertEqual(redirects.resolve(1, arrivedAt: "external"), "hosted")
        XCTAssertEqual(redirects.count, 1)
        XCTAssertFalse(redirects.isEmpty)

        XCTAssertEqual(redirects.resolve(2, arrivedAt: "external"), "hosted")
        XCTAssertTrue(redirects.isEmpty)
        // 届いた結果は 1 回限りなので、同じ id がもう一度来ても付け替えない。
        XCTAssertEqual(redirects.resolve(1, arrivedAt: "external"), "external")
    }

    func testJobsStartedAfterTheMoveAreNotRedirected() {
        var redirects = Redirects()
        redirects.redirect([1], to: "hosted")
        XCTAssertEqual(redirects.resolve(2, arrivedAt: "external"), "external")
        XCTAssertEqual(redirects.count, 1)
    }

    func testMovingAgainUsesTheLatestDestination() {
        var redirects = Redirects()
        redirects.redirect([1, 2], to: "first")
        redirects.redirect([2], to: "second")
        XCTAssertEqual(redirects.resolve(1, arrivedAt: "external"), "first")
        XCTAssertEqual(redirects.resolve(2, arrivedAt: "external"), "second")
        XCTAssertTrue(redirects.isEmpty)
    }

    func testEmptyMoveChangesNothing() {
        var redirects = Redirects()
        redirects.redirect([Int](), to: "hosted")
        XCTAssertEqual(redirects, Redirects())
    }
}
