import Foundation
import Testing

@testable import MemosFeatures

/// The grid the activity card draws, derived from the flat day map `GET /api/stats/heatmap`
/// sends.
///
/// Every expectation here is an independently derived date or count, never one this suite asks
/// the code under test to compute for it. The window, the buckets and the summary are the whole
/// of the feature's logic — the view is a `ForEach` over what these functions return.
@Suite("Heatmap presentation")
struct HeatmapPresentationTests {
    /// Midday UTC on Wednesday 26 August 2026. The midday is deliberate: a window derived from
    /// the instant rather than from the day would end at a different place at noon than at dawn.
    private static let today = Date(timeIntervalSince1970: 1_787_702_400 + 12 * 3600)
    /// Midnight UTC that same day — the epoch second 2026-08-26T00:00:00Z, worked out by hand.
    private static let todayMidnight = Date(timeIntervalSince1970: 1_787_702_400)

    // MARK: - the window

    /// The cold start: an account with nothing in it still gets the whole twelve weeks, so the
    /// card is a shape from the first launch rather than an empty strip that grows a square a day.
    @Test("with no activity at all the full twelve-week window is drawn")
    func emptyCountsGiveTheWholeWindow() {
        let grid = HeatmapPresentation.grid(from: [:], today: Self.today)

        #expect(grid.cells.count == 84)
        #expect(grid.columns.count == 12)
        #expect(grid.columns.allSatisfy { $0.count == 7 })
        // 83 days before 26 August 2026: 26 back to 31 July, 31 back to 30 June, 26 back to 4 June.
        #expect(grid.cells.first?.date == "2026-06-04")
        #expect(grid.cells.last?.date == "2026-08-26")
        #expect(grid.cells.allSatisfy { $0.level == 0 })
        #expect(grid.summary == "No memos in the last 12 weeks")
    }

    /// A household whose first memo is nine days old is not shown eleven empty weeks in front of
    /// it. The window starts where the history does.
    @Test("the window clamps forward to the first day with activity")
    func sparseCountsClampTheWindowForward() {
        let grid = HeatmapPresentation.grid(from: ["2026-08-17": 1], today: Self.today)

        // 17 to 26 August inclusive is ten days: one full column and a short one.
        #expect(grid.cells.count == 10)
        #expect(grid.columns.map(\.count) == [7, 3])
        #expect(grid.cells.first?.date == "2026-08-17")
        #expect(grid.cells.last?.date == "2026-08-26")
        #expect(grid.cells.first?.count == 1)
        #expect(grid.cells.first?.level == 1)
        #expect(grid.summary == "1 memo in the last 2 weeks")
    }

    /// History older than the window does not move the window and does not go into the count the
    /// card reads out. Twelve weeks is what it says, so twelve weeks is what it must total.
    @Test("a day older than the window is neither drawn nor counted")
    func daysBeforeTheWindowAreLeftOut() {
        let grid = HeatmapPresentation.grid(
            from: ["2026-01-01": 5, "2026-08-25": 2], today: Self.today
        )

        #expect(grid.cells.count == 84)
        #expect(grid.cells.first?.date == "2026-06-04")
        #expect(!grid.cells.contains { $0.date == "2026-01-01" })
        #expect(grid.cells.first { $0.date == "2026-08-25" }?.count == 2)
        #expect(grid.summary == "2 memos in the last 12 weeks")
    }

    /// The days between two active ones are days, not gaps: a heatmap that only drew the days it
    /// had counts for would be a bar chart with the calendar removed.
    @Test("days with no memos are still days")
    func quietDaysAreStillCells() {
        let grid = HeatmapPresentation.grid(
            from: ["2026-08-20": 1, "2026-08-26": 1], today: Self.today
        )

        let quiet = grid.cells.filter { $0.date >= "2026-08-21" && $0.date <= "2026-08-25" }
        #expect(quiet.count == 5)
        #expect(quiet.allSatisfy { $0.count == 0 && $0.level == 0 })
    }

    // MARK: - today

    @Test("the last cell is today, and it is the only one")
    func todayIsMarkedOnce() {
        let grid = HeatmapPresentation.grid(from: ["2026-08-26": 3], today: Self.today)

        let marked = grid.cells.filter(\.isToday)
        #expect(marked.count == 1)
        #expect(marked.first?.date == "2026-08-26")
        #expect(marked.first?.count == 3)
        #expect(grid.cells.last?.isToday == true)
    }

    /// The date a cell carries is a real day, not only a label — that is what the date-jump this
    /// card becomes the axis for (MEMNG-120) will act on.
    @Test("a cell carries the day it stands for")
    func cellsCarryTheirDay() {
        let grid = HeatmapPresentation.grid(from: [:], today: Self.today)

        #expect(grid.cells.last?.day == Self.todayMidnight)
        #expect(grid.cells.last?.id == "2026-08-26")
    }

    /// The day the server cut, not the day the phone is having. `date(created_at)` runs in the
    /// database connection's zone, which is UTC on this estate — so a key one second before UTC
    /// midnight belongs to the day that is ending, wherever the reader is standing.
    @Test("days are cut in UTC, the way the server cuts them")
    func daysAreCutInUTC() {
        #expect(HeatmapPresentation.key(for: Self.todayMidnight) == "2026-08-26")
        #expect(
            HeatmapPresentation.key(for: Self.todayMidnight.addingTimeInterval(-1)) == "2026-08-25"
        )
        #expect(
            HeatmapPresentation.key(for: Self.todayMidnight.addingTimeInterval(86_399))
                == "2026-08-26"
        )
        #expect(HeatmapPresentation.day(for: "2026-08-26") == Self.todayMidnight)
        #expect(HeatmapPresentation.day(for: "not a day") == nil)
    }

    // MARK: - the buckets

    /// Every boundary of the five buckets, from both sides. A threshold tested only in the middle
    /// of its range is a threshold that can move without anything noticing.
    @Test(
        "the buckets are the web client's, at every boundary",
        arguments: zip(
            [-5, 0, 1, 2, 3, 4, 6, 7, 50],
            [0, 0, 1, 2, 2, 3, 3, 4, 4]
        )
    )
    func bucketBoundaries(count: Int, level: Int) {
        #expect(HeatmapPresentation.level(for: count) == level)
    }

    @Test("a cell's level is the bucket its own count falls in")
    func cellsCarryTheirBucket() {
        let grid = HeatmapPresentation.grid(
            from: ["2026-08-22": 1, "2026-08-23": 3, "2026-08-24": 6, "2026-08-25": 7],
            today: Self.today
        )

        #expect(grid.cells.first { $0.date == "2026-08-22" }?.level == 1)
        #expect(grid.cells.first { $0.date == "2026-08-23" }?.level == 2)
        #expect(grid.cells.first { $0.date == "2026-08-24" }?.level == 3)
        #expect(grid.cells.first { $0.date == "2026-08-25" }?.level == 4)
    }

    // MARK: - what VoiceOver reads

    @Test("the summary counts memos and weeks, and says so in the reader's own numbers")
    func summaryWording() {
        #expect(HeatmapPresentation.summary(memos: 0, weeks: 12) == "No memos in the last 12 weeks")
        #expect(HeatmapPresentation.summary(memos: 1, weeks: 12) == "1 memo in the last 12 weeks")
        #expect(
            HeatmapPresentation.summary(memos: 42, weeks: 12) == "42 memos in the last 12 weeks"
        )
        #expect(HeatmapPresentation.summary(memos: 5, weeks: 1) == "5 memos in the last week")
        #expect(HeatmapPresentation.summary(memos: 0, weeks: 1) == "No memos in the last week")
    }

    /// MEMNG-175. An unanswered heatmap and a household that has written nothing produce exactly
    /// the same empty counts and exactly the same twelve weeks of level-0 days, so the sentence
    /// read off the grid is a claim the app cannot make until the server has spoken — and the
    /// first open of the search sheet used to make it.
    @Test("an unanswered heatmap does not claim there were no memos")
    func anUnansweredHeatmapClaimsNothing() {
        let cold = HeatmapPresentation.grid(from: [:], today: Self.today)

        #expect(HeatmapPresentation.summary(for: cold, loaded: false) == "Loading activity")
        // Once it IS answered, an account with nothing on it says so — the emptiness is the news.
        #expect(HeatmapPresentation.summary(for: cold, loaded: true) == cold.summary)
        #expect(cold.summary.contains("No memos"))
        // And an answered heatmap with something on it reads back what it counted, so the
        // sentence above is the ABSENCE of an answer and not a summary that never says anything.
        let warm = HeatmapPresentation.grid(from: ["2026-08-26": 4], today: Self.today)
        #expect(HeatmapPresentation.summary(for: warm, loaded: true) == warm.summary)
        #expect(warm.summary.contains("4 memos"))
        #expect(HeatmapPresentation.summary(for: warm, loaded: false) == "Loading activity")
    }

    @Test("the summary totals only the days the grid actually shows")
    func summaryTotalsTheWindow() {
        let grid = HeatmapPresentation.grid(
            from: ["2026-08-24": 2, "2026-08-25": 1, "2026-08-26": 4], today: Self.today
        )

        #expect(grid.summary == "7 memos in the last week")
    }
}
