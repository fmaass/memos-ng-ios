import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// What a tap on an activity square does — and, mostly, what it does not do.
///
/// The heatmap became a control when it moved into the search sheet (MEMNG-126), and the whole of
/// that control's logic is this decision. It is asserted here rather than through the grid because
/// the case that matters is the one a finger cannot reach: a square with nothing under it must
/// leave the timeline exactly where it was.
@Suite("Heatmap date jump")
struct HeatmapDateJumpTests {
    /// Midnight UTC on Wednesday 26 August 2026 — the same instant `HeatmapPresentationTests`
    /// derives its window from, worked out by hand from the epoch.
    private static let today = Date(timeIntervalSince1970: 1_787_702_400)

    private func cell(date: String, count: Int) -> HeatCell {
        HeatCell(
            date: date,
            day: Date(timeIntervalSince1970: 0),
            count: count,
            level: HeatmapPresentation.level(for: count),
            isToday: false
        )
    }

    private func target(of tap: HeatmapDayTap) -> MemoQueryAnchor? {
        if case .jump(let anchor) = tap { return anchor }
        return nil
    }

    /// The day is taken from the grid the card actually draws, not written by hand here, so the
    /// key this decision reads is the key the server sent.
    @Test("a day with memos on it takes the timeline to that day")
    func anActiveDayJumps() throws {
        let grid = HeatmapPresentation.grid(from: ["2026-08-24": 3], today: Self.today)
        let square = try #require(grid.cells.first { $0.date == "2026-08-24" })

        let anchor = try #require(target(of: HeatmapDateJump.tap(on: square)), "the day is inert")
        #expect(anchor == .day(year: 2026, month: 8, day: 24))
        // And it lands on the right INSTANT, which is the part a wrong calendar breaks silently.
        // The server's day keys are cut in UTC, so the bound is midnight UTC at the END of the
        // 24th — 2026-08-25T00:00:00Z, epoch second 1_787_616_000, one day before the window's
        // own `today`. Read in Berlin it would be 22:00Z on the 24th, hiding the last two hours
        // of memos this very square is counting.
        #expect(
            anchor.createdBefore(in: HeatmapDateJump.anchorCalendar)
                == Date(timeIntervalSince1970: 1_787_616_000)
        )
    }

    /// The no-op. A square with nothing under it reloads nothing: a list that empties itself to
    /// show the same emptiness the square already showed is a dead jump.
    @Test("a day with nothing on it is not a jump")
    func anEmptyDayIsIgnored() {
        #expect(HeatmapDateJump.tap(on: cell(date: "2026-08-24", count: 0)) == .ignore)
        // Positive control: the same day, one memo on it, IS a jump — so the refusal is the count
        // and not the date.
        #expect(
            target(of: HeatmapDateJump.tap(on: cell(date: "2026-08-24", count: 1)))
                == .day(year: 2026, month: 8, day: 24)
        )
    }

    /// Out of range. `Calendar.date(from:)` ROLLS OVER — month 13 day 40 is a real day in 2027 —
    /// so a decision that only parsed would send the timeline to a day no square stands for.
    @Test("a key that is not a day is not a jump")
    func anImpossibleKeyIsIgnored() {
        for key in ["2026-13-40", "2026-02-30", "not-a-day", "2026-08", ""] {
            #expect(
                HeatmapDateJump.tap(on: cell(date: key, count: 5)) == .ignore,
                "\(key) was taken for a day"
            )
        }
        // Positive control: a real key with the same count is a jump, so the refusals above are
        // the keys and not the count.
        #expect(target(of: HeatmapDateJump.tap(on: cell(date: "2026-08-24", count: 5))) != nil)
    }

    /// Over a whole grid: eighty-four squares, and only the two the household wrote on are
    /// controls. This is the category the view reads to decide which cells become buttons at all.
    @Test("only the days with memos on them are jumps")
    func onlyActiveDaysAreJumps() {
        // The oldest day is the window's own first day (83 days before 26 August), so nothing is
        // clamped away and the grid really is the full twelve weeks of squares.
        let grid = HeatmapPresentation.grid(
            from: ["2026-08-24": 3, "2026-06-04": 1], today: Self.today
        )
        let jumps = grid.cells.compactMap { target(of: HeatmapDateJump.tap(on: $0)) }

        #expect(grid.cells.count == 84, "the window was not the full twelve weeks")
        #expect(jumps == [.day(year: 2026, month: 6, day: 4), .day(year: 2026, month: 8, day: 24)])
    }

    /// What VoiceOver reads on a square that is a control. The grid as a whole says how much was
    /// written; a day that can be opened has to say which day it is.
    @Test("a tappable day says its date and how much is on it")
    func theLabelNamesTheDayAndTheCount() throws {
        let grid = HeatmapPresentation.grid(
            from: ["2026-08-24": 3, "2026-08-20": 1], today: Self.today
        )
        let three = try #require(grid.cells.first { $0.date == "2026-08-24" })
        let one = try #require(grid.cells.first { $0.date == "2026-08-20" })
        let locale = Locale(identifier: "en_GB")

        let label = HeatmapDateJump.label(for: three, locale: locale)
        #expect(label.contains("24"), "\(label)")
        #expect(label.contains("August"), "\(label)")
        #expect(label.contains("2026"), "\(label)")
        #expect(label.hasSuffix(", 3 memos"), "\(label)")
        // One memo is one memo, not "1 memos".
        #expect(HeatmapDateJump.label(for: one, locale: locale).hasSuffix(", 1 memo"))
    }

    /// What the timeline says about itself once it has been taken somewhere. Without it the list
    /// simply looks wrong: yesterday's memos are gone and nothing on screen says why.
    @Test("an anchored timeline names the day it was taken to")
    func theTitleNamesTheAnchor() {
        let locale = Locale(identifier: "en_GB")
        let day = HeatmapDateJump.title(for: .day(year: 2026, month: 8, day: 24), locale: locale)
        #expect(day.hasPrefix("Jumped to "), "\(day)")
        #expect(day.contains("24"), "\(day)")
        #expect(day.contains("August"), "\(day)")
        #expect(day.contains("2026"), "\(day)")

        // A month anchor is the same sentence one period up — and it names no day, which is the
        // control on the day case above saying "24" because the anchor did.
        let month = HeatmapDateJump.title(for: .month(year: 2026, month: 8), locale: locale)
        #expect(month.hasPrefix("Jumped to "), "\(month)")
        #expect(month.contains("August"), "\(month)")
        #expect(month.contains("2026"), "\(month)")
        #expect(!month.contains("24"), "\(month)")
    }
}
