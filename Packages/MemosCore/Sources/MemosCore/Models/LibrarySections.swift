import Foundation

// Ported from the SPA's `frontend/src/lib/librarySections.ts` (memos-ng v2.0.0), vectors included
// (`LibrarySectionsTests`). A month is a CALENDAR month in one named zone, read through a Gregorian
// calendar set to that zone: a UTC slice of the instant would file a late-evening photograph on the
// last of a month — and every New Year's Eve photograph after 23:00 in Zurich — under the month
// before.
//
// The two constants keep the SPA's values under Swift names (`LIBRARY_TIME_ZONE`, `UNDATED_KEY`
// there); the strict lint refuses a screaming-snake identifier.

/// The one calendar the library is cut in, whatever zone the device is in: the All grid's days
/// and months, the day and month buckets it counts and a day's jump all name it, so a Months
/// tile, its count and its day in All can never disagree about where a picture's day ends.
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
    return calendarDay(of: takenAt, in: libraryCalendar(in: timeZone))
}

private func calendarDay(of instant: Date, in calendar: Calendar) -> String? {
    let parts = calendar.dateComponents([.year, .month, .day], from: instant)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return "\(year)-\(twoDigits(month))-\(twoDigits(day))"
}

/// One calendar day of the All view (MEMNG-597, plan page 3929 decision 13): every row taken on
/// it, in the order the list handed them over.
public struct LibraryDaySection: Sendable, Equatable, Identifiable {
    /// `YYYY-MM-DD` in the grouping zone, or `undatedSectionKey`.
    public let key: String
    public fileprivate(set) var items: [LibraryRow]

    public var id: String { key }

    public init(key: String, items: [LibraryRow]) {
        self.key = key
        self.items = items
    }
}

/// The library's rows as day groups, ported from memos-ng `frontend/src/lib/librarySections.ts`
/// `groupByDay` (c8bd91e) with its spec's vectors.
///
/// Each calendar day in `timeZone` is one group, in the list's own order as `groupByMonth` keeps
/// it; a row with no readable instant keeps a group of its own under `undatedSectionKey`.
public func groupByDay(
    _ items: [LibraryRow],
    timeZone: String = libraryTimeZone
) -> [LibraryDaySection] {
    let calendar = libraryCalendar(in: timeZone)
    var order: [String] = []
    var sections: [String: LibraryDaySection] = [:]
    for item in items {
        let key = item.takenAt.flatMap { calendarDay(of: $0, in: calendar) } ?? undatedSectionKey
        if sections[key] == nil {
            order.append(key)
            sections[key] = LibraryDaySection(key: key, items: [])
        }
        sections[key]?.items.append(item)
    }
    return order.compactMap { sections[$0] }
}

/// A day heading row's two words: `Sat` and `26 Sep`.
public struct DayHeadingParts: Sendable, Equatable {
    public let weekday: String
    public let date: String

    public init(weekday: String, date: String) {
        self.weekday = weekday
        self.date = date
    }
}

/// The day heading row of a day key: `{ weekday: "Sat", date: "26 Sep" }`, or `Undated` and no
/// date for a key that names no real day.
public func dayHeadingParts(_ key: String) -> DayHeadingParts {
    guard let parts = dayLabelParts(key) else {
        return DayHeadingParts(weekday: "Undated", date: "")
    }
    return DayHeadingParts(weekday: parts.weekday, date: "\(parts.day) \(parts.month)")
}

/// The scroll pill's words for a day key: `Sat · 26 Sep 2026`, or `Undated`.
public func dayPillLabel(_ key: String) -> String {
    guard let parts = dayLabelParts(key) else { return "Undated" }
    return "\(parts.weekday) · \(parts.day) \(parts.month) \(parts.year)"
}

/// Where one day's marker sits on the page, for `topDay`.
public struct DayMarker: Sendable, Equatable {
    public let key: String
    public let top: Double

    public init(key: String, top: Double) {
        self.key = key
        self.top = top
    }
}

/// The day the scroll pill names: the last marker, in document order, whose top has reached the
/// threshold line — a marker exactly on it counts — or nil while none has, the page at its top.
public func topDay(_ markers: [DayMarker], threshold: Double) -> String? {
    var found: String?
    for marker in markers where marker.top <= threshold {
        found = marker.key
    }
    return found
}

// A day key is already a calendar date in the zone it was counted in, so it is read as a date and
// never as an instant: no zone can move it. English names are spelled here rather than asked of a
// locale, because the web's `en` says "Sep" where an en-GB formatter says "Sept".
private let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
private let monthNames = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]

private struct DayLabelParts {
    let weekday: String
    let day: Int
    let month: String
    let year: Int
}

/// The parts of a `YYYY-MM-DD` key, or nil for anything else — a key that merely CONTAINS a date,
/// or one that names no real day (30 February rolls over in a calendar; here it is refused).
private func dayLabelParts(_ key: String) -> DayLabelParts? {
    let fields = key.split(separator: "-", omittingEmptySubsequences: false)
    guard fields.count == 3, fields.map(\.count) == [4, 2, 2],
        fields.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
        let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2])
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    guard
        let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12))
    else { return nil }
    let back = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    guard back.year == year, back.month == month, back.day == day, let weekday = back.weekday,
        weekdayNames.indices.contains(weekday - 1), monthNames.indices.contains(month - 1)
    else { return nil }
    return DayLabelParts(
        weekday: weekdayNames[weekday - 1], day: day, month: monthNames[month - 1], year: year)
}

/// Where the first row taken on one calendar day sits in a list, or nil when none of them was.
///
/// `day` is a day bucket's key (`YYYY-MM-DD`), which the server counted in `timeZone`; a row is on
/// that day when its instant, read in the SAME zone, names the same key. Read in any other zone, a
/// photograph taken late in the evening would be looked for on the day after the one whose tile
/// was tapped. A row with no readable instant is on no day.
public func firstRowIndex(onDay day: String, in rows: [LibraryRow], timeZone: String) -> Int? {
    rows.firstIndex { dayKey($0.takenAt, timeZone: timeZone) == day }
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
