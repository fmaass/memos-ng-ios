import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// View Options → Group by Day (MEMNG-818), hosted: the grid the Library builds from the device's
/// choice, re-laid in place when the choice moves, keeping the picture the reader was looking at.
///
/// Every grid here takes its grouping from a `LibraryPreferences` over a scratch suite, as the
/// screen takes it from the shared one, so what is asserted is the stored choice's effect.
@MainActor
@Suite("Library view options")
struct LibraryViewOptionsTests {
    /// The All grid as the screen builds it: its grouping read from the device's choice.
    private struct Harness: View {
        let items: [LibraryRow]
        let preferences: LibraryPreferences
        var landing: LibraryLanding?
        var landed: (LibraryLanding) -> Void = { _ in }
        var selection = LibrarySelection()
        var wantsMore: (Int) -> Bool = { _ in false }
        var loadMore: () -> Void = {}
        @Namespace private var zoom

        var body: some View {
            LibraryGrid(
                items: selection.visible(in: items),
                errorText: nil,
                loadingMore: false,
                zoom: zoom,
                wantsMore: wantsMore,
                open: { _ in },
                fetch: { _, _ in },
                loadMore: { loadMore() },
                landing: landing,
                landed: landed,
                selection: selection,
                grouping: preferences.allGrouping,
                preferences: preferences
            )
        }
    }

    /// The same grid over a list a test can lengthen, as the store's next page lengthens it.
    private struct FeedHarness: View {
        let feed: PageFeed
        let preferences: LibraryPreferences
        var landing: LibraryLanding?
        var landed: (LibraryLanding) -> Void = { _ in }

        var body: some View {
            Harness(
                items: feed.items, preferences: preferences, landing: landing, landed: landed)
        }
    }

    /// A device's choice over a suite of its own, taken down when the case ends.
    @MainActor
    private final class ScratchPreferences {
        let name = "memosng.library.tests.\(UUID().uuidString)"
        let preferences: LibraryPreferences

        init(groupByDay: Bool, tiles: LibraryTileLayout = .mixed) throws {
            let defaults = try #require(UserDefaults(suiteName: name))
            preferences = LibraryPreferences(defaults: defaults)
            preferences.select(groupByDay: groupByDay)
            preferences.select(tileLayout: tiles)
        }

        deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    /// `days` days of square pictures, newest first, one day apart from 2026-09-14 back, each day
    /// holding the count the cycle gives it — so a day's bands and the flat grid's bands fall
    /// differently, and a picture opening a band in one layout sits inside a band of the other.
    private static func library(days: Int, cycle: [Int] = [2, 4, 5, 3, 7]) -> [LibraryRow] {
        (0..<days).flatMap { day in
            (0..<cycle[day % cycle.count]).map { row("d\(day)-\($0)", day: day) }
        }
    }

    /// One square picture taken `day` days before 2026-09-14.
    private static func row(_ uid: String, day: Int) -> LibraryRow {
        LibraryRow(
            attachment: MediaViewerPageTests.image(uid, width: 1000, height: 1000),
            takenAt: Date(timeIntervalSince1970: 1_789_387_200 - Double(day) * 86_400),
            mine: true, filename: uid)
    }

    /// The page after `library(days: days)`: one more picture of its last day, then as many older
    /// days again — what the store appends, the list's generation unchanged.
    private static func page(after days: Int) -> [LibraryRow] {
        [row("d\(days - 1)-9", day: days - 1)]
            + library(days: 2 * days).dropFirst(library(days: days).count)
    }

    /// A file that opens a band of `from` (so a switch keeps it) and whose band in `to` the page
    /// takes away: two wide frames of a two-picture day become a hero and its sides once a third
    /// arrives, and a band is named by its first file.
    private static func reCutByPage(
        from: LibraryGridCut, to: LibraryGridCut, before: [LibraryRow], after: [LibraryRow]
    ) -> String? {
        let opensFrom = Set(bands(from, before).compactMap(\.first))
        let opensAfter = Set(bands(to, after).compactMap(\.first))
        let bandBefore = bands(to, before)
        return before.map(\.id).last { file in
            guard opensFrom.contains(file),
                let band = bandBefore.first(where: { $0.contains(file) })?.first
            else { return false }
            return !opensAfter.contains(band)
        }
    }

    /// The bands a cut makes of `items`, each as its files in order.
    private static func bands(_ cut: LibraryGridCut, _ items: [LibraryRow]) -> [[String]] {
        let rows: [LibraryAllRow]
        switch cut.grouping {
        case .byDay:
            rows = MediaLibraryPresentation.daySections(for: items, tiles: cut.tiles)
                .flatMap(\.rows)
        case .flat: rows = MediaLibraryPresentation.flatRows(for: items, tiles: cut.tiles)
        }
        return rows.compactMap { row in
            guard case .band(let band, _) = row else { return nil }
            return band.pictures.map(\.id)
        }
    }

    /// A file deeper than `index` that opens a band in `from` and is the SECOND or THIRD tile of a
    /// band in `to`: a band's identity is its first file, so a restore that found the band by the
    /// recorded file's own id, or that only checked a band exists, cannot pass on it.
    private static func anchor(
        from: LibraryGridCut, to: LibraryGridCut, in items: [LibraryRow],
        deeperThan index: Int
    ) -> String? {
        let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        let inside = Set(bands(to, items).flatMap { $0.dropFirst() })
        // Far enough from the end that a landing on it is not at the scroll's end.
        let tail = items.count - 40
        return bands(from, items).compactMap(\.first).first { id in
            let place = order[id] ?? 0
            return place > index && place < tail && inside.contains(id)
        }
    }

    /// Every label a day heading or a month header of `items` would read.
    private static func headingLabels(_ items: [LibraryRow]) -> Set<String> {
        var labels: Set<String> = []
        for month in MediaLibraryPresentation.daySections(for: items) {
            labels.insert(month.label)
            for day in month.days {
                labels.insert(day.date.isEmpty ? day.weekday : "\(day.weekday) \(day.date)")
            }
        }
        return labels
    }

    // MARK: - Group by Day off

    @Test("All with Group by Day off draws no heading and the grouped layout's rows in its order")
    func flatAllHasNoHeadingsAndTheGroupedOrder() async throws {
        let items = Self.library(days: 4)
        let wanted = Self.headingLabels(items)
        let flat = try ScratchPreferences(groupByDay: false)
        let grouped = try ScratchPreferences(groupByDay: true)
        let window = Self.show(Harness(items: items, preferences: flat.preferences), height: 3000)
        let control = Self.show(
            Harness(items: items, preferences: grouped.preferences), height: 3000)
        defer {
            window.isHidden = true
            control.isHidden = true
        }

        var drawn: Set<String> = []
        var groupedHeadings: [String] = []
        for _ in 0..<80 where drawn.count < items.count || groupedHeadings.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            control.layoutIfNeeded()
            drawn = Set(Self.tileFrames(in: window).keys)
            groupedHeadings = Self.labels(in: control).filter(wanted.contains)
        }
        #expect(!groupedHeadings.isEmpty, "control: the grouped grid drew no heading")
        #expect(
            drawn == Set(items.map(\.id)), "the flat grid drew \(drawn.count) of \(items.count)")
        let headings = Self.labels(in: window).filter(wanted.contains)
        #expect(headings.isEmpty, "Group by Day off still drew \(headings)")

        // The two row sequences over the one list: the grouped layout flattened, and the flat one.
        // Every picture keeps the index the paging trigger is measured in.
        let byDay = MediaLibraryPresentation.daySections(for: items).flatMap(\.rows)
            .flatMap(Self.pictures)
        let oneBlock = MediaLibraryPresentation.flatRows(for: items).flatMap(Self.pictures)
        #expect(oneBlock.map(\.id) == byDay.map(\.id))
        #expect(oneBlock.map(\.index) == byDay.map(\.index))
        #expect(oneBlock.map(\.id) == items.map(\.id), "the flat grid re-ordered the list")
    }

    // MARK: - The toggle keeps its picture

    /// One move of View Options: Group by Day either way (MEMNG-818), the layout either way
    /// (MEMNG-821).
    enum Switch: String, CaseIterable, Sendable {
        case groupOff, groupOn, toSquare, toMixed

        var from: LibraryGridCut {
            switch self {
            case .groupOff, .toSquare: LibraryGridCut(grouping: .byDay, tiles: .mixed)
            case .groupOn: LibraryGridCut(grouping: .flat, tiles: .mixed)
            case .toMixed: LibraryGridCut(grouping: .byDay, tiles: .square)
            }
        }

        var to: LibraryGridCut {
            switch self {
            case .groupOff: LibraryGridCut(grouping: .flat, tiles: .mixed)
            case .groupOn, .toMixed: LibraryGridCut(grouping: .byDay, tiles: .mixed)
            case .toSquare: LibraryGridCut(grouping: .byDay, tiles: .square)
            }
        }
    }

    @Test(
        "a View Options switch deep in the grid keeps the picture at the top in view",
        arguments: Switch.allCases)
    func toggleKeepsTheAnchorVisible(move: Switch) async throws {
        let items = Self.library(days: 30)
        let target = try #require(
            Self.anchor(from: move.from, to: move.to, in: items, deeperThan: 60),
            "fixture: no deep file opens a band of \(move.from) inside one of \(move.to)")
        let scratch = try ScratchPreferences(
            groupByDay: move.from.grouping == .byDay, tiles: move.from.tiles)
        let window = Self.show(Harness(items: items, preferences: scratch.preferences))
        defer { window.isHidden = true }

        let placed = try await Self.place(target, in: window)
        try #require(placed, "control: \(target) never came to rest at the top of the screen")

        scratch.preferences.select(groupByDay: move.to.grouping == .byDay)
        scratch.preferences.select(tileLayout: move.to.tiles)
        var seen: [CGFloat?] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            seen.append(Self.isVisible(target, in: window) ? Self.offset(target, in: window) : nil)
        }
        // In view after the layout passes, and its band at the line: a picture that only drifted
        // less than a screen is not one that was kept.
        let kept = seen.suffix(15).allSatisfy { $0.map { (-2...300).contains($0) } == true }
        #expect(kept, "\(target) was not kept at the top after \(move) (offsets \(seen))")
        // No page count is asserted here: while the new cut is measured, the lazy stack may build
        // tiles near the end, whose ordinary paging trigger then asks for the next page — an
        // append the store serialises, not a reload. The grid has no way to reload; the menu
        // binding writes the preference and nothing else.
    }

    // MARK: - Square Grid

    @Test("Square Grid makes every frame a square, in rows of three, the same pictures in order")
    func squareGridIsRowsOfThree() {
        let items = Self.library(days: 6)
        for grouping in [LibraryGridGrouping.byDay, .flat] {
            let mixed = LibraryGridCut(grouping: grouping, tiles: .mixed)
            let square = LibraryGridCut(grouping: grouping, tiles: .square)
            let rows: [LibraryAllRow] =
                switch grouping {
                case .byDay:
                    MediaLibraryPresentation.daySections(for: items, tiles: .square)
                        .flatMap(\.rows)
                case .flat: MediaLibraryPresentation.flatRows(for: items, tiles: .square)
                }
            let pictures = rows.flatMap(Self.pictures)
            #expect(pictures.allSatisfy { $0.slot == .square }, "\(grouping): a frame not square")
            // Rows of three, the last of a block holding what is left.
            let sizes = Self.bands(square, items).map(\.count)
            #expect(sizes.allSatisfy { (1...3).contains($0) }, "\(grouping): bands \(sizes)")
            #expect(sizes.filter { $0 == 3 }.count >= sizes.count / 2, "\(grouping): \(sizes)")
            // The control: Mixed Sizes is not squares only.
            let mixedRows = Self.bands(mixed, items)
            #expect(mixedRows.map(\.count) != sizes, "control: \(grouping) mixed cut alike")
            #expect(
                Self.bands(square, items).flatMap { $0 } == mixedRows.flatMap { $0 },
                "\(grouping): the square grid holds other pictures or another order")
            #expect(pictures.map(\.index) == Array(0..<items.count), "\(grouping): indices")
        }
    }

    /// At the top of the page there is nothing above to keep: turning Group by Day on there shows
    /// the first month's header and day heading, rather than scrolling the first picture's band
    /// up over them.
    @Test("a toggle at the top of the page leaves it at the top")
    func toggleAtTheTopStaysAtTheTop() async throws {
        let items = Self.library(days: 30)
        let first = try #require(MediaLibraryPresentation.daySections(for: items).first)
        let scratch = try ScratchPreferences(groupByDay: false)
        let window = Self.show(Harness(items: items, preferences: scratch.preferences))
        defer { window.isHidden = true }
        var built = false
        for _ in 0..<60 where !built {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            built = !Self.tiles(in: window).isEmpty
        }
        try #require(built, "control: the flat grid drew no tile")

        scratch.preferences.select(groupByDay: true)
        var tops: [Bool] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            guard let visible = Self.visibleTop(in: window) else { continue }
            let atTop = visible.scroll.contentOffset.y + visible.scroll.adjustedContentInset.top
            let header = Self.labels(in: window).contains(first.label)
            tops.append(abs(atTop) <= 1 && header)
        }
        #expect(
            tops.suffix(10).count == 10 && tops.suffix(10).allSatisfy { $0 },
            "the page left its top, or \(first.label) is not drawn, after the toggle (\(tops))")
    }

    // MARK: - A Months landing while flat

    @Test("a Months→All landing while flat lands on the file's tile, once, asking no page")
    func monthsLandingWhileFlatLandsOnTheTile() async throws {
        let items = Self.library(days: 30)
        let target = try #require(
            Self.anchor(
                from: LibraryGridCut(grouping: .byDay, tiles: .mixed),
                to: LibraryGridCut(grouping: .flat, tiles: .mixed), in: items, deeperThan: 60),
            "fixture: no deep file sits inside a flat band")
        let day = try #require(
            MediaLibraryPresentation.daySections(for: items).flatMap(\.days)
                .first { $0.pictures.contains { $0.id == target } }?.key)
        let landing = LibraryLanding(day: day, rowID: target, serial: 1)
        let consumed = LandingLog()
        let scratch = try ScratchPreferences(groupByDay: false)
        let last = items.count - 1
        let window = Self.show(
            Harness(
                items: items, preferences: scratch.preferences, landing: landing,
                landed: { consumed.landings.append($0) },
                wantsMore: { $0 == last },
                loadMore: { consumed.pages += 1 }))
        defer { window.isHidden = true }

        var reached = false
        var settled = 0
        for _ in 0..<100 where settled < 8 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            reached = Self.isVisible(target, in: window)
            if reached, !consumed.landings.isEmpty { settled += 1 }
        }
        #expect(reached, "the landing never brought \(target)'s tile into view")
        #expect(consumed.landings == [landing], "the landing was not consumed exactly once")
        // The paging is the store's: a landing moves the scroll, never asks for a page.
        #expect(consumed.pages == 0, "the landing asked for \(consumed.pages) page(s)")
    }

    // MARK: - A page after the hold

    @Test("a page arriving after a switch keeps the picture in view, in the band the page made")
    func pageAfterSwitchKeepsTheAnchor() async throws {
        let before = Self.library(days: 6)
        let after = before + Self.page(after: 6)
        let from = LibraryGridCut(grouping: .flat, tiles: .mixed)
        let to = LibraryGridCut(grouping: .byDay, tiles: .mixed)
        let target = try #require(
            Self.reCutByPage(from: from, to: to, before: before, after: after),
            "fixture: no file keeps a band of \(to) the page leaves standing")
        let opener = try #require(Self.bands(to, after).first { $0.contains(target) }?.first)
        try #require(opener != target, "fixture: the page left \(target) opening its band")
        let feed = PageFeed(before)
        let scratch = try ScratchPreferences(groupByDay: false)
        // A short screen, so the last loaded band can rise to the line before the page comes.
        let window = Self.show(
            FeedHarness(feed: feed, preferences: scratch.preferences), height: 200)
        defer { window.isHidden = true }

        let placed = try await Self.place(target, in: window)
        try #require(placed, "control: \(target) never came to rest at the top of the screen")
        scratch.preferences.select(groupByDay: true)
        var switched: [Bool] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            switched.append(Self.isVisible(target, in: window))
        }
        try #require(switched.suffix(10).allSatisfy { $0 }, "control: the switch lost \(target)")

        // The held page released: the list grows, its generation stays.
        feed.items = after
        var seen: [CGFloat?] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            seen.append(Self.isVisible(target, in: window) ? Self.offset(opener, in: window) : nil)
        }
        // The picture in view and the band the page made for it at the line.
        let kept = seen.suffix(15).allSatisfy { $0.map { (-2...20).contains($0) } == true }
        #expect(kept, "\(target) in \(opener)'s band was not kept after the page (\(seen))")
    }

    /// A flat block's bands are named by files the page never takes away — patterns are placed
    /// whole and the leftover starts where the next pattern would — so this case guards the flat
    /// landing's hold through a page rather than reproducing the re-cut the switch case does.
    @Test("a page arriving after a flat landing keeps the file's band at the line")
    func pageAfterFlatLandingKeepsTheFile() async throws {
        let before = Self.library(days: 6)
        let after = before + Self.page(after: 6)
        let flat = LibraryGridCut(grouping: .flat, tiles: .mixed)
        let opens = Set(Self.bands(flat, after).compactMap(\.first))
        #expect(
            Self.bands(flat, before).compactMap(\.first).allSatisfy { opens.contains($0) },
            "a page took a flat band's opener away")
        let band = try #require(Self.bands(flat, before).last { $0.count > 1 })
        let target = band[1]
        let day = try #require(
            MediaLibraryPresentation.daySections(for: before).flatMap(\.days)
                .first { $0.pictures.contains { $0.id == target } }?.key)
        let landing = LibraryLanding(day: day, rowID: target, serial: 1)
        let consumed = LandingLog()
        let feed = PageFeed(before)
        let scratch = try ScratchPreferences(groupByDay: false)
        let window = Self.show(
            FeedHarness(
                feed: feed, preferences: scratch.preferences, landing: landing,
                landed: { consumed.landings.append($0) }),
            height: 200)
        defer { window.isHidden = true }

        var settled = 0
        for _ in 0..<100 where settled < 8 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            if Self.isVisible(target, in: window), !consumed.landings.isEmpty { settled += 1 }
        }
        try #require(settled >= 8, "control: the landing never settled on \(target)")

        feed.items = after
        var seen: [CGFloat?] = []
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            seen.append(Self.isVisible(target, in: window) ? Self.offset(band[0], in: window) : nil)
        }
        let kept = seen.suffix(15).allSatisfy { $0.map { (-2...20).contains($0) } == true }
        #expect(kept, "\(target) was not kept at the line after the page (\(seen))")
        #expect(consumed.landings == [landing], "the landing was consumed again")
    }

    // MARK: - Select and Show Selected

    @Test("Select mode and Show Selected draw the chosen tiles with grouping off")
    func selectAndShowSelectedWhileFlat() async throws {
        let items = Self.library(days: 3)
        let wanted = Self.headingLabels(items)
        let chosen = [items[1], items[7]]
        var selection = LibrarySelection()
        selection.begin()
        for row in chosen { selection.toggle(row) }
        let scratch = try ScratchPreferences(groupByDay: false)

        let selecting = Self.show(
            Harness(items: items, preferences: scratch.preferences, selection: selection),
            height: 2000)
        var narrowed = selection
        narrowed.toggleNarrowed()
        let showing = Self.show(
            Harness(items: items, preferences: scratch.preferences, selection: narrowed),
            height: 2000)
        defer {
            selecting.isHidden = true
            showing.isHidden = true
        }

        var all: [String: NSObject] = [:]
        var few: [String: NSObject] = [:]
        for _ in 0..<80 where all.count < items.count || few.count < chosen.count {
            try await Task.sleep(for: .milliseconds(50))
            selecting.layoutIfNeeded()
            showing.layoutIfNeeded()
            all = Self.tiles(in: selecting)
            few = Self.tiles(in: showing)
        }
        let picked = Set(chosen.map(\.id))
        #expect(Set(all.keys) == Set(items.map(\.id)), "select mode drew \(all.keys.sorted())")
        let marked = all.filter { $0.value.accessibilityTraits.contains(.selected) }.keys
        #expect(Set(marked) == picked, "select mode marked \(marked.sorted())")
        #expect(Set(few.keys) == picked, "Show Selected drew \(few.keys.sorted())")
        #expect(
            few.values.allSatisfy { $0.accessibilityTraits.contains(.selected) },
            "Show Selected drew a chosen tile unmarked")
        for window in [selecting, showing] {
            let headings = Self.labels(in: window).filter(wanted.contains)
            #expect(headings.isEmpty, "a grid with grouping off drew \(headings)")
        }
    }

    // MARK: - Hosting and reading

    private static func pictures(_ row: LibraryAllRow) -> [LibraryDayPicture] {
        guard case .band(let band, _) = row else { return [] }
        return band.pictures
    }

    /// On the test host's own scene, as `MediaLibraryRenderTests.show` explains.
    private static func show(_ harness: some View, height: CGFloat = 844) -> UIWindow {
        let frame = CGRect(origin: .zero, size: CGSize(width: 390, height: height))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene })
            as? UIWindowScene
        {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = UIHostingController(rootView: harness)
        window.makeKeyAndVisible()
        return window
    }

    /// Every loaded tile the hosted grid has built, by the file it shows.
    private static func tiles(in window: UIWindow) -> [String: NSObject] {
        let prefix = LibraryGrid.tileIdentifier("")
        var found: [String: NSObject] = [:]
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.responds(to: Selector(("accessibilityIdentifier"))),
                let identifier = object.value(forKey: "accessibilityIdentifier") as? String,
                identifier.hasPrefix(prefix)
            {
                let uid = String(identifier.dropFirst(prefix.count))
                if found[uid] == nil { found[uid] = object }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    private static func tileFrames(in window: UIWindow) -> [String: CGRect] {
        tiles(in: window).mapValues(\.accessibilityFrame)
    }

    /// Every label the hosted hierarchy reads out.
    private static func labels(in window: UIWindow) -> [String] {
        var found: [String] = []
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    /// The grid's scroll view, and the line under its top inset in window points.
    private static func visibleTop(in root: UIView) -> (scroll: UIScrollView, top: CGFloat)? {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let scroll = view as? UIScrollView {
                let line = CGPoint(
                    x: 0, y: scroll.contentOffset.y + scroll.adjustedContentInset.top)
                return (scroll, scroll.convert(line, to: nil).y)
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// How far below the line under the top inset `uid`'s tile starts, in points.
    private static func offset(_ uid: String, in window: UIWindow) -> CGFloat? {
        guard let frame = tileFrames(in: window)[uid], let visible = visibleTop(in: window)
        else { return nil }
        return frame.minY - visible.top
    }

    /// Whether `uid`'s tile is built and crosses the part of the window the scroll shows.
    private static func isVisible(_ uid: String, in window: UIWindow) -> Bool {
        guard let frame = tileFrames(in: window)[uid], let visible = visibleTop(in: window)
        else { return false }
        return frame.height > 0 && frame.maxY > visible.top + 1
            && frame.minY < window.bounds.maxY - 1
    }

    /// Scrolls down until `uid`'s tile is built, then rests its top 4 pt above the line under the
    /// top inset — the picture the reader is looking at — for five passes in a row.
    private static func place(_ uid: String, in window: UIWindow) async throws -> Bool {
        var stable = 0
        for _ in 0..<240 where stable < 5 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            guard let visible = visibleTop(in: window) else { continue }
            let scroll = visible.scroll
            guard let frame = tileFrames(in: window)[uid] else {
                stable = 0
                scroll.setContentOffset(
                    CGPoint(x: 0, y: scroll.contentOffset.y + 400), animated: false)
                continue
            }
            let delta = frame.minY - (visible.top - 4)
            if abs(delta) <= 1.5 {
                stable += 1
            } else {
                stable = 0
                scroll.setContentOffset(
                    CGPoint(x: 0, y: scroll.contentOffset.y + delta), animated: false)
            }
        }
        return stable >= 5
    }
}

/// The list a hosted grid is handed, lengthened by a test as a next page lengthens the store's.
@MainActor
@Observable
private final class PageFeed {
    var items: [LibraryRow]

    init(_ items: [LibraryRow]) { self.items = items }
}

/// What a hosted grid reported: the landings it consumed and the pages it asked for.
@MainActor
private final class LandingLog {
    var landings: [LibraryLanding] = []
    var pages = 0
}
