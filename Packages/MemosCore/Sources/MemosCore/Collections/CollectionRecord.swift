import Foundation

/// What a collection's membership is made of. The pilot has one kind.
public enum CollectionKind: String, Sendable, Equatable, Codable {
    /// Every picture of every memo carrying the record's tag, and every picture taken in its span,
    /// minus its exclusions.
    case trip
}

/// What a trip's membership last added up to, cached on its record so a card can render before
/// the membership has been read again.
///
/// It is never authoritative: whoever drains the membership computes it afresh and writes it back
/// through `CollectionStore.setSummary(id:_:)`.
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
/// Both ends are instants, written down in UTC like every other date of the record; `zone` is the
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

/// One collection as this device keeps it — device-local, and filed under the identity that made
/// it, never anyone else's.
///
/// Every date is a machine field and is written down as ISO-8601 in UTC; a screen renders it in the
/// device's locale.
public struct CollectionRecord: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var kind: CollectionKind
    public var title: String
    /// The tags whose pictures are the membership. The pilot creates and shows one; a trip made of
    /// its span alone has none.
    public var tags: [String]
    /// The member the owner picked as the cover, or nil for "the first member".
    public var coverUid: String?
    /// Where the record sits among its scope's records; `CollectionStore.records` is sorted by it.
    public var order: Int
    /// Until when the composer offers this trip's tag, or nil when it is not pinned.
    public var pinnedUntil: Date?
    public var lastSummary: TripSummary?
    /// Pictures the owner removed from the trip on this device. The memo keeps its tag.
    public var excludedUids: [String]
    public var createdAt: Date
    /// The trip's window in time, or nil for a trip made of its tag alone. Optional, so a record
    /// written before spans existed decodes without one.
    public var span: TripSpan?

    public init(
        id: UUID,
        kind: CollectionKind,
        title: String,
        tags: [String],
        coverUid: String? = nil,
        order: Int,
        pinnedUntil: Date? = nil,
        lastSummary: TripSummary? = nil,
        excludedUids: [String] = [],
        createdAt: Date,
        span: TripSpan? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.tags = tags
        self.coverUid = coverUid
        self.order = order
        self.pinnedUntil = pinnedUntil
        self.lastSummary = lastSummary
        self.excludedUids = excludedUids
        self.createdAt = createdAt
        self.span = span
    }
}
