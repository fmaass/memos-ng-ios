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

    /// The buckets this view is drawn from, or nil for All, which reads the list instead.
    ///
    /// Months reads DAY buckets, not month buckets: its tiles are days, and a year chosen on the
    /// Years view narrows them on the device (`dayBuckets(_:inYear:)`), the way the web does.
    public var bucketSize: LibraryBucketSize? {
        switch self {
        case .years: .year
        case .months: .day
        case .all: nil
        }
    }
}

/// The buckets a view of this scope may draw, or nil when the store's list does not answer the
/// selection on screen: the size this scope is drawn from, the kind and tag the grid is narrowed
/// to, and the zone the store counts in.
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
    timeZoneIdentifier: String,
    buckets: [LibraryBucket],
    answering request: LibraryBucketRequest?
) -> [LibraryBucket]? {
    guard let size = scope.bucketSize else { return nil }
    let wanted = LibraryBucketRequest(
        size: size,
        filter: filter,
        tag: tag,
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

/// One day of the Months mosaic: its bucket and the day of the month it prints.
public struct LibraryMosaicTile: Sendable, Equatable, Identifiable {
    public let bucket: LibraryBucket
    /// "14" for `2026-09-14`, "3" for `2026-09-03`; the whole key for one that is not a day.
    public let dayLabel: String

    public var id: String { bucket.key }
}

/// One month of the Months view: its header and its days, in the order the server listed them.
public struct LibraryMosaicMonth: Sendable, Equatable, Identifiable {
    /// `YYYY-MM`, or `undatedSectionKey` for a key that names no day.
    public let key: String
    /// "September 2026", in English as `groupByMonth` labels the All view's months.
    public let label: String
    public let tiles: [LibraryMosaicTile]

    public var id: String { key }
}

/// Day buckets filed under their months.
///
/// Months follow the order their first day arrives in and days keep the list's order within them,
/// so newest-first from the server stays newest-first on screen. A bucket without a cover is laid
/// out like any other — whether a cover can be drawn is the tile's question, not the layout's. A
/// key that is not `YYYY-MM-DD` is filed under "Undated" rather than dropped, as `groupByMonth`
/// files a row with no instant.
public func mosaicMonths(_ days: [LibraryBucket]) -> [LibraryMosaicMonth] {
    var order: [String] = []
    var labels: [String: String] = [:]
    var tiles: [String: [LibraryMosaicTile]] = [:]
    for bucket in days {
        let day = LibraryDayKey(bucket.key)
        let key = day?.monthKey ?? undatedSectionKey
        if tiles[key] == nil {
            order.append(key)
            labels[key] = day?.monthLabel ?? "Undated"
        }
        tiles[key, default: []].append(
            LibraryMosaicTile(bucket: bucket, dayLabel: day.map { "\($0.day)" } ?? bucket.key)
        )
    }
    return order.map { key in
        LibraryMosaicMonth(key: key, label: labels[key] ?? key, tiles: tiles[key] ?? [])
    }
}

/// What a bucket's card or tile says about its size: "1 item", "12 items".
public func bucketCountLabel(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count) items"
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

    var monthLabel: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en")
        return "\(calendar.standaloneMonthSymbols[month - 1]) \(year)"
    }
}
