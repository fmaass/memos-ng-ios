import MemosCore
import SwiftUI
import Testing
import UIKit

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

    /// Plan page 3929 decisions 10 and 12: kind, order and the chosen tag, joined as the web
    /// header joins them — every kind, both orders, with and without a tag.
    @Test("the subtitle names the kind, the order and the chosen tag")
    func subtitle() {
        let cases: [(MediaLibraryFilter, MediaLibraryOrder, String?, String)] = [
            (.all, .newestFirst, nil, "All Items · Newest First"),
            (.all, .oldestFirst, nil, "All Items · Oldest First"),
            (.images, .newestFirst, nil, "Photos · Newest First"),
            (.images, .oldestFirst, nil, "Photos · Oldest First"),
            (.videos, .newestFirst, nil, "Videos · Newest First"),
            (.videos, .oldestFirst, nil, "Videos · Oldest First"),
            (.all, .newestFirst, "recap", "All Items · Newest First · #recap"),
            (.all, .oldestFirst, "recap", "All Items · Oldest First · #recap"),
            (.images, .newestFirst, "travel", "Photos · Newest First · #travel"),
            (.images, .oldestFirst, "travel", "Photos · Oldest First · #travel"),
            (.videos, .newestFirst, "food", "Videos · Newest First · #food"),
            (.videos, .oldestFirst, "food", "Videos · Oldest First · #food"),
        ]
        for (filter, order, tag, expected) in cases {
            let line = MediaLibraryPresentation.subtitle(filter: filter, order: order, tag: tag)
            #expect(line == expected, "\(filter) \(order) \(tag ?? "no tag")")
        }
    }

    @Test("the sort rows say what they sort by")
    func sortRowLabels() {
        #expect(
            MediaLibraryOrder.allCases.map(MediaLibraryPresentation.sortLabel(for:))
                == ["Sort by Newest First", "Sort by Oldest First"]
        )
    }
}

/// The options menu's rows as the inline Pickers draw them (plan page 3929 decisions 5, 10 and
/// 12): hosted in a window under a list, which draws an inline Picker's rows the way the menu does
/// — every row, the chosen one marked selected — without a menu that has to be opened by touch.
@MainActor
@Suite("Library options menu render")
struct LibraryOptionsMenuRenderTests {
    private struct Harness: View {
        @State var order: MediaLibraryOrder
        @State var filter: MediaLibraryFilter
        @State var tag: String?
        let tags: [LibraryTag]

        var body: some View {
            List {
                LibraryOptionsMenuContent(
                    order: $order,
                    filter: $filter,
                    tag: $tag,
                    tagRows: MediaLibraryPresentation.tagRows(tags, selected: tag)
                )
            }
        }
    }

    /// Every element the hosted hierarchy reads out, in reading order, with whether it is marked
    /// selected.
    private static func rows(in node: Any, into found: inout [(String, Bool)]) {
        guard let object = node as? NSObject else { return }
        if let label = object.accessibilityLabel, !label.isEmpty {
            found.append((label, object.accessibilityTraits.contains(.selected)))
        }
        for child in object.accessibilityElements ?? [] { rows(in: child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { rows(in: subview, into: &found) }
        }
    }

    @Test("three groups in order, each with its chosen row ticked, under a non-default choice")
    func threeGroupsAndTheirTicks() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(
            rootView: Harness(
                order: .oldestFirst,
                filter: .videos,
                tag: "travel",
                tags: [LibraryTag(name: "travel", count: 3), LibraryTag(name: "food", count: 1)]
            )
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let expected = [
            "Sort by Newest First", "Sort by Oldest First",
            "All Items", "Photos", "Videos",
            "All tags", "travel (3)", "food (1)",
        ]
        var found: [(String, Bool)] = []
        for _ in 0..<80 {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
            found = []
            Self.rows(in: window, into: &found)
            if Set(expected).isSubset(of: found.map(\.0)) { break }
        }

        // First appearance of each row, so the order read is the order drawn.
        var seen: Set<String> = []
        let drawn = found.filter { expected.contains($0.0) && seen.insert($0.0).inserted }
        #expect(drawn.map(\.0) == expected, "the menu draws \(found.map(\.0))")
        let ticked = Set(found.filter { $0.1 && expected.contains($0.0) }.map(\.0))
        #expect(
            ticked == ["Sort by Oldest First", "Videos", "travel (3)"],
            "ticked: \(ticked)"
        )
    }
}
