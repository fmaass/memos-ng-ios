import Foundation

/// What a collection screen is opened on: a trip the server holds, or a collection the Collections
/// root computes — a tag, a month, a year (MEMNG-817) or a picture tag (MEMNG-868). Every lane of `TripMemberStore` is keyed
/// by `id`, so a trip and a tag holding the same pictures never share a row.
///
/// Hashed by `id` alone because `Trip` is only `Equatable`; equal scopes always share an id, so
/// the hash stays consistent with `==`.
public enum CollectionScope: Hashable, Sendable {
    case trip(Trip)
    case automatic(AutomaticCollection)

    /// The trip's uid, or `tag:<name>`, `month:<YYYY-MM>`, `year:<YYYY>`, `picture-tag:<name>`.
    public var id: String {
        switch self {
        case .trip(let trip): trip.uid
        case .automatic(let collection): collection.id
        }
    }

    public var title: String {
        switch self {
        case .trip(let trip): trip.title
        case .automatic(let collection): collection.title
        }
    }

    public var isTrip: Bool {
        if case .trip = self { return true }
        return false
    }

    /// The memo tag whose pictures are members: a trip's own, or the tag a tag collection names.
    /// Nil for a picture tag, which is no memo tag (plan decision 3): nothing that files, journals
    /// or excludes by memo tag may take `favorites` the picture tag for `#favorites` the memo tag.
    public var tag: String? {
        switch self {
        case .trip(let trip): trip.tag
        case .automatic(let collection): collection.tagName
        }
    }

    /// A trip's span, or a month or a year as a span in its zone; nil for a tag.
    public var span: TripSpan? {
        switch self {
        case .trip(let trip): trip.tripSpan
        case .automatic(let collection): collection.period?.span
        }
    }

    /// The picture the card showed, which the screen draws until the drained row arrives.
    public var carriedCover: (uid: String, thumbnailURL: URL?)? {
        switch self {
        case .trip(let trip): trip.cover.map { ($0.id, $0.attachment.thumbnailURL) }
        case .automatic(let collection): collection.cover.map { ($0.uid, $0.thumbnailURL) }
        }
    }

    public static func == (lhs: CollectionScope, rhs: CollectionScope) -> Bool {
        switch (lhs, rhs) {
        case (.trip(let left), .trip(let right)): left == right
        case (.automatic(let left), .automatic(let right)): left == right
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The cover a card showed: the picture's uid and the thumbnail it was drawn from.
public struct CollectionCover: Hashable, Sendable {
    public var uid: String
    public var thumbnailURL: URL?

    public init(uid: String, thumbnailURL: URL?) {
        self.uid = uid
        self.thumbnailURL = thumbnailURL
    }
}

/// A collection with no server record: its membership IS the tag, the picture tag or the calendar
/// bucket.
public struct AutomaticCollection: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case tag(String)
        /// A month bucket's key, `YYYY-MM`.
        case month(String)
        /// A year bucket's key, `YYYY`.
        case year(String)
        /// The pictures carrying a picture tag of their own (MEMNG-868) — `favorites` — read with
        /// `pictureTag=`, never `tag=`: a memo tag of the same name is another collection.
        case pictureTag(String)
    }

    public var kind: Kind
    /// The card's count, shown until a drain has read every member.
    public var count: Int
    public var cover: CollectionCover?
    /// The zone the card's bucket was counted in. The caller passes the bucket read's own answered
    /// zone; nothing here reads the device's, because a month cut in another zone than the one
    /// its card was counted in holds other pictures.
    public var zone: TimeZone

    public init(kind: Kind, count: Int, cover: CollectionCover?, zone: TimeZone) {
        self.kind = kind
        self.count = count
        self.cover = cover
        self.zone = zone
    }

    public var id: String {
        switch kind {
        case .tag(let name): "tag:\(name)"
        case .month(let key): "month:\(key)"
        case .year(let key): "year:\(key)"
        case .pictureTag(let name): "picture-tag:\(name)"
        }
    }

    /// The title of the favorites collection, whose card and screen name it so.
    public static let favoritesTitle = "Favorites"

    /// The card's own title: `#name`, "Sep 2026" (the Months view's label), "2026", "Favorites" —
    /// a picture tag without the `#` a memo tag is written with.
    public var title: String {
        switch kind {
        case .tag(let name): "#\(name)"
        case .month(let key): monthBucketLabel(key) ?? key
        case .year(let key): key
        case .pictureTag(let name): name == FavoriteTag.name ? Self.favoritesTitle : name
        }
    }

    /// The memo tag a tag collection names; nil for a month, a year or a picture tag.
    var tagName: String? {
        switch kind {
        case .tag(let name): name
        case .month, .year, .pictureTag: nil
        }
    }

    /// The picture tag a picture-tag collection names; nil for every other kind.
    public var pictureTagName: String? {
        if case .pictureTag(let name) = kind { return name }
        return nil
    }

    /// The bucket key a month or a year walk starts at; nil for a tag.
    var bucket: String? {
        switch kind {
        case .tag, .pictureTag: nil
        case .month(let key), .year(let key): key
        }
    }

    /// A month's or a year's interval in `zone`; nil for a tag, or for a key naming no period.
    public var period: CollectionPeriod? {
        switch kind {
        case .tag, .pictureTag: nil
        case .month(let key): CollectionPeriod(month: key, in: zone)
        case .year(let key): CollectionPeriod(year: key, in: zone)
        }
    }
}

/// A calendar period as instants: from `start`, included, to `nextStart`, excluded — the next
/// period's first instant, so the last second (and any fraction of it) of the period is inside and
/// no instant belongs to two periods.
public struct CollectionPeriod: Hashable, Sendable {
    public var start: Date
    public var nextStart: Date
    public var zone: TimeZone

    public init(start: Date, nextStart: Date, zone: TimeZone) {
        self.start = start
        self.nextStart = nextStart
        self.zone = zone
    }

    /// `YYYY-MM` in `zone`, or nil for anything else.
    public init?(month key: String, in zone: TimeZone) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
            let year = Self.digits(parts[0]), let month = Self.digits(parts[1]),
            (1...12).contains(month)
        else { return nil }
        let next = month == 12 ? (year + 1, 1) : (year, month + 1)
        self.init(from: (year, month), to: next, in: zone)
    }

    /// `YYYY` in `zone`, or nil for anything else.
    public init?(year key: String, in zone: TimeZone) {
        guard key.count == 4, let year = Self.digits(key[...]) else { return nil }
        self.init(from: (year, 1), to: (year + 1, 1), in: zone)
    }

    private init?(from first: (Int, Int), to next: (Int, Int), in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard
            let start = calendar.date(
                from: DateComponents(year: first.0, month: first.1, day: 1)),
            let nextStart = calendar.date(
                from: DateComponents(year: next.0, month: next.1, day: 1))
        else { return nil }
        self.init(start: start, nextStart: nextStart, zone: zone)
    }

    /// Digits only: `Int` alone would read "+026" as a year.
    private static func digits(_ text: Substring) -> Int? {
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    public func contains(_ instant: Date) -> Bool { start <= instant && instant < nextStart }

    /// The period as the closed span a screen shows: its last whole second as the end. Display
    /// only — membership is asked of `contains`, which keeps the final second's fractions.
    public var span: TripSpan {
        TripSpan(start: start, end: nextStart.addingTimeInterval(-1), zone: zone.identifier)
    }
}
