import XCTest
@testable import MonitorKit

final class LinkOverviewTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private let a = ManagedProject(name: "mirio", path: "/p/mirio", links: [
        ProjectLink(name: "Stripe", url: "https://dashboard.stripe.com", kind: .billing, reminderDay: 1),
        ProjectLink(name: "Bad", url: "ftp://x", kind: .billing, reminderDay: 1),
        ProjectLink(name: "LP", url: "https://mirio.example", pinned: true, note: "本番"),
        ProjectLink(name: "Stripe", url: "https://dup.example", kind: .docs),
        ProjectLink(name: "Docs", url: "https://docs.example", kind: .docs, reminderDay: 15),
    ])
    private let b = ManagedProject(name: "infra", path: "/p/infra", status: .paused, links: [
        ProjectLink(name: "Console", url: "https://console.example", kind: .dashboard, reminderDay: 5),
    ])
    private let c = ManagedProject(name: "none", path: "/p/none")

    private func build(visits: LinkVisits = LinkVisits(), filter: ProjectLinkKind? = nil, dueOnly: Bool = false, today: Date? = nil) -> LinkOverview {
        LinkOverview.build(projects: [a, b, c], visits: visits, today: today ?? date(2026, 10, 8), calendar: calendar, filter: filter, dueOnly: dueOnly)
    }

    func testSectionsFollowSettingsOrderAndSkipProjectsWithoutOpenableLinks() {
        let overview = build()
        XCTAssertEqual(overview.sections.map(\.project.name), ["mirio", "infra"])
        // 開けないもの・同じ名前の後のものは出さず、位置は元の `links` の中のもの。
        XCTAssertEqual(overview.sections[0].rows.map(\.link.name), ["Stripe", "LP", "Docs"])
        XCTAssertEqual(overview.sections[0].rows.map(\.index), [0, 2, 4])
        XCTAssertEqual(overview.sections[0].rows.map(\.id), [0, 2, 4].map { "\(a.id.uuidString)|\($0)" })
        XCTAssertEqual(overview.sections[1].rows.map(\.link.name), ["Console"])
    }

    func testDueCountCountsUnrecordedRemindersAcrossAllProjects() {
        let overview = build()
        // Stripe（1 日）・Console（5 日）は 10/8 時点で期日を過ぎて未記録。Docs（15 日）は先月分が未記録なので due。
        XCTAssertEqual(overview.dueCount, 3)
        XCTAssertEqual(overview.sections[0].rows.map(\.due), [true, false, true])
        XCTAssertEqual(overview.sections[1].rows.map(\.due), [true])
        XCTAssertTrue(overview.sections[0].rows.allSatisfy { $0.lastOpened == nil })
    }

    func testVisitsClearDueAndAreReportedPerRow() {
        var visits = LinkVisits()
        visits.record(projectID: a.id, url: "https://dashboard.stripe.com", at: date(2026, 10, 2))
        visits.record(projectID: a.id, url: "https://docs.example", at: date(2026, 9, 20))
        visits.record(projectID: b.id, url: "https://console.example", at: date(2026, 10, 1))
        let overview = build(visits: visits)
        XCTAssertEqual(overview.sections[0].rows.map(\.due), [false, false, false])
        XCTAssertEqual(overview.sections[0].rows[0].lastOpened, date(2026, 10, 2))
        // 5 日の期日より前にしか開いていない。
        XCTAssertEqual(overview.sections[1].rows.map(\.due), [true])
        XCTAssertEqual(overview.dueCount, 1)
    }

    func testFilterByKindKeepsDueCountOfAll() {
        let billing = build(filter: .billing)
        XCTAssertEqual(billing.sections.map(\.project.name), ["mirio"])
        XCTAssertEqual(billing.sections[0].rows.map(\.link.name), ["Stripe"])
        XCTAssertEqual(billing.dueCount, 3)
        // 種類の無いものは「その他」。
        let other = build(filter: .other)
        XCTAssertEqual(other.sections[0].rows.map(\.link.name), ["LP"])
        XCTAssertEqual(build(filter: .store).sections, [])
    }

    func testDueOnlyDropsRowsAndEmptySections() {
        var visits = LinkVisits()
        visits.record(projectID: b.id, url: "https://console.example", at: date(2026, 10, 6))
        let overview = build(visits: visits, dueOnly: true)
        XCTAssertEqual(overview.sections.map(\.project.name), ["mirio"])
        XCTAssertEqual(overview.sections[0].rows.map(\.link.name), ["Stripe", "Docs"])
        XCTAssertEqual(overview.dueCount, 2)
        XCTAssertEqual(build(visits: visits, filter: .dashboard, dueOnly: true).sections, [])
    }

    func testHasDueAndDuplicateProjectIDs() {
        XCTAssertTrue(LinkOverview.hasDue(a, visits: LinkVisits(), today: date(2026, 10, 8), calendar: calendar))
        XCTAssertFalse(LinkOverview.hasDue(c, visits: LinkVisits(), today: date(2026, 10, 8), calendar: calendar))
        var visits = LinkVisits()
        visits.record(projectID: a.id, url: "https://dashboard.stripe.com", at: date(2026, 10, 2))
        visits.record(projectID: a.id, url: "https://docs.example", at: date(2026, 10, 2))
        XCTAssertFalse(LinkOverview.hasDue(a, visits: visits, today: date(2026, 10, 8), calendar: calendar))
        // 同じ id が重なっていても節は 1 つ。
        let doubled = LinkOverview.build(projects: [a, a], visits: LinkVisits(), today: date(2026, 10, 8), calendar: calendar)
        XCTAssertEqual(doubled.sections.count, 1)
        XCTAssertEqual(doubled.dueCount, 2)
        XCTAssertEqual(LinkOverview.dueCount(projects: [a, b], visits: LinkVisits(), today: date(2026, 10, 8), calendar: calendar), 3)
    }
}
