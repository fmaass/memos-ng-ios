import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The sheet the corner loupe raises, measured rather than looked at.
///
/// Its header is the one part of the sheet that cannot scroll, wrap or be scrolled past: a title
/// and the button that dismisses the sheet, side by side on one line. At an accessibility text
/// size that line is where a header stops fitting, and a truncated "Search" over a field is how a
/// search surface stops being one.
@MainActor
@Suite("Search sheet")
struct SearchSheetTests {
    /// The sheet on the narrowest iPhone still sold, minus its own horizontal padding.
    private static let contentWidth: CGFloat = 393 - 2 * DesignTokens.Space.roomy

    @Test("the sheet header fits at accessibility5")
    func theHeaderFitsAtAccessibility5() {
        let title = SearchSheetTitle()
        let close = SearchSheetCloseButton(close: {})
        let gap = DesignTokens.Space.regular

        // Measured in PARTS, because the header's own body puts a flexible gap between them and a
        // flexible gap answers whatever width it is offered — probing the whole header would read
        // the proposal back rather than the width the header needs. The two ends and the minimum
        // space between them are the whole of what its `HStack` has to fit on one line.
        let titleWidth = LayoutProbe.idealWidth(title, typeSize: .accessibility5)
        let closeWidth = LayoutProbe.idealWidth(close, typeSize: .accessibility5)
        #expect(
            titleWidth + gap + closeWidth <= Self.contentWidth,
            "the header wants \(titleWidth + gap + closeWidth)pt of \(Self.contentWidth)"
        )

        // And it fits because it is small enough, not because it was pinned: a header that
        // ignored the text size would measure the same at both.
        #expect(titleWidth > LayoutProbe.idealWidth(title, typeSize: .large))
        #expect(closeWidth > LayoutProbe.idealWidth(close, typeSize: .large))

        // The header really is those two things: it reports the width it is offered (its gap
        // takes the slack) rather than demanding more of it.
        let header = LayoutProbe.size(
            SearchSheetHeader(close: {}),
            width: Self.contentWidth,
            typeSize: .accessibility5
        )
        #expect(header.width <= Self.contentWidth, "the header overflows the sheet")
    }

    /// Every state the sheet can be in says something a person can act on, and none of them says
    /// it in a way that reads as a fault. The two that carry the whole-word explanation are the
    /// ones a search lands in when it found nothing — before it has run, and after.
    @Test("no state of the sheet is silent, and the empty ones explain whole-word matching")
    func everyOutcomeSaysSomething() {
        let states: [MemoSearchOutcome] = [
            .idle,
            .tooShort(minimum: MemoSearch.minimumTermLength),
            .searching,
            .matched,
            .noMatches,
            .failed("the server said no"),
        ]
        for outcome in states {
            #expect(outcome.title?.isEmpty == false, "\(outcome) draws no title")
        }
        #expect(MemoSearchOutcome.idle.detail?.contains("whole words") == true)
        #expect(MemoSearchOutcome.noMatches.detail?.contains("whole words") == true)
        // Positive control: `detail` is not simply that sentence for everything.
        #expect(MemoSearchOutcome.matched.detail == nil)
        #expect(MemoSearchOutcome.failed("the server said no").detail == "the server said no")
    }

    /// The heatmap is the SHEET's read now, and this is the assertion that says so: appearing is
    /// what loads it.
    ///
    /// Until MEMNG-126 the activity card headed the TIMELINE, and it was re-read on every pull of
    /// that list — a second request in front of a refresh nobody had asked a heatmap question of
    /// (MEMNG-166). The sheet's empty-query state owns the store instead, and SwiftUI builds that
    /// view fresh for every presentation, so the read is once per opening of the sheet and at no
    /// other moment.
    ///
    /// `SearchSheetHeatmap` is what makes it assertable at all: the sheet as a whole needs a
    /// `MemoSearch`, which needs a client from the API layer this bundle deliberately does not
    /// link — the same wall `TimelineToolbarTests` and `SettingsRenderTests` both document.
    @Test("the empty-query state reads the heatmap when it appears")
    func theEmptyStateReadsTheHeatmapWhenItAppears() {
        let loads = Box(0)
        let read = Signal()
        let jumped = Box<MemoQueryAnchor?>(nil)
        let host = UIHostingController(
            rootView: SearchSheetHeatmap(
                load: { _ in
                    loads.value += 1
                    read.fire()
                },
                jump: { jumped.value = $0 }
            )
        )
        host.view.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 400)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // The read is a task, so it lands after the hierarchy exists rather than during it. The
        // wait ENDS ON THE READ (`Signal.fire` stops the run loop) instead of after a window
        // somebody guessed: a fixed window is a false red on a busy build host and a bill every
        // green run pays on a quiet one.
        read.wait()

        #expect(loads.value >= 1, "appearing did not read the heatmap")
        // And opening the sheet jumps nowhere by itself: a jump is a tap on a day.
        #expect(jumped.value == nil)
        // The window is held to the end: a hosted view whose window has gone is a view whose task
        // was cancelled, and the count would then be a reading of the timing rather than of this.
        withExtendedLifetime(window) {}
    }
    /// The tag chips read themselves on the same signal, and this is the case that would silently
    /// never load: with no tags yet the row draws nothing at all, so a read attached to the chips
    /// instead of to the row would be a row that only fetched its tags once it had some.
    @Test("the tag row reads its tags when it appears, even with none to show")
    func theTagRowReadsItsTagsWhenItAppears() {
        let loads = Box(0)
        let read = Signal()
        let searched = Box<MemoQuery?>(nil)
        let shown = Box(false)
        let host = UIHostingController(
            rootView: SearchSheetTags(
                load: { _ in
                    loads.value += 1
                    read.fire()
                },
                search: { query, _ in searched.value = query },
                showResults: { shown.value = true }
            )
        )
        host.view.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 200)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        read.wait()

        #expect(loads.value >= 1, "appearing did not read the tags")
        // And opening the sheet searches for nothing by itself, nor leaves for a result screen:
        // both are a tap on a chip.
        #expect(searched.value == nil)
        #expect(!shown.value)
        withExtendedLifetime(window) {}
    }

    /// The report itself (MEMNG-175): the first open showed nothing until it was closed and
    /// reopened. The load is DELAYED here — held open for as long as the test looks — because that
    /// is the only window in which the defect exists, and it is the window a cold first open spends
    /// entirely inside.
    @Test("a sheet whose tags have not arrived shows that they are coming, not that there are none")
    func aDelayedTagRowShowsItIsLoading() {
        let read = Signal()
        let host = UIHostingController(
            rootView: SearchSheetTags(
                // Never answers. The row has to be worth looking at anyway.
                load: { _ in
                    read.fire()
                    try? await Task.sleep(for: .seconds(3600))
                },
                search: { _, _ in },
                showResults: {}
            )
        )
        host.view.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 200)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        read.wait()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let drawn = host.sizeThatFits(
            in: CGSize(width: Self.contentWidth, height: LayoutProbe.unbounded)
        )
        #expect(drawn.height > 0, "a sheet whose tags are still coming drew nothing at all")
        withExtendedLifetime(window) {}
    }

    /// Which of the two states a section is in, from the only two facts that separate them — one
    /// case per input category, because the interesting one is the pair that look identical from
    /// the outside: an account with no tags, and an account whose tags have not arrived.
    @Test("a section is loading until it has been answered, one way or the other")
    func thePhaseIsDecidedByWhetherTheServerHasSpoken() {
        #expect(SearchSectionPhase.phase(hasLoaded: false, failed: false) == .loading)
        #expect(SearchSectionPhase.phase(hasLoaded: true, failed: false) == .ready)
        // A read that failed has been answered: the server said no, and a section spinning for
        // ever over that would be the worse lie.
        #expect(SearchSectionPhase.phase(hasLoaded: false, failed: true) == .ready)
        #expect(SearchSectionPhase.phase(hasLoaded: true, failed: true) == .ready)
        // Nothing in a waiting section is a control — a placeholder chip searches for a tag
        // nobody has, and a placeholder day opens the timeline at a date chosen by no data.
        #expect(!SearchSectionPhase.loading.acceptsTaps)
        #expect(SearchSectionPhase.ready.acceptsTaps)
    }

    /// The lifetime rule behind the first-presentation defect. A bare `.task` runs once per view
    /// identity; every appearance is a fresh id here, so a presentation SwiftUI tears down and
    /// re-attaches asks again instead of sitting on a read that was cancelled.
    @Test("every appearance of a section is a read of its own")
    func everyAppearanceIsItsOwnRead() {
        let lifecycle = SearchSectionLoad()
        #expect(lifecycle.appearances == 0, "a section that has not appeared owes a read")

        lifecycle.appeared()
        #expect(lifecycle.appearances == 1)
        lifecycle.appeared()
        #expect(lifecycle.appearances == 2, "a second appearance reused the first one's read")
    }

    /// MEMNG-176. The row grew from nothing to a line of chips as the tags landed, and everything
    /// under it moved with it. Waiting, it now keeps the room the chips will take.
    @Test("the tag row is the same height waiting as it is once the tags land")
    func theTagRowKeepsTheRoomItsChipsWillTake() {
        let loaded = [
            MemoTag(name: "travel", count: 9),
            MemoTag(name: "books", count: 4),
            MemoTag(name: "food", count: 2),
        ]
        let waiting = LayoutProbe.size(
            TagChipRow(chips: [], phase: .loading, search: { _, _ in }, showResults: {}),
            width: Self.contentWidth,
            typeSize: .large
        )
        let arrived = LayoutProbe.size(
            TagChipRow(chips: loaded, phase: .ready, search: { _, _ in }, showResults: {}),
            width: Self.contentWidth,
            typeSize: .large
        )

        #expect(waiting.height > 0, "a waiting row kept no room at all")
        #expect(
            waiting.height == arrived.height,
            "the tags landing moved the sheet by \(arrived.height - waiting.height)pt"
        )
        // Control: the height is the ROW's, not a constant — an answered row with nothing in it
        // really does collapse, which is the deliberate "nothing rather than an empty card".
        let empty = LayoutProbe.size(
            TagChipRow(chips: [], phase: .ready, search: { _, _ in }, showResults: {}),
            width: Self.contentWidth,
            typeSize: .large
        )
        #expect(empty.height < waiting.height)
    }

    /// The other half of MEMNG-176. Bare, the sheet's stack is laid out inside the detent and an
    /// over-tall one is centred in what it was offered — which is what walked the title and the
    /// field up off the top while the sheet was still growing.
    @Test("the sheet's content takes the height it is offered instead of overflowing it")
    func theColumnFitsItselfIntoTheSheet() {
        let offered: CGFloat = 300
        let tall = VStack(spacing: 0) {
            ForEach(0..<40, id: \.self) { _ in
                Color.clear.frame(height: 40)
            }
        }

        let column = LayoutProbe.size(
            SearchSheetColumn { tall },
            width: Self.contentWidth,
            height: offered
        )
        #expect(
            column.height <= offered,
            "the sheet's content overflowed its detent by \(column.height - offered)pt"
        )

        // Control: the content really does want more than it was offered, so the fit above is the
        // column's doing and not a stack that happened to be short.
        let bare = LayoutProbe.size(
            tall.padding(DesignTokens.Space.roomy),
            width: Self.contentWidth,
            height: offered
        )
        #expect(bare.height > offered, "the control content fits, so it proves nothing")
    }
}

/// One thing a hosted view did, and the wait for it — with no clock in it anywhere.
///
/// A view's `.task` starts when the view appears, and appearing needs the run loop to turn, so the
/// run loop is what a test has to wait on. It waits INDEFINITELY and the event ENDS the wait:
/// `fire` stops the run loop, so `wait` returns the instant the view acts. That is the difference
/// between this and `run(until: now + 0.4)` — a fixed window is a failure the test invents when the
/// host is loaded (merkur peaked at a one-minute load of 218 on 2026-08-26) and a delay every green
/// run pays when it is not.
///
/// The slice inside the loop is not a deadline. It is a floor against a run loop with no input
/// source left to process, which would otherwise spin the CPU; the loop around it has no bound at
/// all, so a slow host waits longer rather than reporting something that did not happen.
@MainActor
private final class Signal {
    private var fired = 0

    func fire() {
        fired += 1
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func wait() {
        while fired == 0 {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
