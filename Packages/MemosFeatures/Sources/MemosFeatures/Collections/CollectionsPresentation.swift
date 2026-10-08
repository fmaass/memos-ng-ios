import Foundation
import MemosCore

/// What the Collections root and the New trip sheet say, decided outside their view bodies.
enum CollectionsPresentation {
    /// A span of taken dates as the device's locale writes a range of days — "12–28 Mar 2026"
    /// in British English — or nil when either end is unknown. One day is written once.
    static func spanText(
        first: Date?,
        last: Date?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let first, let last else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        let formatter = DateIntervalFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateTemplate = "dMMMy"
        return formatter.string(from: min(first, last), to: max(first, last))
    }

    /// How many pictures a trip or a tag holds: "1 photo", "3 photos".
    static func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }

    /// One tag's line on the New trip sheet: its picture count, then its span once that is read.
    static func tagDetail(count: Int, span: TripTagSpan?, locale: Locale, timeZone: TimeZone)
        -> String
    {
        let counted = photoCount(count)
        guard
            let text = spanText(
                first: span?.firstTaken,
                last: span?.lastTaken,
                locale: locale,
                timeZone: timeZone
            )
        else { return counted }
        return "\(counted) · \(text)"
    }

    /// A trip card's second line: its span and its count, from the summary its record keeps; nil
    /// before a summary was ever written.
    static func cardDetail(_ summary: TripSummary?, locale: Locale, timeZone: TimeZone) -> String? {
        guard let summary else { return nil }
        let counted = photoCount(summary.count)
        guard
            let text = spanText(
                first: summary.firstTaken,
                last: summary.lastTaken,
                locale: locale,
                timeZone: timeZone
            )
        else { return counted }
        return "\(text) · \(counted)"
    }

    /// The tags the sheet suggests, in the order the server listed them: those whose span has
    /// been read and that `TripSuggestion.rule` accepts. A tag whose span has not arrived yet is
    /// not suggested until it has.
    static func suggested(
        _ tags: [LibraryTag],
        spans: [String: TripTagSpan],
        now: Date
    ) -> [LibraryTag] {
        tags.filter { tag in
            guard let span = spans[tag.name] else { return false }
            let summary = TripSummary(
                count: tag.count,
                firstTaken: span.firstTaken,
                lastTaken: span.lastTaken,
                coverUid: nil
            )
            return TripSuggestion.rule(tag: tag.name, summary: summary, now: now)
        }
    }

    /// The cover a trip card shows: the member its summary names, once the membership has been
    /// drained on this device. Nil draws the placeholder, never a broken tile.
    static func cover(of record: CollectionRecord, members: [LibraryRow]) -> MemoAttachment? {
        guard let uid = record.lastSummary?.coverUid else { return nil }
        return members.first { $0.id == uid }?.attachment
    }
}
