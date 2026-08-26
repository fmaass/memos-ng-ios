import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// Which tags the search sheet offers and what a tap on one asks for.
///
/// The cases worth writing down are the ones nobody can tap: the thirteenth tag, which is not
/// drawn, and the tag that would quietly search for everything.
@Suite("Tag chips")
struct TagChipsTests {
    private func tag(_ name: String, _ count: Int) -> MemoTag {
        MemoTag(name: name, count: count)
    }

    /// The server sends its tags in its own order; the row is the household's, most used first.
    @Test("the most used tags come first, and ties are settled by name")
    func chipsAreOrderedByUseThenName() {
        let chips = TagChipsPresentation.chips(
            for: [tag("food", 2), tag("travel", 9), tag("admin", 2), tag("books", 4)]
        )

        #expect(chips.map(\.name) == ["travel", "books", "admin", "food"])
    }

    /// Past a dozen the row has stopped being "the ones you use" and become a list of all of them.
    @Test("the row is capped, and what it keeps is the most used")
    func chipsAreCappedAtTheLimit() {
        let many = (1...20).map { tag("tag\($0)", $0) }

        let chips = TagChipsPresentation.chips(for: many)

        #expect(chips.count == TagChipsPresentation.limit)
        #expect(chips.first?.name == "tag20")
        #expect(chips.last?.name == "tag9", "the cap kept the wrong end of the list")
        #expect(
            !chips.contains(where: { $0.name == "tag8" }),
            "a less used tag survived the cap"
        )
    }

    /// A tag nothing is filed under is refused for the reason an empty heatmap day is: the search
    /// it would run comes back empty, and a control that always does nothing is not a control.
    @Test("a tag nothing is filed under is not a chip")
    func aTagWithNoMemosIsNotAChip() {
        let chips = TagChipsPresentation.chips(for: [tag("travel", 3), tag("stale", 0)])

        #expect(chips.map(\.name) == ["travel"])
        #expect(TagChipsPresentation.query(for: tag("stale", 0)) == nil)
    }

    /// The one that would actually hurt. `MemoQuery` normalises a blank tag away, so a chip for it
    /// would carry the EMPTY query — the plain timeline — and "Show results" would then hand back
    /// every memo the account has as though each one carried the tag.
    @Test("a tag that would search for everything is not a chip")
    func aBlankTagIsNotAChip() {
        for blank in ["", "   ", "\n"] {
            #expect(
                TagChipsPresentation.query(for: tag(blank, 4)) == nil,
                "\(blank.debugDescription)"
            )
        }
        #expect(TagChipsPresentation.chips(for: [tag("  ", 7), tag("travel", 1)]).count == 1)
        // Positive control: a real name with the same count IS a chip, so the refusals above are
        // the names and not the counts.
        #expect(TagChipsPresentation.query(for: tag("travel", 4)) != nil)
    }

    /// What a tap asks the server for: the tag filter, not a text search. The server ANDs one
    /// EXISTS per tag, so the memos that come back are the ones FILED under it rather than the
    /// ones that happen to contain the word.
    @Test("a chip searches for its own tag")
    func aChipSearchesForItsTag() {
        #expect(TagChipsPresentation.query(for: tag("travel", 3)) == MemoQuery(tags: ["travel"]))
        // And for nothing else: no term, no anchor, no archives.
        #expect(TagChipsPresentation.query(for: tag("travel", 3))?.term == nil)
        #expect(TagChipsPresentation.query(for: tag("travel", 3))?.anchor == nil)
    }

    /// The hash is this app's way of saying which kind of word it is; the server stores and
    /// filters on the bare name, and the two must not be confused on the wire.
    @Test("a chip says what it searches for and how much is under it")
    func theLabelsNameTheTagAndTheCount() {
        #expect(TagChipsPresentation.label(for: tag("travel", 3)) == "#travel")
        #expect(
            TagChipsPresentation.accessibilityLabel(for: tag("travel", 3)) == "#travel, 3 memos"
        )
        // One memo is one memo, not "1 memos".
        #expect(TagChipsPresentation.accessibilityLabel(for: tag("food", 1)) == "#food, 1 memo")
    }
}
