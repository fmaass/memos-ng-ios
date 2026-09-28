import Foundation
import Testing

// `LibraryBucketRequest` is built by the store alone; a test names one to say which read a list
// answers.
@testable import MemosCore

/// What the Library's Years and Months views present (MEMNG-586), held as values: which buckets a
/// view may draw, the year a Years card narrows the days to, and how those days file under months.
@Suite("Library bucket layout")
struct LibraryBucketLayoutTests {
    private static func bucket(
        _ key: String, _ count: Int = 1, cover: Bool = true
    ) -> LibraryBucket {
        LibraryBucket(
            key: key,
            count: count,
            coverUID: "cover-\(key)",
            coverThumbnailURL: cover
                ? URL(string: "https://memos.example.invalid/api/attachments/cover-\(key)/thumb")
                : nil
        )
    }

    private static func request(
        _ size: LibraryBucketSize,
        filter: MediaLibraryFilter = .all,
        tag: String? = nil,
        zone: String = "UTC"
    ) -> LibraryBucketRequest {
        LibraryBucketRequest(size: size, filter: filter, tag: tag, timeZoneIdentifier: zone)
    }

    /// `bucketsShown` for a selection on screen, which defaults to the one `request` reads.
    private static func shown(
        _ scope: LibraryScope,
        filter: MediaLibraryFilter = .all,
        tag: String? = nil,
        zone: String = "UTC",
        _ buckets: [LibraryBucket],
        answering request: LibraryBucketRequest?
    ) -> [LibraryBucket]? {
        bucketsShown(
            for: scope,
            filter: filter,
            tag: tag,
            timeZoneIdentifier: zone,
            buckets: buckets,
            answering: request
        )
    }

    // MARK: - scope

    @Test("each scope reads its own bucket size, All the day buckets its headings count")
    func scopeSizes() {
        #expect(LibraryScope.years.bucketSize == .year)
        #expect(LibraryScope.months.bucketSize == .day)
        // MEMNG-597: All reads day buckets for its day headings' counts.
        #expect(LibraryScope.all.bucketSize == .day)
        #expect(LibraryScope.allCases == [.years, .months, .all], "the segment's order")
        #expect(LibraryScope.allCases.map(\.label) == ["Years", "Months", "All"])
    }

    @Test("a view draws the store's list only when it answers a read of its own size")
    func bucketsShownOnlyForTheirSize() {
        let years = [Self.bucket("2026"), Self.bucket("2025")]
        #expect(Self.shown(.years, years, answering: Self.request(.year)) == years)
        // The list is still the Years view's while the Months read is on its way.
        #expect(Self.shown(.months, years, answering: Self.request(.year)) == nil)
        #expect(Self.shown(.years, years, answering: Self.request(.month)) == nil)
        #expect(Self.shown(.years, years, answering: nil) == nil)
        #expect(Self.shown(.all, years, answering: Self.request(.year)) == nil)
        let days = [Self.bucket("2026-09-14")]
        #expect(Self.shown(.months, days, answering: Self.request(.day)) == days)
    }

    /// A read for another kind that failed leaves the previous kind's list in the store; its covers
    /// and counts are not the kind on screen.
    @Test("a list read for another kind is not drawn, and one read for this kind is")
    func bucketsShownOnlyForTheirKind() {
        let images = [Self.bucket("2026", 12)]
        let read = Self.request(.year, filter: .images)
        #expect(Self.shown(.years, filter: .videos, images, answering: read) == nil)
        #expect(Self.shown(.years, filter: .all, images, answering: read) == nil)
        #expect(Self.shown(.years, filter: .images, images, answering: read) == images)
        #expect(
            Self.shown(.months, filter: .videos, images, answering: Self.request(.day)) == nil
        )
    }

    @Test("a list read under another tag, or under none, is not drawn, and one read for it is")
    func bucketsShownOnlyForTheirTag() {
        let untagged = [Self.bucket("2026", 12)]
        #expect(
            Self.shown(.years, tag: "travel", untagged, answering: Self.request(.year)) == nil
        )
        let travel = Self.request(.year, tag: "travel")
        #expect(Self.shown(.years, tag: nil, untagged, answering: travel) == nil)
        #expect(Self.shown(.years, tag: "family", untagged, answering: travel) == nil)
        #expect(Self.shown(.years, tag: "travel", untagged, answering: travel) == untagged)
    }

    @Test("a list counted in another zone is not drawn")
    func bucketsShownOnlyForTheirZone() {
        let years = [Self.bucket("2026")]
        let auckland = Self.request(.year, zone: "Pacific/Auckland")
        #expect(Self.shown(.years, zone: "UTC", years, answering: auckland) == nil)
        #expect(Self.shown(.years, zone: "Pacific/Auckland", years, answering: auckland) == years)
    }

    @Test("an answered empty list is empty, not unanswered")
    func anAnsweredEmptyListIsEmpty() {
        #expect(Self.shown(.years, [], answering: Self.request(.year)) == [])
        #expect(Self.shown(.years, [], answering: nil) == nil)
    }

    // MARK: - year filter

    @Test("a year keeps exactly its own days, in the list's order")
    func yearKeepsItsOwnDays() {
        let days = [
            Self.bucket("2027-01-02"),
            Self.bucket("2026-12-31"),
            Self.bucket("2026-09-14"),
            Self.bucket("2025-12-31"),
            Self.bucket("2026-01-01"),
        ]
        let kept = dayBuckets(days, inYear: "2026").map(\.key)
        #expect(kept == ["2026-12-31", "2026-09-14", "2026-01-01"])
        #expect(dayBuckets(days, inYear: "2025").map(\.key) == ["2025-12-31"])
        #expect(dayBuckets(days, inYear: "2024") == [])
    }

    @Test("a year is matched as a whole field, not as a bare prefix")
    func yearIsAWholeField() {
        let days = [Self.bucket("2026-09-14"), Self.bucket("20261-01-01")]
        #expect(dayBuckets(days, inYear: "202") == [])
        #expect(dayBuckets(days, inYear: "2026").map(\.key) == ["2026-09-14"])
    }

    @Test("no days, or no year, is nothing")
    func emptyInputIsEmpty() {
        #expect(dayBuckets([], inYear: "2026") == [])
        #expect(dayBuckets([Self.bucket("2026-09-14")], inYear: "") == [])
    }

    // MARK: - mosaic

    @Test("days file under their months, each month once in arrival order, days in date order")
    func daysFileUnderMonths() {
        let days = [
            Self.bucket("2026-09-14", 3),
            Self.bucket("2026-09-03", 1),
            Self.bucket("2026-08-31", 7),
            Self.bucket("2025-12-25", 2),
            Self.bucket("2025-12-01", 4),
            Self.bucket("2025-11-30", 5),
        ]
        let months = mosaicMonths(days)
        #expect(months.map(\.key) == ["2026-09", "2026-08", "2025-12", "2025-11"])
        #expect(
            months.map(\.label)
                == ["Sep 2026", "Aug 2026", "Dec 2025", "Nov 2025"]
        )
        #expect(months.map(\.tiles.count) == [2, 1, 2, 1])
        #expect(
            months.map { $0.tiles.map(\.bucket.key) } == [
                ["2026-09-03", "2026-09-14"], ["2026-08-31"], ["2025-12-01", "2025-12-25"],
                ["2025-11-30"],
            ]
        )
        #expect(months[0].tiles.map(\.dayLabel) == ["3", "14"])
        #expect(months[0].tiles.map(\.bucket.count) == [1, 3], "a tile carries its day's count")
    }

    @Test("a day that arrives out of order still joins its month rather than opening another")
    func aMonthIsOneSection() {
        let days = [
            Self.bucket("2026-09-14"),
            Self.bucket("2026-08-02"),
            Self.bucket("2026-09-01"),
        ]
        let months = mosaicMonths(days)
        #expect(months.map(\.key) == ["2026-09", "2026-08"])
        #expect(months[0].tiles.map(\.bucket.key) == ["2026-09-01", "2026-09-14"])
    }

    @Test("a day without a cover is laid out like any other")
    func aMissingCoverIsLaidOut() {
        let days = [
            Self.bucket("2026-09-14"),
            Self.bucket("2026-09-13", 2, cover: false),
            Self.bucket("2026-09-12"),
        ]
        let months = mosaicMonths(days)
        #expect(months.count == 1)
        #expect(months[0].tiles.map(\.bucket.key) == ["2026-09-12", "2026-09-13", "2026-09-14"])
        #expect(months[0].tiles[1].bucket.coverThumbnailURL == nil)
        #expect(months[0].tiles[1].dayLabel == "13")
    }

    @Test("a key that names no day is filed under Undated, not dropped")
    func aKeyThatIsNoDayIsUndated() {
        let days = [
            Self.bucket("2026-09-14"),
            Self.bucket("2026"),
            Self.bucket("2026-13-01"),
            Self.bucket("+026-09-01"),
        ]
        let months = mosaicMonths(days)
        #expect(months.map(\.key) == ["2026-09", undatedSectionKey])
        #expect(months.map(\.label) == ["Sep 2026", "Undated"])
        // Picked and ordered like any month's days: by key, which for these is string order.
        #expect(months[1].tiles.map(\.bucket.key) == ["+026-09-01", "2026", "2026-13-01"])
        #expect(months[1].tiles.map(\.dayLabel) == ["+026-09-01", "2026", "2026-13-01"])
    }

    @Test("no days is no months")
    func noDaysNoMonths() {
        #expect(mosaicMonths([]) == [])
    }

    @Test("a count says item or items")
    func countLabel() {
        #expect(bucketCountLabel(1) == "1 item")
        #expect(bucketCountLabel(0) == "0 items")
        #expect(bucketCountLabel(12) == "12 items")
    }
}
