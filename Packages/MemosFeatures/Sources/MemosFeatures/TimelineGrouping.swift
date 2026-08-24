import Foundation
import MemosCore

/// One day's memos, under one header.
public struct MemoDaySection: Identifiable, Equatable, Sendable {
    /// The start of the day, in the calendar the section was built with. It is the identity: two
    /// pages that both contain a Tuesday produce ONE Tuesday.
    public let day: Date
    public let memos: [Memo]

    public var id: Date { day }

    public init(day: Date, memos: [Memo]) {
        self.day = day
        self.memos = memos
    }
}

/// Turning a flat, cursor-paginated list into days.
///
/// Two things make this worth its own function instead of a `ForEach` trick.
///
/// A day is a LOCAL idea. `createdAt` is an instant; which day it belongs to depends on where the
/// reader is standing. Grouping on the UTC date puts a photo taken at half past midnight in Berlin
/// under the previous day, every night, for everyone west of the meridian's shadow.
///
/// And a page boundary is not a day boundary. The timeline arrives a cursor page at a time and a
/// day will routinely straddle two of them; grouping per page would print the same date header
/// twice with the day cut in half between them. So the whole loaded list is regrouped, every time,
/// off the day each memo actually falls on.
public enum TimelineGrouping {
    public static func sections(
        for memos: [Memo],
        calendar: Calendar = .current
    ) -> [MemoDaySection] {
        var order: [Date] = []
        var grouped: [Date: [Memo]] = [:]
        for memo in memos {
            let day = calendar.startOfDay(for: memo.createdAt)
            if grouped[day] == nil {
                grouped[day] = []
                order.append(day)
            }
            grouped[day]?.append(memo)
        }
        return order.map { MemoDaySection(day: $0, memos: grouped[$0] ?? []) }
    }

    /// What the header says. The two most recent days are named rather than dated — a date nobody
    /// has to decode is the difference between a header and a timestamp.
    public static func title(
        for day: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(day, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let sameYear =
            calendar.component(.year, from: day) == calendar.component(.year, from: now)
        var style =
            sameYear
            ? Date.FormatStyle().weekday(.wide).day().month(.wide)
            : Date.FormatStyle().day().month(.wide).year()
        // The header is written in the same calendar the day was cut on — a date formatted in the
        // system's zone under a section grouped in another one is the same bug twice.
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return day.formatted(calendar.locale.map { style.locale($0) } ?? style)
    }
}
