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
}
