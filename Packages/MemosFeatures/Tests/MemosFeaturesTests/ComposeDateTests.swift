import Foundation
import MemosCore
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
}
