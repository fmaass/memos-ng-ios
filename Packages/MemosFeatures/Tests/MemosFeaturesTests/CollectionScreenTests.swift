import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A tag, a month or a year opened as a trip is (MEMNG-817): the trip's screen over the scope's
/// own reads, the Photos-style hero, no trip-only chrome, and the identity fence; and the gap
/// between two Journal cards of one day (MEMNG-820).
@MainActor
@Suite("Collection screen", .serialized, .mediaGlobals, .timeLimit(.minutes(3)))
struct CollectionScreenTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "collection-screen").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")
    private let bob = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "bob")
    private let identity = MediaIdentity()
    /// The screen's modes, chosen here as the main bar's modes row chooses them (MEMNG-822): the
    /// row under the hero is gone, and no bar is drawn over a screen hosted alone.
    private let modes = CollectionModeChoice()

    init() {
        MediaImageLoader.store = MediaImageStore(
            countLimit: MediaImageLoader.countLimit,
            totalCostLimit: MediaImageLoader.totalCostLimit,
            identity: identity
        )
        MediaImageLoader.transport = MediaSession.shared
        MediaImageLoader.flights = MediaFetchTable()
        MediaRetrySignal.shared = MediaRetrySignal()
    }

    static let files = ["p0", "p1", "p2", "p3", "p4"]
    static let utc = TimeZone(identifier: "UTC")!
    /// The picture the card showed: none of the drained members.
    static let card = CollectionCover(
        uid: "c9",
        thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/c9/thumb"))
    static let tag = scope(.tag("portugal2026"))
    static let month = scope(.month("2026-03"))
    static let year = scope(.year("2026"))

    static func scope(_ kind: AutomaticCollection.Kind, count: Int = 143) -> CollectionScope {
        .automatic(AutomaticCollection(kind: kind, count: count, cover: card, zone: utc))
    }

    private func stores(memberCap: Int = TripMemberStore.memberCap)
        -> (TripStore, TripMemberStore)
    {
        let trips = TripStore(identity: alice, root: root)
        return (trips, TripMemberStore(trips: trips, pageSize: 2, memberCap: memberCap))
    }

    /// The device's Sort By and View Options over a scratch suite, so no stored choice decides a
    /// case: oldest first in one block — the grid as it was drawn before a collection read the
    /// Library's (MEMNG-827) — unless a case names its own.
    static func preferences(
        order: MediaLibraryOrder = .oldestFirst, groupByDay: Bool = false
    ) -> LibraryPreferences {
        let suite = "collection-screen-" + UUID().uuidString
        let preferences = LibraryPreferences(defaults: UserDefaults(suiteName: suite) ?? .standard)
        preferences.select(order)
        preferences.select(groupByDay: groupByDay)
        return preferences
    }

    private func screen(
        _ stores: (TripStore, TripMemberStore), _ wire: TripWire, _ scope: CollectionScope,
        source: IdentitySource? = nil, dock: AppDock? = nil, zone: TimeZone = Self.utc,
        preferences: LibraryPreferences = Self.preferences()
    ) -> some View {
        let access = wire.access
        let source = source ?? IdentitySource(alice)
        return IdentityHost(source: source) { who in
            NavigationStack {
                TripView(
                    scope: scope, openedUnder: alice, trips: stores.0, memberStore: stores.1,
                    identity: who, access: { access }, modes: modes, preferences: preferences)
            }
        }
        .environment(dock ?? AppDock())
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, zone)
    }

    /// A trip on the scripted server, listed by a real refresh: the positive controls' screen.
    private func filedTrip(_ stores: (TripStore, TripMemberStore), _ wire: TripWire) async
        -> CollectionScope
    {
        let uid = wire.transport.trips.seed("Portugal 2026", tag: "portugal2026")
        await stores.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        let trip =
            stores.0.trips.first { $0.uid == uid }
            ?? Trip(
                uid: uid, title: "Portugal 2026", createdAt: .distantPast, updatedAt: .distantPast)
        return .trip(trip)
    }

    /// The node carrying `identifier`, read after its label as `TripProbe.identified` does.
    private static func node(identified identifier: String, in window: UIWindow) -> NSObject? {
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            _ = object.accessibilityLabel
            if object.responds(to: Selector(("accessibilityIdentifier"))),
                object.value(forKey: "accessibilityIdentifier") as? String == identifier
            {
                return object
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// Every node labelled exactly `label`.
    private static func nodes(labelled label: String, in window: UIWindow) -> [NSObject] {
        var found: [NSObject] = []
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.accessibilityLabel == label { found.append(object) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    // MARK: - Trip-only chrome

    /// Rename, Trip Dates, Show Removed and Delete Trip are reached through the Manage menu alone
    /// (the Removed sheet and the dates sheet open from it), so the menu's absence is theirs. A
    /// hosted window cannot open a menu: the menu itself is what is read here, and each item by
    /// its own test below, from the items the menu's provider builds.
    @Test("an automatic collection has no Manage menu; a trip has")
    func noManageMenu() async {
        let wire = TripWire()
        let held = stores()
        let trip = await filedTrip(held, wire)
        await CollectionsHost.with(screen(held, wire, trip)) { screen in
            let menu = await screen.until { screen.element(labelled: TripView.manageButton) != nil }
            #expect(menu, "control: the trip has no Manage menu")
        }
        await CollectionsHost.with(screen(stores(), TripWire(), Self.tag)) { screen in
            _ = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(TripProbe.photos(in: screen.window).count == 5, "precondition: the grid landed")
            #expect(screen.element(labelled: TripView.manageButton) == nil, "a tag has Manage")
        }
    }

    @Test("an automatic collection offers no Trip Dates; a trip does")
    func noSpanItem() async { await expectTripOnly(TripView.spanButton) }

    @Test("an automatic collection offers no Removed from trip; a trip does")
    func noShowRemovedItem() async { await expectTripOnly(TripView.removedRowButton) }

    @Test("an automatic collection offers no Rename; a trip does")
    func noRenameItem() async { await expectTripOnly(TripView.renameButton) }

    @Test("an automatic collection offers no Delete Trip; a trip does")
    func noDeleteItem() async { await expectTripOnly(TripView.deleteButton) }

    /// `title` is offered on a trip's screen — the control that the search finds it — and on
    /// neither a tag's nor a month's, once each has drawn its grid.
    private func expectTripOnly(_ title: String) async {
        let wire = TripWire()
        let held = stores()
        let trip = await filedTrip(held, wire)
        await CollectionsHost.with(screen(held, wire, trip)) { screen in
            let found = await screen.until { Self.offers(title, in: screen.window) }
            #expect(found, "control: a trip does not offer \(title): \(Self.bars(screen.window))")
        }
        for scope in [Self.tag, Self.month] {
            await CollectionsHost.with(screen(stores(), TripWire(), scope)) { screen in
                _ = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
                let grid = TripProbe.photos(in: screen.window).count
                #expect(grid == 5, "precondition: \(scope.id)'s grid landed")
                #expect(
                    !Self.offers(title, in: screen.window),
                    "\(scope.id) offers \(title): \(Self.bars(screen.window))")
            }
        }
    }

    /// Whether `window` offers `title`: as a node of the rendered tree, or as an item of a menu a
    /// navigation bar's item or a button holds — a hosted window cannot open a menu, so its items
    /// are read from the menu the control carries.
    private static func offers(_ title: String, in window: UIWindow) -> Bool {
        !nodes(labelled: title, in: window).isEmpty || menuTitles(in: window).contains(title)
    }

    /// Every title of every menu the navigation bars' items and the buttons under `window` hold,
    /// submenus included.
    private static func menuTitles(in window: UIWindow) -> [String] {
        var titles: [String] = []
        var elements: [UIMenuElement] = menuHolders(in: window).compactMap(\.menu)
        while let next = elements.popLast() {
            if let menu = next as? UIMenu {
                titles.append(menu.title)
                elements.append(contentsOf: menu.children)
            } else if let action = next as? UIAction {
                titles.append(action.title)
            } else if let command = next as? UICommand {
                titles.append(command.title)
            } else if let deferred = next as? UIDeferredMenuElement {
                elements.append(contentsOf: provided(by: deferred))
            }
        }
        return titles
    }

    /// The elements a deferred element provides, asked of its provider as UIKit asks it when the
    /// menu opens: SwiftUI hands a bar item's menu over as one deferred element, built on demand.
    /// The element keeps its provider in an object of its own (`_elementProvider`), which holds
    /// the block; only an instance variable that is a block (`@?`) is ever called.
    static func provided(by deferred: UIDeferredMenuElement) -> [UIMenuElement] {
        typealias Completion = @convention(block) ([UIMenuElement]) -> Void
        typealias Provider = @convention(block) (@escaping Completion) -> Void
        guard let found = ivar(named: "_elementProvider", of: deferred) else { return [] }
        let holder = found as AnyObject
        var provided: [UIMenuElement] = []
        var type: AnyClass? = Swift.type(of: holder)
        while let next = type, next != NSObject.self {
            for (name, encoding) in ivarList(of: next) where encoding == "@?" {
                guard let block = ivar(named: name, of: holder) else { continue }
                let provider = unsafeBitCast(block as AnyObject, to: Provider.self)
                provider { provided.append(contentsOf: $0) }
            }
            type = class_getSuperclass(next)
        }
        return provided
    }

    /// `object`'s object instance variable `name`, looked up on its class and its superclasses.
    static func ivar(named name: String, of object: AnyObject) -> Any? {
        guard let ivar = class_getInstanceVariable(type(of: object), name) else { return nil }
        return object_getIvar(object, ivar)
    }

    /// A class's own instance variables: name and type encoding.
    static func ivarList(of type: AnyClass) -> [(name: String, encoding: String)] {
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(type, &count) else { return [] }
        defer { free(ivars) }
        return (0..<Int(count)).map { index in
            let name = ivar_getName(ivars[index]).map { String(cString: $0) } ?? "?"
            let encoding = ivar_getTypeEncoding(ivars[index]).map { String(cString: $0) } ?? "?"
            return (name, encoding)
        }
    }

    /// What may hold a menu: every bar button item of the navigation bars under `window`, and every
    /// button.
    static func menuHolders(in window: UIWindow) -> [(menu: UIMenu?, name: String)] {
        var found: [(menu: UIMenu?, name: String)] = []
        var views: [UIView] = [window]
        while let view = views.popLast() {
            views.append(contentsOf: view.subviews)
            if let button = view as? UIButton {
                found.append((button.menu, "button \(button.accessibilityLabel ?? "-")"))
            }
            guard let bar = view as? UINavigationBar else { continue }
            for item in bar.items ?? [] {
                let groups = item.leadingItemGroups + item.trailingItemGroups
                let items = (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? [])
                let buttons = items + groups.flatMap(\.barButtonItems)
                for button in buttons {
                    let name = button.accessibilityLabel ?? button.title ?? "-"
                    found.append((button.menu, "bar item \(name)"))
                }
            }
        }
        return found
    }

    /// What the bars hold, for a failure's message: each holder, and its menu's children's kinds.
    private static func bars(_ window: UIWindow) -> String {
        menuHolders(in: window).map { holder in
            let kinds = holder.menu?.children.map { "\(type(of: $0))" } ?? []
            return "\(holder.name) \(kinds)"
        }
        .joined(separator: "; ") + " | titles \(menuTitles(in: window))"
    }

    @Test("an automatic collection's select bar offers no Remove; a trip's does")
    func noRemoveInTheSelectBar() async {
        for automatic in [false, true] {
            let wire = TripWire()
            let held = stores()
            let scope = automatic ? Self.month : await filedTrip(held, wire)
            let dock = AppDock()
            dock.send(.selected(.collections))
            let view = screen(held, wire, scope, dock: dock)
            await CollectionsHost.with(view, height: 3000) { screen in
                _ = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
                let pressed = CollectionsHost.pressBarItem(TripView.selectButton, on: screen)
                #expect(pressed.took, "Select took no press: \(pressed.seen)")
                let reached7 = await screen.until { screen.says("Select Items") }
                #expect(reached7, "no toolbar")
                let photos = TripProbe.photos(in: screen.window)
                #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[0]), "p0 took no press")
                let bar = await screen.until { screen.says("Show Selected (1)") }
                #expect(bar, "control: nothing was chosen")
                // The trip's Remove is its actions menu's row (MEMNG-780); a month has no menu.
                let rows = TripMenuProbe.rows(of: SelectChrome.moreLabel, in: screen.window)
                let remove = rows.contains(TripView.removeRowTitle(1))
                #expect(remove == !automatic, "automatic=\(automatic): \(rows)")
            }
        }
    }

    // MARK: - The hero

    @Test(
        "the hero draws the card's cover edge to edge with the title inside it",
        arguments: ["tag", "month", "year"])
    func theHeroIsPhotosStyle(_ kind: String) async {
        let (scope, title) =
            switch kind {
            case "tag": (Self.tag, "#portugal2026")
            case "month": (Self.month, "Mar 2026")
            default: (Self.year, "2026")
            }
        let wire = TripWire()
        wire.transport.hold()
        await CollectionsHost.with(screen(stores(), wire, scope)) { screen in
            let id = TripView.carriedCoverIdentifier(Self.card.uid)
            let drawn = await screen.until { Self.node(identified: id, in: screen.window) != nil }
            #expect(drawn, "no carried cover: \(TripProbe.labels(in: screen.window))")
            guard let cover = Self.node(identified: id, in: screen.window)?.accessibilityFrame
            else { return }
            #expect(abs(cover.width - screen.window.bounds.width) < 1, "not edge to edge: \(cover)")
            let titles = Self.nodes(labelled: title, in: screen.window).map(\.accessibilityFrame)
            #expect(titles.contains { cover.contains($0) }, "\(title) outside \(cover): \(titles)")
            wire.transport.release()
        }
    }

    @Test("a truncated drain keeps the card's thumbnail rather than a drained row")
    func aTruncatedDrainKeepsTheCarriedCover() async {
        let wire = TripWire()
        let held = stores(memberCap: 3)
        await CollectionsHost.with(screen(held, wire, Self.tag)) { screen in
            let settled = await screen.until { held.1.state(for: Self.tag) == .truncated }
            #expect(settled, "precondition: the drain stopped at the cap")
            let summary = held.1.summary(for: Self.tag)
            #expect(summary?.cover == nil && summary?.coverUid == Self.card.uid, "precondition")
            await screen.settle(turns: 10)
            let carried = TripView.carriedCoverIdentifier(Self.card.uid)
            #expect(TripProbe.identified(carried, in: screen.window), "the card's cover went")
            let rows = Self.files.filter {
                TripProbe.identified(TripView.coverIdentifier($0), in: screen.window)
            }
            #expect(rows.isEmpty, "a drained row stood in: \(rows)")
        }
    }

    // MARK: - The line under the title

    @Test("a month says its period and the card's count, then span and count once complete")
    func theMonthLine() async {
        let wire = TripWire()
        wire.transport.hold()
        let held = stores()
        await CollectionsHost.with(screen(held, wire, Self.month)) { screen in
            let loading = await screen.until { screen.says("March 2026 · 143 photos") }
            #expect(loading, "no loading line: \(TripProbe.labels(in: screen.window))")
            wire.transport.release()
            let span =
                CollectionsPresentation.spanText(
                    first: Date(timeIntervalSince1970: 1_773_316_800),  // 2026-03-12T12:00:00Z
                    last: Date(timeIntervalSince1970: 1_774_008_000),  // 2026-03-20T12:00:00Z
                    locale: Locale(identifier: "en_GB"), timeZone: Self.utc) ?? "?"
            let complete = await screen.until { screen.says("\(span) · 5 photos") }
            #expect(complete, "no settled line: \(TripProbe.labels(in: screen.window))")
        }
    }

    @Test("a truncated summary says the card's count alone, never a span")
    func aTruncatedLineIsTheCountAlone() async {
        let wire = TripWire()
        let held = stores(memberCap: 3)
        await CollectionsHost.with(screen(held, wire, Self.month)) { screen in
            let reached1 = await screen.until { held.1.state(for: Self.month) == .truncated }
            #expect(reached1)
            let said = await screen.until { screen.says("143 photos") }
            #expect(said, "no count line: \(TripProbe.labels(in: screen.window))")
            let spans = TripProbe.labels(in: screen.window).filter { $0.contains("Mar 2026 ·") }
            #expect(spans.isEmpty, "a truncated summary drew a span: \(spans)")
        }
    }

    // MARK: - Lifecycle

    /// A stack opened on `route`, as the Collections tab's: every path it held is logged.
    private func stacked(
        _ stores: (TripStore, TripMemberStore), _ wire: TripWire, _ route: CollectionRoute,
        log: TripStackLog, popper: StackPopper = StackPopper()
    ) -> some View {
        let access = wire.access
        return OpenedStack(route: route, log: log, popper: popper) { route, trail in
            TripView(
                scope: CollectionsScreen.destination(route, in: stores.0),
                openedUnder: route.openedUnder, trips: stores.0, memberStore: stores.1,
                identity: alice, access: { access }, trail: trail)
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, Self.utc)
    }

    @Test("an automatic collection stays open through its loading and a refresh of the trips")
    func theScreenStaysOpen() async {
        let wire = TripWire()
        wire.transport.hold()
        let held = stores()
        let log = TripStackLog()
        let route = CollectionRoute(scope: Self.tag, openedUnder: alice)
        await CollectionsHost.with(stacked(held, wire, route, log: log)) { screen in
            let reached8 = await screen.until { log.paths.last == [route] }
            #expect(reached8, "precondition: pushed")
            try? await Task.sleep(for: TripView.leavingDelay * 2)
            #expect(log.paths.last == [route], "the screen left while loading")
            wire.transport.release()
            let reached2 = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(reached2)
            wire.transport.trips.seed("Spain 2025", tag: "spain2025")
            await held.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
            try? await Task.sleep(for: TripView.leavingDelay * 2)
            #expect(log.paths.last == [route], "the screen left after the trips' refresh")
        }
    }

    @Test("a trip's screen still leaves once its record is gone")
    func aGoneTripLeaves() async {
        let wire = TripWire()
        let held = stores()
        guard case .trip(let trip) = await filedTrip(held, wire) else { return }
        let log = TripStackLog()
        let route = CollectionRoute(trip, openedUnder: alice)
        await CollectionsHost.with(stacked(held, wire, route, log: log)) { screen in
            let reached9 = await screen.until { log.paths.last == [route] }
            #expect(reached9, "precondition: pushed")
            wire.transport.trips.remove(trip.uid)
            await held.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
            let left = await screen.until { log.paths.last == [] }
            #expect(left, "the trip's screen stayed: \(log.paths.map(\.count))")
        }
    }

    /// The read that outlives the screen is a lapsed signature's: the refresher's task is not the
    /// view's, so leaving does not cancel it — only the store's forget fences what it brings.
    @Test("a page still on the wire when an automatic collection is left writes nothing")
    func leavingRetiresTheReads() async {
        let wire = TripWire()
        let held = stores()
        let log = TripStackLog()
        let popper = StackPopper()
        let route = CollectionRoute(scope: Self.month, openedUnder: alice)
        let view = stacked(held, wire, route, log: log, popper: popper)
        await CollectionsHost.with(view) { screen in
            let drained = await screen.until { held.1.state(for: Self.month) == .complete }
            #expect(drained, "precondition: the month drained")
            wire.transport.hold()
            let access = wire.access
            let refresher = TripURLRefresher(
                members: held.1, trips: held.0, scope: Self.month,
                session: IssuingSession(handle: { access.handle }, baseURL: { access.baseURL }),
                lease: held.1.coverLease(for: Self.month))
            let before = wire.transport.listReads.count
            refresher.signatureExpired(uid: "p1")
            let asked = await screen.until { wire.transport.listReads.count > before }
            #expect(asked, "precondition: a page is on the wire")
            popper.pops += 1
            let left = await screen.until { log.paths.last == [] }
            #expect(left, "precondition: the screen left")
            let reads = wire.transport.listReads.count
            wire.transport.release()
            try? await Task.sleep(for: .seconds(1))
            #expect(held.1.members(for: Self.month).isEmpty, "the month's members stood")
            #expect(held.1.state(for: Self.month) == .notLoaded, "the month reads as read")
            #expect(wire.transport.listReads.count == reads, "the walk read on")
        }
    }

    @Test("Photos, Journal and Map each read an automatic collection")
    func everyModeLoads() async {
        let wire = TripWire()
        let held = stores()
        await CollectionsHost.with(screen(held, wire, Self.year), height: 3000) { screen in
            let grid = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(grid, "Photos: \(TripProbe.tiles(in: screen.window))")
            modes.choose(.journal)
            let journal = await screen.until { screen.says("Arrived in Lisbon") }
            #expect(journal, "Journal: \(wire.transport.memoReads)")
            modes.choose(.map)
            await screen.settle(turns: 10)
            let uids = TripMapPresentation.memberUids(of: Self.year, in: held.1)
            #expect(uids == Set(Self.files), "Map: \(String(describing: uids))")
        }
    }

    @Test("a lapsed signature on an automatic collection reads it again")
    func aLapsedSignatureRedrains() async {
        let wire = TripWire()
        let held = stores()
        await held.1.drain(Self.tag, using: wire.access.handle, baseURL: TripWire.baseURL)
        #expect(wire.transport.listReads.count == 3, "precondition: one drain")
        let access = wire.access
        let refresher = TripURLRefresher(
            members: held.1, trips: held.0, scope: Self.tag,
            session: IssuingSession(handle: { access.handle }, baseURL: { access.baseURL }),
            lease: held.1.coverLease(for: Self.tag))
        refresher.signatureExpired(uid: "p1")
        for _ in 0..<200 where wire.transport.listReads.count < 6 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(wire.transport.listReads.count == 6, "the tag was not read again")
    }

    @Test("a refresh of the trips keeps a month's tiles while held; an empty answer replaces them")
    func theTilesSurviveARefresh() async {
        let wire = TripWire()
        let held = stores()
        await CollectionsHost.with(screen(held, wire, Self.month), height: 3000) { screen in
            let reached3 = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(reached3)
            wire.transport.hold()
            wire.transport.trips.seed("Spain 2025", tag: "spain2025")
            await held.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
            #expect(held.1.state(for: Self.month) != .complete, "precondition: let go")
            await screen.settle(turns: 20)
            let kept = TripProbe.tiles(in: screen.window)
            #expect(kept == Self.files, "the held tiles: \(kept)")
            wire.transport.empty()
            wire.transport.release()
            let emptied = await screen.until {
                screen.says(TripView.emptyTitle(for: Self.month))
            }
            #expect(emptied, "an empty answer did not replace them")
            #expect(TripProbe.tiles(in: screen.window).isEmpty)
        }
    }

    @Test("a picture deleted while a tag's tiles are held leaves them, and the hero with its line")
    func aDeletedPictureLeavesTheHeldTiles() async {
        let wire = TripWire()
        let held = stores()
        await CollectionsHost.with(screen(held, wire, Self.tag), height: 3000) { screen in
            let reached4 = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(reached4)
            wire.transport.hold()
            wire.transport.trips.seed("Spain 2025", tag: "spain2025")
            await held.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
            _ = await held.1.delete(["p1"], using: wire.access.handle, baseURL: TripWire.baseURL)
            await screen.settle(turns: 20)
            let kept = TripProbe.tiles(in: screen.window)
            #expect(kept == ["p0", "p2", "p3", "p4"], "the held tiles: \(kept)")
            // The hero's picture, the newest member, deleted while the read is still held.
            let hero = TripView.coverIdentifier("p4")
            #expect(TripProbe.identified(hero, in: screen.window), "precondition: p4 is the hero")
            _ = await held.1.delete(["p4"], using: wire.access.handle, baseURL: TripWire.baseURL)
            await screen.settle(turns: 20)
            #expect(held.1.state(for: Self.tag) == .draining, "precondition: the read is held")
            Self.expectHeroLeft(screen, when: "while held")
            wire.transport.fail()
            wire.transport.release()
            let failed = await screen.until { held.1.state(for: Self.tag) != .draining }
            #expect(failed, "precondition: the held read answered")
            await screen.settle(turns: 20)
            #expect(held.1.state(for: Self.tag) != .complete, "precondition: the read failed")
            Self.expectHeroLeft(screen, when: "after the read failed")
        }
    }

    /// The hero line of the tag's held members once p1 and p4 are deleted: p0 to p3's span, and
    /// three photos.
    private static func heldDetail() -> String {
        let iso = ISO8601DateFormatter()
        let summary = TripMemberSummary(
            count: 3, firstTaken: iso.date(from: "2026-03-12T12:00:00Z"),
            lastTaken: iso.date(from: "2026-03-18T12:00:00Z"), cover: nil)
        guard case .automatic(let collection) = Self.tag else { return "" }
        return CollectionsPresentation.automaticDetail(
            collection, summary: summary, carrying: true, locale: Locale(identifier: "en_GB"),
            timeZone: utc) ?? ""
    }

    /// The deleted hero picture is gone from the hero, the next kept picture stands in its place,
    /// and the line under the title counts and spans the pictures still kept.
    private static func expectHeroLeft(_ screen: PressProbe.Screen, when: String) {
        let labels = TripProbe.labels(in: screen.window)
        let deleted = TripView.coverIdentifier("p4")
        let stood = TripProbe.identified(deleted, in: screen.window)
        #expect(!stood, "\(when): the deleted hero stood")
        let next = TripView.coverIdentifier("p3")
        #expect(TripProbe.identified(next, in: screen.window), "\(when): p3 is not the hero")
        #expect(screen.says(heldDetail()), "\(when): the hero line: \(labels)")
    }

    @Test("across an identity change nothing of the outgoing account stands")
    func theIdentityFence() async {
        let wire = TripWire()
        let held = stores()
        let source = IdentitySource(alice)
        await CollectionsHost.with(screen(held, wire, Self.tag, source: source)) { screen in
            let carried = TripView.carriedCoverIdentifier(Self.card.uid)
            // The drain answered at once, so the hero is the newest drained row by now.
            let row = TripView.coverIdentifier("p4")
            let reached5 = await screen.until { TripProbe.identified(row, in: screen.window) }
            #expect(reached5, "precondition: \(TripProbe.labels(in: screen.window))")
            let reached6 = await screen.until { !TripProbe.tiles(in: screen.window).isEmpty }
            #expect(reached6)
            wire.transport.hold()
            CollectionsSession.identityChanged(to: bob, trips: held.0, members: held.1)
            source.identity = bob
            await screen.settle(turns: 20)
            let said = TripProbe.labels(in: screen.window)
            #expect(!TripProbe.identified(carried, in: screen.window), "the carried cover stood")
            let rows = Self.files.filter {
                TripProbe.identified(TripView.coverIdentifier($0), in: screen.window)
            }
            #expect(rows.isEmpty, "a drained cover stood: \(rows)")
            #expect(!said.contains { $0.contains("photos") }, "a count stood: \(said)")
            #expect(TripProbe.tiles(in: screen.window).isEmpty, "a tile stood")
            wire.transport.release()
        }
    }

    // MARK: - MEMNG-820

    @Test("two Journal cards of one day stand the Timeline's card gap apart")
    func theJournalCardGap() async {
        let wire = TripWire()
        let held = stores()
        await CollectionsHost.with(screen(held, wire, Self.tag), height: 3000) { screen in
            modes.choose(.journal)
            let both = await screen.until {
                TripProbe.card(saying: "Arrived in Lisbon", in: screen.window) != nil
                    && TripProbe.card(saying: "Tram up to the castle", in: screen.window) != nil
            }
            #expect(both, "precondition: both cards of 12 March")
            guard let first = TripProbe.card(saying: "Arrived in Lisbon", in: screen.window),
                let second = TripProbe.card(saying: "Tram up to the castle", in: screen.window)
            else { return }
            let gap = second.accessibilityFrame.minY - first.accessibilityFrame.maxY
            #expect(abs(gap - DesignTokens.Space.regular) < 1, "the gap is \(gap)")
        }
    }

    // MARK: - The bucket's zone

    static let plus14 = TimeZone(identifier: "Pacific/Kiritimati")!
    static let minus12 = TimeZone(identifier: "Etc/GMT+12")!

    @Test("a month's span and its Journal's days are cut in its bucket's zone, not the device's")
    func theBucketsZone() async {
        let wire = TripWire()
        wire.transport.edge()
        let held = stores()
        let collection = AutomaticCollection(
            kind: .month("2026-03"), count: 5, cover: Self.card, zone: Self.plus14)
        let march = CollectionScope.automatic(collection)
        let british = Locale(identifier: "en_GB")
        let view = screen(held, wire, march, zone: Self.minus12)
        await CollectionsHost.with(view, height: 3000) { screen in
            let settled = await screen.until { held.1.summary(for: march)?.complete == true }
            #expect(settled, "precondition: the drain read the whole month")
            let summary = held.1.summary(for: march)
            let line = CollectionsPresentation.automaticDetail(
                collection, summary: summary, carrying: true, locale: british,
                timeZone: Self.plus14)
            let device = CollectionsPresentation.automaticDetail(
                collection, summary: summary, carrying: true, locale: british,
                timeZone: Self.minus12)
            #expect(line != device, "precondition: the two zones name other days")
            #expect(line?.hasPrefix("1") == true, "starts on 1 March: \(String(describing: line))")
            #expect(line?.contains("Feb") == false, "\(String(describing: line))")
            let spanned = await screen.until { line.map { screen.says($0) } ?? false }
            let drawnDevice = device.map { screen.says($0) } ?? false
            #expect(spanned, "the span: \(String(describing: line)); device's: \(drawnDevice)")

            modes.choose(.journal)
            let instant =
                ISO8601DateFormatter().date(from: TripTransport.edgeStamp) ?? .distantPast
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = british
            calendar.timeZone = Self.plus14
            let heading = TimelineGrouping.title(for: instant, calendar: calendar)
            calendar.timeZone = Self.minus12
            let deviceHeading = TimelineGrouping.title(for: instant, calendar: calendar)
            #expect(heading.contains("1 March"), "precondition: \(heading)")
            #expect(deviceHeading.contains("27 February"), "precondition: \(deviceHeading)")
            let journal = await screen.until { screen.says("Arrived in Lisbon") }
            #expect(journal, "precondition: the Journal answered")
            let headed = await screen.until { screen.says(heading) }
            let wrong = screen.says(deviceHeading)
            #expect(headed, "the first day: \(heading); the device's drawn: \(wrong)")
        }
    }

    // MARK: - A carried cover's signature

    /// The card's picture as a card carried it, signed with an `exp` long past.
    static let lapsed = CollectionCover(
        uid: "c9",
        thumbnailURL: URL(
            string: "https://memos.example.invalid/api/attachments/c9/thumb"
                + "?exp=1000000000&scope=1&sig=old"))

    static func lapsedTag() -> CollectionScope {
        .automatic(
            AutomaticCollection(
                kind: .tag("portugal2026"), count: 143, cover: lapsed, zone: utc))
    }

    @Test("the hero draws the card's picture as renewed, and no other picture's renewal")
    func theRenewedCarriedCover() {
        let fresh = URL(string: "https://memos.example.invalid/api/attachments/c9/thumb?sig=new")
        let renewed = MemoAttachment(
            uid: "c9", mime: "image/jpeg", status: .ready, thumbnailURL: fresh)
        let other = MemoAttachment(
            uid: "c8", mime: "image/jpeg", status: .ready, thumbnailURL: fresh)
        let drawn = TripView.heroCover(
            Self.lapsedTag(), summary: nil, members: [], carrying: true, renewed: renewed)
        #expect(drawn == .carried(renewed), "\(drawn)")
        let kept = TripView.heroCover(
            Self.lapsedTag(), summary: nil, members: [], carrying: true, renewed: other)
        guard case .carried(let attachment) = kept else {
            Issue.record("no carried cover: \(kept)")
            return
        }
        #expect(attachment.thumbnailURL == Self.lapsed.thumbnailURL, "\(attachment)")
        let elsewhere = TripView.heroCover(
            Self.lapsedTag(), summary: nil, members: [], carrying: false, renewed: renewed)
        #expect(elsewhere == TripView.HeroCover.none, "another account drew it: \(elsewhere)")
    }

    @Test(
        "a lapsed carried cover past the cap is drawn signed again, in Photos, Journal and Map",
        arguments: [0, 1, 2])
    func aLapsedCarriedCoverIsSignedAgain(mode: Int) async {
        let media = HeldCoverServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        let wire = TripWire()
        let held = stores(memberCap: 3)
        let tag = Self.lapsedTag()
        let modes = [TripMode.photos, .journal, .map]
        if mode > 0 { media.hold() }
        await CollectionsHost.with(screen(held, wire, tag), height: 3000) { screen in
            let truncated = await screen.until { held.1.state(for: tag) == .truncated }
            #expect(truncated, "precondition: the drain stopped short of the card's picture")
            if mode > 0 {
                // Asked under Photos and held there, so the answer reaches the other mode's hero.
                let asked = await screen.until { media.asked("old") > 0 }
                #expect(asked, "precondition: the hero asked for its picture")
                self.modes.choose(modes[mode])
                await screen.settle(turns: 10)
                media.release()
            }
            let renewed = await screen.until(seconds: 10) { !wire.transport.metaReads.isEmpty }
            #expect(renewed, "\(modes[mode]): the hero's picture was not read again")
            let reads = wire.transport.metaReads
            #expect(reads.allSatisfy { $0 == "c9" }, "\(reads)")
            let fresh = await screen.until(seconds: 10) { media.asked("new") > 0 }
            #expect(fresh, "\(modes[mode]): the hero kept the lapsed URL")
            let carried = TripView.carriedCoverIdentifier("c9")
            #expect(TripProbe.identified(carried, in: screen.window), "the card's cover went")
        }
    }

    @Test("two renewals of one carried cover are one read")
    func aCarriedRenewalIsJoined() async {
        let wire = TripWire()
        let held = stores()
        let handle = wire.access.handle
        let base = TripWire.baseURL
        let lease = held.1.coverLease(for: Self.lapsedTag())
        wire.transport.hold()
        let first = Task {
            await held.1.renewCover(uid: "c9", under: lease, using: handle, baseURL: base)
        }
        let second = Task {
            await held.1.renewCover(uid: "c9", under: lease, using: handle, baseURL: base)
        }
        for _ in 0..<200 where wire.transport.metaReads.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(100))
        wire.transport.release()
        await first.value
        await second.value
        #expect(wire.transport.metaReads == ["c9"], "\(wire.transport.metaReads)")
        let url = held.1.renewedCover("c9")?.thumbnailURL?.absoluteString ?? ""
        #expect(url.contains("sig=new"), "\(url)")
    }

    @Test("a carried cover's renewal lands nowhere once the identity moved or the scope was left")
    func aCarriedRenewalIsFenced() async {
        let tag = Self.lapsedTag()
        for leave in [false, true] {
            let wire = TripWire()
            let held = stores()
            let handle = wire.access.handle
            let base = TripWire.baseURL
            let lease = held.1.coverLease(for: tag)
            wire.transport.hold()
            let renewal = Task {
                await held.1.renewCover(uid: "c9", under: lease, using: handle, baseURL: base)
            }
            for _ in 0..<200 where wire.transport.metaReads.isEmpty {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(wire.transport.metaReads == ["c9"], "precondition: the read is on the wire")
            if leave { held.1.forget(tag) } else { held.1.sessionIdentityChanged() }
            wire.transport.release()
            await renewal.value
            let landed = held.1.renewedCover("c9")?.thumbnailURL
            #expect(
                landed == nil, "\(leave ? "forget" : "identity"): \(String(describing: landed))")
        }
    }

    @Test(
        "a carried cover's callback held past the scope's forget reads nothing; a new showing's does"
    )
    func aHeldBackCallbackStartsNothing() async {
        let tag = Self.lapsedTag()
        let wire = TripWire()
        let held = stores()
        let access = wire.access
        let session = IssuingSession(handle: { access.handle }, baseURL: { TripWire.baseURL })
        let gone = CarriedCoverURLRefresher(
            members: held.1, session: session, lease: held.1.coverLease(for: tag))
        held.1.forget(tag)
        // What the media table ran after its cooldown: the refresher of the showing that went.
        gone.signatureExpired(uid: "c9")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(wire.transport.metaReads.isEmpty, "\(wire.transport.metaReads)")
        #expect(held.1.renewedCover("c9") == nil, "a retired showing wrote a cover")

        let shown = CarriedCoverURLRefresher(
            members: held.1, session: session, lease: held.1.coverLease(for: tag))
        shown.signatureExpired(uid: "c9")
        for _ in 0..<200 where held.1.renewedCover("c9") == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(wire.transport.metaReads == ["c9"], "control: \(wire.transport.metaReads)")
    }

    /// The grid's and the Journal's own lapsed-signature callbacks, held by the media table through
    /// its cooldown: once the scope was forgotten — and still once it was opened again, a new
    /// showing — the old showing's callback sends nothing and repopulates nothing; the new
    /// showing's own does read.
    @Test("held-back member and journal callbacks read nothing", arguments: [false, true])
    func heldBackReadsStartNothing(journal: Bool) async {
        let tag = Self.tag
        let wire = TripWire()
        let held = stores()
        let access = wire.access
        let session = IssuingSession(handle: { access.handle }, baseURL: { TripWire.baseURL })
        let what = journal ? "journal" : "members"
        func reads() -> Int {
            journal ? wire.transport.memoReads.count : wire.transport.listReads.count
        }
        func landed() -> Bool {
            journal ? !held.1.journal(for: tag).isEmpty : !held.1.members(for: tag).isEmpty
        }
        func refresher(_ lease: TripMemberStore.CoverLease) -> any SignedURLRefreshing {
            if journal {
                return TripJournalURLRefresher(
                    members: held.1, trips: held.0, scope: tag, session: session, lease: lease)
            }
            return TripURLRefresher(
                members: held.1, trips: held.0, scope: tag, session: session, lease: lease)
        }
        let gone = refresher(held.1.coverLease(for: tag))
        held.1.forget(tag)
        gone.signatureExpired(uid: "p1")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(reads() == 0, "\(what): a forgotten showing read")
        #expect(!landed(), "\(what): a forgotten showing repopulated the scope")

        let shown = refresher(held.1.coverLease(for: tag))
        gone.signatureExpired(uid: "p1")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(reads() == 0, "\(what): the retired showing read beside a new one")
        #expect(!landed(), "\(what): the retired showing repopulated the scope")

        shown.signatureExpired(uid: "p1")
        for _ in 0..<200 where !landed() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(reads() > 0, "control: \(what): the new showing's callback did not read")
        #expect(landed(), "control: \(what): the new showing's read did not land")
    }

    // MARK: - The filter menu (MEMNG-827)

    @Test(
        "a tag's and a month's Photos view has the Library's filter menu; Videos leaves the videos",
        arguments: ["tag", "month"])
    func theFilterMenuNarrowsToVideos(_ kind: String) async {
        let scope = kind == "tag" ? Self.tag : Self.month
        let wire = TripWire()
        wire.transport.film("p1")
        wire.transport.film("p3")
        await CollectionsHost.with(screen(stores(), wire, scope), height: 3000) { screen in
            let grid = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(grid, "control: the grid landed: \(TripProbe.tiles(in: screen.window))")
            let rows = TripMenuProbe.rows(of: TripView.filterButton, in: screen.window)
            let wanted = [
                "All Items", "Photos", "Videos", "Captured by me", "Any", "Public", "Just us",
                "Oldest First", "Newest First", "Group by Day", "Mixed Sizes", "Square Grid",
            ]
            let positions = wanted.map { rows.firstIndex(of: $0) ?? -1 }
            #expect(
                !positions.contains(-1) && positions == positions.sorted(),
                "the filter menu's rows: \(rows)")
            #expect(!rows.contains(TripView.removedRowButton), "a trip-only row: \(rows)")

            #expect(TripMenuProbe.perform("Videos", in: screen.window), "no Videos row")
            let narrowed = await screen.until {
                TripProbe.tiles(in: screen.window) == ["p1", "p3"]
            }
            #expect(narrowed, "Videos left: \(TripProbe.tiles(in: screen.window))")
            let asked = wire.transport.listReads.contains { $0["type"] == "video" }
            #expect(asked, "the kind was not read from the server: \(wire.transport.listReads)")
        }
    }

    @Test("View Options' Group by Day cuts a collection's grid into days as it cuts All")
    func viewOptionsCutTheCollectionGrid() async {
        let wire = TripWire()
        let preferences = Self.preferences(groupByDay: false)
        let host = screen(stores(), wire, Self.tag, preferences: preferences)
        await CollectionsHost.with(host, height: 3000) { screen in
            let grid = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(grid, "control: the grid landed: \(TripProbe.tiles(in: screen.window))")
            #expect(TripProbe.headings(in: screen.window).isEmpty, "one block drew a day")

            #expect(TripMenuProbe.perform("Group by Day", in: screen.window), "no such row")
            #expect(preferences.groupByDay, "the menu did not write the device's choice")
            let days = await screen.until {
                TripProbe.headings(in: screen.window) == TripScreenRenderTests.days
            }
            #expect(days, "the days drawn: \(TripProbe.headings(in: screen.window))")
        }
    }

    @Test("Sort By on a collection is the Library's: Newest First turns the grid round, no read")
    func sortByIsTheDevicesOrder() async {
        let wire = TripWire()
        let preferences = Self.preferences(order: .oldestFirst)
        let host = screen(stores(), wire, Self.tag, preferences: preferences)
        await CollectionsHost.with(host, height: 3000) { screen in
            let grid = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(grid, "control: the grid landed: \(TripProbe.tiles(in: screen.window))")
            let reads = wire.transport.listReads.count
            #expect(TripMenuProbe.perform("Newest First", in: screen.window), "no such row")
            #expect(preferences.order == .newestFirst, "the menu did not write the device's order")
            let turned = await screen.until {
                TripProbe.tiles(in: screen.window) == Array(Self.files.reversed())
            }
            #expect(turned, "the grid: \(TripProbe.tiles(in: screen.window))")
            #expect(wire.transport.listReads.count == reads, "a whole drain was read again")
        }
    }
}

/// The rendition route of a carried cover: held while a test says so, then an `old` signature is
/// answered with the lapse's 403 and any other with a picture. Every URL asked is kept.
nonisolated final class HeldCoverServer: MediaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    private var held = false
    private let payload: Data

    init(payload: Data) { self.payload = payload }

    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }

    /// How many asks named signature `sig`.
    func asked(_ sig: String) -> Int {
        lock.withLock { urls.filter { $0.absoluteString.contains("sig=\(sig)") }.count }
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        lock.withLock { urls.append(url) }
        while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(20)) }
        let lapsed = url.absoluteString.contains("sig=old")
        let response = HTTPURLResponse(
            url: url, statusCode: lapsed ? 403 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": lapsed ? "application/json" : "image/png"])
        return (lapsed ? Data() : payload, response ?? URLResponse())
    }
}

/// A back press a test makes by hand: every rise pops the stack to its root.
@MainActor
@Observable
final class StackPopper {
    var pops = 0
}

/// A stack opened on one route, as the Collections tab's is once a card is pressed.
struct OpenedStack<Destination: View>: View {
    let route: CollectionRoute
    let log: TripStackLog
    let popper: StackPopper
    @ViewBuilder let destination: (CollectionRoute, Binding<[CollectionRoute]>) -> Destination
    @State private var trail: [CollectionRoute] = []

    var body: some View {
        NavigationStack(path: $trail) {
            Color.clear.stackDestination(for: CollectionRoute.self) { destination($0, $trail) }
        }
        .onAppear { if trail.isEmpty { trail = [route] } }
        .onChange(of: popper.pops) {
            // Without its animation: a hand-hosted window does not reliably finish one.
            var popping = Transaction()
            popping.disablesAnimations = true
            withTransaction(popping) { trail = [] }
        }
        .onChange(of: trail) { _, now in log.paths.append(now) }
    }
}
