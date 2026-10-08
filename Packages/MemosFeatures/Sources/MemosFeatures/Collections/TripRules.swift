import Foundation
import MemosCore

/// Which tags the New trip sheet puts under `Suggested`.
///
/// A trip is a short run of pictures that is not ancient history: a tag whose pictures span less
/// than sixty days and whose last picture is no more than two years old, and not in the future.
/// A tag that has gathered pictures for longer than that is a subject (`family`, `garden`), not a
/// journey, and one whose last picture is older is a trip that already had its chance.
enum TripSuggestion {
    /// How long a trip's pictures may span. Exactly this long is no longer a trip.
    static let maxSpan: TimeInterval = 60 * 24 * 60 * 60
    /// How many years back a trip's last picture may lie and still be suggested.
    static let recentYears = 2

    /// Whether `tag`, whose pictures add up to `summary`, is suggested as a trip at `now`.
    ///
    /// A tag with no name, no picture or no taken date is never suggested: there is nothing to
    /// measure a span on.
    static func rule(tag: String, summary: TripSummary, now: Date) -> Bool {
        guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            summary.count > 0,
            let first = summary.firstTaken, let last = summary.lastTaken
        else { return false }
        guard last.timeIntervalSince(first) < maxSpan else { return false }
        // A picture taken after `now` is a clock that was wrong, not a trip still to come.
        guard last <= now else { return false }
        guard let oldest = calendar.date(byAdding: .year, value: -recentYears, to: now) else {
            return false
        }
        return last >= oldest
    }

    /// Years counted in UTC on the Gregorian calendar, so the answer is the same on every device.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }
}

/// The title a new trip is offered, made from its tag.
enum TripTitle {
    /// `portugal2026` becomes "Portugal 2026": trailing digits are split off as a year (with any
    /// `-`, `_`, `.` or space before them dropped) and the first letter is capitalised. Nothing
    /// else is touched, so `nyc` is "Nyc" — the field stays editable for what a rule cannot know.
    static func suggest(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = String(trimmed.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        let separators: Set<Character> = ["-", "_", ".", " "]
        var head = String(trimmed.dropLast(digits.count))
        while let last = head.last, separators.contains(last) { head.removeLast() }
        let named = head.prefix(1).uppercased() + head.dropFirst()
        if named.isEmpty { return digits }
        if digits.isEmpty { return named }
        return "\(named) \(digits)"
    }
}
