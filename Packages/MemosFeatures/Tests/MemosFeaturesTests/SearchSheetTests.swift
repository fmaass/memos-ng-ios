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
        let jumped = Box<MemoQueryAnchor?>(nil)
        let host = UIHostingController(
            rootView: SearchSheetHeatmap(
                load: { _ in loads.value += 1 },
                jump: { jumped.value = $0 }
            )
        )
        host.view.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 400)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // The read is a task, so it lands a turn of the run loop after the hierarchy exists — the
        // same wait `SettingsRenderTests` documents for anything hosted.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

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
        let searched = Box<MemoQuery?>(nil)
        let host = UIHostingController(
            rootView: SearchSheetTags(
                load: { _ in loads.value += 1 },
                search: { query, _ in searched.value = query }
            )
        )
        host.view.frame = CGRect(x: 0, y: 0, width: Self.contentWidth, height: 200)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        #expect(loads.value >= 1, "appearing did not read the tags")
        // And opening the sheet searches for nothing by itself: a search is a tap on a chip.
        #expect(searched.value == nil)
        withExtendedLifetime(window) {}
    }

}
