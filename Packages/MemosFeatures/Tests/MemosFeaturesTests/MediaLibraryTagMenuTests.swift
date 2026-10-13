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
}

/// The round filter button's menu as Photos draws it (MEMNG-779, WPN-12 phase 1): the kinds under
/// a "Filter" heading, a divider, and a nested "Sort By" menu whose label says the order in force.
/// Hosted under a list, which draws an inline Picker's rows the way the menu does — every row, the
/// chosen one marked selected — and a nested menu as the one row that opens it, without a menu
/// that has to be opened by touch.
@MainActor
@Suite("Library filter menu render")
struct LibraryFilterMenuRenderTests {
    private struct FilterHarness: View {
        @State var filter: MediaLibraryFilter
        @State var order: MediaLibraryOrder

        var body: some View {
            List {
                LibraryFilterMenuContent(filter: $filter, order: $order)
            }
        }
    }

    /// The order a list row of the Sort By menu reads from: the store's, as the screen binds it.
    /// The Sort By menu's label on its own: a list draws its two lines as two rows, so what the
    /// label SHOWS is read, not what the menu tells VoiceOver.
    private struct SortLabelHarness: View {
        let store: MediaLibraryStore

        var body: some View {
            List {
                SortByMenuLabel(order: store.order)
            }
        }
    }

    private struct SortHarness: View {
        let store: MediaLibraryStore

        var body: some View {
            let order = Binding(get: { store.order }, set: { store.setOrder($0) })
            List {
                SortByMenu(order: order)
                SortByMenuContent(order: order)
            }
        }
    }

    /// One element the hosted hierarchy reads out: its label and value, whether it is marked
    /// selected, and where it stands.
    private struct Row {
        let label: String
        let value: String
        let selected: Bool
        let frame: CGRect
    }

    /// Every labelled element the hosted hierarchy reads out, each label once (its first
    /// appearance), top to bottom as drawn: a list's section heading is a view the walk reaches
    /// after the rows under it, so the walk's own order is not the order on screen.
    private static func rows(in window: UIWindow) -> [Row] {
        var found: [Row] = []
        var seen: Set<String> = []
        func walk(_ node: Any) {
            guard let object = node as? NSObject else { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if let label = object.accessibilityLabel, !label.isEmpty, seen.insert(label).inserted {
                found.append(
                    Row(
                        label: label,
                        value: object.accessibilityValue ?? "",
                        selected: object.accessibilityTraits.contains(.selected),
                        frame: object.accessibilityFrame))
            }
            for child in object.accessibilityElements ?? [] { walk(child) }
            if let view = object as? UIView {
                for subview in view.subviews { walk(subview) }
            }
        }
        walk(window)
        return found.enumerated().sorted {
            ($0.element.frame.minY, $0.offset) < ($1.element.frame.minY, $1.offset)
        }.map(\.element)
    }

    private static func host(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    private static func settle(_ window: UIWindow, until ready: ([Row]) -> Bool) async -> [Row] {
        var found: [Row] = []
        for _ in 0..<80 {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
            found = rows(in: window)
            if ready(found) { break }
        }
        return found
    }

    /// The nested menu's row reads "Sort By" and then the order in force.
    private static func isSortBy(_ label: String) -> Bool { label.hasPrefix("Sort By") }

    @Test("the filter menu lists Filter, its three kinds, a divider and Sort By, nothing else")
    func filterMenuRows() async {
        let window = Self.host(FilterHarness(filter: .all, order: .newestFirst))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let found = await Self.settle(window) { rows in
            rows.contains { Self.isSortBy($0.label) } && rows.contains { $0.label == "Videos" }
        }

        // Exactly these, in this order: no tag row, no "Clear media cache", no second sort group.
        let drawn = found.map { Self.isSortBy($0.label) ? "Sort By" : $0.label }
        #expect(
            drawn == ["Filter", "All Items", "Photos", "Videos", "Sort By"],
            "the menu draws \(found.map(\.label))")
        let ticked = found.filter(\.selected).map(\.label)
        #expect(ticked == ["All Items"], "ticked: \(ticked)")

        // A kind other than the default ticks its own row and no other: a picker that drew its
        // tick on All Items whatever the kind would pass the case above.
        let kinds: [(MediaLibraryFilter, String)] = [(.videos, "Videos"), (.images, "Photos")]
        for (kind, row) in kinds {
            let other = Self.host(FilterHarness(filter: kind, order: .oldestFirst))
            let under = await Self.settle(other) { rows in
                rows.contains { $0.selected && $0.label == row }
            }
            let chosen = under.filter(\.selected).map(\.label)
            other.isHidden = true
            other.rootViewController = nil
            #expect(chosen == [row], "under \(kind) the menu ticks \(chosen)")
        }

        // The divider between the kinds and Sort By: a list draws a Divider as nothing it reads
        // out, so it is read from the menu's own body — the picker, the Divider, then the nested
        // menu, in that order and nothing between.
        let content = LibraryFilterMenuContent(
            filter: .constant(.all), order: .constant(.newestFirst))
        let parts =
            Mirror(reflecting: content.body).descendant("value").map { tuple in
                Mirror(reflecting: tuple).children.map { "\(type(of: $0.value))" }
            } ?? []
        #expect(parts.count == 3, "the menu's body is \(type(of: content.body))")
        #expect(parts.count == 3 && parts[1] == "Divider", "no divider second: \(parts)")
        #expect(parts.last == "SortByMenu", "the nested menu is not last: \(parts)")
    }

    @Test("Sort By ticks the store's order and its label says it, as the order changes")
    func sortByFollowsTheStore() async {
        let store = MediaLibraryStore(order: .newestFirst)
        let window = Self.host(SortHarness(store: store))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let options = ["Oldest First", "Newest First"]
        // What VoiceOver reads for the nested menu's row: its label, then its value.
        func label(_ rows: [Row]) -> String {
            rows.first { Self.isSortBy($0.label) }.map { "\($0.label), \($0.value)" } ?? "none"
        }

        var found = await Self.settle(window) { rows in
            rows.contains { Self.isSortBy($0.label) }
                && rows.contains { $0.label == "Oldest First" }
        }
        #expect(
            found.map(\.label).filter(options.contains) == options,
            "the submenu's rows: \(found.map(\.label))")
        #expect(
            found.filter { $0.selected && options.contains($0.label) }.map(\.label)
                == ["Newest First"], "ticked under Newest First: \(found.map(\.label))")
        #expect(label(found).contains("Newest First"), "the label reads \(label(found))")

        // What the label SHOWS: "Sort By", and under it the order in force.
        let shown = Self.host(SortLabelHarness(store: store))
        defer {
            shown.isHidden = true
            shown.rootViewController = nil
        }
        var lines = await Self.settle(shown) { $0.contains { $0.label == "Newest First" } }
        #expect(
            lines.map(\.label) == ["Sort By", "Newest First"],
            "the label shows \(lines.map(\.label))")

        store.setOrder(.oldestFirst)
        found = await Self.settle(window) { rows in
            label(rows).contains("Oldest First")
                && rows.contains { $0.selected && $0.label == "Oldest First" }
        }
        #expect(
            found.filter { $0.selected && options.contains($0.label) }.map(\.label)
                == ["Oldest First"], "ticked under Oldest First: \(found.map(\.label))")
        #expect(label(found).contains("Oldest First"), "the label reads \(label(found))")
        #expect(!label(found).contains("Newest First"), "the label kept the old order")
        lines = await Self.settle(shown) { $0.contains { $0.label == "Oldest First" } }
        #expect(
            lines.map(\.label) == ["Sort By", "Oldest First"],
            "the label shows \(lines.map(\.label)) under Oldest First")
    }
}
