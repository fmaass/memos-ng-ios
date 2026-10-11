import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A trip's Map (MEMNG-719): only the trip's markers, filtered by the COMPLETE drained membership.
///
/// The membership is drained for real — a scripted server answers `GET /api/attachments` page
/// after page at the store's own page size of 60 — and the markers are read through the real
/// `PlacesStore` from the same server, so the uid that joins the two is the one the wire carries.
@MainActor
@Suite("Trip map", .serialized, .mediaGlobals)
struct TripMapTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-map").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")
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

    fileprivate func stores(memberCap: Int = TripMembershipStore.memberCap)
        -> (CollectionStore, TripMembershipStore)
    {
        let collections = CollectionStore(identity: alice, root: root)
        return (collections, TripMembershipStore(collections: collections, memberCap: memberCap))
    }

    /// A marker at `latitude`, taken `minute` minutes into the trip.
    fileprivate static func marker(_ uid: String, latitude: Double = 38.7, minute: Int = 0)
        -> PlaceMarker
    {
        let file = "https://memos.example.invalid/api/attachments/\(uid)"
        return PlaceMarker(
            uid: uid, memoUID: "m-\(uid)", mime: "image/jpeg", mine: true,
            latitude: latitude, longitude: -9.14,
            takenAt: Date(timeIntervalSince1970: 1_772_000_000 + Double(minute) * 60),
            thumbnailURL: URL(string: "\(file)/thumb"), previewURL: URL(string: "\(file)/mobile"),
            webURL: URL(string: "\(file)/web"))
    }

    /// The markers' store, loaded from `wire`.
    private func loadedPlaces(_ wire: TripMapWire) async -> PlacesStore {
        let places = TripMapPresentation.reporting(PlacesStore(), to: nil)
        await places.load(using: wire.access.handle, baseURL: TripMapWire.baseURL)
        return places
    }

    // MARK: - the filter

    @Test("a marker outside the trip is absent from the trip's map")
    func aMarkerOutsideTheTripIsAbsent() {
        let all = [Self.marker("a"), Self.marker("x"), Self.marker("b", minute: 1)]
        let kept = TripMapPresentation.markers(all, of: ["a", "b"])
        #expect(kept.map(\.uid) == ["a", "b"], "kept \(kept.map(\.uid))")
        #expect(TripMapPresentation.markers(all, of: nil).isEmpty, "unknown members kept markers")
    }

    @Test("the 61st picture of a three-page drain keeps its marker")
    func aMemberBeyondTheFirstPageIsPresent() async {
        let wire = TripMapWire(members: 125, located: ["t0", "t60", "t124", "x9"])
        let (collections, trips) = stores()
        let record = collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.drain(record, using: wire.access.handle, baseURL: TripMapWire.baseURL)
        let pages = wire.transport.pageReads
        #expect(pages == 3, "precondition: three pages, read \(pages)")
        #expect(trips.state(for: record) == .complete)
        let places = await loadedPlaces(wire)
        let members = TripMapPresentation.memberUids(of: record, in: trips)
        #expect(members?.count == 125, "members \(members?.count ?? -1)")
        let shown = TripMapPresentation.markers(places.markers, of: members).map(\.uid)
        #expect(shown == ["t0", "t60", "t124"], "shown \(shown)")
    }

    @Test("a drain stopped at the cap filters by the pictures it read, and no further")
    func aTruncatedDrainFiltersByWhatItRead() async {
        let wire = TripMapWire(members: 125, located: ["t0", "t60", "t61", "t124"])
        let (collections, trips) = stores(memberCap: 61)
        let record = collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.drain(record, using: wire.access.handle, baseURL: TripMapWire.baseURL)
        #expect(trips.state(for: record) == .truncated)
        let places = await loadedPlaces(wire)
        let members = TripMapPresentation.memberUids(of: record, in: trips)
        let shown = TripMapPresentation.markers(places.markers, of: members).map(\.uid)
        #expect(shown == ["t0", "t60"], "shown \(shown)")
    }

    @Test("while the drain is on the wire the map is pending, never the empty map")
    func aDrainInFlightIsPending() async {
        let wire = TripMapWire(members: 3, located: ["t0"])
        let (collections, trips) = stores()
        let record = collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        let places = await loadedPlaces(wire)
        #expect(places.status == .ready, "precondition: the markers are in")
        wire.transport.hold()
        let drain = Task {
            await trips.drain(record, using: wire.access.handle, baseURL: TripMapWire.baseURL)
        }
        _ = await TripProbe.settled(seconds: 5) { trips.state(for: record) == .draining }
        #expect(trips.state(for: record) == .draining, "precondition: the drain is on the wire")
        let members = TripMapPresentation.memberUids(of: record, in: trips)
        #expect(members == nil, "members were computed from a drain in flight: \(members ?? [])")
        let shown = TripMapPresentation.markers(places.markers, of: members)
        let state = TripMapPresentation.state(
            places: places.status, membership: trips.state(for: record),
            membershipError: trips.lastError, shown: shown.count)
        #expect(state == .pending, "a drain in flight read as \(state)")
        wire.transport.release()
        await drain.value
        let after = TripMapPresentation.memberUids(of: record, in: trips)
        #expect(TripMapPresentation.markers(places.markers, of: after).map(\.uid) == ["t0"])
    }

    @Test("no member that knows where it was taken is the empty map, and says so")
    func theEmptyMap() async {
        let wire = TripMapWire(members: 3, located: ["x0", "x1"])
        let (collections, trips) = stores()
        let record = collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.drain(record, using: wire.access.handle, baseURL: TripMapWire.baseURL)
        let places = await loadedPlaces(wire)
        #expect(places.status == .ready, "precondition: the account has located photos")
        let members = TripMapPresentation.memberUids(of: record, in: trips)
        let shown = TripMapPresentation.markers(places.markers, of: members)
        let state = TripMapPresentation.state(
            places: places.status, membership: trips.state(for: record),
            membershipError: trips.lastError, shown: shown.count)
        #expect(state == .empty, "read as \(state)")
        let notice = TripMapPresentation.notice(for: state, error: nil)
        #expect(notice?.title == "No places in this trip")
    }

    @Test("the trip map's states: the membership first, then the markers")
    func states() {
        func state(
            _ places: PlacesStatus, _ membership: TripMembershipState, _ error: String? = nil,
            shown: Int = 0
        ) -> PlacesStatus {
            TripMapPresentation.state(
                places: places, membership: membership, membershipError: error, shown: shown)
        }
        #expect(state(.ready, .notLoaded, shown: 1) == .pending)
        #expect(state(.ready, .draining, "old", shown: 1) == .pending)
        #expect(state(.ready, .notLoaded, "the server returned 500") == .error)
        #expect(state(.pending, .complete) == .pending)
        #expect(state(.error, .complete) == .error)
        #expect(state(.empty, .truncated) == .empty)
        #expect(state(.ready, .complete, shown: 0) == .empty)
        #expect(state(.ready, .truncated, shown: 2) == .ready)
        let error = TripMapPresentation.notice(for: .error, error: "the server returned 500")
        #expect(error?.message == "the server returned 500")
        #expect(TripMapPresentation.notice(for: .error, error: nil)?.message != nil)
        #expect(TripMapPresentation.notice(for: .ready, error: nil) == nil)
        #expect(TripMapPresentation.notice(for: .pending, error: nil) == nil)
    }

    // MARK: - what a tap opens, and what closes it

    @Test("a tap opens the viewer with no sheet up, over the sheet with one, a list as the sheet")
    func presentingOpens() throws {
        let markers = [Self.marker("a"), Self.marker("b", latitude: 40)]
        let selection = try #require(PlacesPresentation.open("a", in: markers))
        let sheet = PlaceSheet(markers: markers, canZoomIn: false, members: [])
        var presenting = PlacesPresenting()
        presenting.open(.viewer(selection))
        #expect(presenting.viewing?.id == "a")
        #expect(presenting.viewingFromSheet == nil)
        presenting = PlacesPresenting()
        presenting.open(.sheet(sheet))
        #expect(presenting.sheet?.id == sheet.id)
        presenting.open(.viewer(selection))
        #expect(presenting.viewing == nil, "a cover was asked of the screen under a live sheet")
        #expect(presenting.viewingFromSheet?.id == "a")
    }

    @Test("the viewer a trip pin opens pages only over the trip's markers")
    func theViewerPagesOnlyOverTheTrip() {
        // Two photographs taken at one spot, one of them not the trip's.
        let all = [Self.marker("a"), Self.marker("x", minute: 1), Self.marker("c", latitude: 41)]
        let shown = TripMapPresentation.markers(all, of: ["a", "c"])
        let pins = PlacesPresentation.pins(for: shown)
        guard let pin = pins.first(where: { $0.spec.uids.contains("a") }),
            let action = PlacesPresentation.tap(pin: pin, in: shown)
        else {
            Issue.record("no pin holds the trip's photograph: \(pins.map(\.spec.uids))")
            return
        }
        guard case .viewer(let selection) = action else {
            Issue.record("the pin listed a sheet: a photograph outside the trip shares it")
            return
        }
        #expect(selection.pages.map(\.id) == ["a"], "pages \(selection.pages.map(\.id))")
        let cluster = PlacesPresentation.clusterTap(members: pins, in: shown, cameraDistance: 1000)
        let listed = cluster.markers.map(\.uid)
        #expect(Set(listed) == ["a", "c"], "listed \(listed)")
    }

    @Test("an excluded member's marker leaves the map, and a viewer open on it closes")
    func anExcludedMemberLeaves() async throws {
        let wire = TripMapWire(members: 3, located: ["t0", "t1"])
        let (collections, trips) = stores()
        let record = collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.drain(record, using: wire.access.handle, baseURL: TripMapWire.baseURL)
        let places = await loadedPlaces(wire)
        let before = TripMapPresentation.markers(
            places.markers, of: TripMapPresentation.memberUids(of: record, in: trips))
        #expect(before.map(\.uid) == ["t0", "t1"], "precondition: both are on the map")
        var presenting = PlacesPresenting()
        presenting.open(.viewer(try #require(PlacesPresentation.open("t1", in: [before[1]]))))
        var kept = PlacesPresenting()
        kept.open(.viewer(try #require(PlacesPresentation.open("t0", in: [before[0]]))))

        collections.exclude(id: record.id, uid: "t1")
        let live = try #require(collections.records.first { $0.id == record.id })
        let members = TripMapPresentation.memberUids(of: live, in: trips)
        let after = TripMapPresentation.markers(places.markers, of: members)
        let pins = after.map(\.uid)
        #expect(pins == ["t0"], "the excluded picture kept its pin: \(pins)")
        presenting.keep(only: TripMapPresentation.kept(after, members: members))
        #expect(presenting.viewing == nil, "a viewer stayed open on a picture the trip excluded")
        kept.keep(only: TripMapPresentation.kept(after, members: members))
        #expect(kept.viewing?.id == "t0", "a viewer on a picture still in the trip was closed")
    }

    @Test("a trip deleted under the map closes its sheet and its viewers")
    func aDeletedTripClosesEverything() async throws {
        let wire = TripMapWire(members: 3, located: ["t0", "t1"])
        let (collections, trips) = stores()
        let record = collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.drain(record, using: wire.access.handle, baseURL: TripMapWire.baseURL)
        let places = await loadedPlaces(wire)
        let shown = TripMapPresentation.markers(
            places.markers, of: TripMapPresentation.memberUids(of: record, in: trips))
        var presenting = PlacesPresenting()
        presenting.open(.sheet(PlaceSheet(markers: shown, canZoomIn: false, members: [])))
        presenting.open(.viewer(try #require(PlacesPresentation.open("t0", in: shown))))
        #expect(presenting.viewingFromSheet != nil, "precondition: a viewer over the sheet")

        collections.delete(id: record.id)
        trips.forget(record.id)
        let members = TripMapPresentation.memberUids(of: record, in: trips)
        #expect(members == nil, "a deleted trip still has members: \(members ?? [])")
        let after = TripMapPresentation.markers(places.markers, of: members)
        #expect(after.isEmpty)
        presenting.keep(only: TripMapPresentation.kept(after, members: members))
        #expect(presenting.sheet == nil, "the sheet stayed over a deleted trip")
        #expect(presenting.viewingFromSheet == nil, "the viewer stayed over a deleted trip")
    }

    // MARK: - the store's fence

    @Test("the trip map's store does not apply markers answered for a session that has ended")
    func theStoreIsFenced() async {
        let wire = TripMapWire(members: 1, located: ["t0"])
        let reporter = TripMapReporter()
        let next = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: TripMapWire.baseURL),
            token: { "memos_pat_next" }, transport: wire.transport)
        reporter.activeHandle = SessionHandle(client: next, generation: 2)
        let places = TripMapPresentation.reporting(PlacesStore(), to: reporter)
        await places.load(using: wire.access.handle, baseURL: TripMapWire.baseURL)
        #expect(wire.transport.markerReads == 1, "precondition: the markers were asked for")
        #expect(places.markers.isEmpty, "an ended session's markers reached the trip's map")
        #expect(places.status == .pending, "and the question was recorded as settled")
    }

    // MARK: - the screen

    fileprivate func host(
        _ stores: (CollectionStore, TripMembershipStore), _ wire: TripMapWire,
        _ record: CollectionRecord, probe: PlacesStageProbe? = nil
    ) -> some View {
        let access = wire.access
        return NavigationStack {
            TripView(
                record: record, collections: stores.0, trips: stores.1, subject: "alice",
                access: { access })
        }
        .environment(\.placesStageProbe, probe)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }

    @Test("Map waits while the drain is on the wire, then says the trip has no places")
    func theScreenWaitsThenSaysEmpty() async {
        let wire = TripMapWire(members: 3, located: ["x0"])
        wire.transport.hold()
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        await CollectionsHost.with(host(stores, wire, record), height: 1400) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Map", on: screen) }
            #expect(chosen, "the Map chip took no press")
            _ = await screen.until { wire.transport.markerReads == 1 }
            #expect(wire.transport.markerReads == 1, "choosing Map read no markers")
            let early = await TripProbe.idle(seconds: 1) {
                screen.says(TripMapPresentation.emptyTitle)
            }
            #expect(!early, "the empty map was said while the drain was on the wire")
            wire.transport.release()
            #expect(
                await screen.until { screen.says(TripMapPresentation.emptyTitle) },
                "the empty map never came: \(TripProbe.labels(in: screen.window))")
            #expect(!TripProbe.identified(TripMapPresentation.mapIdentifier, in: screen.window))
        }
    }

    @Test("Map shows the map for a trip with a located member, the chip chosen")
    func theScreenShowsTheMap() async {
        let wire = TripMapWire(members: 3, located: ["t1", "x0"])
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        await CollectionsHost.with(host(stores, wire, record), height: 1400) { screen in
            let chosen = await screen.until { TripProbe.pressAtOnce("Map", on: screen) }
            #expect(chosen, "the Map chip took no press")
            #expect(
                await screen.until {
                    TripProbe.identified(TripMapPresentation.mapIdentifier, in: screen.window)
                }, "no map: \(TripProbe.labels(in: screen.window))")
            let chip = screen.element(labelled: "Map")
            #expect(chip?.accessibilityTraits.contains(.selected) == true)
            #expect(!screen.says(TripMapPresentation.emptyTitle))
        }
    }
}

extension TripMapTests {
    /// The trip's screen on Map, its stage seen through `probe`, once the map has its markers.
    private func onMap(
        _ screen: PressProbe.Screen, _ probe: PlacesStageProbe, staged: [String]
    ) async -> Bool {
        _ = await screen.until { TripProbe.pressAtOnce("Map", on: screen) }
        return await screen.until { probe.staged == staged && probe.presenting != nil }
    }

    @Test("the screen hands the map the trip's markers only, the 61st member's among them")
    func theScreenStagesOnlyTheTrip() async {
        let wire = TripMapWire(members: 125, located: ["t0", "x9", "t60", "t124"])
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        let probe = PlacesStageProbe()
        let view = host(stores, wire, record, probe: probe)
        await CollectionsHost.with(view, height: 1400) { screen in
            let staged = await onMap(screen, probe, staged: ["t0", "t60", "t124"])
            #expect(staged, "the map was handed \(probe.staged)")
            #expect(wire.transport.pageReads == 3, "precondition: a three-page drain")
        }
    }

    @Test("excluding a picture closes the viewer its pin opened, and takes its pin off")
    func anExclusionClosesTheViewer() async throws {
        let wire = TripMapWire(members: 3, located: ["t0", "t1"])
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        let probe = PlacesStageProbe()
        let selection = try #require(PlacesPresentation.open("t1", in: [Self.marker("t1")]))
        let view = host(stores, wire, record, probe: probe)
        await CollectionsHost.with(view, height: 1400) { screen in
            #expect(await onMap(screen, probe, staged: ["t0", "t1"]), "staged \(probe.staged)")
            probe.tap?(.viewer(selection))
            #expect(probe.presenting?().viewing?.id == "t1", "precondition: the viewer is open")
            stores.0.exclude(id: record.id, uid: "t1")
            let closed = await screen.until { probe.presenting?().viewing == nil }
            #expect(closed, "the viewer stayed open on a picture the trip excluded")
            #expect(await screen.until { probe.staged == ["t0"] }, "staged \(probe.staged)")
        }
    }

    @Test("excluding a picture closes the sheet listing it, and the viewer over that sheet")
    func anExclusionClosesTheSheet() async throws {
        let wire = TripMapWire(members: 3, located: ["t0", "t1"])
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        let probe = PlacesStageProbe()
        let listed = [Self.marker("t0"), Self.marker("t1")]
        let sheet = PlaceSheet(markers: listed, canZoomIn: false, members: [])
        let selection = try #require(PlacesPresentation.open("t0", in: listed))
        let view = host(stores, wire, record, probe: probe)
        await CollectionsHost.with(view, height: 1400) { screen in
            #expect(await onMap(screen, probe, staged: ["t0", "t1"]), "staged \(probe.staged)")
            probe.tap?(.sheet(sheet))
            probe.tap?(.viewer(selection))
            #expect(probe.presenting?().sheet != nil, "precondition: the sheet is up")
            #expect(probe.presenting?().viewingFromSheet != nil, "precondition: a viewer over it")
            stores.0.exclude(id: record.id, uid: "t1")
            let closed = await screen.until {
                probe.presenting?().sheet == nil && probe.presenting?().viewingFromSheet == nil
            }
            #expect(closed, "the sheet or its viewer stayed over a picture the trip excluded")
        }
    }

    @Test("deleting the trip closes the viewer a pin opened on its map")
    func aDeletionClosesTheViewer() async throws {
        let wire = TripMapWire(members: 3, located: ["t0", "t1"])
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        let probe = PlacesStageProbe()
        let selection = try #require(PlacesPresentation.open("t0", in: [Self.marker("t0")]))
        let view = host(stores, wire, record, probe: probe)
        await CollectionsHost.with(view, height: 1400) { screen in
            #expect(await onMap(screen, probe, staged: ["t0", "t1"]), "staged \(probe.staged)")
            probe.tap?(.viewer(selection))
            #expect(probe.presenting?().viewing?.id == "t0", "precondition: the viewer is open")
            let manage = TripManage()
            manage.askDelete()
            #expect(manage.confirmDelete(record.id, in: stores.0, forgetting: stores.1))
            let closed = await screen.until { probe.presenting?().viewing == nil }
            #expect(closed, "the viewer stayed open over a trip that was deleted")
        }
    }
}

// MARK: - Fixtures

/// A session whose active handle the test sets: what a sign-in as somebody else leaves.
@MainActor
final class TripMapReporter: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }
    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }
    func noteTransportFailure(_ failure: ServerReachability.Reason, issuedUnder generation: Int) {}
    func noteTransportSuccess(issuedUnder generation: Int) {}
}

@MainActor
final class TripMapWire {
    static let baseURL = URL(string: "https://memos.example.invalid")!
    let transport: TripMapTransport
    let access: CollectionsAccess

    init(members: Int, located: [String]) {
        transport = TripMapTransport(members: members, located: located)
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.baseURL),
            token: { "memos_pat_trip_map" },
            transport: transport)
        access = CollectionsAccess(
            handle: SessionHandle(client: client, generation: 1), baseURL: Self.baseURL)
    }
}

/// The scripted server: the trip's tag holds `t0`…`t<members-1>` oldest first, paged at the
/// request's own `limit` with an offset for a cursor; the map answers a marker for each of
/// `located`, `x…` being pictures of no trip.
final class TripMapTransport: ClientTransport, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var held = false
    private nonisolated(unsafe) var pages = 0
    private nonisolated(unsafe) var markers = 0
    private nonisolated let members: Int
    private nonisolated let located: [String]

    nonisolated init(members: Int, located: [String]) {
        self.members = members
        self.located = located
    }

    /// Pages of the trip read so far.
    nonisolated var pageReads: Int { lock.withLock { pages } }
    /// Marker reads so far.
    nonisolated var markerReads: Int { lock.withLock { markers } }
    nonisolated func hold() { lock.withLock { held = true } }
    nonisolated func release() { lock.withLock { held = false } }

    nonisolated func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        switch operationID {
        case "list_attachments_api_attachments_get":
            let items = URLComponents(string: request.path ?? "")?.queryItems ?? []
            let query = Dictionary(
                items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            lock.withLock { pages += 1 }
            while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(20)) }
            let start = Int(query["cursor"] ?? "") ?? 0
            let limit = Int(query["limit"] ?? "") ?? 60
            let end = min(start + limit, members)
            let rows = (start..<max(start, end)).map { Self.item("t\($0)", minute: $0) }
            let next = end < members ? "\(end)" : nil
            return Self.json("[" + rows.joined(separator: ",") + "]", next: next)
        case "list_markers_api_map_markers_get":
            lock.withLock { markers += 1 }
            let rows = located.enumerated().map { Self.marker($0.element, index: $0.offset) }
            return Self.json("{\"markers\":[" + rows.joined(separator: ",") + "]}", next: nil)
        case "attachment_tags_api_attachments_tags_get":
            return Self.json("[]", next: nil)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    private nonisolated static func stamp(_ minute: Int) -> String {
        Date(timeIntervalSince1970: 1_772_000_000 + Double(minute) * 60).ISO8601Format()
    }

    private nonisolated static func item(_ uid: String, minute: Int) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":false,"memoUid":"m-\(uid)",\
        "takenAt":"\(stamp(minute))","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private nonisolated static func marker(_ uid: String, index: Int) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,"width":1000,\
        "height":800,"duration":null,"sha256":null,"capture_instant":null,"capture_civil":null,\
        "capture_source":null,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,"renditions":[],\
        "position":null,"thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile","webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print","memo_uid":"m-\(uid)",\
        "latitude":\(38.0 + Double(index)),"longitude":-9.14,"taken_at":"\(stamp(index))"}
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

extension TripMapTests {
    /// The Map's viewer is the trip's too (MEMNG-720): a pin's viewer offers Use as Cover, and it
    /// sets the trip's cover.
    @Test("a trip Map pin's viewer offers Use as Cover, and it makes that picture the cover")
    func aMapViewerUsesAsCover() async throws {
        let wire = TripMapWire(members: 3, located: ["t0", "t1"])
        let stores = stores()
        let record = stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        let probe = PlacesStageProbe()
        let selection = try #require(PlacesPresentation.open("t1", in: [Self.marker("t1")]))
        let view = host(stores, wire, record, probe: probe)
        await CollectionsHost.with(view, height: 1400) { screen in
            #expect(await onMap(screen, probe, staged: ["t0", "t1"]), "staged \(probe.staged)")
            probe.tap?(.viewer(selection))
            // The overlay's control set (MEMNG-768): a pin's one shared action is Show Memo, so
            // the menu is there only because the trip's row is in it — and neither row is a
            // button of its own.
            let menu = await screen.until {
                TripProbe.presentedLabels(over: screen.host).contains("More")
            }
            let drawn = TripProbe.presentedLabels(over: screen.host)
            #expect(menu, "the Map's viewer drew no menu: \(drawn)")
            #expect(
                screen.element(labelled: TripView.useAsCoverButton) == nil,
                "Use as Cover is drawn outside the menu")
            #expect(
                screen.element(labelled: MediaTileAction.showMemo(uid: "").title) == nil,
                "the one shared action is drawn as its own button beside a host's row")
            // The trip's own action, run as the viewer's menu row runs it: a menu cannot be opened
            // from a test, so the row's dispatch is `MediaViewerHostItem.tapped()`.
            let action = TripView.useAsCover(record.id, in: stores.0)
            MediaViewerHostItem(action: action, attachment: selection.startPage.attachment) {}
                .tapped()
            #expect(stores.0.records.first?.coverUid == "t1", "the row chose no cover")
        }
    }
}
