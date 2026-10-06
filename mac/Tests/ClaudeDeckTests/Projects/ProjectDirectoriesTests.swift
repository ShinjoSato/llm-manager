import XCTest
@testable import MonitorKit

final class ProjectDirectoriesTests: XCTestCase {
    private func project(_ name: String, _ path: String, _ status: ProjectStatus = .active) -> ManagedProject {
        ManagedProject(name: name, path: path, status: status)
    }

    private func room(_ id: String, _ cwd: String, _ status: SessionStatus = .idle, at: Double? = nil) -> ProjectRoomKey {
        ProjectRoomKey(key: RoomKey(id: id, name: id, status: status, activityAt: at, searchText: ""), cwd: cwd)
    }

    func testActiveFirstThenInactiveKeepingSettingsOrder() {
        let projects = [project("p1", "/p/1", .paused), project("b", "/p/b"), project("ar", "/p/ar", .archived), project("a", "/p/a")]
        let list = ProjectDirectories.directories(projects: projects, rooms: [])
        XCTAssertEqual(list.map(\.project.name), ["b", "a", "p1", "ar"])
        XCTAssertTrue(list.allSatisfy { $0.ids.isEmpty && $0.liveCount == 0 && $0.urgentStatus == nil })
    }

    func testRoomsGoToDeepestProjectEvenWhenInactive() {
        let projects = [project("root", "/p"), project("app", "/p/app", .paused)]
        let rooms = [room("x", "/p/app/ios"), room("y", "/p/docs"), room("z", "/elsewhere")]
        let list = ProjectDirectories.directories(projects: projects, rooms: rooms)
        XCTAssertEqual(list.map(\.project.name), ["root", "app"])
        XCTAssertEqual(list.map(\.ids), [["y"], ["x"]])
    }

    func testCountAndUrgentStatusIgnoreStoppedRooms() {
        let a = project("a", "/p/a")
        let rooms = [room("s", "/p/a", .stopped, at: 9), room("w", "/p/a", .working, at: 1), room("i", "/p/a", .idle, at: 5)]
        let directory = ProjectDirectories.directories(projects: [a], rooms: rooms)[0]
        XCTAssertEqual(directory.liveCount, 2)
        XCTAssertEqual(directory.urgentStatus, .working)
        XCTAssertEqual(directory.ids, ["w", "s", "i"])

        let onlyStopped = ProjectDirectories.directories(projects: [a], rooms: [room("s", "/p/a", .stopped)])[0]
        XCTAssertEqual(onlyStopped.liveCount, 0)
        XCTAssertNil(onlyStopped.urgentStatus)
        XCTAssertEqual(onlyStopped.ids, ["s"])
    }

    func testUrgentStatusPrefersPermissionThenWaitingThenError() {
        let a = project("a", "/p/a")
        func urgent(_ statuses: [SessionStatus]) -> SessionStatus? {
            let rooms = statuses.enumerated().map { room("\($0.offset)", "/p/a", $0.element) }
            return ProjectDirectories.directories(projects: [a], rooms: rooms)[0].urgentStatus
        }
        XCTAssertEqual(urgent([.waiting, .permission]), .permission)
        XCTAssertEqual(urgent([.working, .error, .waiting]), .waiting)
        XCTAssertEqual(urgent([.working, .error]), .error)
        XCTAssertEqual(urgent([.idle, .working]), .working)
    }

    func testOrderInsideDirectoryIsAttentionActiveIdleThenRecent() {
        let rooms = [room("idle", "/p/a", .idle, at: 9), room("work", "/p/a", .working, at: 1),
                     room("perm", "/p/a", .permission, at: 0), room("work2", "/p/a", .working, at: 5)]
        let directory = ProjectDirectories.directories(projects: [project("a", "/p/a")], rooms: rooms)[0]
        XCTAssertEqual(directory.ids, ["perm", "work2", "work", "idle"])
    }

    func testDuplicateProjectIdsMakeOneRow() {
        let a = project("a", "/p/a")
        XCTAssertEqual(ProjectDirectories.directories(projects: [a, a], rooms: []).count, 1)
    }

    func testFilterMatchesNameAndPathWithAllTerms() {
        let list = ProjectDirectories.directories(projects: [project("Mirio", "/Users/me/project/mirio"),
                                                             project("blog", "/Users/me/sites/blog")], rooms: [])
        XCTAssertEqual(ProjectDirectories.filter(list, query: "mirio").map(\.project.name), ["Mirio"])
        XCTAssertEqual(ProjectDirectories.filter(list, query: "sites").map(\.project.name), ["blog"])
        XCTAssertEqual(ProjectDirectories.filter(list, query: "me blog").map(\.project.name), ["blog"])
        XCTAssertEqual(ProjectDirectories.filter(list, query: "ＭＩＲＩＯ").map(\.project.name), ["Mirio"])
        XCTAssertTrue(ProjectDirectories.filter(list, query: "nothing").isEmpty)
        XCTAssertEqual(ProjectDirectories.filter(list, query: "  ").count, 2)
    }

    func testEntriesPutInactiveUnderHeader() {
        let a = project("a", "/p/a"), p = project("p", "/p/p", .paused), b = project("b", "/p/b")
        let entries = ProjectDirectories.entries(ProjectDirectories.directories(projects: [a, p, b], rooms: []))
        XCTAssertEqual(entries.map(\.id), ["d-\(a.id.uuidString)", "d-\(b.id.uuidString)", "inactive", "d-\(p.id.uuidString)"])
        XCTAssertEqual(entries[2], .inactiveHeader(count: 1))
    }

    func testEntriesOmitHeaderWithoutInactive() {
        let a = project("a", "/p/a")
        XCTAssertEqual(ProjectDirectories.entries(ProjectDirectories.directories(projects: [a], rooms: [])).map(\.id),
                       ["d-\(a.id.uuidString)"])
        XCTAssertTrue(ProjectDirectories.entries([]).isEmpty)
    }

    func testPathTail() {
        XCTAssertEqual(ProjectDirectories.pathTail("/Users/me/project/ai-manager"), "…/project/ai-manager")
        XCTAssertEqual(ProjectDirectories.pathTail("/project/ai-manager/"), "/project/ai-manager")
        XCTAssertEqual(ProjectDirectories.pathTail("/tmp"), "/tmp")
        XCTAssertEqual(ProjectDirectories.pathTail("/"), "/")
    }
}
