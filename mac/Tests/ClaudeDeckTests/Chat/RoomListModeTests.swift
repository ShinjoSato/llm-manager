import XCTest
@testable import MonitorKit

final class RoomListModeTests: XCTestCase {
    func testSavedValueFallsBackToRooms() {
        XCTAssertEqual(RoomListMode(saved: nil), .rooms)
        XCTAssertEqual(RoomListMode(saved: "unknown"), .rooms)
        XCTAssertEqual(RoomListMode(saved: "rooms"), .rooms)
        XCTAssertEqual(RoomListMode(saved: "directories"), .directories)
    }

    func testAttentionCountCountsPermissionAndWaiting() {
        XCTAssertEqual(RoomListMode.attentionCount([.permission, .waiting, .working, .idle, .error, .stopped, .unknown]), 2)
        XCTAssertEqual(RoomListMode.attentionCount([]), 0)
    }

    func testRoomsModeGroupsByPhaseInOrder() {
        let keys = [
            RoomKey(id: "a", name: "a", status: .idle, activityAt: 30, searchText: ""),
            RoomKey(id: "b", name: "b", status: .working, activityAt: 10, searchText: ""),
            RoomKey(id: "c", name: "c", status: .permission, activityAt: 5, searchText: ""),
            RoomKey(id: "d", name: "d", status: .working, activityAt: 20, searchText: ""),
        ]
        XCTAssertEqual(RoomGrouping.entries(RoomGrouping.group(keys)), [
            .header(.attention, count: 1), .row("c"),
            .header(.active, count: 2), .row("d"), .row("b"),
            .header(.idle, count: 1), .row("a"),
        ])
    }
}
