import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// A day is a local idea and a page is not a day. Both of those are easy to get wrong in a way
/// nothing but a test would notice — the first only bites people in a timezone, the second only
/// once the list is long enough to paginate.
@MainActor
@Suite("Timeline day grouping")
struct TimelineGroupingTests {
    /// Berlin: an hour ahead of UTC in winter, two in summer. A UTC-based grouping puts every
    /// memo written after 23:00 local on the wrong day here, which is precisely the bug.
    private func berlin() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func memo(_ uid: String, _ iso: String) -> Memo {
        MemoFixture.memo(uid: uid, content: uid, createdAt: instant(iso))
    }

    @Test("memos fall on the day they were written where the reader is standing")
    func daysAreLocal() {
        let calendar = berlin()
        // 22:30 UTC on 1 March is 23:30 on 1 March in Berlin — same day.
        // 23:30 UTC on 1 March is 00:30 on 2 MARCH in Berlin — the next one.
        let sections = TimelineGrouping.sections(
            for: [
                memo("late", "2026-03-01T23:30:00Z"),
                memo("earlier", "2026-03-01T22:30:00Z"),
            ],
            calendar: calendar
        )
        #expect(sections.count == 2)
        #expect(sections[0].memos.map(\.uid) == ["late"])
        #expect(sections[1].memos.map(\.uid) == ["earlier"])
        #expect(calendar.component(.day, from: sections[0].day) == 2)
        #expect(calendar.component(.day, from: sections[1].day) == 1)
    }

    @Test("the minute either side of local midnight is two different days")
    func nearMidnightBoundary() {
        let calendar = berlin()
        // 22:59:59Z and 23:00:01Z are 23:59:59 and 00:00:01 local, on either side of midnight.
        let sections = TimelineGrouping.sections(
            for: [
                memo("justAfter", "2026-03-01T23:00:01Z"),
                memo("justBefore", "2026-03-01T22:59:59Z"),
            ],
            calendar: calendar
        )
        #expect(sections.count == 2)
        #expect(sections[0].memos.map(\.uid) == ["justAfter"])
        #expect(sections[1].memos.map(\.uid) == ["justBefore"])
        // And midnight itself belongs to the day it opens, not the one it closes.
        let midnight = TimelineGrouping.sections(
            for: [memo("midnight", "2026-03-01T23:00:00Z")],
            calendar: calendar
        )
        #expect(calendar.component(.day, from: midnight[0].day) == 2)
        #expect(calendar.component(.hour, from: midnight[0].day) == 0)
    }

    /// The list arrives a cursor page at a time and a day routinely straddles the boundary.
    /// Grouping the page instead of the list prints the same date header twice with the day cut in
    /// half between them — this is the assertion that catches it.
    @Test("a day split across two cursor pages is one day, not two")
    func aDaySpanningTwoPages() {
        let calendar = berlin()
        let firstPage = [
            memo("p1a", "2026-03-02T18:00:00Z"),
            memo("p1b", "2026-03-02T09:00:00Z"),
        ]
        let secondPage = [
            memo("p2a", "2026-03-02T08:00:00Z"),
            memo("p2b", "2026-03-01T20:00:00Z"),
        ]
        let afterFirst = TimelineGrouping.sections(for: firstPage, calendar: calendar)
        #expect(afterFirst.count == 1)

        let afterSecond = TimelineGrouping.sections(
            for: firstPage + secondPage, calendar: calendar
        )
        #expect(afterSecond.count == 2)
        #expect(afterSecond[0].memos.map(\.uid) == ["p1a", "p1b", "p2a"])
        #expect(afterSecond[1].memos.map(\.uid) == ["p2b"])
        // One section per day, and each day named once.
        #expect(Set(afterSecond.map(\.day)).count == afterSecond.count)
    }

    @Test("a day is still one day when its memos do not arrive together")
    func nonContiguousArrivalStillMerges() {
        let calendar = berlin()
        let sections = TimelineGrouping.sections(
            for: [
                memo("mondayEvening", "2026-03-02T18:00:00Z"),
                memo("sunday", "2026-03-01T12:00:00Z"),
                memo("mondayMorning", "2026-03-02T07:00:00Z"),
            ],
            calendar: calendar
        )
        #expect(sections.count == 2)
        #expect(sections[0].memos.map(\.uid) == ["mondayEvening", "mondayMorning"])
        #expect(sections[1].memos.map(\.uid) == ["sunday"])
    }

    @Test("an empty list has no days")
    func emptyList() {
        #expect(TimelineGrouping.sections(for: [], calendar: berlin()).isEmpty)
    }

    @Test("the two most recent days are named rather than dated")
    func headerTitles() {
        let calendar = berlin()
        let now = instant("2026-03-02T12:00:00Z")
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let older = calendar.date(byAdding: .day, value: -9, to: today)!
        #expect(TimelineGrouping.title(for: today, now: now, calendar: calendar) == "Today")
        #expect(
            TimelineGrouping.title(for: yesterday, now: now, calendar: calendar) == "Yesterday"
        )
        let olderTitle = TimelineGrouping.title(for: older, now: now, calendar: calendar)
        #expect(olderTitle != "Today")
        #expect(olderTitle != "Yesterday")
        #expect(!olderTitle.isEmpty)
    }
}
