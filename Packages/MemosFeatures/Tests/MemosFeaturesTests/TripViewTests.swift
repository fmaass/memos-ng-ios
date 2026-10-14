import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

// MARK: - The Manage menu, as a flow

/// What the Trip screen's Manage menu does to the trip, without a screen.
@MainActor
@Suite("Trip manage flow")
struct TripManageTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-manage").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    /// Lisbon, Porto and Faro on a scripted server, listed by a real refresh, in that order.
    private func three() async -> (TripStore, [Trip], TripWire) {
        let wire = TripWire()
        for title in ["Lisbon", "Porto", "Faro"] {
            wire.transport.trips.seed(title, tag: title.lowercased())
        }
        let store = TripStore(identity: alice, root: root)
        await store.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        return (store, store.trips, wire)
    }

    @Test(
        "a new title is trimmed, and a blank or unchanged one writes nothing",
        arguments: [
            ("  Lisbon 2026 \n", "Lisbon 2026"),
            ("   ", nil),
            ("", nil),
            ("Lisbon", nil),
            (" Lisbon ", nil),
        ] as [(String, String?)]
    )
    func renamed(draft: String, expected: String?) {
        #expect(TripManage.renamed(draft, from: "Lisbon") == expected)
    }

    @Test("Rename writes the trimmed title once; a second yes writes nothing")
    func renameOnce() async {
        let (store, made, wire) = await three()
        let manage = TripManage()
        let unasked = manage.confirmRename(made[0].uid, in: store, using: wire.access)
        #expect(unasked == nil, "nothing was asked")
        manage.askRename(current: made[0].title)
        #expect(manage.question == .rename)
        #expect(manage.draft == "Lisbon", "the field starts from the current title")
        manage.draft = " Lisboa "
        let write = manage.confirmRename(made[0].uid, in: store, using: wire.access)
        #expect(write != nil)
        #expect(manage.question == nil)
        #expect(await write?.value == true)
        #expect(store.trips.first { $0.uid == made[0].uid }?.title == "Lisboa")
        // A second yes with a draft that WOULD be written: only the claim refuses it.
        manage.draft = "Lissabon"
        let again = manage.confirmRename(made[0].uid, in: store, using: wire.access)
        #expect(again == nil, "a second yes")
        #expect(store.trips.first { $0.uid == made[0].uid }?.title == "Lisboa")
        #expect(wire.transport.trips.calls(TripRows.patch).count == 1)
    }

    @Test("Delete removes that trip and no other, once; a yes nobody was asked for does nothing")
    func deleteOnce() async {
        let (store, made, wire) = await three()
        let manage = TripManage()
        let access = wire.access
        #expect(manage.confirmDelete(made[1].uid, in: store, using: access) == nil, "unasked")
        #expect(store.trips.count == 3)
        manage.askDelete()
        #expect(manage.question == .delete)
        let write = manage.confirmDelete(made[1].uid, in: store, using: access)
        #expect(write != nil)
        #expect(manage.confirmDelete(made[1].uid, in: store, using: access) == nil, "a second yes")
        // A second yes for a trip that IS there: only the claim refuses it.
        let other = manage.confirmDelete(made[0].uid, in: store, using: access)
        #expect(other == nil, "a second yes for another trip")
        #expect(await write?.value == true)
        #expect(store.trips.map(\.title) == ["Lisbon", "Faro"])
        #expect(wire.transport.trips.calls(TripRows.delete).count == 1)
        #expect(manage.question == nil)
    }

    @Test("the footer names the cap only when the drain stopped at it")
    func capNote() {
        #expect(
            TripView.capNote(.truncated, cap: 2000) == "Showing the first 2000 photos of this trip")
        #expect(TripView.capNote(.complete, cap: 2000) == nil)
        #expect(TripView.capNote(.draining, cap: 2000) == nil)
        #expect(TripView.capNote(.notLoaded, cap: 2000) == nil)
    }

    @Test("a trip that left the store leaves the stack, with everything pushed above it")
    func theTrailKeepsWhatExists() async {
        let (_, made, _) = await three()
        let routes = made.map(TripRoute.init)
        let ids = made.map(\.uid)
        #expect(CollectionsPresentation.trail(routes, keeping: ids) == routes)
        #expect(CollectionsPresentation.trail(routes, keeping: [ids[0], ids[2]]) == [routes[0]])
        #expect(CollectionsPresentation.trail(routes, keeping: [ids[1], ids[2]]).isEmpty)
        #expect(CollectionsPresentation.trail([], keeping: []).isEmpty)
    }

    @Test("the viewer pages through the trip as the store holds it now, once it holds it")
    func viewerSource() {
        let opened = MediaFixture.attachment(uid: "trip-viewer-opened")
        let fresh = LibraryRow(
            attachment: MediaFixture.attachment(uid: "trip-viewer-fresh"), takenAt: nil,
            mine: true, filename: "fresh.jpg")
        guard let selection = MediaViewerPresentation.viewer(for: [opened], startingAt: opened.uid)
        else {
            Issue.record("no viewer opened over a picture")
            return
        }
        let now = TripView.viewerSource(for: selection, members: [fresh], loaded: true).pages
        #expect(now.map(\.attachment.uid) == ["trip-viewer-fresh"])
        // Before the store holds the trip — not yet read, or a snapshot of a trip that is gone —
        // the pages the viewer opened with stand in.
        let unread = TripView.viewerSource(for: selection, members: [], loaded: false).pages
        #expect(unread.map(\.attachment.uid) == ["trip-viewer-opened"])
        // A trip read and found empty is empty: nothing it no longer holds comes back.
        let emptied = TripView.viewerSource(for: selection, members: [], loaded: true).pages
        #expect(emptied.isEmpty, "a trip read empty brought back \(emptied.map(\.attachment.uid))")
    }

    @Test("a viewer outlives its trip once the trip is read without ANY page it may be holding")
    func viewerOutlived() {
        let opened = MediaFixture.attachment(uid: "trip-viewer-opened")
        let paged = MediaFixture.attachment(uid: "trip-viewer-paged")
        let other = LibraryRow(
            attachment: MediaFixture.attachment(uid: "trip-viewer-other"), takenAt: nil,
            mine: true, filename: "other.jpg")
        let same = LibraryRow(attachment: opened, takenAt: nil, mine: true, filename: "o.jpg")
        let next = LibraryRow(attachment: paged, takenAt: nil, mine: true, filename: "p.jpg")
        guard let lone = MediaViewerPresentation.viewer(for: [opened], startingAt: opened.uid),
            let pair = MediaViewerPresentation.viewer(for: [opened, paged], startingAt: opened.uid)
        else {
            Issue.record("no viewer opened over a picture")
            return
        }
        #expect(TripView.viewerOutlived(lone, holding: [], members: [], loaded: true), "empty")
        #expect(
            TripView.viewerOutlived(lone, holding: [], members: [other], loaded: true),
            "read without the opened page")
        #expect(!TripView.viewerOutlived(lone, holding: [], members: [same, other], loaded: true))
        #expect(!TripView.viewerOutlived(lone, holding: [], members: [], loaded: false), "unread")
        // The opened page survives, a page it was opened with does not: the reader may be on it.
        #expect(
            TripView.viewerOutlived(pair, holding: [], members: [same], loaded: true),
            "a page the viewer opened with left the trip, and the viewer stayed")
        // Nor one handed to it since, by an earlier reading of the trip.
        #expect(
            TripView.viewerOutlived(
                lone, holding: ["trip-viewer-other"], members: [same], loaded: true),
            "a page an earlier reading handed the viewer left the trip, and the viewer stayed")
        #expect(
            !TripView.viewerOutlived(
                pair, holding: ["trip-viewer-other"], members: [next, other, same], loaded: true))
    }

    @Test("what a viewer holds grows by every reading of the trip, never by an unread one")
    func viewerHolds() {
        let opened = MediaFixture.attachment(uid: "trip-holds-opened")
        let other = LibraryRow(
            attachment: MediaFixture.attachment(uid: "trip-holds-other"), takenAt: nil,
            mine: true, filename: "other.jpg")
        guard let lone = MediaViewerPresentation.viewer(for: [opened], startingAt: opened.uid)
        else {
            Issue.record("no viewer opened over a picture")
            return
        }
        let first = TripView.viewerHolds(lone, earlier: [], members: [], loaded: false)
        #expect(first == ["trip-holds-opened"], "held \(first.sorted())")
        let read = TripView.viewerHolds(lone, earlier: ["gone"], members: [other], loaded: true)
        #expect(read == ["trip-holds-opened", "gone", "trip-holds-other"], "held \(read.sorted())")
        let unread = TripView.viewerHolds(lone, earlier: [], members: [other], loaded: false)
        #expect(unread == ["trip-holds-opened"], "an unread list was held: \(unread.sorted())")
    }

    @Test("Photos, Journal and Map are all open")
    func modes() {
        #expect(TripMode.allCases.map(\.title) == ["Photos", "Journal", "Map"])
        #expect(TripMode.allCases.filter(\.isAvailable) == [.photos, .journal, .map])
    }
}

// MARK: - The screen

/// The Trip screen over a scripted server: a three-page drain in `taken_asc`, two pictures a page
/// (the store's page size, injected, so three pages fit one screen), each on its own day.
@MainActor
@Suite("Trip screen", .serialized, .mediaGlobals)
struct TripScreenRenderTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-screen").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    /// This test's own picture store, transport, fetch table and retry signal, as the loader's
    /// own suite installs them: a picture another suite left in the store would never be asked for.
    private let identity = MediaIdentity()

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

    /// The day headings the Library would draw over p0 to p4, which a trip's grid draws none of.
    static let days = ["Thu 12 Mar", "Sat 14 Mar", "Mon 16 Mar", "Wed 18 Mar", "Fri 20 Mar"]
    /// Every member's tile, in the order the drain's pages came.
    static let files = ["p0", "p1", "p2", "p3", "p4"]

    private func stores(memberCap: Int = TripMemberStore.memberCap)
        -> (TripStore, TripMemberStore)
    {
        let trips = TripStore(identity: alice, root: root)
        return (trips, TripMemberStore(trips: trips, pageSize: 2, memberCap: memberCap))
    }

    /// `title` on the scripted server under `tag`, with its removals and its cover already made
    /// there, listed into the stores by a real refresh: the trip as listed.
    private func filed(
        _ stores: (TripStore, TripMemberStore), _ wire: TripWire, _ title: String, tag: String,
        excluding removed: [String] = [], cover: String? = nil
    ) async -> Trip {
        let uid = wire.transport.trips.seed(title, tag: tag, cover: cover)
        if !removed.isEmpty { wire.transport.trips.edit(uid) { $0.exclusions = removed } }
        await stores.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        return stores.0.trips.first { $0.uid == uid }
            ?? Trip(uid: uid, title: title, createdAt: .distantPast, updatedAt: .distantPast)
    }

    private func trip(
        _ stores: (TripStore, TripMemberStore), _ wire: TripWire,
        _ record: Trip, viewer: any MediaTransport = MediaSession.shared,
        shareLane: TripShareLane? = nil, manage: TripManage = TripManage()
    ) -> some View {
        let access = wire.access
        return NavigationStack {
            TripView(
                trip: record, trips: stores.0, memberStore: stores.1, identity: alice,
                access: { access }, manage: manage, viewerTransport: viewer, shareLane: shareLane)
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }

    @Test("the grid shows every page of the drain in taken order, and not the excluded picture")
    func threePagesInOrder() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(
            stores, wire, "Portugal 2026", tag: "portugal2026", excluding: ["p2"])
        var expected = Self.files
        expected.remove(at: 2)
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            _ = await screen.until { TripProbe.tiles(in: screen.window) == expected }
            #expect(TripProbe.tiles(in: screen.window) == expected)
            #expect(screen.says("Portugal 2026"))
            #expect(screen.says("4 photos"), "the hero counts the members, the excluded one not")
        }
    }

    @Test("the drain's requests name the trip, order=taken_asc and no tag or type, page after page")
    func theDrainsRequests() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            _ = await screen.until { wire.transport.listReads.count >= 3 }
            await screen.settle(turns: 4)
        }
        // What the app put on the wire, read from the member requests themselves.
        let sent = wire.transport.trips.calls(TripRows.members).map(\.path)
        #expect(sent.count == 3, "one read per page, \(sent)")
        for path in sent {
            #expect(path.hasPrefix("/api/collections/\(record.uid)/attachments?"), "\(path)")
            #expect(TripRows.query(path, "tag") == nil, "the member route named a tag: \(path)")
            #expect(TripRows.query(path, "type") == nil, "a kind was named: \(path)")
            #expect(TripRows.query(path, "order") == "taken_asc", "\(path)")
        }
        #expect(sent.map { TripRows.query($0, "cursor") } == [nil, "c1", "c2"])
    }

    /// The owner's rule (MEMNG-740): a trip is the Library's All without its days — every member
    /// a tile of one block, and no day heading over any of them.
    @Test("the grid is one block of every member, with no day heading over any of them")
    func theGridHasNoDays() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let drawn = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(drawn, "control: the members were drawn: \(TripProbe.tiles(in: screen.window))")
            let headings = TripProbe.headings(in: screen.window)
            #expect(headings.isEmpty, "the trip's grid drew the Library's days: \(headings)")
        }
    }

    /// A video of a tagged memo is a member (MEMNG-740), drawn as the Library draws one and opened
    /// the same way: the server, like the real one, leaves it out of a read that names images.
    @Test("a video member is a Video tile, and its tap opens the viewer")
    func aVideoMemberOpens() async {
        let wire = TripWire()
        wire.transport.film("p1")
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let drawn = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(drawn, "the video is not a member: \(TripProbe.tiles(in: screen.window))")
            let video = screen.element(labelled: "Video")
            #expect(video != nil, "no tile reads as a video")
            // Out of `#expect`: a closure in the macro's expansion can be refused by the compiler.
            let pressed = video.map { TripProbe.pressAtOnce($0) } ?? false
            #expect(pressed, "the video tile took no press")
            var pager: UIScrollView?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, pager == nil {
                pager = TripProbe.pager(over: screen.host)
                if pager == nil { await screen.settle(turns: 5) }
            }
            #expect(pager != nil, "the video's tap opened no viewer")
        }
    }

    @Test("a tag holding the query's own syntax stays off the member route, the order untouched")
    func aTagWithQuerySyntax() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Odd", tag: "a&order=taken_desc")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            _ = await screen.until { !wire.transport.listReads.isEmpty }
        }
        // The member route names the trip, not its tag: the tag never reaches the query, and
        // the one `order` is the app's own.
        let first = wire.transport.trips.calls(TripRows.members).first?.path ?? ""
        let items = URLComponents(string: first)?.queryItems ?? []
        #expect(first.hasPrefix("/api/collections/\(record.uid)/attachments?"), "\(first)")
        #expect(items.filter { $0.name == "order" }.map(\.value) == ["taken_asc"], "\(first)")
        #expect(!items.contains { $0.name == "tag" }, "the tag reached the query: \(first)")
        #expect(!first.contains("taken_desc"), "the tag's text reached the query: \(first)")
    }

    @Test("the hero shows the trip's chosen cover")
    func theHeroShowsTheCover() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026", cover: "p3")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let shown = await screen.until {
                CollectionsHost.identified(TripView.coverIdentifier("p3"), in: screen.window)
            }
            #expect(shown, "the hero does not draw the chosen cover p3")
            #expect(!CollectionsHost.identified(TripView.coverIdentifier("p0"), in: screen.window))
        }
    }

    @Test("a cover that was excluded gives way to the first member")
    func anExcludedCoverFallsBack() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(
            stores, wire, "Portugal 2026", tag: "portugal2026", excluding: ["p3"], cover: "p3")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let shown = await screen.until {
                CollectionsHost.identified(TripView.coverIdentifier("p0"), in: screen.window)
            }
            #expect(shown, "the hero does not fall back to the first member p0")
            #expect(!CollectionsHost.identified(TripView.coverIdentifier("p3"), in: screen.window))
        }
    }

    @Test("the chip row offers Photos, Journal and Map, every one enabled")
    func theChipRow() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            #expect(await screen.until { screen.element(labelled: "Photos") != nil })
            let journal = screen.element(labelled: "Journal")
            let map = screen.element(labelled: "Map")
            #expect(journal?.accessibilityTraits.contains(.notEnabled) == false)
            #expect(map?.accessibilityTraits.contains(.notEnabled) == false)
            #expect(
                screen.element(labelled: "Photos")?.accessibilityTraits.contains(.selected) == true)
            #expect(screen.element(labelled: TripView.manageButton) != nil, "no Manage menu")
            #expect(wire.transport.memoReads.isEmpty, "Photos read the journal")
        }
    }

    // MARK: - Select (MEMNG-721)

    /// The trip on a dock that says the Collections tab is on screen, its grid drained: all five
    /// pictures are on screen when `body` runs.
    private func selectingTrip(
        _ wire: TripWire, shareLane: TripShareLane? = nil,
        stores given: (TripStore, TripMemberStore)? = nil,
        _ body: (PressProbe.Screen, AppDock) async -> Void
    ) async {
        let dock = AppDock()
        dock.send(.selected(.collections))
        let stores = given ?? stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let view = trip(stores, wire, record, shareLane: shareLane).environment(dock)
        await CollectionsHost.with(view, height: 3000) { screen in
            _ = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(TripProbe.photos(in: screen.window).count == 5, "control: the grid landed")
            await body(screen, dock)
        }
    }

    /// Presses the navigation bar's `label` and waits until `ready`. The count line is text, not a
    /// control, so it is read with `says`: `element(labelled:)` finds buttons only.
    private func pressBar(
        _ label: String, on screen: PressProbe.Screen, until ready: () -> Bool
    ) async -> Bool {
        let pressed = CollectionsHost.pressBarItem(label, on: screen)
        #expect(pressed.took, "\(label) took no press: \(pressed.seen)")
        return await screen.until(ready)
    }

    /// The Library's select mode on the trip's grid: its toolbar stands where the main bar stood,
    /// because the dock's one bottom bar on Collections is select mode's, and Close gives it back.
    @Test("Select on a trip stands the Library's toolbar in the main bar's place; Close ends it")
    func selectOnATrip() async {
        await selectingTrip(TripWire()) { screen, dock in
            #expect(dock.bar(on: .collections) == .tabs, "control: the tabs stand before Select")
            #expect(!screen.says("0 Items Selected"))
            let entered = await pressBar("Select", on: screen) {
                screen.says("0 Items Selected")
            }
            #expect(entered, "Select stood no toolbar")
            let bar = dock.bar(on: .collections)
            #expect(bar == .select, "the dock reads \(bar)")
            #expect(
                MainTabs<EmptyView>.leadingShape(dock, on: .collections) == nil,
                "the main bar stands beside the toolbar")
            #expect(screen.element(labelled: TripView.manageButton) == nil, "Manage stayed")
            let left = await pressBar("Close", on: screen) {
                !screen.says("0 Items Selected")
            }
            #expect(left, "Close left the toolbar standing")
            #expect(dock.bar(on: .collections) == .tabs, "the tabs did not come back")
            #expect(screen.element(labelled: TripView.manageButton) != nil, "Manage did not return")
        }
    }

    /// Delete stays the Library's "only own" (2.2.1 (36)): another member's picture can be chosen
    /// and shared, never deleted; one of mine beside it makes Delete live, and the run sends mine
    /// alone, which then leaves the trip.
    @Test("a trip's Delete is off for another member's picture, and deletes only mine")
    func deleteOnlyOwnOnATrip() async {
        let wire = TripWire()
        wire.transport.others("p1")
        await selectingTrip(wire) { screen, dock in
            let entered = await pressBar("Select", on: screen) {
                screen.says("0 Items Selected")
            }
            #expect(entered, "Select stood no toolbar")
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[1]), "p1 took no press")
            #expect(await screen.until { screen.says("1 Item Selected") })
            let share = screen.element(labelled: "Share")
            let delete = screen.element(labelled: "Delete")
            #expect(share?.accessibilityTraits.contains(.notEnabled) == false, "Share is off")
            #expect(
                delete?.accessibilityTraits.contains(.notEnabled) == true,
                "Delete is offered for another member's picture")

            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[0]), "p0 took no press")
            #expect(await screen.until { screen.says("2 Items Selected") })
            let live = screen.element(labelled: "Delete")
            #expect(live?.accessibilityTraits.contains(.notEnabled) == false, "Delete stayed off")
            #expect(live?.accessibilityActivate() == true, "Delete took no press")
            let asked = await screen.until {
                TripProbe.dialogActions(in: screen.host)?.contains("Delete") == true
            }
            #expect(asked, "no question was asked")
            #expect(TripProbe.pressDialog("Delete", in: screen.host), "the alert had no Delete")
            let gone = await screen.until { TripProbe.photos(in: screen.window).count == 4 }
            #expect(gone, "the deleted picture stayed in the trip")
            #expect(wire.transport.deletes == ["/api/attachments/p0"], "\(wire.transport.deletes)")
        }
    }

    /// Share on a trip's selection: each chosen picture's ORIGINAL is fetched, in the order chosen,
    /// and the share sheet offers exactly those files, under the names they were uploaded as.
    @Test("a trip's Share fetches the chosen originals in the order chosen and offers just them")
    func shareOnATrip() async {
        let lane = TripShareRecorder()
        await selectingTrip(TripWire(), shareLane: lane.lane) { screen, _ in
            let entered = await pressBar("Select", on: screen) { screen.says("0 Items Selected") }
            #expect(entered, "Select stood no toolbar")
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[3]), "p3 took no press")
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[1]), "p1 took no press")
            #expect(await screen.until { screen.says("2 Items Selected") })
            #expect(screen.element(labelled: "Share")?.accessibilityActivate() == true)
            let offered = await screen.until { TripProbe.shareSheet(over: screen.host) != nil }
            #expect(offered, "no share sheet: asked \(lane.asked)")
            #expect(lane.asked == ["p3 original", "p1 original"], "asked \(lane.asked)")
            let sheet = TripProbe.shareSheet(over: screen.host)
            #expect(sheet.flatMap(TripProbe.sharedNames) == ["p3.jpg", "p1.jpg"])
        }
    }

    /// Close while Share is still fetching: the batch is let go, so its files are offered neither
    /// then nor over the next Select, and it asks for no further picture.
    @Test("Close while a trip's Share is fetching offers nothing, then or on the next Select")
    func closeAbandonsATripShare() async {
        let lane = TripShareRecorder()
        lane.holding = true
        await selectingTrip(TripWire(), shareLane: lane.lane) { screen, _ in
            let entered = await pressBar("Select", on: screen) { screen.says("0 Items Selected") }
            #expect(entered, "Select stood no toolbar")
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[0]), "p0 took no press")
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[2]), "p2 took no press")
            #expect(await screen.until { screen.says("2 Items Selected") })
            #expect(screen.element(labelled: "Share")?.accessibilityActivate() == true)
            #expect(await screen.until { lane.asked.count == 1 }, "the first file was not asked")
            let left = await pressBar("Close", on: screen) { !screen.says("2 Items Selected") }
            #expect(left, "Close left the toolbar standing")
            lane.holding = false
            await screen.settle(turns: 40)
            #expect(TripProbe.shareSheet(over: screen.host) == nil, "a sheet over a closed Select")
            let again = await pressBar("Select", on: screen) { screen.says("0 Items Selected") }
            #expect(again, "Select stood no toolbar the second time")
            await screen.settle(turns: 40)
            #expect(TripProbe.shareSheet(over: screen.host) == nil, "the left batch was offered")
            #expect(lane.asked == ["p0 original"], "the left batch asked on: \(lane.asked)")
        }
    }

    /// Select mode belongs to the grid: choosing Journal ends it, and the tabs come back.
    @Test("choosing Journal on a trip ends select mode and gives the tabs back")
    func journalEndsSelectOnATrip() async {
        await selectingTrip(TripWire()) { screen, dock in
            let entered = await pressBar("Select", on: screen) {
                screen.says("0 Items Selected")
            }
            #expect(entered, "Select stood no toolbar")
            #expect(TripProbe.pressAtOnce("Journal", on: screen), "the chip took no press")
            let ended = await screen.until {
                !screen.says("0 Items Selected")
                    && dock.bar(on: .collections) == .tabs
            }
            #expect(ended, "select mode outlived the grid: \(dock.bar(on: .collections))")
        }
    }

    // MARK: - Journal (MEMNG-718)

    /// The calendar the screen cuts days on in these tests: UTC, in British English.
    private static var journalCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    /// The heading the journal draws over the day of `stamp`.
    private static func journalHeading(_ stamp: String) -> String {
        let day = (try? Date(stamp, strategy: .iso8601)) ?? .distantPast
        return TimelineGrouping.title(for: day, calendar: journalCalendar)
    }

    @Test("Journal lists the trip's memos oldest first, as cards under a heading per day")
    func theJournalIsOldestFirst() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let texts = TripTransport.journal.map(\.text)
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let shown = await screen.until {
                TripProbe.tops(of: texts, in: screen.window).count == texts.count
            }
            #expect(shown, "the journal never drew: \(TripProbe.labels(in: screen.window))")
            #expect(
                TripProbe.tops(of: texts, in: screen.window) == texts,
                "the journal is not oldest first")
            let days = [TripTransport.journal[0].stamp, TripTransport.journal[2].stamp]
                .map(Self.journalHeading)
            #expect(
                TripProbe.tops(of: days, in: screen.window, exact: true) == days,
                "the day headings are not oldest first: \(TripProbe.labels(in: screen.window))")
            let journal = screen.element(labelled: "Journal")
            #expect(journal?.accessibilityTraits.contains(.selected) == true)
        }
        let reads = wire.transport.memoReads
        #expect(reads.count == 2, "one read per page: \(reads)")
        for query in reads {
            #expect(query["tag"] == "portugal2026")
            #expect(query["sort"] == "created_at")
        }
    }

    @Test("a journal stopped at the cap counts memos under the list, not photos")
    func theJournalCapFooter() async {
        let wire = TripWire()
        let stores = stores(memberCap: 2)
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let note = TripView.journalCapNote(.truncated, cap: 2) ?? "?"
            let said = await screen.until { screen.says(note) }
            #expect(said, "no memo cap note: \(TripProbe.labels(in: screen.window))")
            #expect(!screen.says(TripView.capNote(.truncated, cap: 2) ?? "?"), "it counts photos")
            #expect(stores.1.journalState(for: record) == .truncated)
        }
    }

    @Test("a trip whose tag no memo carries says its journal is empty")
    func anEmptyJournal() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Spain 2025", tag: "spain2025")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let said = await screen.until { screen.says(TripView.journalEmptyTitle) }
            #expect(said, "no empty line: \(TripProbe.labels(in: screen.window))")
            #expect(stores.1.journalState(for: record) == .complete)
        }
    }

    @Test("a journal card asks for its memo, the way the Library's Show Memo does")
    func aJournalCardOpensItsMemo() async {
        let wire = TripWire()
        let stores = stores()
        let jump = MemoJump()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let second = TripTransport.journal[1]
        let view = trip(stores, wire, record).environment(jump)
        await CollectionsHost.with(view, height: 3000) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let drawn = await screen.until {
                TripProbe.card(saying: second.text, in: screen.window) != nil
            }
            #expect(drawn, "no card says \(second.text)")
            let card = TripProbe.card(saying: second.text, in: screen.window)
            #expect(card?.accessibilityActivate() == true, "the card took no press")
            #expect(jump.pending == second.uid, "the card asked for \(jump.pending ?? "nothing")")
        }
    }

    /// A card's PHOTO stays on the trip (MEMNG-769): the viewer opens over this screen, over that
    /// memo's own two pictures, with the trip's menu and no memo asked for; Close lands back on the
    /// Journal, its card still drawn and its chip still chosen.
    @Test("a journal card's photo opens the viewer on the trip, and Close lands on the Journal")
    func aJournalPhotoOpensTheViewerHere() async {
        let wire = TripWire()
        wire.transport.pictureJournal()
        let stores = stores()
        let jump = MemoJump()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let second = TripTransport.journal[1]
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media).environment(jump)
        await CollectionsHost.with(view, height: 3000) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let drawn = await screen.until {
                TripProbe.card(saying: second.text, in: screen.window) != nil
            }
            #expect(drawn, "no card says \(second.text)")
            let card = TripProbe.card(saying: second.text, in: screen.window)
            let ran = card.map { TripProbe.runAction("Open photo", of: $0) } ?? false
            #expect(ran, "no Open photo ran: \(TripProbe.actionNames(of: card))")
            var pager: UIScrollView?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, pager == nil {
                pager = TripProbe.pager(over: screen.host)
                if pager == nil { await screen.settle(turns: 5) }
            }
            await screen.settle(turns: 20)
            let pages = pager.map(TripProbe.pageCount)
            #expect(pages == 2, "the viewer's pages: \(pages.map(String.init) ?? "no viewer")")
            #expect(jump.pending == nil, "the photo asked for memo \(jump.pending ?? "?")")
            let overlay = TripProbe.presentedLabels(over: screen.host)
            #expect(overlay.contains("More"), "the trip's viewer drew no menu: \(overlay)")
            #expect(
                screen.element(labelled: TripView.useAsCoverButton) == nil,
                "Use as Cover is drawn outside the menu")

            #expect(TripProbe.pressAtOnce("Close", on: screen), "the viewer has no Close")
            let closed = await screen.until(seconds: 10) {
                TripProbe.pager(over: screen.host) == nil
            }
            #expect(closed, "the viewer did not close")
            let back = await screen.until {
                TripProbe.card(saying: second.text, in: screen.window) != nil
            }
            #expect(back, "the Journal is gone: \(TripProbe.labels(in: screen.window))")
            let journal = screen.element(labelled: "Journal")
            #expect(journal?.accessibilityTraits.contains(.selected) == true)
            #expect(jump.pending == nil, "closing asked for memo \(jump.pending ?? "?")")
        }
    }

    /// The Journal's viewer re-signs as the grid's does: a page whose signature lapsed reads the
    /// trip again, and the open viewer takes the copy that read signed. The memo's pictures are
    /// refused before the card draws them, so the viewer's page is one nothing has loaded yet.
    @Test("a journal viewer whose page lapsed shows the copy the trip was read again for")
    func aJournalViewerFollowsTheRedrain() async {
        let wire = TripWire()
        wire.transport.pictureJournal()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let second = TripTransport.journal[1]
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media).environment(MemoJump())
        await CollectionsHost.with(view, height: 3000) { screen in
            let gridded = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(gridded, "the trip was not drawn")
            // Every signature the first reads hand out lapses; the memo is still read under v1.
            await media.revoke("v1")
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let drawn = await screen.until {
                TripProbe.card(saying: second.text, in: screen.window) != nil
            }
            #expect(drawn, "no card says \(second.text)")
            // From here the server signs anew.
            wire.transport.resign("v2")
            let card = TripProbe.card(saying: second.text, in: screen.window)
            let ran = card.map { TripProbe.runAction("Open photo", of: $0) } ?? false
            #expect(ran, "no Open photo ran: \(TripProbe.actionNames(of: card))")
            let lapsed = await TripProbe.settled(seconds: 10) {
                await media.asked("p1", "mobile", sig: "v1") >= 1
            }
            let seen = await media.log()
            #expect(lapsed, "the viewer never asked for p1 under v1: \(seen)")
            let followed = await TripProbe.settled(seconds: 10) {
                await media.asked("p1", "mobile", sig: "v2") >= 1
            }
            #expect(followed, "the Journal's viewer never took p1's new signature")
        }
    }

    @Test("a drain stopped at the cap says so under the grid")
    func theCapFooter() async {
        let wire = TripWire()
        let stores = stores(memberCap: 3)
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let note = TripView.capNote(.truncated, cap: 3) ?? "?"
            #expect(await screen.until { screen.says(note) })
            #expect(stores.1.state(for: record) == .truncated)
        }
    }

    @Test("a drain that failed says why, and never that the trip is empty")
    func aFailedDrain() async {
        let wire = TripWire()
        wire.transport.fail()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            _ = await screen.until { stores.1.lastError != nil }
            let error = stores.1.lastError ?? "?"
            #expect(await screen.until { screen.says(error) }, "the failure is not on screen")
            #expect(!screen.says(TripView.emptyTitle))
        }
    }

    @Test("a viewer open over the trip shows the page the trip was read again for")
    func anOpenViewerFollowsTheRedrain() async {
        let wire = TripWire()
        let stores = stores()
        // The cover is p4 at the viewer's tier, so the page opened — p0, the first tile — is a
        // picture nothing has loaded at that tier yet.
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026", cover: "p4")
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media)
        await CollectionsHost.with(view, height: 3000) { screen in
            let drawn = await TripProbe.settled(seconds: 10) { await media.drewTheGrid() }
            #expect(drawn, "the grid and the cover never loaded under the first signatures")
            // Every signature the first read handed out lapses, and the server signs anew.
            await media.revoke("v1")
            wire.transport.resign("v2")
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.count == 5, "the grid's tiles: \(photos.count)")
            #expect(photos.first.map(TripProbe.pressAtOnce) == true, "p0's tile took no press")
            let lapsed = await TripProbe.settled(seconds: 10) {
                await media.asked("p0", "mobile", sig: "v1") >= 1
            }
            let seen = await media.log()
            let shown = TripProbe.presentation(screen)
            #expect(lapsed, "the viewer never asked for p0 under v1: \(seen) \(shown)")
            let followed = await TripProbe.settled(seconds: 10) {
                await media.asked("p0", "mobile", sig: "v2") >= 1
            }
            #expect(followed, "the open viewer never took p0's new signature")
            #expect(wire.transport.listReads.count >= 6, "the trip was not read again")
        }
    }

    @Test("a viewer open over a trip that is read again empty closes, rather than keep its pages")
    func anOpenViewerClosesOnAnEmptiedTrip() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026", cover: "p4")
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media)
        await CollectionsHost.with(view, height: 3000) { screen in
            let drawn = await TripProbe.settled(seconds: 10) { await media.drewTheGrid() }
            #expect(drawn, "the grid and the cover never loaded under the first signatures")
            // The signatures lapse, and the trip's tag has meanwhile left every picture.
            await media.revoke("v1")
            wire.transport.resign("v2")
            wire.transport.empty()
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.first.map(TripProbe.pressAtOnce) == true, "p0's tile took no press")
            let opened = await TripProbe.settled(seconds: 10) {
                await media.asked("p0", "mobile", sig: "v1") >= 1
            }
            #expect(opened, "the viewer never opened on p0")
            let reread = await TripProbe.settled(seconds: 10) {
                wire.transport.listReads.count >= 4 && stores.1.members(for: record).isEmpty
            }
            #expect(reread, "the trip was not read again empty")
            var closed = false
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !closed {
                let presented = screen.host.presentedViewController
                closed = presented == nil || presented?.isBeingDismissed == true
                try? await Task.sleep(for: .milliseconds(50))
            }
            let shown = TripProbe.presentation(screen)
            #expect(closed, "the viewer stayed open over a trip read empty: \(shown)")
        }
    }

    @Test(
        "a viewer open over a trip read again without a page it holds closes, the opened one kept")
    func anOpenViewerClosesOnAPartlyEmptiedTrip() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026", cover: "p4")
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media)
        await CollectionsHost.with(view, height: 3000) { screen in
            let drawn = await TripProbe.settled(seconds: 10) { await media.drewTheGrid() }
            #expect(drawn, "the grid and the cover never loaded under the first signatures")
            // The signatures lapse, and the trip's tag has meanwhile left p1 — only p1.
            await media.revoke("v1")
            wire.transport.resign("v2")
            wire.transport.drop("p1")
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.first.map(TripProbe.pressAtOnce) == true, "p0's tile took no press")
            let opened = await TripProbe.settled(seconds: 10) {
                await media.asked("p0", "mobile", sig: "v1") >= 1
            }
            #expect(opened, "the viewer never opened on p0")
            let reread = await TripProbe.settled(seconds: 10) {
                stores.1.members(for: record).map(\.id) == ["p0", "p2", "p3", "p4"]
            }
            #expect(reread, "the trip was not read again without p1, p0 kept")
            var closed = false
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !closed {
                let presented = screen.host.presentedViewController
                closed = presented == nil || presented?.isBeingDismissed == true
                try? await Task.sleep(for: .milliseconds(50))
            }
            let shown = TripProbe.presentation(screen)
            #expect(closed, "the viewer stayed open holding p1, which left the trip: \(shown)")
        }
    }

    @Test("a lapsed signature on the trip reads the trip again")
    func aLapsedSignatureRedrains() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await stores.1.drain(record, using: wire.access.handle, baseURL: TripWire.baseURL)
        #expect(wire.transport.listReads.count == 3, "precondition: one drain")
        let access = wire.access
        let refresher = TripURLRefresher(
            members: stores.1, trips: stores.0, uid: record.uid,
            session: IssuingSession(handle: { access.handle }, baseURL: { access.baseURL }))
        let sameOwner = ObjectIdentifier(refresher.owner) == ObjectIdentifier(stores.1)
        #expect(sameOwner, "the refresher answers for the trip store")
        refresher.signatureExpired(uid: "p1")
        for _ in 0..<200 where wire.transport.listReads.count < 6 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(wire.transport.listReads.count == 6, "the trip was not read again")
    }

    @Test("Delete returns to the root, and the trip is gone; the other trip stays")
    func deleteReturnsToTheRoot() async {
        let wire = TripWire()
        let stores = stores()
        let other = await filed(stores, wire, "Spain 2025", tag: "spain2025")
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let manage = TripManage()
        let access = wire.access
        let stack = TripStackLog()
        let view = TripStack(log: stack) { trail in
            CollectionsScreen(
                trips: stores.0, members: stores.1, tags: LibraryTagStore(), identity: alice,
                access: { access }, openTag: { _ in }, trail: trail, tripManage: { manage })
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        await CollectionsHost.with(view, height: 3000) { screen in
            #expect(await screen.until { screen.element(labelled: "Portugal 2026") != nil })
            // Pushed without its animation: a hand-hosted window does not reliably finish one (see
            // StackChromeTests), and the transition is not what is under test.
            #expect(TripProbe.pressAtOnce("Portugal 2026", on: screen), "the card is not a link")
            // Every distinct reading on the way, for the failure's message.
            var seen: [[String]] = []
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, seen.last != Self.files {
                let now = TripProbe.tiles(in: screen.window)
                if seen.last != now { seen.append(now) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            let pushed = seen.last == Self.files
            #expect(pushed, "the trip was not pushed: \(seen)")
            #expect(stack.paths.last?.count == 1, "the stack went \(stack.paths.map(\.count))")
            // The menu's Delete Trip asks; the dialog's yes is the flow's confirm.
            manage.askDelete()
            // Read in the loop's own condition rather than through a closure — the same wait written
            // with `idle` timed out on an alert that was up on the next line.
            var trace: [String] = []
            let askDeadline = Date().addingTimeInterval(4)
            while Date() < askDeadline, TripProbe.dialogActions(in: screen.host) == nil {
                let now = TripProbe.presentation(screen)
                if trace.last != now { trace.append(now) }
                try? await Task.sleep(for: .milliseconds(100))
            }
            trace.append("after: " + TripProbe.presentation(screen))
            let asked = TripProbe.dialogActions(in: screen.host) != nil
            trace.append("after2: " + TripProbe.presentation(screen))
            #expect(asked, "no confirmation was presented: \(trace)")
            #expect(
                TripProbe.dialogActions(in: screen.host)?.contains(TripView.deleteButton) == true)
            // The alert's own Delete Trip: the yes travels the action the alert runs, and the
            // alert goes on its way out as it would under a finger.
            #expect(
                TripProbe.pressDialog(TripView.deleteButton, in: screen.host),
                "the alert's Delete Trip took no press")
            let back = await TripProbe.idle(seconds: 10) {
                TripProbe.tiles(in: screen.window).isEmpty
                    && screen.element(labelled: "Spain 2025") != nil
            }
            #expect(back, "the screen did not return: \(TripProbe.labels(in: screen.window))")
        }
        #expect(stores.0.trips.map(\.uid) == [other.uid])
        #expect(wire.transport.trips.rows.map(\.uid) == [other.uid], "the server kept the trip")
    }

    /// A press on Collections while it shows takes its stack back to the root (MEMNG-781): through
    /// the bar's own press binding and the dock, into the root's own stack. A press on another
    /// tab, and the press that comes back to Collections from there, leave the trip pushed.
    @Test("a press on the selected Collections tab pops the trip; a press elsewhere does not")
    func reselectingCollectionsPopsToTheRoot() async {
        let wire = TripWire()
        let stores = stores()
        _ = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let access = wire.access
        let dock = AppDock()
        let stack = TripStackLog()
        let view = TrailHost(log: stack) { trail in
            CollectionsRootView.stack(trail: trail) {
                CollectionsScreen(
                    trips: stores.0, members: stores.1, tags: LibraryTagStore(), identity: alice,
                    access: { access }, openTag: { _ in }, trail: trail)
            }
        }
        .environment(dock)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        await CollectionsHost.with(view, height: 3000) { screen in
            let listed = await screen.until { screen.element(labelled: "Portugal 2026") != nil }
            #expect(listed, "the trip's card was not drawn")
            #expect(TripProbe.pressAtOnce("Portugal 2026", on: screen), "the card is not a link")
            let pushed = await screen.until { stack.paths.last?.count == 1 }
            #expect(pushed, "the trip was not pushed: \(stack.paths.map(\.count))")
            // The bar's press binding over a selection that shows Collections.
            let bar = MainTabs<EmptyView>.pressing(
                selection: .constant(.collections), dock: dock)
            bar.wrappedValue = .timeline
            dock.send(.pressedTab(.collections, showing: .timeline))
            let early = await screen.until(seconds: 1) { stack.paths.last?.isEmpty == true }
            #expect(!early, "a press from another tab popped the stack")
            bar.wrappedValue = .collections
            let popped = await screen.until { stack.paths.last?.isEmpty == true }
            #expect(popped, "the re-tap left the stack at \(stack.paths.map(\.count))")
        }
    }

    @Test("the root's drain and the trip's are one request chain")
    func theDrainsJoin() async {
        let wire = TripWire()
        wire.transport.hold()
        let stores = stores()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026")
        let access = wire.access
        let view = NavigationStack {
            CollectionsScreen(
                trips: stores.0, members: stores.1, tags: LibraryTagStore(), identity: alice,
                access: { access }, openTag: { _ in })
        }
        await CollectionsHost.with(view, height: 3000) { screen in
            _ = await screen.until { wire.transport.listReads.count == 1 }
            #expect(screen.press("Portugal 2026"), "the card is not a link")
            // The trip's own drain is asked while the root's is still on the wire.
            await screen.settle(turns: 10)
            wire.transport.release()
            _ = await screen.until { TripProbe.tiles(in: screen.window) == Self.files }
            #expect(TripProbe.tiles(in: screen.window) == Self.files)
        }
        #expect(wire.transport.listReads.filter { $0["cursor"] == nil }.count == 1)
    }

    // MARK: The viewer over the members, and the main bar (MEMNG-715)

    /// What the trip's viewer's Use as Cover row does with a member's uid; false for a non-member.
    typealias Cover = (String) -> Bool

    /// The trip with p2 or p4 excluded, its grid drawn, and a tile's tap opening the viewer: the
    /// pager and the trip's members, for the viewer tests below.
    private func openViewer(
        excluding excluded: String, at tile: Int, jump: MemoJump,
        _ body: (PressProbe.Screen, UIScrollView?, TripMediaServer, [String], Cover) async -> Void
    ) async {
        let wire = TripWire()
        wire.transport.nameNoOriginal()
        let stores = stores()
        let record = await filed(
            stores, wire, "Portugal 2026", tag: "portugal2026", excluding: [excluded])
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media).environment(jump)
        let access = wire.access
        await CollectionsHost.with(view, height: 3000) { screen in
            let live = { stores.0.trips.first { $0.uid == record.uid } ?? record }
            let drained = await TripProbe.settled(seconds: 10) {
                stores.1.state(for: live()) == .complete
                    && TripProbe.photos(in: screen.window).count == 4
            }
            let members = stores.1.members(for: live()).map(\.id)
            #expect(drained, "the trip was not drawn: \(members)")
            let photos = TripProbe.photos(in: screen.window)
            #expect(
                photos.indices.contains(tile) && TripProbe.pressAtOnce(photos[tile]),
                "tile \(tile) of \(photos.count) took no press")
            var pager: UIScrollView?
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, pager == nil {
                pager = TripProbe.pager(over: screen.host)
                if pager == nil { await screen.settle(turns: 5) }
            }
            await screen.settle(turns: 20)
            // The trip's own action, run as the viewer's menu row runs it: a menu cannot be opened
            // from a test, so the row's dispatch is `MediaViewerHostItem.tapped()`.
            let cover: Cover = { uid in
                let rows = stores.1.members(for: live())
                guard let row = rows.first(where: { $0.id == uid }) else { return false }
                let action = TripView.useAsCover(
                    record.uid, in: stores.0, manage: TripManage(), access: { access })
                MediaViewerHostItem(action: action, attachment: row.attachment) {}.tapped()
                return true
            }
            await body(screen, pager, media, members, cover)
        }
    }

    /// The viewer's pages are the members the grid shows, never the drained list with the
    /// excluded picture back in it: four pages, and the page after p1 is p3 — read by the still
    /// the viewer asks for, the excluded p2's never.
    @Test("the trip's viewer pages over its members: after p1 comes p3, never the excluded p2")
    func theViewerSkipsTheExcluded() async {
        let jump = MemoJump()
        await openViewer(excluding: "p2", at: 1, jump: jump) { screen, pager, media, members, _ in
            #expect(members == ["p0", "p1", "p3", "p4"], "the members: \(members)")
            let pages = pager.map(TripProbe.pageCount)
            let raw = pager.map { "\($0.contentSize) in \($0.bounds.size)" } ?? "no pager"
            let counted = pages.map(String.init) ?? "none"
            #expect(pages == members.count, "the viewer's pages: \(counted), \(raw)")
            // From p1's page — the member before the excluded one — one page on.
            if let pager { await TripProbe.page(pager, to: 1, on: screen) }
            #expect(pager.map(TripProbe.pageIndex) == 1, "the pager is not on p1's page")
            if let pager { await TripProbe.page(pager, to: 2, on: screen) }
            #expect(pager.map(TripProbe.pageIndex) == 2, "the pager did not move one page on")
            // p3's still is what the viewer asks for. Its Show Memo said so before, and is now a
            // row of the menu the trip's Use as Cover makes (MEMNG-768): no test opens a menu.
            let drew = await TripProbe.settled(seconds: 5) {
                await media.asked("p3", "mobile", sig: "v1") >= 1
            }
            #expect(drew, "the page after p1 drew no p3 — the drained list?")
            let asked = await media.asked("p2", "mobile", sig: "v1")
            let log = await media.log()
            #expect(asked == 0, "the viewer drew the excluded p2: \(log)")
        }
    }

    /// The edge of the list: the last picture excluded, the viewer opened on the last member has
    /// no page after it — the pager ends where the grid does.
    @Test("a trip whose last picture is excluded ends its viewer at the last member")
    func theViewerEndsAtTheLastMember() async {
        let jump = MemoJump()
        await openViewer(excluding: "p4", at: 3, jump: jump) { screen, pager, media, members, _ in
            #expect(members == ["p0", "p1", "p2", "p3"], "the members: \(members)")
            let raw = pager.map { "\($0.contentSize) in \($0.bounds.size)" } ?? "no pager"
            #expect(pager.map(TripProbe.pageCount) == 4, "the viewer's pages: \(raw)")
            let opened = await TripProbe.settled(seconds: 5) { pager.map(TripProbe.pageIndex) == 3 }
            #expect(opened, "the viewer is not on its last page")
            // The last member's still, read as the test above reads it.
            let drew = await TripProbe.settled(seconds: 5) {
                await media.asked("p3", "mobile", sig: "v1") >= 1
            }
            #expect(drew, "the last page drew no p3")
        }
    }

    /// The Collections root with its dock, a trip pushed from its card the way a finger does.
    private func pushedTrip(
        dock: AppDock, _ body: (PressProbe.Screen, UIScrollView?) async -> Void
    ) async {
        let wire = TripWire()
        let stores = stores()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026")
        let access = wire.access
        let stack = TripStackLog()
        let view = TripStack(log: stack) { trail in
            CollectionsScreen(
                trips: stores.0, members: stores.1, tags: LibraryTagStore(), identity: alice,
                access: { access }, openTag: { _ in }, trail: trail)
        }
        .environment(dock)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        await CollectionsHost.with(view, height: 700) { screen in
            #expect(await screen.until { screen.element(labelled: "Portugal 2026") != nil })
            #expect(TripProbe.pressAtOnce("Portugal 2026", on: screen), "the card is not a link")
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, stack.paths.last?.count != 1 {
                await screen.settle(turns: 5)
            }
            let pushed = stack.paths.last?.count == 1
            #expect(pushed, "the trip was not pushed: \(stack.paths.map(\.count))")
            await screen.settle(turns: 40)
            await body(screen, TripProbe.mainScroll(in: screen.window))
        }
    }

    /// The Trip screen stands in the Collections tab's stack under the one main bar: its foot
    /// clears the bar, and its scroll folds and unfolds the bar the way the Timeline's does,
    /// through the dock's existing fold reading.
    @Test("the Trip screen clears the main bar, and its scroll folds and unfolds it")
    func theTripScreenFoldsTheBar() async {
        let dock = AppDock()
        dock.send(.selected(.collections))
        await pushedTrip(dock: dock) { screen, scroller in
            #expect(scroller != nil, "no scroll view on the Trip screen")
            let foot = scroller?.adjustedContentInset.bottom ?? 0
            #expect(foot >= LeadingMainBar.height, "the trip's foot runs under the bar: \(foot)")
            var shapes = [MainTabs<EmptyView>.leadingShape(dock, on: .collections)]
            if let scroller { await TripProbe.drag(scroller, by: 240, on: screen) }
            shapes.append(MainTabs<EmptyView>.leadingShape(dock, on: .collections))
            if let scroller {
                let top = -scroller.adjustedContentInset.top
                await TripProbe.drag(scroller, by: top - scroller.contentOffset.y, on: screen)
            }
            shapes.append(MainTabs<EmptyView>.leadingShape(dock, on: .collections))
            #expect(shapes == [.tabs, .folded, .tabs], "the bar went \(shapes)")
            #expect(dock.mode == .tabs)
        }
    }

    /// The trip's scroll is the Collections tab's: while the dock says another tab is on screen —
    /// its own feed the one that counts — the trip's drag folds nothing.
    @Test("a trip scroll heard while another tab shows folds nothing")
    func aTripScrollUnderAnotherTabFoldsNothing() async {
        let dock = AppDock()
        dock.send(.selected(.timeline))
        await pushedTrip(dock: dock) { screen, scroller in
            #expect(scroller != nil, "no scroll view on the Trip screen")
            if let scroller { await TripProbe.drag(scroller, by: 240, on: screen) }
            #expect(dock.mode == .tabs, "the trip's drag moved the dock to \(dock.mode)")
        }
    }
}

// MARK: - Probes

/// A stack whose path the test's screen is handed, as the Collections tab hands its own.
struct TripStack<Root: View>: View {
    var log = TripStackLog()
    @ViewBuilder let root: (Binding<[TripRoute]>) -> Root
    @State private var trail: [TripRoute] = []

    var body: some View {
        NavigationStack(path: $trail) { root($trail) }
            .onChange(of: trail, initial: true) { _, now in log.paths.append(now) }
    }
}

/// A trail the test's root makes its own stack over, as the Collections tab owns its own.
struct TrailHost<Root: View>: View {
    var log = TripStackLog()
    @ViewBuilder let root: (Binding<[TripRoute]>) -> Root
    @State private var trail: [TripRoute] = []

    var body: some View {
        root($trail)
            .onChange(of: trail, initial: true) { _, now in log.paths.append(now) }
    }
}

/// Every path the test's stack has held, in order.
@MainActor
final class TripStackLog {
    var paths: [[TripRoute]] = []
}

@MainActor
enum TripProbe {
    /// What UIKit presents, in every window of the scene, for a failure's message: a wait for the
    /// confirmation was seen to read nothing to its deadline and the alert on the line after.
    static func presentation(_ screen: PressProbe.Screen) -> String {
        var parts: [String] = []
        let windows = screen.window.windowScene?.windows ?? [screen.window]
        for window in windows {
            var chain: [String] = []
            var next = window.rootViewController
            while let controller = next {
                chain.append(
                    "\(type(of: controller))(tc=\(controller.transitionCoordinator != nil),"
                        + "pres=\(controller.isBeingPresented),dis=\(controller.isBeingDismissed))")
                next = controller.presentedViewController
            }
            parts.append("w\(window === screen.window ? "*" : "")[\(chain.joined(separator: ">"))]")
        }
        return parts.joined(separator: " ")
    }

    /// Waits for an answer that has to be awaited, leaving the screen alone between asks.
    static func settled(seconds: TimeInterval, _ ready: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await ready() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await ready()
    }

    /// The grid's tiles, top to bottom and then leading to trailing, one node per place.
    static func photos(in window: UIWindow) -> [NSObject] {
        var found: [CGRect: NSObject] = [:]
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.accessibilityLabel == "Photo", found[object.accessibilityFrame] == nil {
                found[object.accessibilityFrame] = object
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found.sorted {
            ($0.key.minY, $0.key.minX) < ($1.key.minY, $1.key.minX)
        }.map(\.value)
    }

    /// Activates `element` with whatever it changes applied without animation.
    static func pressAtOnce(_ element: NSObject) -> Bool {
        var instant = Transaction()
        instant.disablesAnimations = true
        return withTransaction(instant) { element.accessibilityActivate() }
    }

    /// `press`, with whatever it changes applied without animation.
    static func pressAtOnce(_ label: String, on screen: PressProbe.Screen) -> Bool {
        var instant = Transaction()
        instant.disablesAnimations = true
        return withTransaction(instant) { screen.press(label) }
    }

    /// Waits for `ready` while leaving the screen alone: `until` lays the window out on every turn.
    static func idle(seconds: TimeInterval, _ ready: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ready()
    }

    /// The loaded tiles' files, top to bottom and then leading to trailing, read by the identifier
    /// each tile carries (`LibraryGrid.tileIdentifier`), since no label says which file it shows.
    static func tiles(in window: UIWindow) -> [String] {
        let prefix = LibraryGrid.tileIdentifier("")
        var found: [String: CGRect] = [:]
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.responds(to: Selector(("accessibilityIdentifier"))),
                let identifier = object.value(forKey: "accessibilityIdentifier") as? String,
                identifier.hasPrefix(prefix)
            {
                let uid = String(identifier.dropFirst(prefix.count))
                if found[uid] == nil { found[uid] = object.accessibilityFrame }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found.sorted {
            ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX)
        }.map(\.key)
    }

    /// The day headings on screen, top to bottom.
    static func headings(in window: UIWindow) -> [String] {
        let wanted = Set(TripScreenRenderTests.days)
        var found: [String: CGFloat] = [:]
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel, wanted.contains(label), found[label] == nil {
                found[label] = object.accessibilityFrame.minY
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found.sorted { $0.value < $1.value }.map(\.key)
    }

    /// Which of `needles` are on screen, top to bottom: a node whose label holds one (or IS one,
    /// `exact`) stands at its highest such node.
    static func tops(of needles: [String], in window: UIWindow, exact: Bool = false) -> [String] {
        var found: [String: CGFloat] = [:]
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel {
                for needle in needles where exact ? label == needle : label.contains(needle) {
                    let top = object.accessibilityFrame.minY
                    found[needle] = min(found[needle] ?? top, top)
                }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found.sorted { $0.value < $1.value }.map(\.key)
    }

    /// The memo card whose label holds `text`: the node that is a button, as a card reads.
    static func card(saying text: String, in window: UIWindow) -> NSObject? {
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel, label.contains(text),
                object.accessibilityTraits.contains(.button)
            {
                return object
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// Whether a node on screen carries `identifier`, read after its label as VoiceOver would:
    /// a pushed screen's nodes answered their identifier only once their label had been asked.
    static func identified(_ identifier: String, in window: UIWindow) -> Bool {
        labels(in: window).contains("#" + identifier)
    }

    /// Every label and identifier on screen, for a failure's message.
    static func labels(in window: UIWindow) -> [String] {
        var found: [String] = []
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
            if object.responds(to: Selector(("accessibilityIdentifier"))),
                let id = object.value(forKey: "accessibilityIdentifier") as? String, !id.isEmpty
            {
                found.append("#" + id)
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    /// Runs the action titled `label` of the alert presented over `host` — its handler, with the
    /// alert's own dismissal started just before it — and says whether there was one to run. The
    /// handler is read by key: the action's view answers no `accessibilityActivate`. Not UIKit's
    /// order for a tap, which `pressAlert` keeps: there the handler runs after the alert has gone.
    static func pressDialog(_ label: String, in host: UIViewController) -> Bool {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        var next = host.presentedViewController
        while let controller = next, !(controller is UIAlertController) {
            next = controller.presentedViewController
        }
        guard let alert = next as? UIAlertController,
            let action = alert.actions.first(where: { $0.title == label }),
            let block = action.value(forKey: "handler") as AnyObject?
        else { return false }
        alert.dismiss(animated: true)
        unsafeBitCast(block, to: Handler.self)(action)
        return true
    }

    /// Runs the action titled `label` in the order UIKit runs a tap on an alert: the alert is
    /// dismissed FIRST and the handler runs once it has gone. `pressDialog` runs the handler while
    /// the dismissal is still animating, and a handler that raises the next question then presents
    /// it over an alert that is still leaving — UIKit drops that presentation ("already
    /// presenting"), and the test sees a question nobody asked. A person's tap never produces that
    /// order, so the sign-out tests press this way.
    static func pressAlert(_ label: String, in host: UIViewController) -> Bool {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        var next = host.presentedViewController
        while let controller = next, !(controller is UIAlertController) {
            next = controller.presentedViewController
        }
        guard let alert = next as? UIAlertController,
            let action = alert.actions.first(where: { $0.title == label }),
            let block = action.value(forKey: "handler") as AnyObject?
        else { return false }
        let handler = unsafeBitCast(block, to: Handler.self)
        alert.dismiss(animated: true) { handler(action) }
        return true
    }

    /// The share sheet presented over `host`, if one is: the activity controller in the chain of
    /// presentations, or among the children of one of them.
    static func shareSheet(over host: UIViewController) -> UIActivityViewController? {
        var next = host.presentedViewController
        while let controller = next {
            var stack = [controller]
            while let candidate = stack.popLast() {
                if let sheet = candidate as? UIActivityViewController { return sheet }
                stack.append(contentsOf: candidate.children)
            }
            next = controller.presentedViewController
        }
        return nil
    }

    /// The names of the files `sheet` was handed, read from the controller itself; nil when this
    /// system's controller does not keep them where key-value coding can read them.
    static func sharedNames(_ sheet: UIActivityViewController) -> [String]? {
        let held =
            class_getInstanceVariable(UIActivityViewController.self, "_activityItems") != nil
            || sheet.responds(to: NSSelectorFromString("activityItems"))
        guard held, let items = sheet.value(forKey: "activityItems") as? [Any] else { return nil }
        return items.compactMap { ($0 as? URL)?.lastPathComponent }
    }

    /// The titles of the actions of the alert or dialog presented over `host`, if one is.
    static func dialogActions(in host: UIViewController) -> [String]? {
        var next = host.presentedViewController
        while let controller = next {
            if let alert = controller as? UIAlertController {
                return alert.actions.compactMap(\.title)
            }
            next = controller.presentedViewController
        }
        return nil
    }

    /// The viewer's pager: the horizontal scroll view of the cover presented over `host`.
    static func pager(over host: UIViewController) -> UIScrollView? {
        guard let root = host.presentedViewController?.view else { return nil }
        var stack: [UIView] = [root]
        var best: UIScrollView?
        while let view = stack.popLast() {
            if let scroller = view as? UIScrollView, scroller.window != nil,
                scroller.bounds.width > 0,
                scroller.contentSize.width > scroller.bounds.width * 1.5,
                scroller.contentSize.width > (best?.contentSize.width ?? 0)
            {
                best = scroller
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }

    /// How many pages the pager holds, a page being its own width.
    static func pageCount(_ pager: UIScrollView) -> Int {
        Int((pager.contentSize.width / pager.bounds.width).rounded())
    }

    /// The page the pager stands on.
    static func pageIndex(_ pager: UIScrollView) -> Int {
        Int((pager.contentOffset.x / pager.bounds.width).rounded())
    }

    /// Swipes the pager to page `index`: the moves a finger makes, told to the delegate as a drag
    /// that begins and ends around them, so the pager settles where a swipe would leave it.
    static func page(_ pager: UIScrollView, to index: Int, on screen: PressProbe.Screen) async {
        let from = pager.contentOffset.x
        let to = CGFloat(index) * pager.bounds.width
        pager.delegate?.scrollViewWillBeginDragging?(pager)
        for step in 1...5 {
            let x = from + (to - from) * CGFloat(step) / 5
            pager.setContentOffset(CGPoint(x: x, y: pager.contentOffset.y), animated: false)
            await screen.settle(turns: 2)
        }
        var target = pager.contentOffset
        pager.delegate?.scrollViewWillEndDragging?(
            pager, withVelocity: .zero, targetContentOffset: &target)
        pager.setContentOffset(target, animated: false)
        pager.delegate?.scrollViewDidEndDragging?(pager, willDecelerate: false)
        await screen.settle(turns: 30)
    }

    /// The tallest scroll view on screen that scrolls up and down: the pushed screen's own.
    static func mainScroll(in window: UIWindow) -> UIScrollView? {
        var best: UIScrollView?
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let scroller = view as? UIScrollView, scroller.window != nil,
                !(scroller is UITextView), !view.isHidden,
                scroller.contentSize.width <= scroller.bounds.width + 1,
                scroller.bounds.height > (best?.bounds.height ?? window.bounds.height / 2)
            {
                best = scroller
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }

    /// Drags `scroller` by `distance` from where it stands, as `LibraryChromeRenderTests` drags
    /// the Timeline: the moves a finger makes, told to the delegate as a drag that begins and
    /// ends around them, so the scroll phase is the reader's and not the layout's.
    static func drag(
        _ scroller: UIScrollView, by distance: CGFloat, on screen: PressProbe.Screen
    ) async {
        let from = scroller.contentOffset.y
        scroller.delegate?.scrollViewWillBeginDragging?(scroller)
        for step in 1...5 {
            let y = from + distance * CGFloat(step) / 5
            scroller.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            await screen.settle(turns: 2)
            try? await Task.sleep(for: .milliseconds(25))
        }
        var target = scroller.contentOffset
        scroller.delegate?.scrollViewWillEndDragging?(
            scroller, withVelocity: .zero, targetContentOffset: &target)
        scroller.delegate?.scrollViewDidEndDragging?(scroller, willDecelerate: false)
        await screen.settle(turns: 40)
    }

    /// Presses `item`: drawn as itself when it is the one action, else a row of the `menu` the
    /// control opens. Answers what the windows showed when nothing took the press.
    static func pressMenuItem(
        _ item: String, under menu: String, on screen: PressProbe.Screen
    ) async -> (took: Bool, seen: String) {
        if let direct = screen.element(labelled: item) {
            return (direct.accessibilityActivate(), "direct")
        }
        guard let opener = screen.element(labelled: menu) else {
            return (false, "no \(menu): \(labels(in: screen.window))")
        }
        let opened = opener.accessibilityActivate()
        let windows = { screen.window.windowScene?.windows ?? [screen.window] }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for window in windows() {
                if let row = node(labelled: item, in: window), row.accessibilityActivate() {
                    return (true, "menu")
                }
            }
            await screen.settle(turns: 5)
        }
        let seen = windows().map { labels(in: $0).joined(separator: ",") }
        return (false, "opened=\(opened) \(seen)")
    }

    /// Every label drawn by what is presented over `host` — the viewer — and nothing under it:
    /// the screen beneath answers "More" of its own.
    static func presentedLabels(over host: UIViewController) -> [String] {
        var top = host
        while let next = top.presentedViewController { top = next }
        guard top !== host, let root = top.view else { return [] }
        var found: [String] = []
        var stack: [Any] = [root]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    /// Runs `element`'s accessibility action named `name`, the way VoiceOver's rotor runs it.
    static func runAction(_ name: String, of element: NSObject) -> Bool {
        let actions = element.accessibilityCustomActions ?? []
        guard let action = actions.first(where: { $0.name == name }) else { return false }
        if let handler = action.actionHandler { return handler(action) }
        guard let target = action.target as? NSObject else { return false }
        _ = target.perform(action.selector, with: action)
        return true
    }

    /// The names of `element`'s accessibility actions, for a failure's message.
    static func actionNames(of element: NSObject?) -> [String] {
        element?.accessibilityCustomActions?.map(\.name) ?? []
    }

    /// The first node that reads as `label`, a button or not: a menu's rows answer as rows.
    private static func node(labelled label: String, in window: UIWindow) -> NSObject? {
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.accessibilityLabel == label { return object }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }
}

// MARK: - What a Journal card's tap opens (MEMNG-769)

/// A Journal card's text goes to the memo on the Timeline; its photo opens the viewer on the trip,
/// over that memo's own pictures — without a screen.
@MainActor
@Suite("Trip journal opening")
struct TripJournalOpeningTests {
    private func picture(_ uid: String) -> MemoAttachment {
        let file = "https://memos.example.invalid/api/attachments/\(uid)"
        return MemoAttachment(
            uid: uid, mime: "image/jpeg", status: .ready, width: 1000, height: 800,
            thumbnailURL: URL(string: "\(file)/thumb"), previewURL: URL(string: "\(file)/mobile"),
            webURL: URL(string: "\(file)/web"), downloadURL: URL(string: "\(file)/download"))
    }

    private func memo(_ attachments: [MemoAttachment]) -> Memo {
        let stamp = Date(timeIntervalSince1970: 1_772_000_000)
        return Memo(
            uid: "j1", owner: "fabian", mine: true, content: "Tram up to the castle",
            visibility: .private, pinned: false, createdAt: stamp, updatedAt: stamp,
            tags: ["portugal2026"], attachments: attachments)
    }

    /// The selection a photo tap opened, or nil when the tap opened something else.
    private func viewer(_ opening: TripView.JournalOpening) -> MediaViewerSelection? {
        if case .viewer(let selection) = opening { return selection }
        return nil
    }

    @Test("a card's text opens its memo on the Timeline")
    func theTextOpensTheMemo() {
        #expect(TripView.journalOpening(nil, of: memo([picture("a")])) == .memo("j1"))
    }

    @Test("a card's photo opens the viewer over the memo's pictures, at the one tapped")
    func aPhotoOpensTheViewer() throws {
        let opening = TripView.journalOpening(picture("b"), of: memo([picture("a"), picture("b")]))
        let selection = try #require(viewer(opening), "the photo opened \(opening)")

        #expect(selection.pages.map(\.id) == ["a", "b"])
        #expect(selection.startPage.id == "b", "opened on \(selection.startPage.id)")
        // As the grid's: nothing in a trip's viewer deletes.
        #expect(!selection.deletable)
        // Each page names its memo, so the viewer offers Show Memo as a grid page does.
        let actions = MediaTileMenu.actions(for: selection.startPage.attachment)
        #expect(actions.first == .showMemo(uid: "j1"), "the page offers \(actions)")
    }

    @Test("the last of three pictures opens on the last page, a lone picture on its one page")
    func theEdgesOfTheMemo() throws {
        let three = memo([picture("a"), picture("b"), picture("c")])
        let last = try #require(viewer(TripView.journalOpening(picture("c"), of: three)))
        #expect(last.startIndex == 2, "opened on page \(last.startIndex)")
        #expect(last.pages.count == 3)

        let alone = memo([picture("a")])
        let lone = try #require(viewer(TripView.journalOpening(picture("a"), of: alone)))
        #expect(lone.pages.map(\.id) == ["a"])
        #expect(lone.startIndex == 0)
    }

    /// The journal's latest read renews a page; a page no memo of it holds any more keeps its own
    /// copy, and every page keeps the memo it belongs to.
    @Test("a journal viewer's pages take the journal's renewed copies, keeping their memo")
    func theJournalViewerTakesRenewedCopies() throws {
        let opening = TripView.journalOpening(picture("a"), of: memo([picture("a"), picture("b")]))
        let selection = try #require(viewer(opening))
        var fresh = picture("a")
        fresh.previewURL = URL(string: "https://memos.example.invalid/renewed/a/mobile")

        let source = TripView.journalViewerSource(for: selection, memos: [memo([fresh])])
        guard case .fixed(let pages) = source else {
            Issue.record("not a fixed source")
            return
        }
        #expect(pages.map(\.id) == ["a", "b"])
        #expect(pages.first?.stillURL == fresh.previewURL, "a kept its old copy")
        #expect(pages.last?.stillURL == selection.pages.last?.stillURL, "b changed without a row")
        #expect(pages.map(\.memoUID) == ["j1", "j1"])
    }

    /// A tap that does nothing reads as a broken card: a file the viewer cannot show opens the
    /// memo, as the Timeline's card does.
    @Test("a tapped file the viewer cannot show opens the memo, never nothing")
    func anUnviewableFileOpensTheMemo() {
        let pdf = MemoAttachment(uid: "d", mime: "application/pdf", status: .ready)
        #expect(TripView.journalOpening(pdf, of: memo([picture("a"), pdf])) == .memo("j1"))
    }
}

// MARK: - Fixtures

/// A share lane a test can watch and hold: every file asked for, as "<uid> <rendition>", and a
/// file written for each under a name of its own, so the sheet's names are the batch's renames.
@MainActor
final class TripShareRecorder {
    private(set) var asked: [String] = []
    /// While true, a download waits before it answers.
    var holding = false
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "trip-share").appending(path: UUID().uuidString)

    var lane: TripShareLane {
        TripShareLane(
            generation: { 1 },
            download: { [self] file, rendition in
                asked.append("\(file.uid) \(rendition)")
                let deadline = Date().addingTimeInterval(10)
                while holding, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: "download-\(file.uid)")
                try Data("picture \(file.uid)".utf8).write(to: url)
                return url
            }
        )
    }
}

@MainActor
final class TripWire {
    static let baseURL = URL(string: "https://memos.example.invalid")!
    let transport = TripTransport()
    let access: CollectionsAccess

    init() {
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.baseURL),
            token: { "memos_pat_trip" },
            transport: transport)
        access = CollectionsAccess(
            handle: SessionHandle(client: client, generation: 1), baseURL: Self.baseURL)
    }
}

/// The scripted server: `portugal2026`'s pictures in three pages of `taken_asc`, `spain2025`'s one.
final class TripTransport: ClientTransport, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var reads: [[String: String]] = []
    private nonisolated(unsafe) var journalReads: [[String: String]] = []
    private nonisolated(unsafe) var failing = false
    private nonisolated(unsafe) var held = false
    private nonisolated(unsafe) var signature = "v1"
    private nonisolated(unsafe) var emptied = false
    private nonisolated(unsafe) var unoriginal = false
    private nonisolated(unsafe) var pictured = false
    private nonisolated(unsafe) var dropped: Set<String> = []
    private nonisolated(unsafe) var others: Set<String> = []
    private nonisolated(unsafe) var films: Set<String> = []
    private nonisolated(unsafe) var deleted: [String] = []
    private nonisolated(unsafe) var sent: [String] = []
    /// The trips the server holds. A trip's members are its tag's listing below; its count is
    /// that listing's pictures less those removed from the trip or deleted.
    nonisolated let trips = TripRows()

    nonisolated init() {
        trips.counting { [weak self] row in self?.count(of: row) ?? 0 }
    }

    private nonisolated func count(of row: TripRows.Row) -> Int {
        let gone = lock.withLock { emptied ? nil : dropped }
        guard let gone else { return 0 }
        let listed: [String] =
            switch row.tag {
            case "portugal2026": (0..<5).map { "p\($0)" }
            case "spain2025": ["s0"]
            default: []
            }
        return listed.filter { !gone.contains($0) && !row.exclusions.contains($0) }.count
    }

    /// Every list read so far, as its query.
    nonisolated var listReads: [[String: String]] { lock.withLock { reads } }
    /// Every memo list read so far, as its query.
    nonisolated var memoReads: [[String: String]] { lock.withLock { journalReads } }
    /// Every DELETE sent so far, as its path.
    nonisolated var deletes: [String] { lock.withLock { deleted } }
    /// Every request sent so far that is not a read, as its method and operation.
    nonisolated var writes: [String] { lock.withLock { sent.filter { !$0.hasPrefix("GET ") } } }

    /// `portugal2026`'s memos, oldest first: two on the 12th, one on the 14th.
    nonisolated static let journal: [(uid: String, text: String, stamp: String)] = [
        ("j0", "Arrived in Lisbon", "2026-03-12T09:00:00Z"),
        ("j1", "Tram up to the castle", "2026-03-12T18:00:00Z"),
        ("j2", "A day out in Sintra", "2026-03-14T10:00:00Z"),
    ]

    nonisolated func fail() { lock.withLock { failing = true } }
    nonisolated func hold() { lock.withLock { held = true } }
    nonisolated func release() { lock.withLock { held = false } }
    /// What every URL read from here on is signed with.
    nonisolated func resign(_ next: String) { lock.withLock { signature = next } }
    /// The trip's tag leaves every picture: from here on its reads answer empty.
    nonisolated func empty() { lock.withLock { emptied = true } }
    /// The trip's pictures name no original: nothing to share, so "Show Memo" is the viewer's one
    /// shared action, and the trip's Use as Cover row is all that makes it a menu (MEMNG-768).
    nonisolated func nameNoOriginal() { lock.withLock { unoriginal = true } }
    /// The journal's second memo carries two pictures of its own, p1 and p3.
    nonisolated func pictureJournal() { lock.withLock { pictured = true } }
    /// The trip's tag leaves one picture: from here on its reads answer without it.
    nonisolated func drop(_ uid: String) { lock.withLock { _ = dropped.insert(uid) } }
    /// `uid` is another member's picture: from here on its reads say it is not mine.
    nonisolated func others(_ uid: String) { lock.withLock { _ = others.insert(uid) } }
    /// `uid` is a video from here on: a read that names images leaves it out, as the server does.
    nonisolated func film(_ uid: String) { lock.withLock { _ = films.insert(uid) } }

    nonisolated func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { sent.append("\(request.method) \(operationID)") }
        if let answered = try await trips.answer(
            request, body: body, operationID: operationID,
            listing: { [weak self] query in
                try await self?.listing(query) ?? (HTTPResponse(status: .notFound), nil)
            })
        {
            return answered
        }
        switch operationID {
        case "list_attachments_api_attachments_get":
            let items = URLComponents(string: request.path ?? "")?.queryItems ?? []
            let query = Dictionary(
                items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            return try await listing(query)
        case "attachment_tags_api_attachments_tags_get":
            return Self.json("[]", next: nil)
        case "delete_attachment_api_attachments__uid__delete":
            let path = request.path ?? ""
            lock.withLock {
                deleted.append(path)
                if let uid = path.split(separator: "/").last { dropped.insert(String(uid)) }
            }
            return (HTTPResponse(status: .noContent), nil)
        case "list_memos_api_memos_get":
            let items = URLComponents(string: request.path ?? "")?.queryItems ?? []
            let query = Dictionary(
                items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            let (pictures, sig) = lock.withLock {
                journalReads.append(query)
                return (pictured, signature)
            }
            return Self.memoPage(query, pictures: pictures, signed: sig)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    /// A list read — the Library's, or a trip's member route asking for its tag — answered as
    /// the server now holds the tag.
    private nonisolated func listing(_ query: [String: String]) async throws -> (
        HTTPResponse, HTTPBody?
    ) {
        lock.withLock { reads.append(query) }
        while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(20)) }
        if lock.withLock({ failing }) {
            return (HTTPResponse(status: .internalServerError), nil)
        }
        if lock.withLock({ emptied }) { return Self.json("[]", next: nil) }
        let (sig, gone, bare, theirs, clips) = lock.withLock {
            (signature, dropped, unoriginal, others, films)
        }
        return Self.page(
            query, signed: sig, without: gone, bare: bare, theirs: theirs, films: clips)
    }

    private nonisolated static func page(
        _ query: [String: String], signed sig: String, without gone: Set<String>,
        bare: Bool = false, theirs: Set<String> = [], films: Set<String> = []
    ) -> (HTTPResponse, HTTPBody?) {
        if query["tag"] == "spain2025" {
            return json("[\(item("s0", taken: "2025-05-01T12:00:00Z", sig: sig))]", next: nil)
        }
        if query["tag"] != "portugal2026" { return json("[]", next: nil) }
        let days = ["12", "14", "16", "18", "20"].map { "2026-03-\($0)T12:00:00Z" }
        let rows = days.enumerated().map { day -> String? in
            let uid = "p\(day.offset)"
            if gone.contains(uid) { return nil }
            let film = films.contains(uid)
            if film, query["type"] == "image" { return nil }
            return item(
                uid, taken: day.element, sig: sig, bare: bare, mine: !theirs.contains(uid),
                mime: film ? "video/mp4" : "image/jpeg")
        }
        // The server's order: oldest taken first only when the read asks for it, newest first
        // under `taken_desc` and the member route's default alike.
        let ordered = query["order"] == "taken_asc" ? rows : Array(rows.reversed())
        func list(_ picks: Int...) -> String {
            "[" + picks.compactMap { ordered[$0] }.joined(separator: ",") + "]"
        }
        switch query["cursor"] {
        case nil: return json(list(0, 1), next: "c1")
        case "c1": return json(list(2, 3), next: "c2")
        default: return json(list(4), next: nil)
        }
    }

    /// A page of `portugal2026`'s memos, two at a time, in the order the query's `sort` asks for:
    /// oldest first under `created_at`, newest first under anything else — the server's default.
    private nonisolated static func memoPage(
        _ query: [String: String], pictures: Bool, signed sig: String
    ) -> (HTTPResponse, HTTPBody?) {
        let all = query["tag"] == "portugal2026" ? journal : []
        let ordered = query["sort"] == "created_at" ? all : all.reversed()
        let rows = ordered.map { memo in
            let uids = pictures && memo.uid == "j1" ? ["p1", "p3"] : []
            let attached = uids.map { reference($0, sig: sig) }
            return """
                {"uid":"\(memo.uid)","owner":"fabian","mine":true,"content":"\(memo.text)",\
                "visibility":"PRIVATE","pinned":false,"created_at":"\(memo.stamp)",\
                "updated_at":"\(memo.stamp)","archived_at":null,"tags":["portugal2026"],\
                "attachments":[\(attached.joined(separator: ","))]}
                """
        }
        let first = query["cursor"] == nil
        let picked = first ? Array(rows.prefix(2)) : Array(rows.dropFirst(2))
        let next = first && rows.count > 2 ? "\"k1\"" : "null"
        let items = picked.joined(separator: ",")
        let body = "{\"items\":[\(items)],\"nextCursor\":\(next),\"totalCount\":null}"
        return json(body, next: nil)
    }

    /// A memo's own picture, as the memo read carries it (`AttachmentRef`), signed as `item`'s.
    private nonisolated static func reference(_ uid: String, sig: String) -> String {
        let query = "?exp=\(sig == "v1" ? 1_000_000_000 : 4_000_000_000)&scope=1&sig=\(sig)"
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,"width":1000,\
            "height":800,"duration":null,"sha256":null,"capture_instant":null,\
            "capture_civil":null,"capture_source":null,"mine":true,"hasPrint":false,\
            "hasLegacyPrint":false,"renditions":[],"position":null,\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)","webReady":true,\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)",\
            "downloadUrl":"/api/attachments/\(uid)/download\(query)",\
            "printUrl":"/api/attachments/\(uid)/print\(query)"}
            """
    }

    /// `v1` is signed with an `exp` long past, so a refusal of it reads as a lapse; any other
    /// signature with one far ahead.
    private nonisolated static func item(
        _ uid: String, taken: String, sig: String, bare: Bool = false, mine: Bool = true,
        mime: String = "image/jpeg"
    ) -> String {
        let query = "?exp=\(sig == "v1" ? 1_000_000_000 : 4_000_000_000)&scope=1&sig=\(sig)"
        let download = bare ? "" : "/api/attachments/\(uid)/download\(query)"
        return """
            {"uid":"\(uid)","mime":"\(mime)","status":"ready","blurhash":null,\
            "width":1000,"height":800,"mine":\(mine),"hasPrint":false,"hasLegacyPrint":false,\
            "webReady":true,\
            "renditions":[],"tags":[],"orphan":false,"memoUid":"m-\(uid)",\
            "takenAt":"\(taken)","filename":"\(uid).jpg",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)",\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)",\
            "downloadUrl":"\(download)",\
            "printUrl":"/api/attachments/\(uid)/print\(query)"}
            """
    }

    private nonisolated static func json(_ text: String, next: String?) -> (HTTPResponse, HTTPBody?)
    {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let next, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = next
        }
        return (response, HTTPBody(text))
    }
}

/// The picture server: every picture it is asked for, and a refusal for a signature revoked.
actor TripMediaServer: MediaTransport {
    private var urls: [URL] = []
    private var revoked: Set<String> = []
    private let payload: Data

    init(payload: Data) { self.payload = payload }

    func revoke(_ sig: String) { revoked.insert(sig) }

    /// Every picture asked for, as path and signature, for a failure's message.
    func log() -> [String] {
        urls.map { "\($0.path) \($0.query?.components(separatedBy: "sig=").last ?? "-")" }
    }

    /// How often `uid`'s `tier` was asked for under `sig`.
    func asked(_ uid: String, _ tier: String, sig: String) -> Int {
        urls.filter {
            $0.path.hasSuffix("/\(uid)/\(tier)") && $0.absoluteString.contains("sig=\(sig)")
        }.count
    }

    /// Whether all five tiles and the cover, p4, have been asked for.
    func drewTheGrid() -> Bool {
        (0..<5).allSatisfy { asked("p\($0)", "thumb", sig: "v1") >= 1 }
            && asked("p4", "mobile", sig: "v1") >= 1
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        urls.append(url)
        let refused = revoked.contains { url.absoluteString.contains("sig=\($0)") }
        let response = HTTPURLResponse(
            url: url,
            statusCode: refused ? 403 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": refused ? "application/json" : "image/png"]
        )!
        return (refused ? Data() : payload, response)
    }
}

extension TripScreenRenderTests {
    /// The trip's viewer offers Use as Cover; pressing it makes the page on screen the cover, and
    /// the hero draws it once the viewer has closed (MEMNG-720).
    @Test("Use as Cover in the trip's viewer makes that picture the hero's cover")
    func useAsCoverReachesTheHero() async {
        let jump = MemoJump()
        await openViewer(excluding: "p4", at: 2, jump: jump) { screen, _, _, members, cover in
            #expect(members == ["p0", "p1", "p2", "p3"], "the members: \(members)")
            // The overlay's control set (MEMNG-768): Show Memo is this file's one shared action,
            // so the menu is there only because the trip's row is in it — and neither row is a
            // button of its own.
            let menu = await screen.until {
                TripProbe.presentedLabels(over: screen.host).contains("More")
            }
            let drawn = TripProbe.presentedLabels(over: screen.host)
            #expect(menu, "the trip's viewer drew no menu: \(drawn)")
            #expect(
                screen.element(labelled: TripView.useAsCoverButton) == nil,
                "Use as Cover is drawn outside the menu")
            #expect(
                screen.element(labelled: MediaTileAction.showMemo(uid: "").title) == nil,
                "the one shared action is drawn as its own button beside a host's row")
            #expect(cover("p2"), "p2 is not a member")
            let shown = await screen.until(seconds: 10) {
                CollectionsHost.identified(TripView.coverIdentifier("p2"), in: screen.window)
            }
            #expect(shown, "the hero does not draw the chosen p2")
            #expect(!CollectionsHost.identified(TripView.coverIdentifier("p0"), in: screen.window))
        }
    }
}

// MARK: - Select mode's Remove from trip (MEMNG-722)

/// Remove from Trip: the chosen pictures leave this trip on the server, through the trip's
/// exclusions in one batch — the grid, the hero, the selection and the viewer with them — and
/// nothing is sent that could change a memo; the Trip's Show Removed list gives each one back.
extension TripScreenRenderTests {
    @Test("Remove from Trip takes the chosen out of the grid and the hero, and changes no memo")
    func removeFromATrip() async {
        let wire = TripWire()
        let stores = stores()
        await selectingTrip(wire, stores: stores) { screen, _ in
            let entered = await pressBar("Select", on: screen) {
                screen.says("0 Items Selected")
            }
            #expect(entered, "Select stood no toolbar")
            let photos = TripProbe.photos(in: screen.window)
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[0]), "p0 took no press")
            #expect(photos.count == 5 && TripProbe.pressAtOnce(photos[1]), "p1 took no press")
            #expect(await screen.until { screen.says("2 Items Selected") })

            let remove = screen.element(labelled: LibrarySelectToolbar.removeLabel)
            #expect(remove?.accessibilityActivate() == true, "Remove from Trip took no press")

            let gone = await screen.until { TripProbe.photos(in: screen.window).count == 3 }
            #expect(gone, "the removed pictures stayed in the grid")
            #expect(screen.says("3 photos"), "the hero still counts the removed pictures")
            // Select mode stays, holding nothing: the removed pictures left the selection with
            // the trip.
            let emptied = await screen.until { screen.says("0 Items Selected") }
            #expect(emptied, "a removed picture stayed chosen")
            #expect(wire.transport.trips.rows.first?.exclusions.sorted() == ["p0", "p1"])
            let exclude = "PUT \(TripRows.exclude)"
            #expect(
                wire.transport.writes == [exclude, exclude],
                "a removal wrote: \(wire.transport.writes)")
            #expect(wire.transport.deletes.isEmpty)
        }
    }

    @Test("the viewer pages through the trip without a removed picture, and one open on it closes")
    func theViewerAfterARemoval() async throws {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await stores.1.drain(record, using: wire.access.handle, baseURL: TripWire.baseURL)
        let all = stores.1.members(for: record)
        #expect(all.count == 5, "control: the drain landed")
        let opened = try #require(
            MediaViewerPresentation.viewer(for: all.map(\.attachment), startingAt: "p1"))

        try await stores.1.remove(
            ["p1"], from: record, using: wire.access.handle, baseURL: TripWire.baseURL)

        let live = try #require(stores.0.trips.first { $0.uid == record.uid })
        let members = stores.1.members(for: live)
        let loaded = stores.1.summary(for: live) != nil
        let pages = TripView.viewerSource(for: opened, members: members, loaded: loaded).pages
        #expect(pages.map(\.attachment.uid) == ["p0", "p2", "p3", "p4"])
        #expect(
            TripView.viewerOutlived(opened, holding: [], members: members, loaded: loaded),
            "a viewer holding the removed picture stayed open")
        #expect(wire.transport.writes == ["PUT \(TripRows.exclude)"], "\(wire.transport.writes)")
    }

    @Test("Show Removed lists the removed pictures, and Add Back returns one to the trip")
    func addBackFromTheRemovedList() async throws {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await stores.1.drain(record, using: wire.access.handle, baseURL: TripWire.baseURL)
        try await stores.1.remove(
            ["p3"], from: record, using: wire.access.handle, baseURL: TripWire.baseURL)
        let live = stores.0.trips.first { $0.uid == record.uid } ?? record
        let access = wire.access
        let view = NavigationStack {
            TripRemovedList(trip: live, trips: stores.0, members: stores.1, access: { access })
        }
        await CollectionsHost.with(view) { screen in
            let listed = await screen.until {
                screen.element(labelled: TripRemovedList.addBackButton) != nil
            }
            #expect(listed, "the removed picture was not listed")
            #expect(!screen.says(TripRemovedList.emptyTitle))
            #expect(screen.press(TripRemovedList.addBackButton), "Add Back took no press")
            let back = await screen.until {
                wire.transport.trips.rows.first?.exclusions == []
                    && stores.0.trips.first.map { stores.1.members(for: $0).count } == 5
            }
            #expect(back, "Add Back left the picture removed")
            #expect(stores.0.trips.first.map { stores.1.members(for: $0).count } == 5)
            #expect(await screen.until { screen.says(TripRemovedList.emptyTitle) })
        }
        let written = ["PUT \(TripRows.exclude)", "DELETE \(TripRows.include)"]
        #expect(wire.transport.writes == written, "\(wire.transport.writes)")
    }

    @Test("the Library's toolbar offers no Remove; the trip's does")
    func onlyTheTripOffersRemove() async {
        let library = LibrarySelectToolbar(
            count: 1, ownCount: 1, isSharing: false, isDeleting: false, share: {}, delete: {})
        await CollectionsHost.with(library) { screen in
            #expect(screen.element(labelled: "Delete") != nil, "control: the toolbar stood")
            #expect(screen.element(labelled: LibrarySelectToolbar.removeLabel) == nil)
        }
        let trip = LibrarySelectToolbar(
            count: 1, ownCount: 1, isSharing: false, isDeleting: false, share: {}, delete: {},
            remove: {})
        await CollectionsHost.with(trip) { screen in
            #expect(screen.element(labelled: LibrarySelectToolbar.removeLabel) != nil)
        }
    }
}

// MARK: - The trip on the server: a refused edit, Show Removed, a trip of dates alone

extension TripScreenRenderTests {
    /// One write per trip at a time: an edit asked while another is out is the store's `.busy`,
    /// said on the error line under the title, and nothing of it reaches the server.
    @Test("an edit asked while another is out says so under the title and sends nothing")
    func aBusyEditSendsNothing() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let manage = TripManage()
        let access = wire.access
        let host = trip(stores, wire, record, manage: manage)
        await CollectionsHost.with(host, height: 3000) { screen in
            let drawn = await screen.until { screen.says("Portugal 2026") }
            #expect(drawn, "the trip never drew")
            wire.transport.trips.hold(TripRows.patch)
            manage.askRename(current: record.title)
            manage.draft = "Algarve 2026"
            let rename = manage.confirmRename(record.uid, in: stores.0, using: access)
            #expect(rename != nil, "the rename was not taken")
            let sent = await screen.until { wire.transport.trips.calls(TripRows.patch).count == 1 }
            #expect(sent, "the rename never reached the server")
            let cover = manage.setCover("p1", of: record.uid, in: stores.0, using: access)
            #expect(await cover?.value == false, "the second edit was not refused")
            let busy = TripStore.Failure.busy.errorDescription ?? "?"
            let said = await screen.until {
                screen.says(busy)
                    && CollectionsHost.identified(TripView.errorLineID, in: screen.window)
            }
            #expect(said, "no error line: \(TripProbe.labels(in: screen.window))")
            #expect(
                wire.transport.trips.calls(TripRows.patch).count == 1, "the refused edit was sent")
            wire.transport.trips.release(TripRows.patch)
            #expect(await rename?.value == true, "the rename did not land")
        }
        let row = wire.transport.trips.rows.first { $0.uid == record.uid }
        #expect(row?.title == "Algarve 2026")
        #expect(row?.cover == nil, "the refused cover reached the server")
        #expect(wire.transport.trips.calls(TripRows.patch).count == 1)
    }

    /// Show Removed is offered before anything is known: its sheet opens on a trip whose members
    /// are still being read, says so, and then lists the exact removed set.
    @Test("Show Removed opens before any member is known: loading, then the removed set")
    func showRemovedBeforeTheMembers() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(
            stores, wire, "Portugal 2026", tag: "portugal2026", excluding: ["p3"])
        wire.transport.trips.hold(TripRows.members)
        let manage = TripManage()
        let host = trip(stores, wire, record, manage: manage)
        await CollectionsHost.with(host, height: 3000) { screen in
            let drawn = await screen.until { screen.says("Portugal 2026") }
            #expect(drawn, "the trip never drew")
            #expect(stores.1.members(for: record).isEmpty, "a member was known")
            // The Manage menu's action, as the menu's Show Removed calls it: a toolbar menu does
            // not open in a hand-hosted window.
            manage.showRemoved()
            let loading = await screen.until { screen.says(TripRemovedList.loadingTitle) }
            #expect(loading, "the sheet did not say it was reading")
            #expect(stores.1.members(for: record).isEmpty, "the members came before the hold")
            wire.transport.trips.release(TripRows.members)
            let listed = await screen.until {
                screen.element(labelled: TripRemovedList.addBackButton) != nil
            }
            #expect(listed, "the removed set never drew: \(TripProbe.labels(in: screen.window))")
            var removed: [String] = []
            if case .exact(let rows) = stores.1.removedState(for: record) {
                removed = rows.map(\.id)
            }
            #expect(removed == ["p3"], "the removed set: \(removed)")
        }
    }

    /// A trip past the member cap cannot be listed exactly: the sheet says the list is not
    /// available rather than guess.
    @Test("Show Removed on a trip past the cap says the list is not available")
    func showRemovedPastTheCap() async {
        let wire = TripWire()
        let stores = stores(memberCap: 2)
        let record = await filed(
            stores, wire, "Portugal 2026", tag: "portugal2026", excluding: ["p3"])
        let manage = TripManage()
        let host = trip(stores, wire, record, manage: manage)
        await CollectionsHost.with(host, height: 3000) { screen in
            let capped = await screen.until { stores.1.state(for: record) == .truncated }
            #expect(capped, "the drain did not stop at the cap")
            // The Manage menu's action, as the menu's Show Removed calls it: a toolbar menu does
            // not open in a hand-hosted window.
            manage.showRemoved()
            let said = await screen.until { screen.says(TripRemovedList.unavailableTitle) }
            #expect(said, "no unavailable line: \(TripProbe.labels(in: screen.window))")
            #expect(screen.element(labelled: TripRemovedList.addBackButton) == nil)
            #expect(stores.1.removedState(for: record) == .unavailable)
        }
    }

    /// A trip of dates alone has no tag, so no journal: the chip says why and reads nothing.
    @Test("a trip of dates alone says its journal has no tag, and reads no memo")
    func aSpanOnlyJournal() async {
        let wire = TripWire()
        let stores = stores()
        let uid = wire.transport.trips.seed(
            "Lisbon", spanStart: "2026-03-10T00:00:00Z", spanEnd: "2026-03-20T00:00:00Z",
            tz: "UTC")
        await stores.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
        guard let record = stores.0.trips.first(where: { $0.uid == uid }) else {
            Issue.record("the trip was not listed")
            return
        }
        #expect(record.tag == nil)
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let said = await screen.until { screen.says(TripMemberStore.noTagJournal) }
            #expect(said, "no no-tag line: \(TripProbe.labels(in: screen.window))")
            // A second answer, were one coming, has a second to arrive.
            try? await Task.sleep(for: .seconds(1))
            await screen.settle(turns: 5)
            #expect(!screen.says(TripView.journalEmptyTitle), "the journal claimed it read")
        }
        #expect(wire.transport.memoReads.isEmpty, "a journal read: \(wire.transport.memoReads)")
        #expect(stores.1.journalState(for: record) == .notLoaded)
    }
}

// MARK: - The whole identity, and the Journal's own renewal (MEMNG-754 R1)

extension TripScreenRenderTests {
    /// The Trip screen over an identity the test moves, as the session's identity reaches it.
    private func switchingTrip(
        _ stores: (TripStore, TripMemberStore), _ wire: TripWire, _ record: Trip,
        _ source: IdentitySource, viewer: any MediaTransport
    ) -> some View {
        let access = wire.access
        return IdentityHost(source: source) { who in
            NavigationStack {
                TripView(
                    trip: record, trips: stores.0, memberStore: stores.1, identity: who,
                    access: { access }, viewerTransport: viewer)
            }
            .environment(\.locale, Locale(identifier: "en_GB"))
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        }
    }

    /// Another account of the household may see the same trip with other pictures: while its own
    /// read is out, the screen shows none of the outgoing account's photos, and a viewer open over
    /// them closes — whether the stores or the screen hear of the new account first.
    @Test(
        "another account's screen shows none of this one's photos, nor its viewer, meanwhile",
        arguments: [true, false])
    func anAccountChangeDropsTheShownMembers(storesFirst: Bool) async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let source = IdentitySource(alice)
        let bob = TimelineSnapshotIdentity(server: alice.server, subject: "bob")
        let view = switchingTrip(stores, wire, record, source, viewer: media)
            .environment(MemoJump())
        await CollectionsHost.with(view, height: 3000) { screen in
            let gridded = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(gridded, "precondition: the trip was not drawn")
            let tiles = TripProbe.photos(in: screen.window)
            let pressed = tiles.first.map { TripProbe.pressAtOnce($0) } ?? false
            #expect(pressed, "precondition: no tile took a press")
            let opened = await screen.until(seconds: 10) {
                TripProbe.pager(over: screen.host) != nil
            }
            #expect(opened, "precondition: the viewer never opened")
            wire.transport.trips.hold(TripRows.members)
            if storesFirst {
                CollectionsSession.identityChanged(to: bob, trips: stores.0, members: stores.1)
                source.identity = bob
            } else {
                // The screen first, a turn ahead of the stores: they still hold the outgoing
                // account's members while the screen already shows the incoming one.
                source.identity = bob
                await screen.settle(turns: 5)
                CollectionsSession.identityChanged(to: bob, trips: stores.0, members: stores.1)
            }
            await stores.0.refresh(using: wire.access.handle, baseURL: TripWire.baseURL)
            let relisted = stores.0.trips.contains { $0.uid == record.uid }
            #expect(relisted, "precondition: the other account lists the trip")
            let closed = await screen.until(seconds: 10) {
                TripProbe.pager(over: screen.host) == nil
            }
            #expect(closed, "the viewer stayed open over the outgoing account's photos")
            await screen.settle(turns: 10)
            let left = TripProbe.photos(in: screen.window).count
            #expect(left == 0, "the other account was shown \(left) of the outgoing one's photos")
            wire.transport.trips.release(TripRows.members)
            let own = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(own, "the other account's own read never drew")
        }
    }

    /// A trip opened over members already read keeps them on screen from its first frame while
    /// its own read is out — not only once a later read has settled.
    @Test("a trip opened over members already read keeps them while its own read is out")
    func openedOverReadMembers() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await stores.1.drain(record, using: wire.access.handle, baseURL: TripWire.baseURL)
        let read = stores.1.state(for: record) == .complete
        #expect(read, "precondition: the members were read")
        wire.transport.trips.hold(TripRows.members)
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let draining = await screen.until { stores.1.state(for: record) == .draining }
            #expect(draining, "precondition: the screen's own read never went out")
            await screen.settle(turns: 10)
            let shown = TripProbe.photos(in: screen.window).count
            #expect(shown == 5, "the screen dropped the members it opened over: \(shown)")
            wire.transport.trips.release(TripRows.members)
        }
    }

    /// A Journal photo removed from the trip is no member, so a read of the members never
    /// re-signs it, and a Removed list read before it lapsed holds the lapsed copy: the Journal's
    /// viewer renews its pages by reading the journal again, whatever either list holds.
    @Test(
        "a journal viewer re-signs a photo removed from the trip, its Removed list read or not",
        arguments: [false, true])
    func aJournalViewerRenewsARemovedPhoto(removedRead: Bool) async {
        let wire = TripWire()
        wire.transport.pictureJournal()
        let stores = stores()
        let record = await filed(
            stores, wire, "Portugal 2026", tag: "portugal2026", excluding: ["p1"])
        if removedRead {
            await stores.1.removed(
                for: record, using: wire.access.handle, baseURL: TripWire.baseURL)
            if case .exact(let rows) = stores.1.removedState(for: record) {
                #expect(rows.map(\.id) == ["p1"], "precondition: the removed list")
            } else {
                Issue.record("precondition: the removed list was not read")
            }
        }
        let second = TripTransport.journal[1]
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        let view = trip(stores, wire, record, viewer: media).environment(MemoJump())
        await CollectionsHost.with(view, height: 3000) { screen in
            let gridded = await screen.until { TripProbe.photos(in: screen.window).count == 4 }
            #expect(gridded, "precondition: the trip was not drawn")
            await media.revoke("v1")
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "the Journal chip took no press")
            let drawn = await screen.until {
                TripProbe.card(saying: second.text, in: screen.window) != nil
            }
            #expect(drawn, "no card says \(second.text)")
            wire.transport.resign("v2")
            let card = TripProbe.card(saying: second.text, in: screen.window)
            let ran = card.map { TripProbe.runAction("Open photo", of: $0) } ?? false
            #expect(ran, "no Open photo ran: \(TripProbe.actionNames(of: card))")
            let lapsed = await TripProbe.settled(seconds: 10) {
                await media.asked("p1", "mobile", sig: "v1") >= 1
            }
            #expect(lapsed, "precondition: the viewer never asked for p1 under v1")
            let renewed = await TripProbe.settled(seconds: 10) {
                await media.asked("p1", "mobile", sig: "v2") >= 1
            }
            #expect(renewed, "the removed photo p1 never took its new signature")
        }
    }

    /// A removal the server acknowledged leaves the screen even when no read of the members lands
    /// after it: the members the screen holds while it waits for one are the store's truth too,
    /// not a copy that keeps the picture on screen and in reach of the toolbar (MEMNG-793).
    @Test("an acknowledged removal leaves the grid though every read after it fails")
    func anAcknowledgedRemovalLeavesTheHeldGrid() async {
        let wire = TripWire()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        await CollectionsHost.with(trip(stores, wire, record), height: 3000) { screen in
            let gridded = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(gridded, "precondition: the trip was not drawn")
            wire.transport.trips.fail([TripRows.members])

            let outcome = try? await stores.1.remove(
                ["p0"], from: record, using: wire.access.handle, baseURL: TripWire.baseURL)

            #expect(outcome?.done == ["p0"], "control: the server took p0 out")
            #expect(stores.1.state(for: record) != .complete, "control: no read landed after it")
            let left = await screen.until { TripProbe.photos(in: screen.window).count == 4 }
            let shown = TripProbe.photos(in: screen.window).count
            #expect(left, "the screen still shows the removed picture: \(shown) photos")
            wire.transport.trips.fail([])
        }
    }

    /// The Journal's viewer open over j1's two pictures, through its card's Open photo.
    private func journalViewer(
        _ stores: (TripStore, TripMemberStore), _ wire: TripWire, _ record: Trip,
        _ media: TripMediaServer, _ body: (PressProbe.Screen) async -> Void
    ) async {
        let second = TripTransport.journal[1]
        let view = trip(stores, wire, record, viewer: media).environment(MemoJump())
        await CollectionsHost.with(view, height: 3000) { screen in
            let gridded = await screen.until { TripProbe.photos(in: screen.window).count == 5 }
            #expect(gridded, "precondition: the trip was not drawn")
            let chosen = await screen.until { TripProbe.pressAtOnce("Journal", on: screen) }
            #expect(chosen, "precondition: the Journal chip took no press")
            let drawn = await screen.until {
                TripProbe.card(saying: second.text, in: screen.window) != nil
            }
            #expect(drawn, "precondition: no card says \(second.text)")
            let card = TripProbe.card(saying: second.text, in: screen.window)
            let ran = card.map { TripProbe.runAction("Open photo", of: $0) } ?? false
            #expect(ran, "precondition: no Open photo ran: \(TripProbe.actionNames(of: card))")
            let opened = await screen.until(seconds: 10) {
                TripProbe.pager(over: screen.host).map(TripProbe.pageCount) == 2
            }
            #expect(opened, "precondition: the viewer never opened over two pages")
            await body(screen)
        }
    }

    /// A picture deleted while the Journal's viewer is open over it leaves the viewer, as it
    /// leaves the grid's: the pager drops its page and stays open over the other (MEMNG-794).
    @Test("a picture deleted under an open journal viewer leaves its pages")
    func aDeletedPictureLeavesTheJournalViewer() async {
        let wire = TripWire()
        wire.transport.pictureJournal()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        await journalViewer(stores, wire, record, media) { screen in
            let outcome = await stores.1.delete(
                ["p3"], using: wire.access.handle, baseURL: TripWire.baseURL)
            #expect(outcome?.deleted == ["p3"], "control: p3 was deleted")
            let dropped = await screen.until(seconds: 10) {
                screen.host.presentedViewController != nil
                    && TripProbe.pager(over: screen.host) == nil
            }
            let pages = TripProbe.pager(over: screen.host).map(TripProbe.pageCount) ?? 1
            #expect(dropped, "the viewer still pages to the deleted picture: \(pages) pages")
            #expect(screen.host.presentedViewController != nil, "the viewer closed over p1")
        }
    }

    /// When the deleted picture was the only page left, the viewer closes, as it does after a
    /// delete of its own: an empty pager is a black screen with a close button on it (MEMNG-794).
    @Test("a journal viewer whose only page is deleted under it closes")
    func aJournalViewerOfADeletedPictureCloses() async {
        let wire = TripWire()
        wire.transport.pictureJournal()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let media = TripMediaServer(payload: MediaFixture.png(.red))
        MediaImageLoader.transport = media
        defer { MediaImageLoader.transport = MediaSession.shared }
        await journalViewer(stores, wire, record, media) { screen in
            let first = await stores.1.delete(
                ["p3"], using: wire.access.handle, baseURL: TripWire.baseURL)
            #expect(first?.deleted == ["p3"], "control: p3 was deleted")
            let second = await stores.1.delete(
                ["p1"], using: wire.access.handle, baseURL: TripWire.baseURL)
            #expect(second?.deleted == ["p1"], "control: p1 was deleted")
            let closed = await screen.until(seconds: 10) {
                screen.host.presentedViewController == nil
            }
            #expect(closed, "the viewer stayed open over its deleted pictures")
        }
    }

    /// The Journal and the grid renew different lists: a journal read re-signs the journal's memos
    /// and leaves the members' rows as they were. So a picture in both — a member a tagged memo
    /// carries — renewed for the Journal's viewer is still renewed for the grid when the grid asks
    /// inside the same minute: the cooldown is kept per list, never shared between the two.
    @Test("a member renewed for the Journal is still renewed for the grid inside the cooldown")
    func aJournalRenewalLeavesTheGridItsOwn() async {
        let wire = TripWire()
        wire.transport.pictureJournal()
        let stores = stores()
        let record = await filed(stores, wire, "Portugal 2026", tag: "portugal2026")
        let access = wire.access
        await stores.1.drain(record, using: access.handle, baseURL: TripWire.baseURL)
        await stores.1.loadJournal(record, using: access.handle, baseURL: TripWire.baseURL)
        let member = {
            stores.1.members(for: record).first { $0.id == "p1" }?.attachment.previewURL
        }
        let carried = {
            stores.1.journal(for: record).flatMap(\.attachments)
                .first { $0.uid == "p1" }?.previewURL
        }
        let signed = { (url: URL?) in url?.query?.contains("sig=v2") == true }
        let both = member() != nil && carried() != nil
        #expect(both, "precondition: p1 is a member that a journal memo carries")
        // From here every read signs anew; both lists still hold p1 under v1.
        wire.transport.resign("v2")
        let session = IssuingSession(handle: { access.handle }, baseURL: { access.baseURL })
        let journal = TripJournalURLRefresher(
            members: stores.1, trips: stores.0, uid: record.uid, session: session)
        let grid = TripURLRefresher(
            members: stores.1, trips: stores.0, uid: record.uid, session: session)
        // The loader's own dispatcher, its cooldown real: an ask it defers waits a minute.
        let table = MediaFetchTable(currentGeneration: { 0 })
        let key = MediaFetchTable.Key(
            image: MediaImageKey(uid: "p1", tier: "mobile"), generation: 0)
        let now = Date()
        let askedJournal = table.refresh(key, via: journal, at: now)
        #expect(askedJournal, "the Journal's renewal was not asked")
        let journalRenewed = await TripProbe.settled(seconds: 10) { signed(carried()) }
        #expect(journalRenewed, "the journal never took p1's new signature")
        let stale = !signed(member())
        #expect(stale, "precondition: the journal read re-signed the member row too")
        let askedGrid = table.refresh(key, via: grid, at: now.addingTimeInterval(1))
        #expect(askedGrid, "the grid's renewal waited out the Journal's cooldown")
        let gridRenewed = await TripProbe.settled(seconds: 10) { signed(member()) }
        #expect(gridRenewed, "the member row kept p1's lapsed URL")
        let journalKept = signed(carried())
        #expect(journalKept, "the journal lost p1's new signature")
    }
}
