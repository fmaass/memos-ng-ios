import CoreGraphics
import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// Which square a finger is over (MEMNG-178).
///
/// A tap only ever lands inside a square, so a hit test built for taps is never asked the
/// questions that matter here: what a finger 200pt to the left of the grid means, what the 2pt of
/// air between two columns means, and what the empty slots under a short trailing column mean.
/// Under a scrub those readings arrive constantly, and each one that answers "nothing" is a frame
/// where the date field goes blank or sticks.
@Suite("Heatmap scrub")
struct HeatmapScrubTests {
    /// Midnight UTC on Wednesday 26 August 2026 — the same instant the presentation and jump
    /// suites derive their windows from.
    private static let today = Date(timeIntervalSince1970: 1_787_702_400)
    private static let side: CGFloat = 12
    private static let gap: CGFloat = 2
    private static var pitch: CGFloat { side + gap }

    /// The full twelve weeks: 84 squares, twelve columns of seven, oldest column first.
    private static var full: HeatmapGrid {
        // The second key is the window's own first day, so nothing is clamped away and the grid
        // really is twelve columns of seven.
        HeatmapPresentation.grid(from: ["2026-08-24": 3, "2026-06-04": 1], today: today)
    }

    private func cell(_ x: CGFloat, _ y: CGFloat, in grid: HeatmapGrid) -> HeatCell? {
        HeatmapScrub.cell(
            at: CGPoint(x: x, y: y), in: grid, side: Self.side, gap: Self.gap
        )
    }

    @Test("the first square is the one under the grid's own origin")
    func theFirstSquare() throws {
        let grid = Self.full
        #expect(grid.cells.count == 84, "the window was not the full twelve weeks")

        let first = try #require(cell(0, 0, in: grid))

        #expect(first.date == "2026-06-04")
        #expect(first.date == grid.columns[0][0].date)
    }

    @Test("the last square is the one under the far corner")
    func theLastSquare() throws {
        let grid = Self.full
        let corner = Self.pitch * 12
        let last = try #require(cell(corner, corner, in: grid))

        #expect(last.date == "2026-08-26")
        #expect(last.isToday)
    }

    /// A finger sliding along the bottom row strays under it; one sliding to the left edge strays
    /// past it. Both keep scrubbing rather than dropping the field.
    @Test("a finger outside the grid keeps scrubbing at the nearest square")
    func outOfGridDragsClamp() throws {
        let grid = Self.full

        let farAbove = try #require(cell(-400, -400, in: grid))
        #expect(farAbove.date == "2026-06-04")
        let farLeft = try #require(cell(-400, 0, in: grid))
        #expect(farLeft.date == "2026-06-04")
        let farBeyond = try #require(cell(9_999, 9_999, in: grid))
        #expect(farBeyond.date == "2026-08-26")
        // Above the grid but inside it horizontally: the column is kept, the row is clamped.
        let above = try #require(cell(Self.pitch * 3 + 1, -50, in: grid))
        #expect(above.date == grid.columns[3][0].date)
        // Below it: same column, last row.
        let below = try #require(cell(Self.pitch * 3 + 1, 5_000, in: grid))
        #expect(below.date == grid.columns[3][6].date)
    }

    /// The week boundary. A column is a week, so this is where the field ticks over from one week
    /// to the next — and the 2pt of air before it belongs to the week on its left, because a dead
    /// stripe between every column reads as the field stuttering under a moving finger.
    @Test("a column starts at its own pitch, and the air before it is still the last one")
    func weekBoundaries() throws {
        let grid = Self.full

        let insideFirst = try #require(cell(Self.side - 0.1, 0, in: grid))
        #expect(insideFirst.date == "2026-06-04")
        let inTheGap = try #require(cell(Self.side, 0, in: grid))
        #expect(inTheGap.date == "2026-06-04", "the air between two columns was a dead stripe")
        let justBefore = try #require(cell(Self.pitch - 0.1, 0, in: grid))
        #expect(justBefore.date == "2026-06-04")
        // One week on, to the day.
        let nextWeek = try #require(cell(Self.pitch, 0, in: grid))
        #expect(nextWeek.date == "2026-06-11")
        let weekAfter = try #require(cell(Self.pitch * 2, 0, in: grid))
        #expect(weekAfter.date == "2026-06-18")
        // And down a row is one day, not one week.
        let nextDay = try #require(cell(0, Self.pitch, in: grid))
        #expect(nextDay.date == "2026-06-05")
        let lastOfTheWeek = try #require(cell(0, Self.pitch * 6, in: grid))
        #expect(lastOfTheWeek.date == "2026-06-10")
    }

    /// The one genuinely empty region. The window stops on today, so the last column is short and
    /// its lower slots stand for days that have not happened — a scrub there answers with that
    /// column's last real day rather than with nothing.
    @Test("the empty slots under a short trailing column answer with its last day")
    func shortTrailingColumn() throws {
        // Clamped forward to the first day with activity: three days, one column of three.
        let grid = HeatmapPresentation.grid(from: ["2026-08-24": 1], today: Self.today)
        #expect(grid.columns.count == 1)
        #expect(grid.columns[0].count == 3, "the window was not the clamped three days")

        let first = try #require(cell(0, 0, in: grid))
        #expect(first.date == "2026-08-24")
        let second = try #require(cell(0, Self.pitch, in: grid))
        #expect(second.date == "2026-08-25")
        let third = try #require(cell(0, Self.pitch * 2, in: grid))
        #expect(third.date == "2026-08-26")
        // Rows 3 to 6 are slots for days that do not exist.
        let belowTheDays = try #require(cell(0, Self.pitch * 4, in: grid))
        #expect(belowTheDays.date == "2026-08-26")
        let rightAtTheBottom = try #require(cell(0, Self.pitch * 6.5, in: grid))
        #expect(rightAtTheBottom.date == "2026-08-26")
    }

    @Test("a grid with no squares in it has nothing under any point")
    func anEmptyGridAnswersNothing() {
        let empty = HeatmapGrid(columns: [], summary: "No memos in the last week")

        #expect(cell(0, 0, in: empty) == nil)
        #expect(cell(50, 50, in: empty) == nil)
        // Positive control: the same point on a real grid answers, so the nils are the emptiness.
        #expect(cell(0, 0, in: Self.full) != nil)
    }

    @Test("a square with nothing written on it is still a day the scrubber can reach")
    func emptyDaysAreScrubbable() throws {
        let grid = Self.full
        // The day before the only day with anything on it, which is a zero-count square.
        let quiet = try #require(grid.cells.first { $0.date == "2026-08-23" })
        #expect(quiet.count == 0)

        // The scrubber's anchor ignores the count that the bare tap-to-jump refused on.
        #expect(HeatmapDateJump.anchor(for: quiet) == .day(year: 2026, month: 8, day: 23))
        #expect(HeatmapDateJump.tap(on: quiet) == .ignore, "control: the old tap still refuses it")
        // And a day WITH memos on it is reachable by both, so the difference is the count gate and
        // not two decisions that disagree about what a day is.
        let busy = try #require(grid.cells.first { $0.date == "2026-08-24" })
        #expect(HeatmapDateJump.anchor(for: busy) == .day(year: 2026, month: 8, day: 24))
        #expect(HeatmapDateJump.tap(on: busy) == .jump(.day(year: 2026, month: 8, day: 24)))
    }

    @Test("a key that is not a day is not a square the scrubber can reach either")
    func impossibleKeysHaveNoAnchor() {
        for key in ["2026-13-40", "2026-02-30", "not-a-day", "2026-08", ""] {
            let cell = HeatCell(
                date: key, day: Date(timeIntervalSince1970: 0), count: 0, level: 0, isToday: false
            )
            #expect(HeatmapDateJump.anchor(for: cell) == nil, "\(key) was taken for a day")
        }
        // Positive control: a real key with the same zero count does have an anchor.
        let real = HeatCell(
            date: "2026-08-24", day: Self.today, count: 0, level: 0, isToday: false
        )
        #expect(HeatmapDateJump.anchor(for: real) == .day(year: 2026, month: 8, day: 24))
    }

    /// What a swipe does, because a swipe cannot scrub. VoiceOver adjusts the grid the way it
    /// adjusts a picker, one day per swipe, and the two ends are where an adjustment has to stop
    /// rather than wrap: running off the oldest square and reappearing on today is a jump across
    /// twelve weeks that nothing announced.
    @Test("an adjustment moves one day and stops at both ends")
    func steppingMovesOneDayAndClamps() throws {
        let grid = Self.full
        let first = try #require(grid.cells.first)
        let last = try #require(grid.cells.last)
        #expect(first.date == "2026-06-04")
        #expect(last.date == "2026-08-26")

        let later = try #require(HeatmapScrub.stepped(from: "2026-08-24", by: 1, in: grid))
        #expect(later.date == "2026-08-25")
        let earlier = try #require(HeatmapScrub.stepped(from: "2026-08-24", by: -1, in: grid))
        #expect(earlier.date == "2026-08-23")

        // The ends hold.
        let offTheStart = try #require(HeatmapScrub.stepped(from: first.date, by: -1, in: grid))
        #expect(offTheStart.date == first.date, "an adjustment ran off the oldest square")
        let offTheEnd = try #require(HeatmapScrub.stepped(from: last.date, by: 1, in: grid))
        #expect(offTheEnd.date == last.date, "an adjustment ran off today")
        // Control: from one in, the same adjustment does move.
        let second = try #require(HeatmapScrub.stepped(from: "2026-06-05", by: -1, in: grid))
        #expect(second.date == first.date)
    }

    /// A date typed into the field can be older than the twelve weeks the grid draws, so "the
    /// chosen day" is not always a square. The first adjustment then has to land somewhere rather
    /// than doing nothing, which is what a reader with no other way to move would experience.
    @Test("an adjustment from a day that is not on the grid starts at the end it is moving from")
    func steppingFromOffTheGrid() throws {
        let grid = Self.full

        let oldest = try #require(HeatmapScrub.stepped(from: nil, by: 1, in: grid))
        #expect(oldest.date == "2026-06-04")
        let newest = try #require(HeatmapScrub.stepped(from: nil, by: -1, in: grid))
        #expect(newest.date == "2026-08-26")
        let old = try #require(HeatmapScrub.stepped(from: "2025-01-01", by: 1, in: grid))
        #expect(old.date == "2026-06-04")
        // And a grid with no squares has nowhere to step to at all.
        let empty = HeatmapGrid(columns: [], summary: "")
        #expect(HeatmapScrub.stepped(from: nil, by: 1, in: empty) == nil)
    }

    /// What VoiceOver reads as the grid's value. The grid is ONE element with a value rather than
    /// eighty-four with labels, so this sentence is the only thing standing between a reader and
    /// a wall of unlabelled squares.
    @Test("the grid's spoken value is the chosen day and what is on it")
    func theSpokenValueNamesTheChosenDay() throws {
        let grid = Self.full
        let locale = Locale(identifier: "en_GB")

        let spoken = try #require(HeatmapScrub.spoken("2026-08-24", in: grid, locale: locale))
        #expect(spoken.contains("24"), "\(spoken)")
        #expect(spoken.contains("August"), "\(spoken)")
        #expect(spoken.hasSuffix(", 3 memos"), "\(spoken)")
        // A day the grid does not draw has no value to read, so the card falls back to its summary.
        #expect(HeatmapScrub.spoken("2025-01-01", in: grid, locale: locale) == nil)
        #expect(HeatmapScrub.spoken(nil, in: grid, locale: locale) == nil)
        // And the lookup the activation uses agrees with it.
        #expect(HeatmapScrub.cell(for: "2026-08-24", in: grid)?.count == 3)
        #expect(HeatmapScrub.cell(for: "2025-01-01", in: grid) == nil)
    }

    @Test("a square with nothing on it says so rather than saying nothing")
    func theLabelSaysWhenADayIsEmpty() throws {
        let grid = Self.full
        let quiet = try #require(grid.cells.first { $0.date == "2026-08-23" })
        let locale = Locale(identifier: "en_GB")

        #expect(HeatmapDateJump.label(for: quiet, locale: locale).hasSuffix(", no memos"))
        // Controls: one and many still read as they did.
        let busy = try #require(grid.cells.first { $0.date == "2026-08-24" })
        #expect(HeatmapDateJump.label(for: busy, locale: locale).hasSuffix(", 3 memos"))
    }
}
