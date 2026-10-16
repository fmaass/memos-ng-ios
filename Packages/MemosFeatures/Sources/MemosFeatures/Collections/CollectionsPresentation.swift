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

    /// The root header's subtitle (MEMNG-757): the trip count alone. No order phrase, because the
    /// trips stand in the order the server lists them, which is no rule a phrase could name.
    static func headerSubtitle(tripCount: Int) -> String {
        switch tripCount {
        case 0: "No trips yet"
        case 1: "1 trip"
        default: "\(tripCount) trips"
        }
    }

    /// What the header says while the list failed with no trip to show: never "No trips yet",
    /// which the server did not say.
    static let headerUnread = "Trips not read"

    /// The header's subtitle over the trips the store holds: the count, or `headerUnread` when the
    /// list failed and there is nothing to count.
    static func headerSubtitle(tripCount: Int, listFailed: Bool) -> String {
        tripCount == 0 && listFailed ? headerUnread : headerSubtitle(tripCount: tripCount)
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

    /// A trip card's second line: its taken dates and its count. The count is the server's for
    /// this account (`memberCount`); the dates are the drained members' first and last taken once
    /// they are read here (`summary`), else the trip's span, else none.
    static func tripDetail(
        _ trip: Trip, summary: TripMemberSummary?, locale: Locale, timeZone: TimeZone
    ) -> String {
        let counted = photoCount(trip.memberCount)
        let first = summary?.firstTaken ?? trip.spanStart
        let last = summary?.lastTaken ?? trip.spanEnd
        guard let text = spanText(first: first, last: last, locale: locale, timeZone: timeZone)
        else { return counted }
        return "\(text) · \(counted)"
    }

    /// An automatic collection's line under its title (MEMNG-817; owner, 13:09 CEST 2026-10-14:
    /// "the same subheading below the title as for trips: timespan and amount of pictures").
    ///
    /// - A summary of a drain that read every member: its taken span and its count, as a trip's.
    /// - A summary of a drain that stopped short: the count alone — the card's, since the members
    ///   read are not all of them, and neither are their dates.
    /// - Nothing settled yet: a month's or a year's own period and the card's count
    ///   ("September 2026 · 143 photos"), a tag's count alone.
    ///
    /// The card's count is shown only under the account the card was read for (`carrying`).
    static func automaticDetail(
        _ collection: AutomaticCollection, summary: TripMemberSummary?, carrying: Bool,
        locale: Locale, timeZone: TimeZone
    ) -> String? {
        if let summary, summary.complete {
            let counted = photoCount(summary.count)
            guard
                let text = spanText(
                    first: summary.firstTaken, last: summary.lastTaken, locale: locale,
                    timeZone: timeZone)
            else { return counted }
            return "\(text) · \(counted)"
        }
        let counted = carrying ? photoCount(collection.count) : nil
        if summary != nil { return counted }
        switch (periodText(collection, locale: locale), counted) {
        case (let period?, let counted?): return "\(period) · \(counted)"
        case (let period?, nil): return period
        case (nil, let counted): return counted
        }
    }

    /// A month's or a year's own name in its zone — "September 2026", "2026" — or nil for a tag.
    static func periodText(_ collection: AutomaticCollection, locale: Locale) -> String? {
        guard let period = collection.period else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = period.zone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = period.zone
        switch collection.kind {
        case .tag: return nil
        case .month: formatter.setLocalizedDateFormatFromTemplate("MMMMy")
        case .year: formatter.setLocalizedDateFormatFromTemplate("y")
        }
        return formatter.string(from: period.start)
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

    /// The cover a trip card shows: the chosen one while it is a drained member, else the first
    /// member (`TripMemberStore.summary`); before the members are read here, the server's chosen
    /// cover. Nil draws the placeholder, never a broken tile.
    static func cover(of trip: Trip, summary: TripMemberSummary?) -> MemoAttachment? {
        (summary?.cover ?? trip.cover)?.attachment
    }

    /// What each card shows for its trip: the store's summary, else the one it last showed while
    /// that one still fits the trip — a change to any trip lets every trip's members go, and the
    /// card keeps its dates and cover for the time the re-read takes. Only under the identity
    /// it was read for: another account's trip of the same uid is not this one's.
    static func shownSummary(
        of trip: Trip, store: TripMemberSummary?, held: [String: HeldTripSummary],
        under identity: TimelineSnapshotIdentity?
    ) -> TripMemberSummary? {
        store ?? held[trip.uid]?.summary(for: trip, under: identity)
    }

    /// One card of the Months row: the bucket's key, its title, its count and its cover.
    struct MonthCard: Equatable, Identifiable {
        let key: String
        let title: String
        let count: Int
        let cover: MemoAttachment?
        var id: String { key }
    }

    /// The Months row's cards (MEMNG-783): each month bucket titled with its short month and year
    /// (`monthBucketLabel`, "Sep 2026"), newest first, with its count and its own cover. A key
    /// that names no month has no card.
    static func monthCards(_ buckets: [LibraryBucket]) -> [MonthCard] {
        buckets.compactMap { bucket in
            monthBucketLabel(bucket.key).map {
                MonthCard(
                    key: bucket.key, title: $0, count: bucket.count,
                    cover: LibraryBucketCover.attachment(for: bucket))
            }
        }
        .sorted { $0.key > $1.key }
    }

    /// The buckets `store` holds while they answer a read of `size`, every kind, every tag and
    /// everyone's pictures of any visibility (MEMNG-787), in its own zone — else nil, so a failed
    /// or another read puts no row on screen.
    static func bucketsShown(_ store: LibraryBucketStore, size: LibraryBucketSize)
        -> [LibraryBucket]?
    {
        guard let request = store.loadedRequest, request.size == size, request.filter == .all,
            request.tag == nil, !request.mine, request.visibility == .any,
            request.timeZoneIdentifier == store.timeZoneIdentifier
        else { return nil }
        return store.buckets
    }

    /// The tags the listed trips are made of (decision H) — none while the list is unread or
    /// failed, since a list nobody has read says nothing about which tags are trips.
    static func tripTags(_ trips: [Trip], listFailed: Bool) -> Set<String> {
        listFailed ? [] : Set(trips.compactMap(\.tag))
    }

    /// `tags` in their order, less every one in `tripTags`: a trip's tag is the trip's card, not a
    /// tag's, and no second trip is made of it.
    static func tags(_ tags: [LibraryTag], excluding tripTags: Set<String>) -> [LibraryTag] {
        tags.filter { !tripTags.contains($0.name) }
    }

    /// The pushed collections that still exist: the stack up to the first trip `ids` no longer
    /// holds, since a screen pushed from a trip that is gone has nothing to stand on either. A tag,
    /// a month or a year has no record to lose, and stays (MEMNG-817).
    static func trail(_ routes: [CollectionRoute], keeping ids: [String]) -> [CollectionRoute] {
        let kept = Set(ids)
        return Array(routes.prefix { !$0.scope.isTrip || kept.contains($0.id) })
    }
}

/// A card's last summary, the trip it was read for and whose trip that was: it stands in only for
/// a trip with the same tag, span and chosen cover under the same identity, since a summary of
/// anything else would show the wrong dates — or another account's.
struct HeldTripSummary: Equatable {
    let identity: TimelineSnapshotIdentity?
    let tag: String?
    let span: TripSpan?
    let cover: String?
    let summary: TripMemberSummary

    init(_ trip: Trip, _ summary: TripMemberSummary, under identity: TimelineSnapshotIdentity?) {
        self.identity = identity
        tag = trip.tag
        span = trip.tripSpan
        cover = trip.cover?.id
        self.summary = summary
    }

    func summary(for trip: Trip, under identity: TimelineSnapshotIdentity?) -> TripMemberSummary? {
        guard identity != nil, identity == self.identity else { return nil }
        return tag == trip.tag && span == trip.tripSpan && cover == trip.cover?.id ? summary : nil
    }
}
