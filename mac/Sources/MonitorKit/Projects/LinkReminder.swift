import Foundation

/// 毎月 N 日に確認するリンクの「確認が必要か」の判定。暦と今日を引数に取る純粋関数。
public enum LinkReminder {
    public enum Status: Sendable, Equatable {
        case none
        /// 期日を過ぎて（前月の分も含めて）まだ開いていない。
        case due
    }

    /// 「毎月 N 日に確認」の文言。
    public static func label(day: Int) -> String { "毎月 \(day) 日に確認" }

    /// `month` を含む月の期日（N がその月の日数を超える月は末日）。0 時。
    public static func dueDate(reminderDay: Int, inMonthOf month: Date, calendar: Calendar) -> Date? {
        guard (1...31).contains(reminderDay),
              let range = calendar.range(of: .day, in: .month, for: month),
              let start = calendar.dateInterval(of: .month, for: month)?.start else { return nil }
        let day = min(reminderDay, range.count)
        return calendar.date(byAdding: .day, value: day - 1, to: start)
    }

    /// 今日の時点で最後に迎えた期日（今月の期日が今日以前ならそれ、まだなら前月の期日）。
    public static func latestDueDate(reminderDay: Int, today: Date, calendar: Calendar) -> Date? {
        guard let thisMonth = dueDate(reminderDay: reminderDay, inMonthOf: today, calendar: calendar) else { return nil }
        if thisMonth <= today { return thisMonth }
        guard let previous = calendar.date(byAdding: .month, value: -1, to: today) else { return nil }
        return dueDate(reminderDay: reminderDay, inMonthOf: previous, calendar: calendar)
    }

    /// 最後に迎えた期日より前にしか開いていない（または未記録）なら `due`。確認の日が無い・範囲外なら `none`。
    public static func status(reminderDay: Int?, lastOpened: Date?, today: Date, calendar: Calendar) -> Status {
        guard let reminderDay, let threshold = latestDueDate(reminderDay: reminderDay, today: today, calendar: calendar) else { return .none }
        guard let lastOpened else { return .due }
        return lastOpened < threshold ? .due : .none
    }

    public static func isDue(_ link: ProjectLink, lastOpened: Date?, today: Date, calendar: Calendar) -> Bool {
        status(reminderDay: link.validReminderDay, lastOpened: lastOpened, today: today, calendar: calendar) == .due
    }
}
