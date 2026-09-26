import MemosCore
import Testing

@testable import MemosFeatures

/// The Tags section of the Library's options menu and what the grid says under a tag (MEMNG-513),
/// held as data: which rows the inline Picker draws, which one carries the checkmark, and which
/// empty state sits over a grid a tag has emptied.
@MainActor
@Suite("Library tag menu presentation")
struct MediaLibraryTagMenuTests {
    private let travel = LibraryTag(name: "travel", count: 3)
    private let food = LibraryTag(name: "food", count: 0)

    @Test("All tags comes first, then each tag with its count, and exactly one row is ticked")
    func rowsAndTheCheckmark() {
        let rows = MediaLibraryPresentation.tagRows([travel, food], selected: "travel")

        #expect(rows.map(\.label) == ["All tags", "travel (3)", "food (0)"])
        #expect(rows.map(\.selection) == [nil, "travel", "food"])
        #expect(rows.filter(\.isSelected).map(\.selection) == ["travel"])

        let unfiltered = MediaLibraryPresentation.tagRows([travel, food], selected: nil)
        #expect(unfiltered.filter(\.isSelected).count == 1)
        #expect(unfiltered.first?.isSelected == true, "All tags is not ticked with no tag chosen")
    }

    @Test("no tags from the server leaves only All tags, ticked")
    func zeroTags() {
        let rows = MediaLibraryPresentation.tagRows([], selected: nil)
        #expect(rows.map(\.label) == ["All tags"])
        #expect(rows.first?.isSelected == true)
    }

    @Test("one tag is one row under All tags")
    func oneTag() {
        let rows = MediaLibraryPresentation.tagRows([travel], selected: nil)
        #expect(rows.map(\.label) == ["All tags", "travel (3)"])
    }

    @Test("a tag the server calls All tags is its own row, not the every-tag row")
    func aTagNamedAllTagsIsDistinct() {
        let impostor = LibraryTag(name: "All tags", count: 2)
        let rows = MediaLibraryPresentation.tagRows([impostor], selected: "All tags")

        #expect(rows.count == 2)
        #expect(rows.map(\.selection) == [nil, "All tags"])
        #expect(rows.map(\.label) == ["All tags", "All tags (2)"])
        #expect(rows.filter(\.isSelected).map(\.selection) == ["All tags"])
        #expect(rows.first?.isSelected == false, "the nil row was ticked by a matching label")
    }

    @Test("a chosen tag the list does not name still has a ticked row")
    func aChosenTagOutsideTheListStaysTicked() {
        let rows = MediaLibraryPresentation.tagRows([food], selected: "travel")
        #expect(rows.filter(\.isSelected).map(\.selection) == ["travel"])
        #expect(rows.last?.label == "travel", "a count the list never gave was shown")
    }

    @Test("an emptied grid under a tag shows the tag's empty state, not an error")
    func theTagEmptyState() throws {
        let empty = try #require(
            MediaLibraryPresentation.emptyOverlay(
                itemsEmpty: true, isLoading: false, lastError: nil, filter: .all, tag: "travel"
            )
        )
        #expect(empty.title == "No pictures with this tag")
        #expect(empty.message.contains("travel"), "the message does not name the tag")
        #expect(empty != MediaLibraryPresentation.emptyState(for: .all))

        // Without a tag it is the tab's own sentence, and over an error or a load it is nothing.
        #expect(
            MediaLibraryPresentation.emptyOverlay(
                itemsEmpty: true, isLoading: false, lastError: nil, filter: .videos, tag: nil
            ) == MediaLibraryPresentation.emptyState(for: .videos)
        )
        #expect(
            MediaLibraryPresentation.emptyOverlay(
                itemsEmpty: true, isLoading: false, lastError: "boom", filter: .all, tag: "travel"
            ) == nil
        )
        #expect(
            MediaLibraryPresentation.emptyOverlay(
                itemsEmpty: true, isLoading: true, lastError: nil, filter: .all, tag: "travel"
            ) == nil
        )
        #expect(
            MediaLibraryPresentation.emptyOverlay(
                itemsEmpty: false, isLoading: false, lastError: nil, filter: .all, tag: "travel"
            ) == nil
        )
    }

    @Test("the subtitle is the chosen tag, and nothing without one")
    func subtitle() {
        #expect(MediaLibraryPresentation.subtitle(for: "travel") == "#travel")
        #expect(MediaLibraryPresentation.subtitle(for: nil).isEmpty)
    }
}
