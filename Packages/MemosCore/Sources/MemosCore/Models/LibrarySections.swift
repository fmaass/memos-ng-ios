import Foundation

// Ported from the SPA's `frontend/src/lib/librarySections.ts` (memos-ng v2.0.0), vectors included
// (`LibrarySectionsTests`). A month is a CALENDAR month in one named zone, read through a Gregorian
// calendar set to that zone: a UTC slice of the instant would file a late-evening photograph on the
// last of a month — and every New Year's Eve photograph after 23:00 in Zurich — under the month
// before.
//
// The two constants keep the SPA's values under Swift names (`LIBRARY_TIME_ZONE`, `UNDATED_KEY`
// there); the strict lint refuses a screaming-snake identifier.

/// The zone a month is a calendar month of when the caller names none.
public let libraryTimeZone = "Europe/Zurich"

/// The key of the section a row with no readable instant is filed under.
public let undatedSectionKey = "undated"

/// One month of the library: every row of it, in the order the list handed them over.
public struct LibraryMonthSection: Sendable, Equatable, Identifiable {
    /// `YYYY-MM` in the grouping zone — the same key the buckets endpoint returns for a month —
    /// or `undatedSectionKey`.
    public let key: String
    /// "September 2026": English whatever the device's language, as the SPA's `Intl` in `en`.
    public let label: String
    public fileprivate(set) var items: [LibraryRow]

    public var id: String { key }
}

/// The library's rows as month sections.
///
/// Sections follow the list's own order (the server sorts by `takenAt` in either direction), so the
/// grid never re-sorts what it was handed; a month's rows keep their list order too. A row whose
/// instant could not be read is shown under its own "Undated" section rather than lost: `takenAt`
/// is nil for exactly that row (`LibraryRow`), where the SPA meets an unparseable string.
public func groupByMonth(
    _ items: [LibraryRow],
    timeZone: String = libraryTimeZone
) -> [LibraryMonthSection] {
    let calendar = libraryCalendar(in: timeZone)
    var order: [String] = []
    var sections: [String: LibraryMonthSection] = [:]
    for item in items {
        let month = item.takenAt.flatMap { calendarMonth(of: $0, in: calendar) }
        let key = month?.key ?? undatedSectionKey
        if sections[key] == nil {
            order.append(key)
            let label = month?.label ?? "Undated"
            sections[key] = LibraryMonthSection(key: key, label: label, items: [])
        }
        sections[key]?.items.append(item)
    }
    return order.compactMap { sections[$0] }
}

/// The calendar day of an instant in `timeZone` as `YYYY-MM-DD` — the buckets endpoint's day key —
/// or nil for a row with no readable instant.
public func dayKey(_ takenAt: Date?, timeZone: String = libraryTimeZone) -> String? {
    guard let takenAt else { return nil }
    let parts = libraryCalendar(in: timeZone).dateComponents([.year, .month, .day], from: takenAt)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return "\(year)-\(twoDigits(month))-\(twoDigits(day))"
}

/// A Gregorian calendar in the named zone, speaking English.
///
/// The SPA's `Intl` throws on a zone it does not know, and one unknown identifier must not take the
/// grid down with it, so such an identifier groups in the library's own zone instead.
private func libraryCalendar(in identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en")
    let zone = TimeZone(identifier: identifier) ?? TimeZone(identifier: libraryTimeZone)
    calendar.timeZone = zone ?? .gmt
    return calendar
}

private func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
}

private struct CalendarMonth {
    let key: String
    let label: String
}

private func calendarMonth(of instant: Date, in calendar: Calendar) -> CalendarMonth? {
    let parts = calendar.dateComponents([.year, .month], from: instant)
    guard let year = parts.year, let month = parts.month else { return nil }
    let names = calendar.standaloneMonthSymbols
    guard names.indices.contains(month - 1) else { return nil }
    return CalendarMonth(key: "\(year)-\(twoDigits(month))", label: "\(names[month - 1]) \(year)")
}
