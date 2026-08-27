import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The sheet's filter section — the controls, not the request they build.
///
/// What the filters ask the server for is asserted in MemosCore, against real requests
/// (`@Suite("Filters")`). This bundle cannot build a `MemoSearch` at all: that needs a client from
/// the API layer, which MemosFeaturesTests deliberately does not link (`SearchSheetTests` documents
/// the same wall). So what is measured here is what a person can SEE and reach — which filters the
/// row admits to, which chips stay reachable, and whether any of it still fits at the accessibility
/// text sizes.
@MainActor
@Suite("Search filters")
struct SearchFilterControlsTests {
    /// The sheet on the narrowest iPhone still sold, minus its own horizontal padding.
    private static let contentWidth: CGFloat = 393 - 2 * DesignTokens.Space.roomy

    private func tag(_ name: String, _ count: Int) -> MemoTag {
        MemoTag(name: name, count: count)
    }

    /// The guard behind the whole section (design note §5, Q4): a filter that hides memos without
    /// saying so is the worse failure, and the row is drawn COLLAPSED most of the time. So the
    /// summary has to name every kind of thing that can be narrowed — one case per category, not
    /// just the tags.
    @Test("a collapsed filter row says everything it is hiding")
    func theSummaryNamesEveryFilterThatIsSet() {
        #expect(
            SearchFilterSummary.text(for: .empty) == nil,
            "an unnarrowed search claimed a filter"
        )
        #expect(SearchFilterSummary.accessibilityLabel(for: .empty) == "Filters, none set")

        #expect(
            SearchFilterSummary.text(for: SearchFilters(tags: ["travel", "food"]))
                == "#travel · #food",
            "a tag went unnamed"
        )
        #expect(
            SearchFilterSummary.text(for: SearchFilters(visibility: .protected)) == "Protected",
            "a visibility went unnamed"
        )
        #expect(
            SearchFilterSummary.text(for: SearchFilters(archive: .only)) == "Archived only",
            "an archive scope went unnamed"
        )
        // The default archive scope is not a filter and must not read as one — a row that always
        // said something would say nothing.
        #expect(SearchFilters(archive: .active).isEmpty)
        #expect(SearchFilterSummary.text(for: SearchFilters(archive: .active)) == nil)

        // All of them at once, in the order the controls stand.
        let everything = SearchFilters(
            tags: ["travel"], visibility: .private, archive: .including
        )
        #expect(SearchFilterSummary.text(for: everything) == "#travel · Private · Include archived")
        #expect(
            SearchFilterSummary.accessibilityLabel(for: everything)
                == "Filters, #travel · Private · Include archived",
            "VoiceOver hears less than the screen shows"
        )
    }

    /// Every scope a person can choose says which one it is. Exhaustive over the cases, so a scope
    /// added later cannot arrive without a word — and distinct, because two options sharing a word
    /// is a control that cannot be used.
    @Test("every archive scope has its own word, and each one mentions the archive")
    func theArchiveScopesAreNamedAndDistinct() {
        let labels = MemoArchiveScope.allCases.map(\.label)

        #expect(labels.count == 3, "a scope was added without a case here")
        #expect(Set(labels).count == labels.count, "two archive scopes share a label: \(labels)")
        for (scope, label) in zip(MemoArchiveScope.allCases, labels) {
            #expect(!label.isEmpty, "\(scope) draws nothing")
            #expect(
                label.lowercased().contains("archiv"),
                "\(scope) is called \"\(label)\", which never mentions the archive"
            )
        }
    }

    /// The row is also how a tag comes OFF. A chosen tag pushed out of the top dozen — a household
    /// with fifty tags, or counts that moved — would otherwise go on narrowing the list from
    /// somewhere nobody can see or reach.
    @Test("a chosen tag stays on the row however the counts move")
    func aChosenTagIsAlwaysDrawn() {
        var many: [MemoTag] = []
        for count in 1...20 {
            many.append(tag("tag\(count)", count))
        }

        // "tag3" is far outside the twelve most used, and chosen.
        let chips: [MemoTag] = SearchFilterTags.chips(offering: many, chosen: ["tag3"])
        let names: [String] = chips.map(\.name)
        let appearances: Int = names.filter({ $0 == "tag3" }).count

        #expect(names.contains("tag3"), "a chosen tag fell off the row")
        #expect(names.first == "tag20", "the offered end of the row stopped being most-used")
        #expect(appearances == 1, "a chosen tag that IS offered was drawn twice")
        // It keeps the count the server gave it: the row is not inventing a tag, it is keeping one.
        let kept: MemoTag? = chips.first(where: { $0.name == "tag3" })
        #expect(kept?.count == 3)

        // Control: unchosen, that same tag is not on the row — so the rule above is the choosing
        // and not a cap that never applies.
        let unchosen: [MemoTag] = SearchFilterTags.chips(offering: many, chosen: [])
        let unchosenNames: [String] = unchosen.map(\.name)
        #expect(!unchosenNames.contains("tag3"), "an unchosen tag was kept past the cap")
        #expect(unchosen.count == TagChipsPresentation.limit)

        // A chosen tag the server has stopped mentioning at all still draws, so it can be taken
        // off. It has no count, because none is known.
        let vanished: [MemoTag] = SearchFilterTags.chips(
            offering: [tag("travel", 3)],
            chosen: ["gone"]
        )
        let vanishedNames: [String] = vanished.map(\.name)
        #expect(vanishedNames == ["travel", "gone"])
        #expect(vanished.last?.count == 0)
    }

    /// A search narrowed by filters alone puts nothing in the field, so the screen it pushes has
    /// nothing to be called — an empty navigation bar over a list of memos nobody can name.
    @Test("a results screen with no term is named by its filters")
    func theResultsScreenIsNamedByWhateverTheSearchWas() {
        // The field wins whenever it holds anything, including the text a tag shortcut writes.
        #expect(
            SearchResultsTitle.text(term: "travel", filters: SearchFilters(tags: ["trip"]))
                == "travel"
        )
        #expect(SearchResultsTitle.text(term: "#travel", filters: .empty) == "#travel")

        // Nothing typed: the filters say what the list is.
        #expect(
            SearchResultsTitle.text(term: "", filters: SearchFilters(tags: ["trip"])) == "#trip"
        )
        #expect(
            SearchResultsTitle.text(term: "   ", filters: SearchFilters(archive: .only))
                == "Archived only",
            "a field of spaces was taken for a title"
        )

        // Neither: a word rather than a blank bar. It is not reachable from the sheet — an
        // unnarrowed, untyped search is never run — but a title that could be empty is not a title.
        #expect(!SearchResultsTitle.text(term: "", filters: .empty).isEmpty)
    }

    /// The wiring, pressed rather than inspected. A chip in this row is a CHOICE, not a gesture
    /// that ends somewhere: it hands its tag back and nothing else happens, which is the whole
    /// difference between this row and the shortcut row above it — and the only reason a second
    /// tag can be chosen at all.
    @Test("a tap on a filter chip hands back its tag and goes nowhere")
    func aFilterChipTogglesItsOwnTag() {
        let travel = tag("travel", 9)
        let chosen = Box<MemoTag?>(nil)

        let pressed = PressProbe.withElement(
            labelled: TagChipsPresentation.accessibilityLabel(for: travel),
            in: FilterTagChipRow(
                chips: [travel, tag("food", 2)],
                chosen: [],
                phase: .ready,
                toggle: { chosen.value = $0 }
            )
        ) { $0?.accessibilityActivate() ?? false }

        #expect(pressed, "the chip did not accept an activation")
        #expect(chosen.value?.name == "travel", "the chip handed back the wrong tag")

        // What that choice becomes, and what the SAME gesture on it does next.
        #expect(SearchFilters.empty.toggling("travel").contains("travel"))
        #expect(!SearchFilters.empty.toggling("travel").toggling("travel").contains("travel"))

        // Control: a row still waiting for its tags has no controls in it at all, so a chip cannot
        // be pressed before anyone knows what it is.
        let early = Box(false)
        let foundWhileLoading = PressProbe.withElement(
            labelled: TagChipsPresentation.accessibilityLabel(for: travel),
            in: FilterTagChipRow(
                chips: [travel],
                chosen: [],
                phase: .loading,
                toggle: { _ in early.value = true }
            )
        ) { $0 != nil }
        #expect(!foundWhileLoading, "a chip in a waiting row was a control")
        #expect(!early.value)
    }

    /// A selection that resized the chip would shuffle every tag after it along the row on every
    /// tap, which is the same jump `TagChipRow` already keeps room against (MEMNG-176).
    @Test("choosing a tag does not change the size of its chip")
    func aChosenChipIsTheSameSizeAsAnUnchosenOne() {
        let travel = tag("travel", 9)
        let unchosen = LayoutProbe.size(
            FilterTagChip(tag: travel, selected: false),
            width: Self.contentWidth,
            typeSize: .large
        )
        let chosen = LayoutProbe.size(
            FilterTagChip(tag: travel, selected: true),
            width: Self.contentWidth,
            typeSize: .large
        )

        #expect(unchosen.width > 0, "an unchosen chip drew nothing")
        #expect(
            chosen == unchosen,
            "choosing the tag moved the row by \(chosen.width - unchosen.width)pt"
        )

        // Control: the chip really is measured, not a constant — a longer tag is a wider chip.
        let longer = LayoutProbe.size(
            FilterTagChip(tag: MemoTag(name: "travelling-with-children", count: 9), selected: true),
            width: Self.contentWidth,
            typeSize: .large
        )
        #expect(longer.width > chosen.width)
    }

    /// The one row that is always on screen, at the text size where a row stops fitting. It is a
    /// glyph, a word, whatever the filters say, and a chevron on one line; the summary can
    /// truncate, but the row may not overflow the sheet.
    @Test("the filter row fits at accessibility5")
    func theDisclosureRowFitsAtAccessibility5() {
        let narrowed = SearchFilters(tags: ["travel", "food"], visibility: .protected)
        for filters in [SearchFilters.empty, narrowed] {
            let row = LayoutProbe.size(
                SearchFilterDisclosure(filters: filters, expanded: false, toggle: {}),
                width: Self.contentWidth,
                typeSize: .accessibility5
            )
            #expect(
                row.width <= Self.contentWidth,
                "the filter row overflows the sheet by \(row.width - Self.contentWidth)pt"
            )
            #expect(row.height > 0, "the filter row drew nothing")
        }

        // And it grows with the text size rather than ignoring it — a row pinned to one height
        // would pass the fit above by being unreadable.
        let large = LayoutProbe.size(
            SearchFilterDisclosure(filters: narrowed, expanded: false, toggle: {}),
            width: Self.contentWidth,
            typeSize: .large
        )
        let huge = LayoutProbe.size(
            SearchFilterDisclosure(filters: narrowed, expanded: false, toggle: {}),
            width: Self.contentWidth,
            typeSize: .accessibility5
        )
        #expect(huge.height > large.height)
    }
}
