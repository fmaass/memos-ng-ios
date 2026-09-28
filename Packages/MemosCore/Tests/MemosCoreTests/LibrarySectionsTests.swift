import Foundation
import MemosCore
import Testing

// The nine `groupByMonth` cases are memos-ng's `frontend/src/lib/librarySections.spec.ts` at
// v2.0.0, titles verbatim and vectors unchanged: if one changes, both sides change together or the
// port is broken. Every fixture sits where a UTC slice of the instant names a different month than
// the Zurich calendar does, or pairs such an item with the case under test — a UTC-sliced
// implementation fails every one of them.
//
// The `dayKey` suite and the unknown-zone case at the bottom are NOT from that spec: the SPA's
// spec has no `dayKey` vectors, and its `Intl` throws on an unknown zone where this port falls
// back.

private let zurich = "Europe/Zurich"

/// An instant as the spec writes it. Fractional seconds are parsed when present — vector 5 turns
/// on one millisecond.
private func instant(_ iso: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    if iso.contains(".") {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    return try #require(formatter.date(from: iso), "the fixture \(iso) did not parse")
}

private func row(_ uid: String, takenAt: Date?) -> LibraryRow {
    LibraryRow(
        attachment: MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready),
        takenAt: takenAt,
        mine: true,
        filename: "\(uid).jpg"
    )
}

/// The spec's `at(uid, takenAt)`.
private func at(_ uid: String, _ iso: String) throws -> LibraryRow {
    row(uid, takenAt: try instant(iso))
}

private func keys(_ items: [LibraryRow], _ timeZone: String? = nil) -> [String] {
    let sections = timeZone.map { groupByMonth(items, timeZone: $0) } ?? groupByMonth(items)
    return sections.map(\.key)
}

private func shape(_ sections: [LibraryMonthSection]) -> [[String]] {
    sections.map { [$0.key, $0.label] + $0.items.map(\.id) }
}

@Suite("groupByMonth")
struct LibrarySectionsTests {
    @Test("puts a 22:30 UTC item on the last of August into September in Zurich")
    func lateAugustIsSeptember() throws {
        let item = try at("a", "2026-08-31T22:30:00Z")
        let sections = groupByMonth([item], timeZone: zurich)
        try #require(sections.count == 1)
        #expect(sections[0].key == "2026-09")
        #expect(sections[0].label == "September 2026")
        #expect(sections[0].items == [item])
    }

    @Test("puts New Year's Eve 23:30 UTC into January of the next year")
    func newYearsEveIsJanuary() throws {
        let sections = try groupByMonth([at("a", "2025-12-31T23:30:00Z")], timeZone: zurich)
        #expect(sections.map { [$0.key, $0.label] } == [["2026-01", "January 2026"]])
    }

    @Test("keeps one March section across the spring DST change and follows the summer offset")
    func springChange() throws {
        let items = try [
            at("before", "2026-03-29T00:30:00Z"),  // 01:30 CET, before the clocks go forward
            at("after", "2026-03-29T01:30:00Z"),  // 03:30 CEST, after
            at("april", "2026-03-31T22:30:00Z"),  // 00:30 CEST on 1 April: +2 now, not +1
        ]
        let expected = [
            ["2026-03", "March 2026", "before", "after"],
            ["2026-04", "April 2026", "april"],
        ]
        #expect(shape(groupByMonth(items, timeZone: zurich)) == expected)
    }

    @Test("keeps one October section across the autumn DST change and follows the winter offset")
    func autumnChange() throws {
        let items = try [
            at("dst", "2026-10-25T00:30:00Z"),  // 02:30 CEST on the night the clocks go back
            at("november", "2026-10-31T23:30:00Z"),  // 00:30 CET on 1 November: +1 again
        ]
        let expected = [
            ["2026-10", "October 2026", "dst"],
            ["2026-11", "November 2026", "november"],
        ]
        #expect(shape(groupByMonth(items, timeZone: zurich)) == expected)
    }

    @Test("starts the month at exactly Zurich midnight, not a millisecond later")
    func monthStartsAtMidnight() throws {
        #expect(try keys([at("m", "2026-06-30T22:00:00Z")], zurich) == ["2026-07"])
        #expect(try keys([at("m", "2026-06-30T21:59:59.999Z")], zurich) == ["2026-06"])
    }

    @Test("keeps the list order: sections in order of first appearance, items in list order")
    func keepsListOrder() throws {
        let newestFirst = try [
            at("c", "2026-09-02T10:00:00Z"),
            at("b", "2026-08-31T22:30:00Z"),
            at("a", "2026-08-15T10:00:00Z"),
        ]
        let sections = groupByMonth(newestFirst, timeZone: zurich)
        let expected = [["2026-09", "c", "b"], ["2026-08", "a"]]
        #expect(sections.map { [$0.key] + $0.items.map(\.id) } == expected)
        #expect(keys(newestFirst.reversed(), zurich) == ["2026-08", "2026-09"])
    }

    @Test("defaults to Europe/Zurich and honours another zone when one is passed")
    func defaultAndOtherZone() throws {
        let late = try [at("a", "2026-08-31T22:30:00Z")]
        #expect(keys(late) == ["2026-09"])
        #expect(keys(late, "America/New_York") == ["2026-08"])
    }

    /// The SPA's fixture is the string `not-a-date`; `LibraryRow.takenAt` is a `Date?`, so an
    /// unreadable instant arrives here as a row whose `takenAt` is nil.
    @Test("files an unreadable takenAt under Undated instead of throwing out of Intl")
    func undatedSection() throws {
        let items = try [at("ok", "2026-09-02T10:00:00Z"), row("bad", takenAt: nil)]
        let expected = [
            ["2026-09", "September 2026", "ok"],
            ["undated", "Undated", "bad"],
        ]
        #expect(shape(groupByMonth(items, timeZone: zurich)) == expected)
    }

    @Test("returns no sections for no items")
    func noItems() {
        #expect(groupByMonth([], timeZone: zurich).isEmpty)
    }

    // Not from the spec: see the file header.
    @Test("a zone the system does not know groups in Europe/Zurich rather than failing")
    func unknownZoneFallsBack() throws {
        #expect(try keys([at("a", "2026-08-31T22:30:00Z")], "Not/AZone") == ["2026-09"])
    }
}

// Not from the spec: the SPA's spec carries no `dayKey` vectors.
@Suite("dayKey")
struct LibraryDayKeyTests {
    @Test("a day starts at exactly Zurich midnight, not a millisecond later")
    func dayStartsAtMidnight() throws {
        #expect(try dayKey(instant("2026-06-30T22:00:00Z")) == "2026-07-01")
        #expect(try dayKey(instant("2026-06-30T21:59:59.999Z")) == "2026-06-30")
    }

    @Test("honours another zone when one is passed")
    func otherZone() throws {
        let midnight = try instant("2026-06-30T22:00:00Z")
        #expect(dayKey(midnight, timeZone: "America/New_York") == "2026-06-30")
    }

    @Test("an instant that could not be read has no day")
    func noInstantNoDay() {
        #expect(dayKey(nil) == nil)
        #expect(dayKey(nil, timeZone: zurich) == nil)
    }
}

// MEMNG-597 (plan page 3929 decision 13): the All view's day groups, their labels and the day the
// scroll pill names — memos-ng `frontend/src/lib/__tests__/librarySections.spec.ts` at c8bd91e,
// titles verbatim and vectors unchanged. The spec's `not-a-date` string arrives here as a row
// whose `takenAt` is nil, as in `undatedSection` above.

private func dayShape(_ items: [LibraryRow], _ timeZone: String? = nil) -> [[String]] {
    let groups = timeZone.map { groupByDay(items, timeZone: $0) } ?? groupByDay(items)
    return groups.map { [$0.key] + $0.items.map(\.id) }
}

@Suite("groupByDay")
struct LibraryDayGroupTests {
    @Test("files a 23:30 UTC item on 30 September under 1 October in Zurich")
    func lateSeptemberIsOctober() throws {
        let item = try at("a", "2026-09-30T23:30:00Z")
        #expect(
            groupByDay([item], timeZone: zurich) == [
                LibraryDaySection(key: "2026-10-01", items: [item])
            ])
    }

    @Test(
        "keeps the list order, newest first: days in order of first appearance, items in list order"
    )
    func keepsListOrder() throws {
        let items = try [
            at("c", "2026-10-01T08:00:00Z"),
            at("b", "2026-09-30T23:30:00Z"),  // 01:30 CEST on 1 October
            at("a", "2026-09-30T12:00:00Z"),
            at("z", "2026-09-27T09:00:00Z"),
        ]
        #expect(
            dayShape(items, zurich) == [
                ["2026-10-01", "c", "b"],
                ["2026-09-30", "a"],
                ["2026-09-27", "z"],
            ])
    }

    @Test("keeps an ascending list ascending rather than re-sorting it")
    func keepsAscending() throws {
        let items = try [
            at("a", "2026-09-26T10:00:00Z"), at("b", "2026-09-27T10:00:00Z"),
            at("c", "2026-09-27T11:00:00Z"),
        ]
        #expect(dayShape(items, zurich) == [["2026-09-26", "a"], ["2026-09-27", "b", "c"]])
    }

    @Test("starts the day at exactly Zurich midnight, not a millisecond later")
    func startsAtMidnight() throws {
        #expect(try dayShape([at("m", "2026-09-26T22:00:00Z")], zurich) == [["2026-09-27", "m"]])
        #expect(
            try dayShape([at("m", "2026-09-26T21:59:59.999Z")], zurich) == [["2026-09-26", "m"]])
    }

    @Test("defaults to Europe/Zurich and honours another zone when one is passed")
    func defaultZone() throws {
        let late = try [at("a", "2026-09-30T23:30:00Z")]
        #expect(dayShape(late) == [["2026-10-01", "a"]])
        #expect(dayShape(late, "America/New_York") == [["2026-09-30", "a"]])
        #expect(dayShape(late, zurich) == [["2026-10-01", "a"]])
    }

    @Test("keeps an unreadable takenAt in its own group instead of dropping it or throwing")
    func undatedGroup() throws {
        let items = try [
            at("ok", "2026-09-27T10:00:00Z"), row("bad", takenAt: nil),
            at("ok2", "2026-09-27T11:00:00Z"),
        ]
        #expect(dayShape(items, zurich) == [["2026-09-27", "ok", "ok2"], ["undated", "bad"]])
    }

    @Test("returns no groups for no items")
    func noItems() {
        #expect(groupByDay([], timeZone: zurich).isEmpty)
    }
}

// 2026-09-26 is a Saturday and 2026-09-27 a Sunday.
@Suite("day labels")
struct LibraryDayLabelTests {
    @Test("names the heading row as weekday and day-month")
    func headingParts() {
        #expect(dayHeadingParts("2026-09-26") == DayHeadingParts(weekday: "Sat", date: "26 Sep"))
        #expect(dayHeadingParts("2026-09-27") == DayHeadingParts(weekday: "Sun", date: "27 Sep"))
    }

    @Test("names the scroll pill as weekday · day month year")
    func pillLabel() {
        #expect(dayPillLabel("2026-09-26") == "Sat · 26 Sep 2026")
        #expect(dayPillLabel("2027-01-01") == "Fri · 1 Jan 2027")
    }

    @Test("formats the key as a calendar date, so the first and last of a year stay put")
    func yearEdges() {
        #expect(dayHeadingParts("2026-01-01") == DayHeadingParts(weekday: "Thu", date: "1 Jan"))
        #expect(dayPillLabel("2025-12-31") == "Wed · 31 Dec 2025")
    }

    @Test("labels the undated group Undated")
    func undated() {
        #expect(dayHeadingParts("undated") == DayHeadingParts(weekday: "Undated", date: ""))
        #expect(dayPillLabel("undated") == "Undated")
    }

    @Test(
        "treats a key that only contains a date, or names no real day, as undated rather than throwing",
        arguments: ["x2026-09-26", "2026-09-26T10:00", "2026-02-30", "2026-13-01", ""]
    )
    func notADay(_ key: String) {
        #expect(dayHeadingParts(key) == DayHeadingParts(weekday: "Undated", date: ""))
        #expect(dayPillLabel(key) == "Undated")
    }
}

@Suite("topDay")
struct LibraryTopDayTests {
    private static let headings = [
        DayMarker(key: "2026-09-27", top: -300),
        DayMarker(key: "2026-09-26", top: 40),
        DayMarker(key: "2026-09-20", top: 400),
    ]

    @Test("is null when no heading has reached the threshold")
    func noneReached() {
        #expect(topDay(Self.headings, threshold: -301) == nil)
        #expect(topDay([], threshold: 100) == nil)
    }

    @Test("names the last heading in document order that has reached the threshold")
    func lastReached() {
        #expect(topDay(Self.headings, threshold: 100) == "2026-09-26")
        #expect(topDay(Self.headings, threshold: 1000) == "2026-09-20")
        #expect(topDay(Self.headings, threshold: -100) == "2026-09-27")
    }

    @Test("counts a heading exactly at the threshold as reached")
    func exactlyAtThreshold() {
        #expect(topDay(Self.headings, threshold: 40) == "2026-09-26")
        #expect(topDay(Self.headings, threshold: 39.5) == "2026-09-27")
    }
}
