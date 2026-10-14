import Foundation
@testable import MemosCore
import Testing

/// The scope a collection screen is opened on (MEMNG-817): its id, its title as the card wrote
/// it, and a month's or a year's interval in the zone its bucket was counted in.
@Suite("Collection scope — ids, titles and periods")
struct CollectionScopeTests {
    static let zurich = TimeZone(identifier: "Europe/Zurich")!

    static func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    static func automatic(
        _ kind: AutomaticCollection.Kind, count: Int = 3, cover: CollectionCover? = nil,
        zone: TimeZone = zurich
    ) -> AutomaticCollection {
        AutomaticCollection(kind: kind, count: count, cover: cover, zone: zone)
    }

    @Test("each scope has its own id: the trip's uid, tag:, month:, year:")
    func ids() {
        let trip = Trip(uid: "t1", title: "Lisbon", tag: "lisbon", createdAt: .now, updatedAt: .now)
        #expect(CollectionScope.trip(trip).id == "t1")
        #expect(CollectionScope.automatic(Self.automatic(.tag("lisbon"))).id == "tag:lisbon")
        #expect(CollectionScope.automatic(Self.automatic(.month("2026-09"))).id == "month:2026-09")
        #expect(CollectionScope.automatic(Self.automatic(.year("2026"))).id == "year:2026")
        let scopes: Set<CollectionScope> = [
            .trip(trip), .automatic(Self.automatic(.tag("lisbon"))),
            .automatic(Self.automatic(.tag("lisbon"))),
        ]
        #expect(scopes.count == 2, "a trip and its own tag collapsed, or one tag counted twice")
    }

    @Test("titles are the cards' own: #tag, the Months view's label, the year")
    func titles() {
        #expect(Self.automatic(.tag("lisbon")).title == "#lisbon")
        #expect(Self.automatic(.month("2026-09")).title == "Sep 2026")
        #expect(Self.automatic(.month("2026-09")).title == monthBucketLabel("2026-09"))
        #expect(Self.automatic(.year("2026")).title == "2026")
        let trip = Trip(uid: "t1", title: "Lisbon", createdAt: .now, updatedAt: .now)
        #expect(CollectionScope.trip(trip).title == "Lisbon")
    }

    @Test("only a trip is a trip; a tag names its tag and has no span; a month has one")
    func kindFacts() throws {
        let trip = Trip(uid: "t1", title: "Lisbon", tag: "lisbon", createdAt: .now, updatedAt: .now)
        #expect(CollectionScope.trip(trip).isTrip)
        #expect(CollectionScope.trip(trip).tag == "lisbon")
        let tag = CollectionScope.automatic(Self.automatic(.tag("lisbon")))
        #expect(!tag.isTrip)
        #expect(tag.tag == "lisbon")
        #expect(tag.span == nil, "a tag has no span")
        let month = CollectionScope.automatic(Self.automatic(.month("2026-09")))
        #expect(month.tag == nil)
        let span = try #require(month.span)
        #expect(span.start == Self.instant("2026-08-31T22:00:00Z"))
        #expect(span.end == Self.instant("2026-09-30T21:59:59Z"))
        #expect(span.zone == "Europe/Zurich")
    }

    @Test("the carried cover is the card's picture and its thumbnail")
    func carriedCover() throws {
        let url = URL(string: "https://memos.example.invalid/api/attachments/c1/thumb")
        let scope = CollectionScope.automatic(
            Self.automatic(.month("2026-09"), cover: CollectionCover(uid: "c1", thumbnailURL: url)))
        let carried = try #require(scope.carriedCover)
        #expect(carried.uid == "c1")
        #expect(carried.thumbnailURL == url)
        #expect(CollectionScope.automatic(Self.automatic(.tag("x"))).carriedCover == nil)
    }

    @Test("a month's upper bound is the next month's first instant, across both DST changes")
    func dstMonths() throws {
        let march = try #require(CollectionPeriod(month: "2026-03", in: Self.zurich))
        #expect(march.start == Self.instant("2026-02-28T23:00:00Z"), "not 1 March 00:00 CET")
        #expect(march.nextStart == Self.instant("2026-03-31T22:00:00Z"), "not 1 April 00:00 CEST")
        let october = try #require(CollectionPeriod(month: "2026-10", in: Self.zurich))
        #expect(october.start == Self.instant("2026-09-30T22:00:00Z"), "not 1 October 00:00 CEST")
        #expect(
            october.nextStart == Self.instant("2026-10-31T23:00:00Z"), "not 1 November 00:00 CET")
        let december = try #require(CollectionPeriod(month: "2026-12", in: Self.zurich))
        #expect(december.nextStart == Self.instant("2026-12-31T23:00:00Z"), "December did not roll")
        let year = try #require(CollectionPeriod(year: "2026", in: Self.zurich))
        #expect(year.start == Self.instant("2025-12-31T23:00:00Z"))
        #expect(year.nextStart == Self.instant("2026-12-31T23:00:00Z"))
    }

    @Test("the final second and the start are in; nextStart and the second before start are out")
    func boundsInclusion() throws {
        let october = try #require(CollectionPeriod(month: "2026-10", in: Self.zurich))
        #expect(october.contains(Self.instant("2026-10-31T22:59:59Z")), "the final second")
        #expect(october.contains(Self.instant("2026-10-31T22:59:59.900Z")), "its last fraction")
        #expect(!october.contains(Self.instant("2026-10-31T23:00:00Z")), "nextStart")
        #expect(october.contains(Self.instant("2026-09-30T22:00:00Z")), "the exact start")
        #expect(!october.contains(Self.instant("2026-09-30T21:59:59Z")), "one second before")
    }

    @Test("a key naming no period has none, and the month and year keys are digits only")
    func malformedKeys() {
        #expect(CollectionPeriod(month: "2026-13", in: Self.zurich) == nil)
        #expect(CollectionPeriod(month: "2026-9", in: Self.zurich) == nil)
        #expect(CollectionPeriod(month: "+026-09", in: Self.zurich) == nil)
        #expect(CollectionPeriod(year: "+026", in: Self.zurich) == nil)
        #expect(CollectionPeriod(year: "26", in: Self.zurich) == nil)
        #expect(Self.automatic(.tag("x")).period == nil)
        #expect(Self.automatic(.month("2026-09")).period != nil, "control: a good key has one")
    }
}
