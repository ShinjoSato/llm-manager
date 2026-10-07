import XCTest
@testable import MonitorKit

final class LinkReminderTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    private func status(day: Int?, last: Date?, today: Date) -> LinkReminder.Status {
        LinkReminder.status(reminderDay: day, lastOpened: last, today: today, calendar: calendar)
    }

    func testDueDateClampsToEndOfMonth() {
        XCTAssertEqual(LinkReminder.dueDate(reminderDay: 31, inMonthOf: date(2026, 4, 10), calendar: calendar), date(2026, 4, 30))
        XCTAssertEqual(LinkReminder.dueDate(reminderDay: 31, inMonthOf: date(2026, 2, 1), calendar: calendar), date(2026, 2, 28))
        // うるう年。
        XCTAssertEqual(LinkReminder.dueDate(reminderDay: 30, inMonthOf: date(2028, 2, 15), calendar: calendar), date(2028, 2, 29))
        XCTAssertEqual(LinkReminder.dueDate(reminderDay: 1, inMonthOf: date(2026, 10, 31, hour: 23), calendar: calendar), date(2026, 10, 1))
        XCTAssertNil(LinkReminder.dueDate(reminderDay: 0, inMonthOf: date(2026, 1, 1), calendar: calendar))
        XCTAssertNil(LinkReminder.dueDate(reminderDay: 32, inMonthOf: date(2026, 1, 1), calendar: calendar))
    }

    func testLatestDueDateIsThisMonthOnOrAfterDayOtherwisePreviousMonth() {
        XCTAssertEqual(LinkReminder.latestDueDate(reminderDay: 10, today: date(2026, 10, 10), calendar: calendar), date(2026, 10, 10))
        XCTAssertEqual(LinkReminder.latestDueDate(reminderDay: 10, today: date(2026, 10, 25), calendar: calendar), date(2026, 10, 10))
        XCTAssertEqual(LinkReminder.latestDueDate(reminderDay: 10, today: date(2026, 10, 9, hour: 23, minute: 59), calendar: calendar), date(2026, 9, 10))
        // 年をまたぐ前月。
        XCTAssertEqual(LinkReminder.latestDueDate(reminderDay: 20, today: date(2026, 1, 5), calendar: calendar), date(2025, 12, 20))
        // 前月の末日に丸める（3/1 時点の 31 日は 2/28）。
        XCTAssertEqual(LinkReminder.latestDueDate(reminderDay: 31, today: date(2026, 3, 1), calendar: calendar), date(2026, 2, 28))
    }

    func testUnrecordedIsDueAndNoReminderIsNone() {
        XCTAssertEqual(status(day: 5, last: nil, today: date(2026, 10, 1)), .due)
        XCTAssertEqual(status(day: nil, last: nil, today: date(2026, 10, 1)), .none)
        XCTAssertEqual(status(day: 0, last: nil, today: date(2026, 10, 1)), .none)
        XCTAssertEqual(status(day: 40, last: nil, today: date(2026, 10, 1)), .none)
    }

    func testDueOnAndAfterDayUntilOpened() {
        let today = date(2026, 10, 10, hour: 9)
        // 期日の前に開いたままなら due、期日の当日以降に開いていれば none。
        XCTAssertEqual(status(day: 10, last: date(2026, 10, 9, hour: 23, minute: 59), today: today), .due)
        XCTAssertEqual(status(day: 10, last: date(2026, 10, 10, hour: 0, minute: 1), today: today), .none)
        XCTAssertEqual(status(day: 10, last: date(2026, 9, 10), today: today), .due)
        XCTAssertEqual(status(day: 10, last: date(2026, 10, 25), today: date(2026, 10, 31)), .none)
    }

    func testBeforeDayDependsOnPreviousMonth() {
        let today = date(2026, 10, 5)
        // 先月の期日以降に開いていれば今月の期日までは none。
        XCTAssertEqual(status(day: 10, last: date(2026, 9, 10), today: today), .none)
        XCTAssertEqual(status(day: 10, last: date(2026, 9, 30), today: today), .none)
        // 先月の期日より前にしか開いていなければ、今月の期日前でも due（先月分の見忘れ）。
        XCTAssertEqual(status(day: 10, last: date(2026, 9, 9), today: today), .due)
        XCTAssertEqual(status(day: 10, last: date(2026, 8, 10), today: today), .due)
    }

    func testThirtyFirstInShortMonths() {
        // 4 月は 30 日が期日。
        XCTAssertEqual(status(day: 31, last: date(2026, 3, 31), today: date(2026, 4, 29)), .none)
        XCTAssertEqual(status(day: 31, last: date(2026, 3, 31), today: date(2026, 4, 30)), .due)
        XCTAssertEqual(status(day: 31, last: date(2026, 4, 30, hour: 12), today: date(2026, 5, 30)), .none)
        XCTAssertEqual(status(day: 31, last: date(2026, 4, 30, hour: 12), today: date(2026, 5, 31)), .due)
        // うるう年の 2 月は 29 日。
        XCTAssertEqual(status(day: 31, last: date(2028, 1, 31), today: date(2028, 2, 28)), .none)
        XCTAssertEqual(status(day: 31, last: date(2028, 1, 31), today: date(2028, 2, 29)), .due)
        XCTAssertEqual(status(day: 31, last: date(2028, 2, 29), today: date(2028, 3, 30)), .none)
    }

    func testLinkHelpers() {
        XCTAssertEqual(LinkReminder.label(day: 5), "毎月 5 日に確認")
        let link = ProjectLink(name: "Stripe", url: "https://dashboard.stripe.com", reminderDay: 1)
        XCTAssertTrue(LinkReminder.isDue(link, lastOpened: nil, today: date(2026, 10, 8), calendar: calendar))
        XCTAssertFalse(LinkReminder.isDue(link, lastOpened: date(2026, 10, 1), today: date(2026, 10, 8), calendar: calendar))
        // 範囲外の日は確認しない扱い。
        let bad = ProjectLink(name: "x", url: "https://x.example", reminderDay: 99)
        XCTAssertFalse(LinkReminder.isDue(bad, lastOpened: nil, today: date(2026, 10, 8), calendar: calendar))
    }
}
