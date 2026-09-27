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
