import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The date field the heatmap scrubs (MEMNG-178).
///
/// Two properties are worth holding here and neither is visible on a screenshot. The first is the
/// debounce, which has no timer in it: the model cannot commit while a finger is moving because it
/// holds nothing to commit WITH — `scrub(to:)` returns nothing at all, and the anchor a caller
/// acts on exists only as the return of the gesture's end. So what is asserted is the end: once
/// per gesture, at the day the finger stopped on, and never for a touch that met no square.
///
/// The second is the zone. The picker deals in the device's calendar and the heatmap's squares are
/// cut in the server's, and every mismatch between them is a silent off-by-one day for anybody who
/// is not on Greenwich.
@MainActor
@Suite("Search day selection")
struct SearchDaySelectionTests {
    private static var berlin: Calendar { calendar("Europe/Berlin") }
    private static var auckland: Calendar { calendar("Pacific/Auckland") }
    private static var utc: Calendar { calendar("UTC") }

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// A day at its start in UTC — what a heatmap square carries.
    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        HeatmapDateJump.anchorCalendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
    }

    /// A wall-clock instant somewhere, which is what a `DatePicker` hands back.
    private static func instant(
        _ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int
    ) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour)
        )!
    }

    @Test("the field opens on today, cut in the server's day and not the device's")
    func itOpensOnTodayInUTC() {
        // Half past eleven at night in London is already tomorrow in Berlin. The square lit has to
        // be the one the server counted this memo-writing day under, which is the UTC one.
        let lateOn26th = Date(timeIntervalSince1970: 1_787_702_400 + 23 * 3_600 + 1_800)
        let selection = SearchDaySelection(today: lateOn26th)

        #expect(selection.selectedKey == "2026-08-26")
        #expect(selection.day == Self.day(2026, 8, 26))
    }

    @Test("a scrub moves the field square by square and the gesture's end is what commits")
    func aScrubMovesTheFieldAndEndsInOneCommit() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))

        selection.scrub(to: Self.day(2026, 8, 1))
        #expect(selection.selectedKey == "2026-08-01", "the field did not follow the finger")
        selection.scrub(to: Self.day(2026, 7, 15))
        #expect(selection.selectedKey == "2026-07-15")
        selection.scrub(to: Self.day(2026, 6, 4))
        #expect(selection.selectedKey == "2026-06-04")

        // One commit, and it is the square the finger stopped on — not the first one it crossed.
        #expect(selection.endScrub() == .day(year: 2026, month: 6, day: 4))
        // The gesture is over: releasing again is not a second choice of the same day.
        #expect(selection.endScrub() == nil)
    }

    @Test("a touch that met no square commits nothing")
    func aTouchWithNoScrubCommitsNothing() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))

        // A finger down and up on the card's padding: `move` never ran.
        #expect(selection.endScrub() == nil, "an empty touch reloaded the timeline")
        #expect(selection.selectedKey == "2026-08-26", "an empty touch moved the field")

        // Positive control: the same release after one square DOES commit, so the refusal above
        // is the absent gesture and not an end that never works.
        selection.scrub(to: Self.day(2026, 8, 24))
        #expect(selection.endScrub() == .day(year: 2026, month: 8, day: 24))
    }

    @Test("a day picked in the field commits at once and moves the highlight")
    func aPickedDayCommitsAtOnce() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))

        let picked = Self.instant(Self.utc, 2026, 6, 4, 12)
        let anchor = selection.pick(picked, in: Self.utc)
        #expect(anchor == .day(year: 2026, month: 6, day: 4))
        // The heatmap follows the field, which is the half of MEMNG-178 a finger never exercises.
        #expect(selection.selectedKey == "2026-06-04")
    }

    /// The off-by-one this whole conversion exists for. Half past midnight on the 24th in Berlin
    /// is half past ten at night on the 23rd in UTC — so a picker value read in the wrong calendar
    /// anchors the timeline to the day BEFORE the one the person saw themselves choose.
    @Test("a picked day is the day the picker showed, wherever the device is")
    func aPickedDayIsTheDayThatWasShown() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))

        let justAfterMidnight = Self.instant(Self.berlin, 2026, 8, 24, 0)
        let inBerlin = selection.pick(justAfterMidnight, in: Self.berlin)
        #expect(inBerlin == .day(year: 2026, month: 8, day: 24))
        #expect(selection.selectedKey == "2026-08-24")

        // And the other way round the world: late on the 24th in Auckland is still the 24th in the
        // field, though it is the 23rd in UTC as an instant.
        let lateEvening = Self.instant(Self.auckland, 2026, 8, 24, 23)
        let inAuckland = selection.pick(lateEvening, in: Self.auckland)
        #expect(inAuckland == .day(year: 2026, month: 8, day: 24))
        #expect(selection.selectedKey == "2026-08-24")
    }

    @Test("a picked day ends any half-finished scrub rather than committing it later")
    func pickingClearsAHalfFinishedScrub() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))

        selection.scrub(to: Self.day(2026, 8, 1))
        #expect(selection.pick(Self.instant(Self.utc, 2026, 6, 4, 12), in: Self.utc) != nil)

        // The scrub that was interrupted is gone: its release cannot take the timeline back to a
        // day the field has moved off.
        #expect(selection.endScrub() == nil)
        #expect(selection.selectedKey == "2026-06-04")
    }

    /// The round trip, over a whole year in three zones, so a day whose local midnight does not
    /// exist — the night a zone enters daylight saving — is covered wherever it happens to fall
    /// rather than only where a hand-written case remembered to look.
    @Test("the picker is handed back the very day the field is on")
    func thePickerShowsTheDayTheFieldIsOn() throws {
        let zones = [Self.utc, Self.berlin, Self.auckland]
        let start = Self.day(2026, 1, 1)

        for offset in 0..<400 {
            let utcDay = try #require(
                HeatmapDateJump.anchorCalendar.date(byAdding: .day, value: offset, to: start)
            )
            let wanted = HeatmapDateJump.anchorCalendar.dateComponents(
                [.year, .month, .day], from: utcDay
            )
            for zone in zones {
                let selection = SearchDaySelection(today: utcDay)
                let shown = zone.dateComponents(
                    [.year, .month, .day], from: selection.pickerDate(in: zone)
                )
                #expect(
                    shown == wanted,
                    "\(zone.timeZone.identifier) showed \(shown) for \(wanted)"
                )
            }
        }
    }

    /// And the trip back, which is the same property from the other end: whatever the picker was
    /// handed, picking it again must not move the field.
    @Test("picking the day the picker is already showing does not move the field")
    func theRoundTripIsStable() {
        for zone in [Self.utc, Self.berlin, Self.auckland] {
            let selection = SearchDaySelection(today: Self.day(2026, 3, 29))
            let shown = selection.pickerDate(in: zone)
            #expect(selection.pick(shown, in: zone) == .day(year: 2026, month: 3, day: 29))
            #expect(
                selection.selectedKey == "2026-03-29",
                "\(zone.timeZone.identifier) drifted a day on the round trip"
            )
        }
    }

    @Test("a scrub the system takes away rolls the field back and commits nothing")
    func aCancelledScrubRollsBack() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))
        let opened = selection.day

        selection.scrub(to: Self.day(2026, 8, 22))
        #expect(selection.day != opened, "the scrub never moved the field")
        selection.cancelScrub()

        #expect(
            selection.day == opened,
            "a cancelled scrub left the field naming an uncommitted day"
        )
        #expect(selection.endScrub() == nil, "a cancelled scrub still had something to commit")
    }

    @Test("a cancellation after a normal end changes nothing")
    func aLateCancellationIsANoOp() {
        let selection = SearchDaySelection(today: Self.day(2026, 8, 26))
        let target = Self.day(2026, 8, 22)

        selection.scrub(to: target)
        #expect(selection.endScrub() != nil)
        let committed = selection.day
        selection.cancelScrub()

        #expect(selection.day == committed, "the reset after a normal end rolled back a commit")
    }
}
