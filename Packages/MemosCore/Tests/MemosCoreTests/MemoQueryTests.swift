import Foundation
import MemosCore
import Testing

/// What a search asks for, before anything has been sent.
///
/// `MemoQuery` is pure, so every claim here is stated against the value itself rather than read
/// back off a request: the calendar is named by the test, and the instants it should produce are
/// written out as the moments they are, computed by hand rather than by the code under test.
@Suite("MemoQuery")
struct MemoQueryTests {
    /// Europe/Berlin, because it is the household's time zone and because it changes offset twice
    /// a year — which is the whole of what the day-to-bound mapping has to survive.
    private static var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test("a day maps to created_before at the start of the next local day")
    func aDayMapsToTheStartOfTheNextLocalDay() {
        let calendar = Self.berlin

        // An ordinary summer day. CEST is UTC+2, so the next local midnight is 22:00 the day
        // before, in UTC — which is what the server is actually compared against.
        #expect(
            MemoQuery(anchor: .day(year: 2026, month: 8, day: 24)).parameters(in: calendar)
                .createdBefore == Self.instant("2026-08-24T22:00:00Z"),
            "a summer day did not end at the next local midnight"
        )

        // The night the clocks go back: 25 October 2026 is 25 hours long in Berlin. Adding a fixed
        // 86 400 s to its start lands at 22:00Z — an hour before the day is over — and every memo
        // written in that last hour would be missing from a list anchored at this day.
        #expect(
            MemoQuery(anchor: .day(year: 2026, month: 10, day: 25)).parameters(in: calendar)
                .createdBefore == Self.instant("2026-10-25T23:00:00Z"),
            "the 25-hour day was cut an hour short"
        )

        // The night the clocks go forward: 29 March 2026 is 23 hours long. A fixed-length day
        // overshoots here, pulling the first hour of the NEXT day into the list.
        #expect(
            MemoQuery(anchor: .day(year: 2026, month: 3, day: 29)).parameters(in: calendar)
                .createdBefore == Self.instant("2026-03-29T22:00:00Z"),
            "the 23-hour day reached into the day after it"
        )

        // A month anchor is the same rule one period up: the first instant after the month.
        #expect(
            MemoQuery(anchor: .month(year: 2026, month: 8)).parameters(in: calendar)
                .createdBefore == Self.instant("2026-08-31T22:00:00Z"),
            "a month did not end at the start of the next one"
        )
        #expect(
            MemoQuery(anchor: .month(year: 2026, month: 12)).parameters(in: calendar)
                .createdBefore == Self.instant("2026-12-31T23:00:00Z"),
            "a December anchor did not roll into the next year"
        )

        // The same day read in another time zone is another instant — the bound is local, and a
        // control that it is not silently computed in UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(
            MemoQuery(anchor: .day(year: 2026, month: 8, day: 24)).parameters(in: utc)
                .createdBefore == Self.instant("2026-08-25T00:00:00Z"),
            "control: the bound ignored the calendar it was given"
        )
    }

    @Test("a term and a day travel as one query")
    func aTermAndADayTravelTogether() {
        let calendar = Self.berlin
        let both = MemoQuery(term: "travel", anchor: .day(year: 2026, month: 8, day: 24))
        let parameters = both.parameters(in: calendar)

        #expect(parameters.q == "travel", "the day erased the term")
        #expect(
            parameters.createdBefore == Self.instant("2026-08-24T22:00:00Z"),
            "the term erased the day"
        )
        #expect(!both.isEmpty)

        // Controls: each half alone carries only its own parameter, so the test above is about the
        // two composing rather than about one of them being set unconditionally.
        let termOnly = MemoQuery(term: "travel").parameters(in: calendar)
        #expect(termOnly.q == "travel")
        #expect(termOnly.createdBefore == nil, "control: a term alone invented a date bound")
        let day = MemoQuery(anchor: .day(year: 2026, month: 8, day: 24))
        let dayOnly = day.parameters(in: calendar)
        #expect(dayOnly.q == nil, "control: a day alone invented a search term")
        #expect(dayOnly.createdBefore == Self.instant("2026-08-24T22:00:00Z"))

        // The rest of the filters compose with them just as flatly.
        let everything = MemoQuery(
            term: "travel",
            anchor: .day(year: 2026, month: 8, day: 24),
            tags: ["trip", "food"],
            visibility: .protected,
            includeArchived: true
        )
        let all = everything.parameters(in: calendar)
        #expect(all.q == "travel")
        #expect(all.createdBefore == Self.instant("2026-08-24T22:00:00Z"))
        #expect(all.tag == ["trip", "food"])
        #expect(all.visibility == .protected)
        #expect(all.includeArchived == true)
        #expect(all.archivedOnly == nil, "an archive flag that is off is left out, not sent false")
    }

    @Test("an empty query is the plain timeline request")
    func anEmptyQueryAsksForNothing() {
        let parameters = MemoQuery().parameters(in: Self.berlin)

        #expect(parameters == MemoQuery.Parameters(), "an empty query put something on the wire")
        #expect(parameters.q == nil)
        #expect(parameters.createdBefore == nil)
        #expect(parameters.tag == nil)
        #expect(parameters.visibility == nil)
        // Absent, not `false`: the server defaults both to False, and leaving them out is what
        // keeps the plain request the one this app has always sent.
        #expect(parameters.includeArchived == nil)
        #expect(parameters.archivedOnly == nil)
        #expect(MemoQuery().isEmpty)
        #expect(MemoQuery() == MemoQuery.empty)

        // A field of spaces is not a search, and neither is a tag of spaces: both normalise to the
        // plain timeline rather than reaching the wire as an empty parameter.
        #expect(MemoQuery(term: "   ") == MemoQuery.empty)
        #expect(MemoQuery(term: "\n\t").isEmpty)
        #expect(MemoQuery(tags: ["", "  "]) == MemoQuery.empty)
        #expect(MemoQuery(term: "  travel  ").term == "travel", "the term kept its whitespace")

        // Controls: anything actually asked for is NOT the plain request.
        #expect(!MemoQuery(term: "travel").isEmpty)
        #expect(!MemoQuery(anchor: .month(year: 2026, month: 8)).isEmpty)
        #expect(!MemoQuery(tags: ["trip"]).isEmpty)
        #expect(!MemoQuery(visibility: .public).isEmpty)
        #expect(!MemoQuery(includeArchived: true).isEmpty)
        #expect(!MemoQuery(archivedOnly: true).isEmpty)
    }

    @Test("a query round-trips through its own serialization")
    func aQueryRoundTripsThroughItsOwnSerialization() throws {
        let calendar = Self.berlin
        let queries: [MemoQuery] = [
            .empty,
            MemoQuery(term: "travel"),
            MemoQuery(anchor: .day(year: 2026, month: 10, day: 25)),
            MemoQuery(anchor: .month(year: 2026, month: 12)),
            MemoQuery(
                term: "travel",
                anchor: .day(year: 2026, month: 8, day: 24),
                tags: ["trip", "food"],
                visibility: .protected,
                includeArchived: true,
                archivedOnly: true
            ),
        ]

        for query in queries {
            let data = try JSONEncoder().encode(query)
            let restored = try JSONDecoder().decode(MemoQuery.self, from: data)
            #expect(restored == query, "a query did not survive being written down")
            #expect(
                restored.parameters(in: calendar) == query.parameters(in: calendar),
                "a query survived but asks the server for something else"
            )
        }

        // A decoded query is normalised like every other one — a blank term written into storage
        // by hand cannot come back as a search for nothing.
        let blank = #"{"term":"   ","tags":["","trip"]}"#
        let decoded = try JSONDecoder().decode(MemoQuery.self, from: Data(blank.utf8))
        #expect(decoded == MemoQuery(tags: ["trip"]))
        #expect(decoded.parameters(in: calendar).q == nil)

        // Control: two queries that differ do not decode equal, so the assertions above are about
        // the round trip rather than about everything comparing equal.
        let one = try JSONEncoder().encode(MemoQuery(term: "travel"))
        #expect(try JSONDecoder().decode(MemoQuery.self, from: one) != MemoQuery(term: "food"))
    }
}
