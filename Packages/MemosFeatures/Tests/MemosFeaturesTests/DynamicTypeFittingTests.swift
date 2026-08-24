import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Accessibility sizes are where a layout stops being a matter of taste. These are fitting
/// assertions, not renders: each one fails when something would be truncated, clipped or simply
/// refuses to grow, which is what a screenshot at the default size can never tell you.
@MainActor
@Suite("Dynamic Type fitting")
struct DynamicTypeFittingTests {
    /// The compose sheet on the narrowest iPhone still sold, minus its own horizontal padding.
    /// If a control wants more than this it has to truncate, and truncating the word that says
    /// who can see a memo is not an option.
    private static let composeContentWidth: CGFloat = 393 - 2 * DesignTokens.Space.regular
    private static let cardWidth: CGFloat = 393 - 2 * DesignTokens.Space.roomy

    @Test("the visibility control fits without truncating at the largest text size")
    func visibilityControlFitsAtAccessibility5() {
        let choices: [MemoVisibility?] = [nil, .private, .protected, .public]
        for choice in choices {
            let pill = VisibilityChoicePill(selection: choice)
            let atLargest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            let atDefault = LayoutProbe.idealWidth(pill, typeSize: .large)
            // It fits the space the sheet actually gives it — so it is never cut short.
            #expect(
                atLargest <= Self.composeContentWidth,
                "\(choice?.label ?? "Default") wants \(atLargest)pt of \(Self.composeContentWidth)"
            )
            // And it fits because it is small enough, not because it was pinned: a control that
            // ignored the text size would measure the same at both.
            #expect(atLargest > atDefault)
        }
    }

    @Test("the timeline card's visibility pill also survives the largest text size")
    func timelinePillFitsAtAccessibility5() {
        for visibility in MemoVisibility.allCases {
            let pill = VisibilityPill(visibility: visibility)
            let atLargest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            let atDefault = LayoutProbe.idealWidth(pill, typeSize: .large)
            #expect(atLargest <= Self.cardWidth)
            #expect(atLargest > atDefault)
        }
    }

    /// The clipping assertion. A card with a fixed height, or a line limit on the body, measures
    /// SHORTER than the text it holds needs — so comparing the laid-out card against the height
    /// UIKit says that string requires at that size is a real check, not a snapshot.
    @Test("a timeline card is at least as tall as its own text at the largest size")
    func cardIsNotClippedAtAccessibility5() {
        let body = String(
            repeating: "The kitchen tap has been dripping since Tuesday and nobody rang. ",
            count: 3
        )
        let card = MemoCard(memo: MemoFixture.memo(content: body, tags: ["house"]))
        let laidOut = LayoutProbe.size(card, width: Self.cardWidth, typeSize: .accessibility5)
        let textAlone = LayoutProbe.textHeight(
            body,
            style: .body,
            category: .accessibilityExtraExtraExtraLarge,
            width: Self.cardWidth - 2 * DesignTokens.Space.roomy
        )
        #expect(textAlone > 0)
        #expect(
            laidOut.height >= textAlone,
            "card is \(laidOut.height)pt tall but its body alone needs \(textAlone)pt"
        )
        // The card is exactly as wide as it was offered — nothing is spilling sideways.
        #expect(abs(laidOut.width - Self.cardWidth) < 1)
    }

    /// The one that kills the pinned font size. MarkdownUI resolves every run through a POINT
    /// size, so a body that ignored Dynamic Type would measure the same at both ends of the scale.
    @Test("a memo body grows with the reader's text size")
    func memoBodyHonoursDynamicType() {
        let body = String(
            repeating: "A sentence about the garden, long enough to wrap more than once. ",
            count: 2
        )
        let view = MemoMarkdownView(content: body)
        let small = LayoutProbe.size(view, width: Self.cardWidth, typeSize: .xSmall).height
        let normal = LayoutProbe.size(view, width: Self.cardWidth, typeSize: .large).height
        let largest = LayoutProbe.size(view, width: Self.cardWidth, typeSize: .accessibility5)
            .height
        #expect(small > 0)
        #expect(normal > small)
        #expect(largest > normal * 2, "body is \(largest)pt at AX5 against \(normal)pt at default")
    }

    @Test("a whole card grows with the reader's text size")
    func cardHonoursDynamicType() {
        let card = MemoCard(
            memo: MemoFixture.memo(content: "Picked up the parcel from the neighbours.")
        )
        let normal = LayoutProbe.size(card, width: Self.cardWidth, typeSize: .large).height
        let largest = LayoutProbe.size(card, width: Self.cardWidth, typeSize: .accessibility5)
            .height
        #expect(largest > normal * 1.5)
    }
}
