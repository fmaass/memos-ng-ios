import Foundation
import Testing

@testable import MemosCore

/// The Months mosaic (MEMNG-596, plan decision 9), held to the web's vectors
/// (`frontend/src/lib/__tests__/mosaic.spec.ts` in memos-ng): the frame cycle, the six-day pick and
/// the month grouping. A ported pure function carries the SAME vectors as its spec, so a change on
/// either side changes both.
@Suite("Library mosaic")
struct LibraryMosaicTests {
    private static let a: [MosaicSlot] = [.heroLeft, .sideRight, .sideRight]
    private static let b: [MosaicSlot] = [.square, .square, .square]
    private static let c: [MosaicSlot] = [.heroRight, .sideLeft, .sideLeft]
    private static let d: [MosaicSlot] = [.wide]

    private static func day(_ key: String, _ count: Int) -> LibraryBucket {
        LibraryBucket(
            key: key,
            count: count,
            coverUID: "c-\(key)",
            coverThumbnailURL: URL(
                string: "https://memos.example.invalid/api/attachments/c-\(key)/thumb")
        )
    }

    // MARK: - mosaicSlots

    /// Written out tile by tile rather than derived from the patterns, so a wrong cycle cannot pass
    /// by agreeing with itself.
    private static let expectedSlots: [[MosaicSlot]] = [
        [],
        [.heroLeft],
        [.heroLeft, .sideRight],
        [.heroLeft, .sideRight, .sideRight],
        [.heroLeft, .sideRight, .sideRight, .square],
        [.heroLeft, .sideRight, .sideRight, .square, .square],
        [.heroLeft, .sideRight, .sideRight, .square, .square, .square],
        [.heroLeft, .sideRight, .sideRight, .square, .square, .square, .heroRight],
        [.heroLeft, .sideRight, .sideRight, .square, .square, .square, .heroRight, .sideLeft],
        [
            .heroLeft, .sideRight, .sideRight, .square, .square, .square,
            .heroRight, .sideLeft, .sideLeft,
        ],
        [
            .heroLeft, .sideRight, .sideRight, .square, .square, .square,
            .heroRight, .sideLeft, .sideLeft, .wide,
        ],
        [
            .heroLeft, .sideRight, .sideRight, .square, .square, .square,
            .heroRight, .sideLeft, .sideLeft, .wide, .heroLeft,
        ],
        [
            .heroLeft, .sideRight, .sideRight, .square, .square, .square,
            .heroRight, .sideLeft, .sideLeft, .wide, .heroLeft, .sideRight,
        ],
    ]

    @Test(
        "lays out n tiles as A, B, C, D cycling, a partial pattern cut at its last filled slot",
        arguments: 0...12
    )
    func slotsCycle(_ n: Int) {
        #expect(mosaicSlots(n) == Self.expectedSlots[n])
    }

    @Test("the patterns spell A, B, C, D in that order, each naming its hero first")
    func patternsAreTheDecision() {
        #expect(monthMosaicCycle == [.a, .b, .c, .d])
        #expect(monthMosaicCycle.map(\.slots) == [Self.a, Self.b, Self.c, Self.d])
    }

    @Test("reaches D at tile 10 and restarts the cycle at tile 11")
    func restartsAfterD() throws {
        let slots = mosaicSlots(11)
        try #require(slots.count == 11)
        #expect(slots[9] == .wide)
        #expect(slots[10] == .heroLeft)
    }

    @Test("starts the cycle at the pattern the offset names, 0 through 3")
    func offsetNamesTheFirstPattern() {
        #expect(mosaicSlots(10, offset: 0) == Self.a + Self.b + Self.c + Self.d)
        #expect(mosaicSlots(10, offset: 1) == Self.b + Self.c + Self.d + Self.a)
        #expect(mosaicSlots(10, offset: 2) == Self.c + Self.d + Self.a + Self.b)
        #expect(mosaicSlots(10, offset: 3) == Self.d + Self.a + Self.b + Self.c)
    }

    @Test("wraps an offset past the last pattern, so any section index is a valid offset")
    func offsetWraps() {
        #expect(mosaicSlots(4, offset: 4) == mosaicSlots(4, offset: 0))
        #expect(mosaicSlots(4, offset: 7) == Self.d + Self.a)
    }

    @Test("cuts a partial pattern after an offset too")
    func offsetThenCut() {
        #expect(mosaicSlots(2, offset: 2) == [.heroRight, .sideLeft])
        #expect(mosaicSlots(2, offset: 3) == [.wide, .heroLeft])
    }

    /// Not a web vector: the web wraps a negative offset the same way, and a count below zero is
    /// no tiles rather than a trap.
    @Test("a negative offset wraps backwards, and a negative count is no tiles")
    func negativeInputs() {
        #expect(mosaicSlots(1, offset: -1) == [.wide])
        #expect(mosaicSlots(3, offset: -4) == Self.a)
        #expect(mosaicSlots(-1) == [])
    }

    // MARK: - pickDays

    /// Nine days of September, newest first as the buckets endpoint returns them. The two days with
    /// 4 tie for the last place: the later one (the 8th) wins it.
    private static let nine = [
        day("2026-09-09", 1),
        day("2026-09-08", 4),
        day("2026-09-07", 9),
        day("2026-09-06", 2),
        day("2026-09-05", 7),
        day("2026-09-04", 4),
        day("2026-09-03", 8),
        day("2026-09-02", 6),
        day("2026-09-01", 5),
    ]

    @Test("keeps the six busiest of nine days in date order and reports three dropped")
    func sixOfNine() {
        let picked = pickDays(Self.nine)
        #expect(
            picked.shown.map(\.key) == [
                "2026-09-01", "2026-09-02", "2026-09-03", "2026-09-05", "2026-09-07", "2026-09-08",
            ]
        )
        #expect(picked.dropped == 3)
    }

    @Test("breaks a tie for the last place toward the later day, whatever order the input came in")
    func tieGoesToTheLaterDay() {
        let tied = [Self.day("2026-09-02", 3), Self.day("2026-09-01", 3)]
        #expect(pickDays(tied, cap: 1).shown.map(\.key) == ["2026-09-02"])
        #expect(pickDays(tied.reversed(), cap: 1).shown.map(\.key) == ["2026-09-02"])
    }

    @Test("passes six days through untouched with zero dropped")
    func sixPassThrough() {
        let six = Array(Self.nine.dropFirst(3).reversed())
        let picked = pickDays(six)
        #expect(picked.shown == six)
        #expect(picked.dropped == 0)
    }

    @Test("passes fewer than six days through in date order, whatever order they came in")
    func fewerInDateOrder() {
        let picked = pickDays([Self.day("2026-09-09", 1), Self.day("2026-09-01", 5)])
        #expect(picked.shown.map(\.key) == ["2026-09-01", "2026-09-09"])
        #expect(picked.dropped == 0)
    }

    @Test("hands back the buckets themselves, cover and all")
    func bucketsThemselves() {
        #expect(pickDays(Self.nine).shown.first == Self.nine[8])
    }

    @Test("takes an empty month to nothing shown and nothing dropped")
    func emptyMonth() {
        #expect(pickDays([]) == PickedDays(shown: [], dropped: 0))
    }

    /// Not a web vector: the web's `slice(0, cap)` would read a negative cap as "all but the last",
    /// an accident of the slice, not a rule. A cap below one shows nothing and counts every day.
    @Test("a cap of zero or below shows nothing and drops every day")
    func capBelowOne() {
        #expect(pickDays(Self.nine, cap: 0) == PickedDays(shown: [], dropped: 9))
        #expect(pickDays(Self.nine, cap: -1) == PickedDays(shown: [], dropped: 9))
    }

    // MARK: - the year filter (web `daysOfYear`)

    private static let years = [
        day("2027-01-01", 1),
        day("2026-12-31", 2),
        day("2026-06-21", 3),
        day("2025-12-31", 4),
        day("12026-01-01", 5),
    ]

    @Test("keeps exactly the day buckets whose key starts with that year")
    func yearKeepsItsDays() {
        #expect(dayBuckets(Self.years, inYear: "2026").map(\.key) == ["2026-12-31", "2026-06-21"])
    }

    /// "12026-01-01" holds "2026-" inside it: only a prefix test keeps it out.
    @Test("matches the year as a whole field, never a substring of another year")
    func yearIsAWholeField() {
        #expect(dayBuckets(Self.years, inYear: "202").map(\.key) == [])
        #expect(dayBuckets(Self.years, inYear: "026").map(\.key) == [])
    }

    @Test("keeps the buckets in the order they came")
    func yearKeepsOrder() {
        #expect(dayBuckets(Self.years, inYear: "2027") == [Self.years[0]])
    }

    // MARK: - the month grouping (web `mosaicSections`)

    @Test("groups by YYYY-MM in the order the months came, titled \"Sep 2026\", each picked")
    func monthsArePicked() {
        let days =
            (0..<9).map { Self.day("2026-09-0\(9 - $0)", $0 + 1) }
            + [Self.day("2026-08-31", 2), Self.day("2026-08-01", 1)]
        let months = mosaicMonths(days)
        #expect(months.map(\.key) == ["2026-09", "2026-08"])
        #expect(months.map(\.label) == ["Sep 2026", "Aug 2026"])
        #expect(months.map(\.tiles.count) == [6, 2])
        #expect(months.map(\.dropped) == [3, 0])
        #expect(months[1].tiles.map(\.bucket.key) == ["2026-08-01", "2026-08-31"])
    }

    @Test("titles January and December of their own year")
    func januaryAndDecember() {
        let months = mosaicMonths([Self.day("2027-01-01", 1), Self.day("2026-12-31", 1)])
        #expect(months.map(\.label) == ["Jan 2027", "Dec 2026"])
    }

    @Test("every month is titled by its three-letter English name")
    func everyMonthLabel() {
        let days = (1...12).map { Self.day("2026-\($0 < 10 ? "0" : "")\($0)-15", 1) }
        #expect(
            mosaicMonths(days).map(\.label) == [
                "Jan 2026", "Feb 2026", "Mar 2026", "Apr 2026", "May 2026", "Jun 2026",
                "Jul 2026", "Aug 2026", "Sep 2026", "Oct 2026", "Nov 2026", "Dec 2026",
            ]
        )
    }

    // MARK: - what a month hands the screen

    /// The frame cycle starts one pattern later per month, so consecutive months differ.
    @Test("a month's tiles carry the slots of its own offset: the section index")
    func slotsOffsetByMonth() {
        let days = [
            Self.day("2026-09-02", 1), Self.day("2026-09-01", 1),
            Self.day("2026-08-02", 1), Self.day("2026-08-01", 1),
            Self.day("2026-07-02", 1), Self.day("2026-07-01", 1),
            Self.day("2026-06-02", 1), Self.day("2026-06-01", 1),
            Self.day("2026-05-02", 1), Self.day("2026-05-01", 1),
        ]
        let months = mosaicMonths(days)
        #expect(
            months.map { $0.tiles.map(\.slot) } == [
                mosaicSlots(2, offset: 0), mosaicSlots(2, offset: 1), mosaicSlots(2, offset: 2),
                mosaicSlots(2, offset: 3), mosaicSlots(2, offset: 4),
            ]
        )
        #expect(months[0].tiles.map(\.slot) == [.heroLeft, .sideRight])
        #expect(months[3].tiles.map(\.slot) == [.wide, .heroLeft])
    }

    @Test("a capped month says how many days it left out, and jumps to its first shown day")
    func moreDaysLine() {
        let nine = mosaicMonths(Self.nine)[0]
        #expect(nine.moreDaysLabel == "and 3 more days")
        #expect(nine.firstShownDay == Self.nine[8])

        let seven = mosaicMonths(Array(Self.nine.prefix(7)))[0]
        #expect(seven.dropped == 1)
        #expect(seven.moreDaysLabel == "and 1 more day")

        let six = mosaicMonths(Array(Self.nine.prefix(6)))[0]
        #expect(six.dropped == 0)
        #expect(six.moreDaysLabel == nil)
        #expect(six.firstShownDay?.key == "2026-09-04")
    }
}

/// The All view's day blocks (MEMNG-597, plan page 3929 decision 13 and its 20:05 CEST amendment,
/// `docs/design/all-by-day-mockup.md` §2), held to the web's `daySlots` vectors in memos-ng
/// `frontend/src/lib/__tests__/mosaic.spec.ts` at c8bd91e, titles verbatim and vectors unchanged.
/// The cycle is A B C B D, each day one step later. Expected layouts are spelled from the pattern
/// constants, never from the code under test.
@Suite("Day mosaic")
struct DayMosaicTests {
    private static let a: [MosaicSlot] = [.heroLeft, .sideRight, .sideRight]
    private static let b: [MosaicSlot] = [.square, .square, .square]
    private static let c: [MosaicSlot] = [.heroRight, .sideLeft, .sideLeft]
    private static let d: [MosaicSlot] = [.wide]

    @Test("gives a day of one or two pictures wide frames only, whatever its index")
    func oneOrTwoAreWide() {
        for k in 0...4 {
            #expect(daySlots(1, dayIndex: k) == [.wide])
            #expect(daySlots(2, dayIndex: k) == [.wide, .wide])
        }
    }

    @Test("lays out no slots for no pictures")
    func noPictures() {
        #expect(daySlots(0, dayIndex: 0) == [])
    }

    @Test("walks A B C B D from day 0")
    func walksTheCycle() {
        #expect(daySlots(13, dayIndex: 0) == Self.a + Self.b + Self.c + Self.b + Self.d)
    }

    @Test("wraps the day index past the end of the cycle")
    func wrapsTheIndex() {
        #expect(daySlots(3, dayIndex: 5) == Self.a)
        #expect(daySlots(3, dayIndex: 9) == [.wide, .square, .square])
    }

    @Test("opens each of five neighbouring days on its own step of the cycle")
    func neighboursDiffer() {
        #expect(
            [0, 1, 2, 3, 4].map { daySlots(3, dayIndex: $0) } == [
                Self.a, Self.b, Self.c, Self.b, [.wide, .square, .square],
            ])
        #expect(daySlots(6, dayIndex: 0) == Self.a + Self.b)
        #expect(daySlots(6, dayIndex: 1) == Self.b + Self.c)
        #expect(daySlots(6, dayIndex: 2) == Self.c + Self.b)
        #expect(daySlots(6, dayIndex: 3) == Self.b + Self.d + [.square, .square])
        #expect(daySlots(6, dayIndex: 4) == Self.d + Self.a + [.square, .square])
    }

    @Test("turns a single leftover into a wide frame")
    func singleLeftoverIsWide() {
        #expect(daySlots(4, dayIndex: 0) == Self.a + [.wide])
        #expect(daySlots(7, dayIndex: 0) == Self.a + Self.b + [.wide])
    }

    @Test("turns a leftover of two into squares, not a cut pattern")
    func leftoverOfTwoIsSquares() {
        #expect(daySlots(5, dayIndex: 0) == Self.a + [.square, .square])
        #expect(daySlots(3, dayIndex: 4) == [.wide, .square, .square])
    }

    @Test("reaches D on a leftover of one without a stray square")
    func reachesD() {
        #expect(daySlots(10, dayIndex: 1) == Self.b + Self.c + Self.b + Self.d)
    }

    @Test("treats a negative day index as its place in the cycle")
    func negativeIndex() {
        #expect(daySlots(3, dayIndex: -1) == [.wide, .square, .square])
    }

    /// Ported as written, though a Swift array is a value and cannot be shared the way the JS one
    /// could: it still pins that the pattern constants are not handed out for editing.
    @Test("hands out a fresh list, so a caller that edits it cannot change the next day")
    func freshList() {
        var first = daySlots(3, dayIndex: 0)
        first[0] = .wide
        #expect(first != Self.a, "control: the copy was edited")
        #expect(daySlots(3, dayIndex: 0) == Self.a)
        #expect(mosaicSlots(3, offset: 0) == Self.a)
    }

    /// Not a web vector: the day cycle is the amendment's order over the SAME four patterns Months
    /// walks, not a second copy of them.
    @Test("the day cycle walks the Months patterns in the order A B C B D")
    func cycleIsTheAmendment() {
        #expect(dayMosaicCycle == [.a, .b, .c, .b, .d])
        #expect(Set(dayMosaicCycle) == Set(monthMosaicCycle))
    }
}
