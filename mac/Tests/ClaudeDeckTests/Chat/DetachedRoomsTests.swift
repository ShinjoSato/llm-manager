import XCTest
@testable import MonitorKit

final class DetachedRoomsTests: XCTestCase {
    private typealias Rooms = DetachedRooms<String>

    func testOpeningTheSameRoomTwiceReusesTheWindow() {
        var rooms = Rooms()
        let first = rooms.open("a")
        XCTAssertTrue(first.isNew)
        let second = rooms.open("a")
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.token, first.token)
        XCTAssertEqual(rooms.rooms, ["a"])
    }

    func testRoomsKeepTheOpeningOrderAndCanBeLookedUpBothWays() {
        var rooms = Rooms()
        let a = UUID(), b = UUID()
        rooms.open("a", token: a)
        rooms.open("b", token: b)
        XCTAssertEqual(rooms.rooms, ["a", "b"])
        XCTAssertEqual(rooms.token(for: "b"), b)
        XCTAssertEqual(rooms.room(for: a), "a")
        XCTAssertNil(rooms.room(for: UUID()))
        XCTAssertNil(rooms.token(for: "c"))
    }

    func testClosingForgetsOnlyThatWindow() {
        var rooms = Rooms()
        let a = rooms.open("a").token
        rooms.open("b")
        rooms.close(a)
        XCTAssertEqual(rooms.rooms, ["b"])
        XCTAssertNil(rooms.room(for: a))
        // 閉じた後は同じルームを新しいウィンドウで開き直せる。
        let reopened = rooms.open("a")
        XCTAssertTrue(reopened.isNew)
        XCTAssertNotEqual(reopened.token, a)
        rooms.close(UUID())
        XCTAssertEqual(rooms.rooms, ["b", "a"])
    }

    func testRetargetKeepsTheWindowAndShowsTheNewRoom() {
        var rooms = Rooms()
        let token = rooms.open("external").token
        XCTAssertNil(rooms.retarget(from: "external", to: "hosted"))
        XCTAssertEqual(rooms.room(for: token), "hosted")
        XCTAssertNil(rooms.token(for: "external"))
    }

    func testRetargetOntoAnAlreadyOpenRoomAsksToCloseTheOldWindow() {
        var rooms = Rooms()
        let old = rooms.open("external").token
        let kept = rooms.open("hosted").token
        XCTAssertEqual(rooms.retarget(from: "external", to: "hosted"), old)
        XCTAssertEqual(rooms.rooms, ["hosted"])
        XCTAssertEqual(rooms.token(for: "hosted"), kept)
    }

    func testRetargetOfARoomThatIsNotOpenDoesNothing() {
        var rooms = Rooms()
        rooms.open("a")
        XCTAssertNil(rooms.retarget(from: "b", to: "c"))
        XCTAssertNil(rooms.retarget(from: "a", to: "a"))
        XCTAssertEqual(rooms.rooms, ["a"])
    }

    func testShownSessionsPutTheMainFirstAndDropDuplicatesAndMissing() {
        XCTAssertEqual(ShownSessions.sessionIds(main: "m", detached: ["x", nil, "m", "y", "x"]), ["m", "x", "y"])
        XCTAssertEqual(ShownSessions.sessionIds(main: nil, detached: ["x"]), ["x"])
        XCTAssertEqual(ShownSessions.sessionIds(main: nil, detached: []), [])
    }

    func testRetentionKeepsRecentLoadingAndPinnedSessions() {
        let keep = TranscriptRetention.keep(recent: ["a", "b", "c", "d", "e"], kept: 2, loading: ["b"], pinned: ["a", "z"])
        XCTAssertEqual(keep, ["d", "e", "b", "a", "z"])
    }

    func testRetentionKeepsPinnedEvenBeyondTheLimit() {
        let pinned: Set<String> = ["p1", "p2", "p3", "p4", "p5"]
        let keep = TranscriptRetention.keep(recent: ["a", "p1"], kept: 1, loading: [], pinned: pinned)
        XCTAssertEqual(keep, pinned)
        XCTAssertEqual(TranscriptRetention.keep(recent: ["a"], kept: 0, loading: [], pinned: []), [])
    }
}
