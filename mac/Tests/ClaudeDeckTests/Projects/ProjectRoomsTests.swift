import XCTest
@testable import MonitorKit

final class ProjectRoomsTests: XCTestCase {
    private func project(_ name: String, _ path: String, _ status: ProjectStatus = .active) -> ManagedProject {
        ManagedProject(name: name, path: path, status: status)
    }

    private func room(_ id: String, _ cwd: String, _ status: SessionStatus = .idle, at: Double? = nil,
                      text: String = "") -> ProjectRoomKey {
        ProjectRoomKey(key: RoomKey(id: id, name: id, status: status, activityAt: at, searchText: text), cwd: cwd)
    }

    func testActiveProjectsAppearInSettingsOrderEvenWithoutRooms() {
        let projects = [project("b", "/p/b"), project("a", "/p/a"), project("c", "/p/c", .paused), project("d", "/p/d", .archived)]
        let sections = ProjectRoomGrouping.sections(projects: projects, rooms: [])
        XCTAssertEqual(sections.map(\.name), ["b", "a"])
        XCTAssertTrue(sections.allSatisfy { $0.ids.isEmpty && $0.urgentStatus == nil })
    }

    func testRoomsGoToDeepestProjectAndOthersLast() {
        let projects = [project("root", "/p"), project("app", "/p/app")]
        let rooms = [room("x", "/p/app/ios"), room("y", "/p/docs"), room("z", "/elsewhere")]
        let sections = ProjectRoomGrouping.sections(projects: projects, rooms: rooms)
        XCTAssertEqual(sections.map(\.name), ["root", "app", "その他"])
        XCTAssertEqual(sections.map(\.ids), [["y"], ["x"], ["z"]])
        XCTAssertTrue(sections[2].isOther)
        XCTAssertEqual(sections[2].id, ProjectRoomSection.otherId)
    }

    func testOtherSectionOmittedWhenEmpty() {
        let sections = ProjectRoomGrouping.sections(projects: [project("a", "/p/a")], rooms: [room("x", "/p/a")])
        XCTAssertEqual(sections.map(\.name), ["a"])
    }

    func testRoomsUnderInactiveProjectGoToOther() {
        let projects = [project("a", "/p/a", .paused)]
        let sections = ProjectRoomGrouping.sections(projects: projects, rooms: [room("x", "/p/a")])
        XCTAssertEqual(sections.map(\.name), ["その他"])
    }

    func testOrderInsideSectionIsAttentionActiveIdleThenRecent() {
        let rooms = [room("idle", "/p/a", .idle, at: 9), room("work", "/p/a", .working, at: 1),
                     room("perm", "/p/a", .permission, at: 0), room("work2", "/p/a", .working, at: 5)]
        let section = ProjectRoomGrouping.sections(projects: [project("a", "/p/a")], rooms: rooms)[0]
        XCTAssertEqual(section.ids, ["perm", "work2", "work", "idle"])
        XCTAssertEqual(section.urgentStatus, .permission)
    }

    func testUrgentStatusPrefersPermissionThenWaitingThenError() {
        let a = project("a", "/p/a")
        XCTAssertEqual(ProjectRoomGrouping.sections(projects: [a], rooms: [room("1", "/p/a", .waiting), room("2", "/p/a", .permission)])[0].urgentStatus, .permission)
        XCTAssertEqual(ProjectRoomGrouping.sections(projects: [a], rooms: [room("1", "/p/a", .working), room("2", "/p/a", .error)])[0].urgentStatus, .error)
        XCTAssertEqual(ProjectRoomGrouping.sections(projects: [a], rooms: [room("1", "/p/a", .stopped), room("2", "/p/a", .idle)])[0].urgentStatus, .idle)
    }

    func testSearchKeepsOnlySectionsWithMatches() {
        let projects = [project("a", "/p/a"), project("b", "/p/b")]
        let rooms = [room("x", "/p/a", text: "feature/login"), room("y", "/p/b"), room("z", "/q")]
        let sections = ProjectRoomGrouping.sections(projects: projects, rooms: rooms, query: "LOGIN")
        XCTAssertEqual(sections.map(\.name), ["a"])
        XCTAssertTrue(ProjectRoomGrouping.sections(projects: projects, rooms: rooms, query: "nothing").isEmpty)
        XCTAssertEqual(ProjectRoomGrouping.sections(projects: projects, rooms: rooms, query: "  ").count, 3)
    }

    func testDuplicateProjectIdsMakeOneSection() {
        let a = project("a", "/p/a")
        XCTAssertEqual(ProjectRoomGrouping.sections(projects: [a, a], rooms: []).count, 1)
    }

    func testEntriesShowEmptyRowsAndHideCollapsed() {
        let a = project("a", "/p/a"), b = project("b", "/p/b"), c = project("c", "/p/c")
        let sections = ProjectRoomGrouping.sections(projects: [a, b, c],
                                                    rooms: [room("x", "/p/a", at: 2), room("y", "/p/a", at: 1), room("z", "/p/c")])
        let entries = ProjectRoomGrouping.entries(sections, collapsed: [c.id.uuidString])
        XCTAssertEqual(entries.map(\.id), ["p-\(a.id.uuidString)", "r-x", "r-y",
                                           "p-\(b.id.uuidString)", "e-\(b.id.uuidString)",
                                           "p-\(c.id.uuidString)"])
        XCTAssertEqual(entries[1], .row("x", sectionId: a.id.uuidString, last: false))
        XCTAssertEqual(entries[2], .row("y", sectionId: a.id.uuidString, last: true))
        XCTAssertEqual(entries[5], .header(sections[2], collapsed: true))
    }

    func testSearchOpensCollapsedSections() {
        let a = project("a", "/p/a")
        let sections = ProjectRoomGrouping.sections(projects: [a], rooms: [room("x", "/p/a")], query: "x")
        let entries = ProjectRoomGrouping.entries(sections, collapsed: [a.id.uuidString], query: "x")
        XCTAssertEqual(entries.map(\.id), ["p-\(a.id.uuidString)", "r-x"])
    }

    func testRowIdStaysWhenRoomMovesBetweenSections() {
        let a = project("a", "/p/a"), b = project("b", "/p/b")
        let before = ProjectRoomGrouping.entries(ProjectRoomGrouping.sections(projects: [a, b], rooms: [room("x", "/p/a")]), collapsed: [])
        let after = ProjectRoomGrouping.entries(ProjectRoomGrouping.sections(projects: [a, b], rooms: [room("x", "/p/b")]), collapsed: [])
        XCTAssertTrue(before.map(\.id).contains("r-x"))
        XCTAssertTrue(after.map(\.id).contains("r-x"))
        XCTAssertTrue(after.map(\.id).contains("e-\(a.id.uuidString)"))
    }
}
