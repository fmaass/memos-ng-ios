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
        @State var mine = false
        @State var visibility = MediaVisibilityFilter.any
        @State var groupByDay = true
        @State var tileLayout = LibraryTileLayout.mixed

        var body: some View {
            List {
                LibraryFilterMenuContent(
                    filter: $filter, mine: $mine, visibility: $visibility, order: $order,
                    groupByDay: $groupByDay, tileLayout: $tileLayout)
            }
        }
    }

    /// The View Options menu's row and, under it, its one item, bound to the device's preference
    /// as the screen binds it (MEMNG-818).
    private struct ViewOptionsHarness: View {
        let preferences: LibraryPreferences

        var body: some View {
            let grouped = Binding(
                get: { preferences.groupByDay },
                set: { preferences.select(groupByDay: $0) })
            let tiles = Binding(
                get: { preferences.tileLayout },
                set: { preferences.select(tileLayout: $0) })
            List {
                ViewOptionsMenu(groupByDay: grouped, tileLayout: tiles)
                ViewOptionsMenuContent(groupByDay: grouped, tileLayout: tiles)
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

    @Test(
        "the filter menu: Filter, kinds, Captured by me, Visibility, Sort By, View Options"
    )
    func filterMenuRows() async {
        let window = Self.host(FilterHarness(filter: .all, order: .newestFirst))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let found = await Self.settle(window) { rows in
            rows.contains { Self.isSortBy($0.label) } && rows.contains { $0.label == "Videos" }
                && rows.contains { $0.label == "View Options" }
        }

        // Exactly these, in this order: no tag row, no "Clear media cache", no second sort group,
        // and View Options last (MEMNG-818).
        // "Captured by me" and Visibility (MEMNG-787) sit between the kinds and Sort By.
        let drawn = found.map {
            Self.isSortBy($0.label)
                ? "Sort By" : $0.label.hasPrefix("Visibility") ? "Visibility" : $0.label
        }
        #expect(
            drawn == [
                "Filter", "All Items", "Photos", "Videos", "Captured by me", "Visibility",
                "Sort By", "View Options",
            ],
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
        // out, so it is read from the menu's own body — the picker, the Divider, the nested Sort
        // By menu, then the nested View Options menu, in that order and nothing between.
        let content = LibraryFilterMenuContent(
            filter: .constant(.all), mine: .constant(false), visibility: .constant(.any),
            order: .constant(.newestFirst), groupByDay: .constant(true),
            tileLayout: .constant(.mixed))
        let parts =
            Mirror(reflecting: content.body).descendant("value").map { tuple in
                Mirror(reflecting: tuple).children.map { "\(type(of: $0.value))" }
            } ?? []
        #expect(parts.count == 4, "the menu's body is \(type(of: content.body))")
        #expect(parts.count == 4 && parts[1] == "Divider", "no divider second: \(parts)")
        #expect(parts.count == 4 && parts[2] == "SortByMenu", "Sort By is not third: \(parts)")
        #expect(parts.last == "ViewOptionsMenu", "View Options is not last: \(parts)")
        #expect(parts.first == "MediaFilterRows", "the shared rows are not first: \(parts)")

        // The shared rows (MEMNG-787): the kinds' Picker, the "Captured by me" Toggle, then the
        // nested Visibility menu, one copy for the Library and the trip alike.
        let shared = MediaFilterRows(
            filter: .constant(.all), mine: .constant(false), visibility: .constant(.any))
        let rows =
            Mirror(reflecting: shared.body).descendant("value").map { tuple in
                Mirror(reflecting: tuple).children.map { "\(type(of: $0.value))" }
            } ?? []
        #expect(rows.count == 3, "the shared rows are \(type(of: shared.body))")
        #expect(rows.first?.hasPrefix("Picker") == true, "no kind picker first: \(rows)")
        #expect(rows.count == 3 && rows[1].hasPrefix("Toggle"), "no toggle second: \(rows)")
        #expect(rows.last == "LibraryVisibilityMenu", "no Visibility menu last: \(rows)")

        // View Options' own two groups (MEMNG-821): the toggle, a divider, then the layout pair.
        let options = ViewOptionsMenuContent(
            groupByDay: .constant(true), tileLayout: .constant(.mixed))
        let groups =
            Mirror(reflecting: options.body).descendant("value").map { tuple in
                Mirror(reflecting: tuple).children.map { "\(type(of: $0.value))" }
            } ?? []
        #expect(groups.count == 3, "View Options' body is \(type(of: options.body))")
        #expect(groups.first?.hasPrefix("Toggle") == true, "no toggle first: \(groups)")
        #expect(groups.count == 3 && groups[1] == "Divider", "no divider second: \(groups)")
    }

    /// MEMNG-818: the one item under View Options turns Group by Day off and on again, and what it
    /// turns is the device's stored choice, not a copy of it.
    @Test("View Options holds Group by Day and the layout pair, each moving the stored value")
    func groupByDayItemTogglesTheStoredValue() async throws {
        let name = "memosng.library.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let preferences = LibraryPreferences(defaults: defaults)
        let window = Self.host(ViewOptionsHarness(preferences: preferences))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let found = await Self.settle(window) { rows in
            rows.contains { $0.label == "View Options" }
                && rows.contains { $0.label == "Group by Day" }
                && rows.contains { $0.label == "Square Grid" }
        }
        #expect(
            found.map(\.label) == ["View Options", "Group by Day", "Mixed Sizes", "Square Grid"],
            "View Options draws \(found.map(\.label))")
        let pair: Set = ["Mixed Sizes", "Square Grid"]
        let ticked = found.filter { $0.selected && pair.contains($0.label) }.map(\.label)
        #expect(ticked == ["Mixed Sizes"], "ticked with nothing chosen: \(ticked)")
        let before = found.first { $0.label == "Group by Day" }?.value

        #expect(Self.activate("Group by Day", in: window), "the item took no press")
        #expect(!preferences.groupByDay, "the press left Group by Day on")
        #expect(defaults.object(forKey: LibraryPreferences.groupByDayKey) as? Bool == false)
        // The item reflects what is stored: its value moved with the press.
        let off = await Self.settle(window) { rows in
            rows.contains { $0.label == "Group by Day" && $0.value != before }
        }
        #expect(
            off.first { $0.label == "Group by Day" }?.value != before,
            "the item still reads \(String(describing: before)) with the choice off")

        #expect(Self.activate("Group by Day", in: window), "the item took no second press")
        #expect(preferences.groupByDay, "the second press left Group by Day off")
        #expect(LibraryPreferences(defaults: defaults).groupByDay, "the store kept it off")

        // The second group: Square Grid chosen is stored, and ticked in Mixed Sizes' place.
        #expect(Self.activate("Square Grid", in: window), "Square Grid took no press")
        #expect(preferences.tileLayout == .square, "the press left Mixed Sizes chosen")
        #expect(defaults.string(forKey: LibraryPreferences.tileLayoutKey) == "square")
        let square = await Self.settle(window) { rows in
            rows.contains { $0.selected && $0.label == "Square Grid" }
        }
        let now = square.filter { $0.selected && pair.contains($0.label) }.map(\.label)
        #expect(now == ["Square Grid"], "ticked under Square Grid: \(now)")
        #expect(preferences.groupByDay, "choosing a layout moved Group by Day")
    }

    /// Presses the switch reading `label` as VoiceOver would, or — when the hosted list's element
    /// took no activation — flips its `UISwitch` and sends the event a tap sends.
    private static func activate(_ label: String, in window: UIWindow) -> Bool {
        var stack: [Any] = [window]
        var target: NSObject?
        var control: UISwitch?
        while let node = stack.popLast() {
            guard let object = node as? NSObject else { continue }
            if target == nil, object.accessibilityLabel == label { target = object }
            if control == nil, let flip = object as? UISwitch { control = flip }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        if target?.accessibilityActivate() == true { return true }
        guard let control else { return false }
        control.setOn(!control.isOn, animated: false)
        control.sendActions(for: .valueChanged)
        return true
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

// MARK: - Captured by me and Visibility (MEMNG-787)

extension LibraryFilterMenuRenderTests {
    /// Any, Public, Just us — the memo visibilities' own words where one exists, and never
    /// Private, which nobody else can see and so is no filter of a shared library.
    @Test("Visibility offers Any, Public and Just us in the app's own words, and no Private")
    func visibilityRows() {
        let labels = MediaVisibilityFilter.allCases.map(\.label)
        #expect(labels == ["Any", "Public", "Just us"], "\(labels)")
        #expect(MediaVisibilityFilter.public.label == MemoVisibility.public.label)
        #expect(MediaVisibilityFilter.justUs.label == MemoVisibility.protected.label)
        #expect(MediaVisibilityFilter.allCases.compactMap(\.visibility) == [.public, .protected])
        #expect(MediaFilterRows.capturedByMe == "Captured by me")
        #expect(MediaFilterRows.capturedByMeSymbol == "person.crop.circle")
    }
}
