import Foundation

/// The point in the calendar a list is anchored at — a day, or a whole month.
///
/// It holds calendar components rather than a `Date` because that is what a person chooses: "24
/// August 2026" is not an instant, and turning it into one needs a time zone the anchor itself has
/// no business carrying. The instant is derived once, at the edge, by `createdBefore(in:)`.
public enum MemoQueryAnchor: Sendable, Equatable, Codable {
    case day(year: Int, month: Int, day: Int)
    case month(year: Int, month: Int)

    /// The exclusive upper bound this anchor becomes on the wire: the FIRST instant after the
    /// anchored period, read in the given calendar.
    ///
    /// The server compares strictly — `created_at < created_before`
    /// (`app/services/memos.py:309-310`) — so the bound has to be the start of the period AFTER
    /// the anchored one. The start of the anchored day would hide the whole of it, and its last
    /// second (23:59:59) would hide every memo written inside that final second.
    ///
    /// It adds a calendar period and takes the start of the day again rather than adding 86 400
    /// seconds: on the night a time zone leaves daylight saving the local day is 25 hours long,
    /// and a fixed-length day would put the bound an hour early, quietly hiding the last hour of
    /// the day the person asked for.
    public func createdBefore(in calendar: Calendar) -> Date? {
        switch self {
        case .day(let year, let month, let day):
            return Self.start(
                after: .day,
                from: DateComponents(year: year, month: month, day: day),
                in: calendar
            )
        case .month(let year, let month):
            return Self.start(
                after: .month,
                from: DateComponents(year: year, month: month, day: 1),
                in: calendar
            )
        }
    }

    /// The day an instant falls on, as an anchor.
    ///
    /// One rule, stated once: the timeline is anchored at a DAY, and which day an instant belongs
    /// to is a question only a calendar can answer. Both callers — a day chosen on the heatmap and
    /// a memo jumped to from the library — read it from here rather than each deriving components
    /// of their own (MEMNG-191).
    public static func day(of date: Date, in calendar: Calendar) -> MemoQueryAnchor? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return nil
        }
        return .day(year: year, month: month, day: day)
    }

    /// The start of the local day one `period` after the day those components name.
    ///
    /// `startOfDay` is taken twice on purpose. Once before adding, because a component-built date
    /// is midnight only on days that HAVE a midnight — on the night the clocks go forward some
    /// zones skip it and the date lands an hour in. Once after, because adding a calendar period
    /// keeps the wall-clock time it started from, which is the wrong hour on the far side of a
    /// transition.
    private static func start(
        after period: Calendar.Component,
        from components: DateComponents,
        in calendar: Calendar
    ) -> Date? {
        guard let anchored = calendar.date(from: components) else { return nil }
        let start = calendar.startOfDay(for: anchored)
        guard let next = calendar.date(byAdding: period, value: 1, to: start) else { return nil }
        return calendar.startOfDay(for: next)
    }
}

/// What a timeline is asking the server for, as one value.
///
/// It is pure: no clock, no client, no calendar of its own — so what a term, a day and a set of
/// tags become on the wire is something a test states directly instead of inferring from a
/// request that has already been sent.
///
/// The empty query is not a special case anywhere: it is the value whose every parameter is
/// absent, and a request carrying none of these parameters IS the plain timeline request this app
/// has always sent.
public struct MemoQuery: Sendable, Equatable, Codable {
    /// The text to match. Whole words against the memo's content only — the server runs
    /// `to_tsvector('simple', content) @@ plainto_tsquery('simple', q)`
    /// (`app/services/memos.py:318-321`), which has no stemming and adds no prefix wildcard.
    public let term: String?
    /// The day or month the list is anchored at, or nil for "from now backwards".
    public let anchor: MemoQueryAnchor?
    /// Tags that must ALL be present — the server ANDs one `EXISTS` per tag
    /// (`app/services/memos.py:322-331`).
    public let tags: [String]
    public let visibility: MemoVisibility?
    /// Archived memos alongside the rest.
    ///
    /// This and `archivedOnly` are two flags rather than one choice because that is the shape the
    /// server takes, and it decides between them itself: `archived_only` wins and
    /// `include_archived` is only consulted when it is off (`app/services/memos.py:305-307`). A
    /// surface that offers both as one choice is the search sheet's job, not this value's.
    public let includeArchived: Bool
    /// Only archived memos.
    public let archivedOnly: Bool
    /// Memos a trip pass brought in alongside the household's own. The server leaves them out
    /// unless asked (`guest=exclude`, MEMNG-1164), which is right for the home timeline and wrong
    /// for the trip they were shared into (MEMNG-1233).
    public let includeGuests: Bool

    public init(
        term: String? = nil,
        anchor: MemoQueryAnchor? = nil,
        tags: [String] = [],
        visibility: MemoVisibility? = nil,
        includeArchived: Bool = false,
        archivedOnly: Bool = false,
        includeGuests: Bool = false
    ) {
        self.term = Self.normalisedTerm(term)
        self.anchor = anchor
        self.tags = Self.normalisedTags(tags)
        self.visibility = visibility
        self.includeArchived = includeArchived
        self.archivedOnly = archivedOnly
        self.includeGuests = includeGuests
    }

    /// The plain timeline: no term, no anchor, no filter.
    public static let empty = MemoQuery()

    /// Whether this query asks for anything at all. An empty one is the plain timeline request.
    public var isEmpty: Bool { self == .empty }

    /// The request parameters this query becomes — the whole of what it says on the wire, named
    /// as the server names them.
    ///
    /// Every field is optional and every one of them is nil for an empty query, so the store can
    /// hand the generated client the same absence it has always handed it.
    public struct Parameters: Sendable, Equatable {
        public var q: String?
        public var createdBefore: Date?
        /// The INCLUSIVE-from-above bound: `created_at > created_after`
        /// (`app/services/memos.py:322-323`). Only a page read towards now carries one, and it is
        /// nil for every other request, so the older direction stays the request it always was.
        public var createdAfter: Date?
        public var tag: [String]?
        public var visibility: MemoVisibility?
        public var includeArchived: Bool?
        public var archivedOnly: Bool?
        /// `guest=include`, or nil to let the server's `exclude` stand.
        public var includeGuests: Bool?
        /// The server's `sort`, or nil to let its own default (`-created_at`) stand. Sent only by
        /// the direction that needs the other one — see `MemoPageDirection`.
        public var sort: String?

        public init(
            q: String? = nil,
            createdBefore: Date? = nil,
            createdAfter: Date? = nil,
            tag: [String]? = nil,
            visibility: MemoVisibility? = nil,
            includeArchived: Bool? = nil,
            archivedOnly: Bool? = nil,
            includeGuests: Bool? = nil,
            sort: String? = nil
        ) {
            self.q = q
            self.createdBefore = createdBefore
            self.createdAfter = createdAfter
            self.tag = tag
            self.visibility = visibility
            self.includeArchived = includeArchived
            self.archivedOnly = archivedOnly
            self.includeGuests = includeGuests
            self.sort = sort
        }
    }

    /// This query as request parameters, with the calendar the anchor is read in.
    ///
    /// An archive flag that is off is left OUT rather than sent as `false`. The server's own
    /// default is `False` for both (`app/services/memos.py:297-298`), so the two are the same
    /// request — and leaving them out is what keeps an empty query byte-identical to the one this
    /// app sent before it could be filtered at all.
    public func parameters(in calendar: Calendar) -> Parameters {
        Parameters(
            q: term,
            createdBefore: anchor?.createdBefore(in: calendar),
            tag: tags.isEmpty ? nil : tags,
            visibility: visibility,
            includeArchived: includeArchived ? true : nil,
            archivedOnly: archivedOnly ? true : nil,
            includeGuests: includeGuests ? true : nil
        )
    }

    /// Whether this query still admits a memo whose ARCHIVE state has just changed.
    ///
    /// Only the archive dimension, and that limit is the point. A memo archived from the timeline
    /// has left the list it was sitting in — the request said `archived_at IS NULL` — and a row
    /// that stays behind is a row the next refresh silently removes, which reads as the app losing
    /// a memo. So the one dimension a client write actually MOVES is judged here.
    ///
    /// The others are deliberately not. Whether a memo still matches `q`, a tag set or a
    /// visibility is a question the server answers with a full-text index and a join, and
    /// re-deriving it here would evict rows the server would have kept — a worse lie than a stale
    /// one, because nothing brings them back until a refresh.
    public func admitsArchiveState(of memo: Memo) -> Bool {
        // The server's own precedence: `archived_only` wins, and `include_archived` is consulted
        // only when it is off (`app/services/memos.py:316-319`).
        if archivedOnly { return memo.isArchived }
        if includeArchived { return true }
        return !memo.isArchived
    }

    /// A term of nothing but spaces is not a search, and a tag of nothing but spaces is not a tag:
    /// both are normalised away here, once, so a blank field can never reach the wire as `q=` and
    /// two queries that ask the same thing compare equal.
    private static func normalisedTerm(_ term: String?) -> String? {
        guard let trimmed = term?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func normalisedTags(_ tags: [String]) -> [String] {
        tags.compactMap { normalisedTerm($0) }
    }
}

extension MemoQuery {
    private enum CodingKeys: String, CodingKey {
        case term
        case anchor
        case tags
        case visibility
        case includeArchived
        case archivedOnly
        case includeGuests
    }

    /// Decoding goes through the same initialiser everything else does, so a query read back from
    /// storage carries the same normalisation as one a person just built. A decoder that assigned
    /// the stored properties directly could reintroduce the blank term the initialiser removes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            term: try container.decodeIfPresent(String.self, forKey: .term),
            anchor: try container.decodeIfPresent(MemoQueryAnchor.self, forKey: .anchor),
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            visibility: try container.decodeIfPresent(MemoVisibility.self, forKey: .visibility),
            includeArchived: try container.decodeIfPresent(Bool.self, forKey: .includeArchived)
                ?? false,
            archivedOnly: try container.decodeIfPresent(Bool.self, forKey: .archivedOnly) ?? false,
            // A query written down before guests existed asked for none.
            includeGuests: try container.decodeIfPresent(Bool.self, forKey: .includeGuests)
                ?? false
        )
    }
}
