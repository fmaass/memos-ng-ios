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
            (nil, .public),
            (.private, nil),
            (.protected, nil),
            (.public, nil),
        ]
        for (choice, accountDefault) in choices {
            let pill = VisibilityChoicePill(selection: choice, accountDefault: accountDefault)
            let atLargest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            let atDefault = LayoutProbe.idealWidth(pill, typeSize: .large)
            let shown = pill.title ?? "(glyph only)"
            // It fits the space the sheet actually gives it — so it is never cut short.
            #expect(
                atLargest <= Self.composeContentWidth,
                "\(shown) wants \(atLargest)pt of \(Self.composeContentWidth)"
            )
            // And it fits because it is small enough, not because it was pinned: a control that
            // ignored the text size would measure the same at both.
            #expect(atLargest > atDefault)
        }
    }

    @Test("the date row fits without truncating at the largest text size")
    func dateRowFitsAtAccessibility5() {
        // Both things the row can be: the default, and a date long enough to be the widest label
        // it ever draws (a December in a four-figure year with a two-digit day).
        let chosen = Date(timeIntervalSince1970: 1_766_000_000)
        for date in [nil, chosen] as [Date?] {
            let pill = MemoDatePill(date: date)
            let atLargest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            let atDefault = LayoutProbe.idealWidth(pill, typeSize: .large)
            #expect(
                atLargest <= Self.composeContentWidth,
                "the date pill wants \(atLargest)pt of \(Self.composeContentWidth)"
            )
            // It fits because it is small enough, not because it was pinned: a control that
            // ignored the text size would measure the same at both.
            #expect(atLargest > atDefault)
        }
        // And the interactive row, which is now the pill and nothing else: putting the date back
        // to the time of writing moved INSIDE the picker, because a control that appears beside
        // another one is a control that moves it.
        let row = MemoDateRow(date: .constant(chosen))
        let rowAtLargest = LayoutProbe.idealWidth(row, typeSize: .accessibility5)
        #expect(
            rowAtLargest <= Self.composeContentWidth,
            "the date row wants \(rowAtLargest)pt of \(Self.composeContentWidth)"
        )
    }

    /// The card the search sheet's empty-query state is made of — the timeline's header until
    /// MEMNG-126, and the same card either way. Its squares answer the card's WIDTH now rather
    /// than the text size (MEMNG-186, and the test below it), so what is left to hold here is
    /// everything around them: the card's own line still grows with the type and still fits, and
    /// the card as a whole is still taller at the accessibility sizes than at the default.
    ///
    /// The sheet's content width and the timeline row's are the same 361pt, so this measurement
    /// holds for the card in its new home without being taken twice.
    @Test("the heatmap card fits at the largest text size")
    func heatmapCardFitsAtAccessibility5() {
        let content = Self.cardWidth - 2 * DesignTokens.Space.regular
        let grid = HeatmapPresentation.grid(
            from: ["2026-08-25": 4], today: Date(timeIntervalSince1970: 1_787_702_400)
        )

        let header = HeatmapHeader()
        let headerLargest = LayoutProbe.idealWidth(header, typeSize: .accessibility5)
        #expect(headerLargest <= content, "the card's line wants \(headerLargest)pt")
        #expect(headerLargest > LayoutProbe.idealWidth(header, typeSize: .large))

        // The whole card, at the width the list really gives it: never wider than its row, and
        // taller at the largest text size — so it answered the size rather than ignoring it.
        let card = HeatmapCard(grid: grid)
        let largest = LayoutProbe.size(card, width: Self.cardWidth, typeSize: .accessibility5)
        let ordinary = LayoutProbe.size(card, width: Self.cardWidth, typeSize: .large)
        #expect(largest.width <= Self.cardWidth)
        #expect(largest.height > ordinary.height, "the card ignored the text size")
    }

    /// MEMNG-186. The squares were sized by `@ScaledMetric`: twelve columns of 12pt cells sitting
    /// in the left third of a 337pt card, growing to a capped 26 only at the accessibility sizes.
    /// A grid of squares is not a function of the text size — it is a function of the width it is
    /// given, and there is now one value that says so for both the drawing and the hit test.
    ///
    /// So the assertion is the geometry itself: the grid is drawn at exactly the size
    /// `HeatmapGeometry` computes for the width the card offers, it fills that width, and it is
    /// the same grid at every text size because the card is the same width at every text size.
    @Test("the heatmap grid is drawn from the card's width at every text size")
    func theHeatmapGridIsDrawnFromTheCardsWidth() {
        let content = Self.cardWidth - 2 * DesignTokens.Space.regular
        // A household that has been writing for the whole window, so the grid really is twelve
        // columns wide. A young account's grid is a column or two and the 44pt cap binds instead
        // of the card — which is correct, and proves nothing about the width.
        let grid = HeatmapPresentation.grid(
            from: ["2026-06-04": 1, "2026-08-25": 4],
            today: Date(timeIntervalSince1970: 1_787_702_400)
        )
        #expect(grid.columns.count == 12, "the fixture is not a full twelve-week window")
        let geometry = HeatmapGeometry(
            availableWidth: content, of: grid, gap: HeatmapGridView.gap
        )

        let drawn = LayoutProbe.size(HeatmapGridView(grid: grid), width: content, typeSize: .large)
        #expect(
            drawn.width == geometry.width,
            "the grid drew \(drawn.width)pt where the geometry says \(geometry.width)pt"
        )
        #expect(drawn.height == geometry.height)
        // It fills the card it is in: what is left over is under a point a column.
        #expect(
            content - drawn.width < CGFloat(grid.columns.count),
            "\(content - drawn.width)pt of the card went unused"
        )

        // The same at the largest text size. The card is no wider there, so the grid is no wider
        // either — and no narrower: the cells are a texture, not type.
        let largest = LayoutProbe.size(
            HeatmapGridView(grid: grid), width: content, typeSize: .accessibility5
        )
        #expect(largest == drawn, "the grid answered the text size instead of the width")

        // And the days that answer to a finger are the same size as the days that do not:
        // scrubbing is what a square DOES, not a shape wrapped around it.
        let scrubbable = HeatmapGridView(
            grid: grid,
            scrubbing: HeatmapScrubbing(
                selectedKey: "2026-08-25", move: { _ in }, end: {}, cancelled: {}
            )
        )
        #expect(LayoutProbe.size(scrubbable, width: content, typeSize: .large) == drawn)

        // Control: the measurement really does follow the width it is offered, so the equalities
        // above are the geometry and not a grid that ignores everything.
        let narrow = LayoutProbe.size(
            HeatmapGridView(grid: grid), width: content / 2, typeSize: .large
        )
        #expect(narrow.width < drawn.width)
    }

    /// A tag chip is a control with a word in it, so it has to grow with the word — and still fit
    /// the sheet it is offered in, because a chip wider than the sheet is one a thumb cannot reach
    /// the end of.
    @Test("a tag chip grows with the text size and still fits the sheet")
    func tagChipFitsAtAccessibility5() {
        let chip = TagChip(tag: MemoTag(name: "travel", count: 12))
        let largest = LayoutProbe.idealWidth(chip, typeSize: .accessibility5)
        let ordinary = LayoutProbe.idealWidth(chip, typeSize: .large)

        #expect(largest <= Self.cardWidth, "the chip wants \(largest)pt of \(Self.cardWidth)")
        // It fits because it is small enough, not because it was pinned: a chip that ignored the
        // text size would measure the same at both.
        #expect(largest > ordinary)
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

    /// The date pill sits beside the visibility pill now, so it has to survive the same sizes.
    /// Its default state — the one everyone sees — is the one that must never truncate.
    @Test("the date pill fits without truncating at the largest text size")
    func datePillFitsAtAccessibility5() {
        for date in [nil, Date(timeIntervalSince1970: 1_750_000_000)] {
            let pill = MemoDatePill(date: date)
            let atLargest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            let atDefault = LayoutProbe.idealWidth(pill, typeSize: .large)
            #expect(
                atLargest <= Self.composeContentWidth,
                "the date pill wants \(atLargest)pt of \(Self.composeContentWidth)"
            )
            #expect(atLargest > atDefault)
        }
    }

    // MARK: - the compose sheet's meta row

    /// A date the writer chose, long enough to be the widest short form the pill ever draws.
    private static let chosenDate = Date(timeIntervalSince1970: 1_766_000_000)

    private static func row(
        _ verbosity: ComposeMetaRow.Verbosity,
        count: Int,
        date: Date?,
        visibility: MemoVisibility?
    ) -> ComposeMetaPills {
        ComposeMetaPills(
            verbosity: verbosity,
            stage: .constant(ComposeStage()),
            attachmentCount: count,
            date: .constant(date),
            visibility: .constant(visibility),
            accountDefault: .protected
        )
    }

    /// Each of the three pills on its own, at the size where a layout stops being a matter of
    /// taste. They are `fixedSize`, so a pill that does not fit is not truncated — it is drawn off
    /// the edge of the sheet.
    @Test("all three meta pills fit at the largest text size")
    func metaPillsFitAtAccessibility5() {
        let budget = Self.composeContentWidth
        for spelling in [ComposeMetaRow.Spelling.glyph, .short] {
            let photos = PhotosPill(count: 12, spelling: spelling)
            let photosLargest = LayoutProbe.idealWidth(photos, typeSize: .accessibility5)
            #expect(photosLargest <= budget, "the photos pill wants \(photosLargest)pt")
            #expect(photosLargest > LayoutProbe.idealWidth(photos, typeSize: .large))

            let date = MemoDatePill(date: Self.chosenDate, spelling: spelling)
            let dateLargest = LayoutProbe.idealWidth(date, typeSize: .accessibility5)
            #expect(dateLargest <= budget, "the date pill wants \(dateLargest)pt")
            #expect(dateLargest > LayoutProbe.idealWidth(date, typeSize: .large))
        }
        for spelling in [ComposeMetaRow.Spelling.glyph, .short, .spelledOut] {
            let pill = VisibilityChoicePill(
                selection: .protected, accountDefault: .protected, spelling: spelling
            )
            let largest = LayoutProbe.idealWidth(pill, typeSize: .accessibility5)
            #expect(largest <= budget, "the visibility pill wants \(largest)pt")
            #expect(largest > LayoutProbe.idealWidth(pill, typeSize: .large))
        }
    }

    /// The promise the whole row rests on. `ViewThatFits` walks the spellings widest-first, so the
    /// LAST one is the one that has to fit when nothing else does — at the largest text size, with
    /// everything on it. If it does not, the row runs off the sheet instead of quietening down.
    @Test("the row's last spelling fits at the largest text size, whatever is on it")
    func metaRowFallbackFitsAtAccessibility5() throws {
        let fallback = try #require(ComposeMetaRow.Verbosity.allCases.last)
        #expect(fallback == .bare)
        let states: [(Int, Date?, MemoVisibility?)] = [
            (0, nil, nil),
            (12, Self.chosenDate, .private),
            (1, Self.chosenDate, .public),
        ]
        for (count, date, visibility) in states {
            let width = LayoutProbe.idealWidth(
                Self.row(fallback, count: count, date: date, visibility: visibility),
                typeSize: .accessibility5
            )
            #expect(
                width <= Self.composeContentWidth,
                "the fallback row wants \(width)pt of \(Self.composeContentWidth)"
            )
        }
        // And the widest spelling is the one the sheet gets at the ordinary text size.
        let full = LayoutProbe.idealWidth(
            Self.row(.plain, count: 12, date: Self.chosenDate, visibility: .protected),
            typeSize: .large
        )
        #expect(full <= Self.composeContentWidth, "the spelled-out row wants \(full)pt")
    }

    /// The row is its three pills and the two gaps between them — nothing else, in any state.
    ///
    /// This is the assertion the old layout failed. A ✕ arrived beside the date once one was
    /// chosen and a spinner arrived beside the picker while photos loaded, and everything to the
    /// right of each moved when it did. Measuring the row against the sum of its three pills is
    /// how a fourth thing gets caught, whatever it is.
    @Test("the meta row is exactly its three pills, in every state")
    func metaRowIsExactlyThreePills() {
        for verbosity in ComposeMetaRow.Verbosity.allCases {
            for (count, date) in [(0, nil as Date?), (12, Self.chosenDate)] {
                let pills = [
                    LayoutProbe.idealWidth(
                        PhotosPill(count: count, spelling: verbosity.count), typeSize: .large),
                    LayoutProbe.idealWidth(
                        MemoDatePill(date: date, spelling: verbosity.date), typeSize: .large),
                    LayoutProbe.idealWidth(
                        VisibilityChoicePill(
                            selection: .protected,
                            accountDefault: .protected,
                            spelling: verbosity.visibility
                        ),
                        typeSize: .large
                    ),
                ]
                let expected = pills.reduce(0, +) + 2 * DesignTokens.Space.snug
                let measured = LayoutProbe.idealWidth(
                    Self.row(verbosity, count: count, date: date, visibility: .protected),
                    typeSize: .large
                )
                #expect(
                    abs(measured - expected) < 1,
                    "\(verbosity) row is \(measured)pt where its three pills are \(expected)pt"
                )
            }
        }
    }

    /// Loading a photo must not resize anything. The spinner is drawn ON the glyph rather than
    /// beside it for exactly this reason — beside it, every pill to the right would shift for as
    /// long as the import took.
    @Test("importing photos does not change the photos pill's width")
    func importingDoesNotResizeThePill() {
        for count in [0, 3] {
            let idle = LayoutProbe.idealWidth(
                PhotosPill(count: count, isImporting: false), typeSize: .large)
            let busy = LayoutProbe.idealWidth(
                PhotosPill(count: count, isImporting: true), typeSize: .large)
            #expect(abs(idle - busy) < 0.5, "idle \(idle)pt vs importing \(busy)pt")
        }
    }

    /// The defect this measures shipped: the date popover presented as a 68-point sliver with one
    /// column of the calendar in it, because a popover takes the size its content ASKS for and a
    /// graphical `DatePicker` asks for nothing at all. At a zero proposal the unframed picker
    /// wanted 24pt — its own padding.
    @Test("the date picker asks for a calendar's width, not a sliver")
    func theDatePickerIsNotASliver() {
        let picker = MemoDatePicker(
            date: .constant(nil), seed: Date(timeIntervalSince1970: 1_750_000_000)
        )
        for typeSize in [DynamicTypeSize.large, .accessibility5] {
            let asked = LayoutProbe.size(picker, width: 0, typeSize: typeSize)
            #expect(asked.width >= 300, "the picker asks for \(asked.width)pt, not a calendar")
            #expect(asked.height >= 300, "the picker asks for \(asked.height)pt of height")
            // And it still fits the narrowest sheet it can be opened from.
            #expect(asked.width <= 393, "the picker wants \(asked.width)pt of a 393pt screen")
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
