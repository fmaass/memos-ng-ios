import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// Backdating is one value carried across three hand-offs — the row, the submission, the queue
/// — and the way it breaks is by being quietly dropped at one of them. These hold the two
/// hand-offs that are pure: what the row says, and what the submission projects.
@MainActor
@Suite("Compose date")
struct ComposeDateTests {
    private let capture = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("a capture nobody dated is stamped when it is written")
    func untouchedTakesTheMoment() {
        let submission = ComposeSubmission(content: "kettle's broken", visibility: nil)
        #expect(submission.createdAt == nil)
        #expect(submission.capturedAt(now: capture) == capture)
    }

    @Test("a chosen date is what the capture carries, not the moment it was written")
    func chosenDateWins() {
        let chosen = Date(timeIntervalSince1970: 1_700_000_000)
        let submission = ComposeSubmission(
            content: "the day we moved in",
            visibility: nil,
            createdAt: chosen
        )
        #expect(submission.capturedAt(now: capture) == chosen)
        #expect(submission.capturedAt(now: capture) != capture)
    }

    @Test("the row says Now until a date is chosen")
    func titleSaysNow() {
        #expect(MemoDateChoice.title(for: nil) == "Now")
        #expect(MemoDateChoice.title(for: nil, compact: true) == "Now")
    }

    @Test("a chosen date is spelled out, and shortened at an accessibility size")
    func titleSpellsOutTheDate() {
        let locale = Locale(identifier: "en_GB")
        let full = MemoDateChoice.title(for: capture, locale: locale)
        let compact = MemoDateChoice.title(for: capture, compact: true, locale: locale)
        // The day the reader is standing in, whatever zone that is — the same calendar the row
        // itself formats through.
        let day = String(Calendar.current.component(.day, from: capture))
        let year = String(Calendar.current.component(.year, from: capture))
        // The day and the month survive both forms; the year and the time are what the short one
        // gives up, because at an accessibility size there is no room for them.
        #expect(full.contains(day))
        #expect(compact.contains(day))
        #expect(full.contains(year))
        #expect(!compact.contains(year))
        #expect(compact.count < full.count)
        #expect(full != "Now")
    }

    @Test("the pill says nothing at all until a date is chosen")
    func pillIsGlyphOnlyUntilChosen() {
        #expect(MemoDateChoice.pillTitle(for: nil) == nil)
        // Not the word "Now": the calendar glyph already says it, and a row of three pills has
        // room only for the answers that differ from the default.
        #expect(MemoDateChoice.pillTitle(for: nil) != "Now")
    }

    @Test("a chosen date reaches the pill in its short form")
    func pillCarriesTheShortDate() throws {
        let locale = Locale(identifier: "en_GB")
        let shown = try #require(MemoDateChoice.pillTitle(for: capture, locale: locale))
        let day = String(Calendar.current.component(.day, from: capture))
        let year = String(Calendar.current.component(.year, from: capture))
        #expect(shown.contains(day))
        // The year and the time stay in the picker and in what a screen reader hears; spelling
        // them out on the pill costs the row its other two.
        #expect(!shown.contains(year))
        #expect(shown == MemoDateChoice.title(for: capture, compact: true, locale: locale))
    }

    /// The picker's binding is what a tap on the calendar reaches, so driving it is the tap. Noon
    /// UTC, because the picker reads its days in the device's calendar: half an hour past noon UTC
    /// is the same local day in every zone there is, and two days on is another day in all of them.
    @Test("a day picked on the calendar closes the picker; a moved time leaves it up")
    func pickingADayClosesThePicker() {
        let noon = Date(timeIntervalSince1970: 1_749_988_800)
        let held = Held()
        let picker = MemoDatePicker(
            date: Binding(get: { held.date }, set: { held.date = $0 }),
            seed: noon
        ) { held.closed += 1 }

        let laterThatDay = noon.addingTimeInterval(30 * 60)
        picker.chosen.wrappedValue = laterThatDay
        #expect(held.date == laterThatDay, "moving the time still dates the memo")
        #expect(held.closed == 0, "moving the time is not what closes the picker")

        let anotherDay = laterThatDay.addingTimeInterval(2 * 86_400)
        picker.chosen.wrappedValue = anotherDay
        #expect(held.date == anotherDay)
        #expect(held.closed == 1)
    }

    private final class Held {
        var date: Date?
        var closed = 0
    }
}
