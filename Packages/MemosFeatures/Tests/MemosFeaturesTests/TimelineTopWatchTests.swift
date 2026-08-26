import CoreGraphics
import Testing

@testable import MemosFeatures

/// When an anchored list may reach for the page above it (MEMNG-179).
///
/// Every case here is a sequence, because the whole of the decision is what came before: the same
/// reading — "the list is at its top" — means "fetch" after a scroll and "do nothing at all" on
/// the frame a jump lands, and a trigger that cannot tell them apart pages the reader straight
/// back to today from the day they just asked for.
///
/// The readings are taken into a local before they are asserted, because `#expect` evaluates its
/// expression inside a closure that captures immutably and this watch is a value that moves.
@Suite("Timeline top watch")
struct TimelineTopWatchTests {
    @Test("a list that opens at its top and stays there never asks for a page above")
    func aStillListAsksForNothing() {
        var watch = TimelineTopWatch()

        // Every frame of a list nobody has scrolled reads the same way.
        let first = watch.arrivedAtTop(true)
        let second = watch.arrivedAtTop(true)
        let third = watch.arrivedAtTop(true)

        #expect(!first, "a list that has not moved asked for the page above it")
        #expect(!second)
        #expect(!third)
    }

    @Test("a scroll away and back asks once")
    func aReturnToTheTopAsksOnce() {
        var watch = TimelineTopWatch()

        let leaving = watch.arrivedAtTop(false)
        let away = watch.arrivedAtTop(false)
        let returning = watch.arrivedAtTop(true)
        // And it does not keep asking while the reader sits there.
        let sitting = watch.arrivedAtTop(true)
        let stillSitting = watch.arrivedAtTop(true)

        #expect(!leaving, "scrolling down asked for the page above")
        #expect(!away)
        #expect(returning, "coming back to the top asked for nothing")
        #expect(!sitting, "sitting at the top asked again")
        #expect(!stillSitting)
    }

    @Test("a second page above needs a second journey away from the top")
    func eachArrivalNeedsItsOwnDeparture() {
        var watch = TimelineTopWatch()

        _ = watch.arrivedAtTop(false)
        let firstReturn = watch.arrivedAtTop(true)
        _ = watch.arrivedAtTop(false)
        let secondReturn = watch.arrivedAtTop(true)

        #expect(firstReturn)
        #expect(secondReturn, "the second return to the top asked for nothing")
    }

    @Test("a jump's own scroll to the top is not a reader coming back to it")
    func aSettledJumpDoesNotCount() {
        var watch = TimelineTopWatch()

        // The frames a jump's animation passes through, from a list that was scrolled deep.
        _ = watch.arrivedAtTop(false)
        _ = watch.arrivedAtTop(false)
        watch.settled()
        let onArrival = watch.arrivedAtTop(true)
        // The reader's OWN next scroll away and back.
        _ = watch.arrivedAtTop(false)
        let afterAReadersScroll = watch.arrivedAtTop(true)

        #expect(
            !onArrival,
            "arriving at the jumped-to day paged the memos it jumped away from back on top"
        )
        // Positive control: settling disarms the jump rather than the trigger.
        #expect(afterAReadersScroll)
    }

    /// The geometry half. `contentOffset` is measured from the content's origin with the inset
    /// above it, so a list at rest at its top reads `-contentInsets.top` rather than zero — the
    /// sum is what is zero there, and reading the offset alone would call a list at rest "scrolled
    /// down by the height of its own inset" and never fire at all.
    @Test("the top of a list is where the offset and the inset cancel")
    func theTopIsWhereTheInsetCancels() {
        #expect(TimelineTopWatch.isAtTop(contentOffsetY: -120, topInset: 120))
        // A little slack, so the page above is on its way while the last rows are still moving.
        #expect(TimelineTopWatch.isAtTop(contentOffsetY: -100, topInset: 120, slack: 40))
        #expect(TimelineTopWatch.isAtTop(contentOffsetY: -80, topInset: 120, slack: 40))
        #expect(!TimelineTopWatch.isAtTop(contentOffsetY: -79, topInset: 120, slack: 40))
        // Scrolled down a screen is not the top by any reading.
        #expect(!TimelineTopWatch.isAtTop(contentOffsetY: 700, topInset: 120))
        // Overscrolled ABOVE the top still is.
        #expect(TimelineTopWatch.isAtTop(contentOffsetY: -260, topInset: 120))
        // And a list with no inset at all reads the plain offset.
        #expect(TimelineTopWatch.isAtTop(contentOffsetY: 0, topInset: 0))
        #expect(!TimelineTopWatch.isAtTop(contentOffsetY: 41, topInset: 0, slack: 40))
    }
}
