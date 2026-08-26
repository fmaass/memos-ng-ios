import Foundation

/// One day of the activity grid.
///
/// It carries the server's own day key AS WELL AS that day as a `Date`. The key is what the
/// heatmap is indexed by and what a test can read; the `Date` is what a caller acts on — the
/// date-jump the loupe will open (MEMNG-120) needs a day, not a string it has to parse again.
/// The cells are drawn as plain rectangles today: the web client's are non-interactive `<span>`s
/// and there is no tap behaviour here either, but the model is already the one a tap would need.
public struct HeatCell: Identifiable, Equatable, Sendable {
    /// `YYYY-MM-DD`, exactly as `GET /api/stats/heatmap` keys its counts.
    public let date: String
    /// The same day, at its start in the calendar the grid was derived with.
    public let day: Date
    public let count: Int
    /// 0–4, the five buckets the web client paints (`frontend/src/lib/heatmap.ts`).
    public let level: Int
    public let isToday: Bool

    public var id: String { date }

    public init(date: String, day: Date, count: Int, level: Int, isToday: Bool) {
        self.date = date
        self.day = day
        self.count = count
        self.level = level
        self.isToday = isToday
    }
}

/// The grid a card draws: columns of seven days, oldest first, and the sentence VoiceOver reads
/// in place of the hundred-odd cells inside it.
public struct HeatmapGrid: Equatable, Sendable {
    /// Column-major, seven days per column — the same order the web client's
    /// `grid-flow-col grid-rows-7` fills. The LAST column may be short when the window does not
    /// divide by seven; the view leaves those slots empty rather than shifting the rest.
    public let columns: [[HeatCell]]
    /// "N memos in the last M weeks" — what the card says as one accessibility element.
    public let summary: String

    public init(columns: [[HeatCell]], summary: String) {
        self.columns = columns
        self.summary = summary
    }

    public var cells: [HeatCell] { columns.flatMap { $0 } }
    public var isEmpty: Bool { columns.isEmpty }
}

/// Turning `GET /api/stats/heatmap` into a grid.
///
/// **What the endpoint sends.** A flat `{"YYYY-MM-DD": count}` of EVERY day the account can see a
/// memo on, all history, with no window at all (`app/services/memos.py` `heatmap`: a
/// `date(created_at)` cast to text, grouped, archived rows excluded). The day is cut by Postgres
/// in the connection's own zone, which on this estate is `Etc/UTC` (probed 2026-08-26) — so the
/// keys are UTC calendar dates, and this file derives its grid in UTC too. Cutting the client's
/// days in the device's zone instead would file a memo under a day the server never counted it
/// on, every night, for anyone east or west of Greenwich.
///
/// **The window is the client's.** Twelve weeks back from today, clamped FORWARD to the first day
/// with any activity, so a young household is not shown weeks of empty cells before its first
/// memo. With no activity at all the whole twelve weeks is drawn — the cold-start grid. This is
/// the web client's rule (`frontend/src/lib/heatmap.ts`) and the two are kept in step deliberately:
/// the same household reads both.
///
/// Pure, and `today` and the calendar are injectable, so the window, the buckets and the summary
/// are asserted rather than eyeballed against a running server.
public enum HeatmapPresentation {
    public static let weeks = 12
    public static let daysPerColumn = 7

    /// The calendar the server's day keys are in. Gregorian and UTC — see the note above.
    public static var dayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// The five buckets, with the same boundaries the web client paints: nothing, one, a couple,
    /// a few, a lot.
    public static func level(for count: Int) -> Int {
        switch count {
        case ..<1: 0
        case 1: 1
        case 2...3: 2
        case 4...6: 3
        default: 4
        }
    }

    public static func grid(
        from counts: [String: Int],
        today: Date = .now,
        weeks: Int = weeks,
        calendar: Calendar = dayCalendar
    ) -> HeatmapGrid {
        let end = calendar.startOfDay(for: today)
        let span = weeks * daysPerColumn - 1
        var start = calendar.date(byAdding: .day, value: -span, to: end) ?? end
        // ISO day keys sort lexicographically in the order they happened, so the earliest key is
        // the first day with activity — the same comparison the web client makes.
        if let earliest = counts.keys.min(), let first = day(for: earliest, calendar: calendar),
            first > start
        {
            start = first
        }
        if start > end { start = end }

        var cells: [HeatCell] = []
        var cursor = start
        while cursor <= end {
            let key = self.key(for: cursor, calendar: calendar)
            let count = counts[key] ?? 0
            cells.append(
                HeatCell(
                    date: key,
                    day: cursor,
                    count: count,
                    level: level(for: count),
                    isToday: cursor == end
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let columns = stride(from: 0, to: cells.count, by: daysPerColumn).map { first in
            Array(cells[first..<min(first + daysPerColumn, cells.count)])
        }
        // Whole weeks, rounding up: a nine-day window is "the last 2 weeks", not 1.28 of them.
        let spanned = (cells.count + daysPerColumn - 1) / daysPerColumn
        return HeatmapGrid(
            columns: columns,
            summary: summary(memos: cells.reduce(0) { $0 + $1.count }, weeks: max(1, spanned))
        )
    }

    /// What VoiceOver reads instead of the cells. The grid is one element, not a hundred: a
    /// rotor that stops on eighty-four unlabelled squares is worse than one that stops on none.
    public static func summary(memos: Int, weeks: Int) -> String {
        let span = weeks == 1 ? "the last week" : "the last \(weeks) weeks"
        if memos == 0 { return "No memos in \(span)" }
        return "\(memos) memo\(memos == 1 ? "" : "s") in \(span)"
    }

    /// What the card says it amounts to — and what it must not say before the server has spoken.
    ///
    /// An unanswered heatmap and a household that has written nothing produce the SAME empty
    /// counts, and the grid derived from them is the same twelve weeks of level-0 days. Reading
    /// "No memos in the last 12 weeks" off it is therefore a claim the app cannot make yet, and it
    /// is the one the first open of the search sheet used to make (MEMNG-175).
    public static func summary(for grid: HeatmapGrid, loaded: Bool) -> String {
        loaded ? grid.summary : "Loading activity"
    }

    /// A day as the server keys it.
    public static func key(for day: Date, calendar: Calendar = dayCalendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// The start of the day a server key names, or `nil` for anything that is not one.
    public static func day(for key: String, calendar: Calendar = dayCalendar) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
        else { return nil }
        return calendar.date(
            from: DateComponents(year: year, month: month, day: dayOfMonth)
        )
    }
}
