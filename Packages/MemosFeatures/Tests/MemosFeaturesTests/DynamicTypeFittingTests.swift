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
        // `nil` with an account default is the WIDEST the pill ever gets — "Default (Protected)"
        // — which is exactly the label the resolved-default fix introduced.
        let choices: [(MemoVisibility?, MemoVisibility?)] = [
            (nil, nil),
            (nil, .protected),
            (.private, nil),
            (.protected, nil),
            (.public, nil),
        ]
        for (choice, accountDefault) in choices {
            let pill = VisibilityChoicePill(selection: choice, accountDefault: accountDefault)
            let atLargest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            let atDefault = LayoutProbe.idealWidth(pill, typeSize: .large)
            // It fits the space the sheet actually gives it — so it is never cut short.
            #expect(
                atLargest <= Self.composeContentWidth,
                "\(pill.title) wants \(atLargest)pt of \(Self.composeContentWidth)"
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

    /// The three ways a memo body can be wrong about text size, in one measurement.
    ///
    /// MarkdownUI resolves every run through a POINT size rather than a Dynamic Type role, which
    /// leaves three failure modes: naming a size that is not the platform's body size (the old
    /// `FontSize(16)`), naming one that never moves (a truly pinned body), and naming one that has
    /// ALREADY been scaled — which scales it twice and produced a 161pt line while this phase was
    /// being written. The floor catches the second, the ceiling catches the third, and matching
    /// `.font(.body)` at the default size catches the first.
    @Test("a memo body is the platform's body text, and grows like it")
    func memoBodyTracksTheBodyRole() {
        let width: CGFloat = 320
        let sample = "Hello"
        let memoDefault = LayoutProbe.size(
            MemoMarkdownView(content: sample), width: width, typeSize: .large
        ).height
        let memoLargest = LayoutProbe.size(
            MemoMarkdownView(content: sample), width: width, typeSize: .accessibility5
        ).height
        let bodyDefault = LayoutProbe.size(
            Text(sample).font(.body), width: width, typeSize: .large
        ).height
        let bodyLargest = LayoutProbe.size(
            Text(sample).font(.body), width: width, typeSize: .accessibility5
        ).height

        // At the default size a memo line IS a body line — not a point smaller.
        #expect(
            abs(memoDefault - bodyDefault) < 0.5,
            "memo line is \(memoDefault)pt against a body line of \(bodyDefault)pt"
        )

        let memoGrowth = memoLargest / memoDefault
        let bodyGrowth = bodyLargest / bodyDefault
        #expect(bodyGrowth > 2.5)
        // It moves with the reader — a pinned body measures the same at both ends.
        #expect(
            memoGrowth > 2.5,
            "memo grew \(memoGrowth)x where the platform's body grew \(bodyGrowth)x"
        )
        // And it moves ONCE. A size that was scaled before it was handed over grows by the
        // square of that factor.
        #expect(
            memoGrowth < bodyGrowth * 1.25,
            "memo grew \(memoGrowth)x where the platform's body grew \(bodyGrowth)x"
        )
    }

    /// The base size is not a taste: it is whatever the platform says `.body` is. Asserting it
    /// against UIKit rather than against the literal is what makes `16` a failure.
    @Test("the body size the theme names is the platform's own body size")
    func themeBodySizeIsThePlatformBodySize() {
        let platform = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).pointSize
        #expect(MemoMarkdownTheme.baseBodyPointSize == platform)
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
