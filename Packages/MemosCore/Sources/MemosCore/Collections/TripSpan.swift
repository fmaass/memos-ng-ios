import Foundation

/// What a run of pictures adds up to — a tag's on the New trip sheet, which `TripSuggestion`
/// weighs. A trip's own is `TripMemberSummary`, made from the server's count.
public struct TripSummary: Sendable, Equatable, Codable {
    /// How many members there were, exclusions already taken out.
    public var count: Int
    /// The earliest taken date among them, or nil when there was no member.
    public var firstTaken: Date?
    /// The latest taken date among them, or nil when there was no member.
    public var lastTaken: Date?
    /// The member the card shows, or nil when there was no member.
    public var coverUid: String?

    public init(count: Int, firstTaken: Date?, lastTaken: Date?, coverUid: String?) {
        self.count = count
        self.firstTaken = firstTaken
        self.lastTaken = lastTaken
        self.coverUid = coverUid
    }
}

/// The window of a trip in time (MEMNG-737): every picture taken from `start` to `end`, both
/// included, is a member, whatever its memo's tags.
///
/// Both ends are instants, sent in UTC like every other date of the record; `zone` is the
/// identifier of the zone the owner set them in (the trip's own, "until 14:00" in Lisbon), kept so
/// the sheet shows them again as they were chosen. The span's own rule never reads the zone: an
/// instant is in the window or it is not.
public struct TripSpan: Sendable, Equatable, Codable {
    public var start: Date
    public var end: Date
    /// A `TimeZone` identifier, such as `Europe/Lisbon`.
    public var zone: String

    public init(start: Date, end: Date, zone: String) {
        self.start = start
        self.end = end
        self.zone = zone
    }

    /// The zone the ends were set in, or the device's when the identifier names none.
    public var timeZone: TimeZone { TimeZone(identifier: zone) ?? .current }

    /// Whether `instant` lies in the window, both ends included.
    public func contains(_ instant: Date) -> Bool { start <= instant && instant <= end }

    /// The days from `first`'s to `last`'s, whole: 00:00:00 of the first day to 23:59:59 of the
    /// last, in `zone` — what a span set by its dates alone covers. Nil when `last` is earlier.
    public static func days(from first: Date, to last: Date, in zone: TimeZone) -> TripSpan? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: first)
        guard last >= first,
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))
        else { return nil }
        return TripSpan(start: start, end: next.addingTimeInterval(-1), zone: zone.identifier)
    }
}

/// The first and last taken date of one tag's pictures, as the New trip sheet shows them.
public struct TripTagSpan: Sendable, Equatable {
    public var firstTaken: Date?
    public var lastTaken: Date?

    public init(firstTaken: Date?, lastTaken: Date?) {
        self.firstTaken = firstTaken
        self.lastTaken = lastTaken
    }
}

extension Trip {
    /// The span with the zone it was picked in, when the trip has both ends; the device's zone
    /// stands in for a trip the server holds without one.
    public var tripSpan: TripSpan? {
        guard let span else { return nil }
        return TripSpan(
            start: span.lowerBound, end: span.upperBound, zone: tz ?? TimeZone.current.identifier)
    }
}
