import Foundation

// What the Library's Years and Months views present, as values (MEMNG-586). The screen draws these
// and decides nothing: the Places split (docs/ARCHITECTURE.md), so a test can hold what is on
// screen without hosting it.

/// Which of the Library's three views is on screen: a card per year, the days of each month as a
/// mosaic, or every file in taken order.
public enum LibraryScope: String, Sendable, Equatable, CaseIterable, Identifiable {
    case years
    case months
    case all

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .years: "Years"
        case .months: "Months"
        case .all: "All"
        }
    }

    /// The buckets this view reads.
    ///
    /// Months reads DAY buckets, not month buckets: its tiles are days, and a year chosen on the
    /// Years view narrows them on the device (`dayBuckets(_:inYear:)`), the way the web does. All
    /// draws the list, and reads day buckets too for its day headings' counts (MEMNG-597, plan page
    /// 3929 decision 13): a heading counts the WHOLE day, as the web's does, never the fragment of
    /// it the pages loaded so far.
    public var bucketSize: LibraryBucketSize? {
        switch self {
        case .years: .year
        case .months, .all: .day
        }
    }
}

/// The buckets a view of this scope may draw, or nil when the store's list does not answer the
/// selection on screen: the size this scope is drawn from, the kind, tag and audience the grid is
/// narrowed to (MEMNG-787), and the zone the store counts in.
///
/// Every field is matched because the store keeps its last list when a read fails. One store
/// serves both views, so a switch leaves the other view's list in it until the new read lands — a
/// year key drawn as a day would be filed under "Undated" — and a read for Videos, or for a tag,
/// that fails leaves the Images list standing, whose covers and counts must not be drawn as if
/// they were the Videos ones. Nil rather than empty, so "nothing falls in these buckets" stays
/// distinguishable from "these buckets have not been read".
public func bucketsShown(
    for scope: LibraryScope,
    filter: MediaLibraryFilter,
    tag: String?,
    mine: Bool,
    visibility: MediaVisibilityFilter,
    timeZoneIdentifier: String,
    buckets: [LibraryBucket],
    answering request: LibraryBucketRequest?
) -> [LibraryBucket]? {
    guard let size = scope.bucketSize else { return nil }
    let wanted = LibraryBucketRequest(
        size: size,
        filter: filter,
        tag: tag,
        mine: mine,
        visibility: visibility,
        timeZoneIdentifier: timeZoneIdentifier
    )
    guard request == wanted else { return nil }
    return buckets
}

/// The day buckets of one year: every day whose key begins with that year and a dash.
///
/// The dash is part of the prefix so that a year is matched as a whole field — a bare prefix would
/// let "202" keep every day of 2026.
public func dayBuckets(
    _ days: [LibraryBucket],
    inYear year: String
) -> [LibraryBucket] {
    let prefix = year + "-"
    return days.filter { $0.key.hasPrefix(prefix) }
}

/// One day of the Months mosaic: its bucket, the day of the month it prints and the frame it sits
/// in. It carries its day's count, which the tile does not draw (plan decision 9).
public struct LibraryMosaicTile: Sendable, Equatable, Identifiable {
    public let bucket: LibraryBucket
    /// "14" for `2026-09-14`, "3" for `2026-09-03`; the whole key for one that is not a day.
    public let dayLabel: String
    public let slot: MosaicSlot

    public var id: String { bucket.key }
}

/// One month of the Months view: its title, the days it shows and how many it left out.
public struct LibraryMosaicMonth: Sendable, Equatable, Identifiable {
    /// `YYYY-MM`, or `undatedSectionKey` for a key that names no day.
    public let key: String
    /// "Sep 2026" (plan decision 9). The All view's month headers keep the full name
    /// (`groupByMonth`); this label is the Months view's own.
    public let label: String
    /// The days `pickDays` kept, in date order.
    public let tiles: [LibraryMosaicTile]
    /// How many of the month's days are not drawn.
    public let dropped: Int

    public var id: String { key }

    /// "and 3 more days", "and 1 more day", or nil for a month that shows every day it has.
    public var moreDaysLabel: String? {
        guard dropped > 0 else { return nil }
        return dropped == 1 ? "and 1 more day" : "and \(dropped) more days"
    }

    /// Where the "more days" line opens All: the first day the month SHOWS, not its first day.
    public var firstShownDay: LibraryBucket? { tiles.first?.bucket }
}

/// Day buckets filed under their months, each month reduced to its `cap` busiest days.
///
/// Months follow the order their first day arrives in, so newest-first from the server stays
/// newest-first on screen; within a month, `pickDays` keeps the busiest and lays them out in date
/// order, and each month's frames start one pattern later than the month above it
/// (`mosaicSlots(_:offset:)` with the month's index). A bucket without a cover is laid out like any
/// other — whether a cover can be drawn is the tile's question, not the layout's. A key that is not
/// `YYYY-MM-DD` is filed under "Undated" rather than dropped, as `groupByMonth` files a row with no
/// instant, and is picked like any month's days.
public func mosaicMonths(_ days: [LibraryBucket], cap: Int = 6) -> [LibraryMosaicMonth] {
    var order: [String] = []
    var labels: [String: String] = [:]
    var members: [String: [LibraryBucket]] = [:]
    for bucket in days {
        let day = LibraryDayKey(bucket.key)
        let key = day?.monthKey ?? undatedSectionKey
        if members[key] == nil {
            order.append(key)
            labels[key] = day?.monthLabel ?? "Undated"
        }
        members[key, default: []].append(bucket)
    }
    return order.enumerated().map { index, key in
        let picked = pickDays(members[key] ?? [], cap: cap)
        let slots = mosaicSlots(picked.shown.count, offset: index)
        let tiles = zip(picked.shown, slots).map { bucket, slot in
            LibraryMosaicTile(
                bucket: bucket,
                dayLabel: LibraryDayKey(bucket.key).map { "\($0.day)" } ?? bucket.key,
                slot: slot
            )
        }
        return LibraryMosaicMonth(
            key: key, label: labels[key] ?? key, tiles: tiles, dropped: picked.dropped)
    }
}

/// What a bucket's card or tile says about its size: "1 item", "12 items".
public func bucketCountLabel(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count) items"
}

/// A month bucket's key (`YYYY-MM`) as its card titles it — "Sep 2026", the short month the
/// Library's Months view writes — or nil for a key that names no month.
public func monthBucketLabel(_ key: String) -> String? {
    guard key.count == 7 else { return nil }
    return LibraryDayKey(key + "-01")?.monthLabel
}

/// A `YYYY-MM-DD` day key read into its fields, or nil for anything else.
private struct LibraryDayKey {
    let year: Int
    let month: Int
    let day: Int

    init?(_ key: String) {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        // Digits only: `Int` alone would read "+026" as a year.
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    var monthKey: String { "\(year)-\(month < 10 ? "0" : "")\(month)" }

    /// "Sep 2026", as the web's `Intl.DateTimeFormat('en', { month: 'short' })` writes it. Spelled
    /// out rather than read from a locale, because a locale's short names are data that can move
    /// between releases, and this title must not.
    var monthLabel: String {
        "\(Self.shortMonths[month - 1]) \(year)"
    }

    private static let shortMonths = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
}
