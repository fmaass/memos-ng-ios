import Foundation

/// What a collection's membership is made of. The pilot has one kind.
public enum CollectionKind: String, Sendable, Equatable, Codable {
    /// Every picture of every memo carrying the record's tag, minus its exclusions.
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

/// One collection as this device keeps it — device-local, and filed under the identity that made
/// it, never anyone else's.
///
/// Every date is a machine field and is written down as ISO-8601 in UTC; a screen renders it in the
/// device's locale.
public struct CollectionRecord: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var kind: CollectionKind
    public var title: String
    /// The tags whose pictures are the membership. The pilot creates and shows one.
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
        createdAt: Date
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
    }
}
