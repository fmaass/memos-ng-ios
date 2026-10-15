import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The trip grid's Kind and Sort (MEMNG-780, decision 2): a filtered read of the member route,
/// with `type` and `order` on the wire, in a slot of its own beside the unfiltered members the
/// hero, the Journal, the Map and the Removed list read. The REAL `TripMemberStore`, every page
/// through the generated client.
@MainActor
@Suite("Trip members — the grid's filter")
struct TripMemberFilterTests {
    private let seeder = TripSeeder()

    private func seeded() async -> (trip: Trip, trips: TripStore, members: TripMemberStore) {
        let uid = seeder.server.seed(title: "Portugal 2026", tag: "portugal2026", pictures: [])
        let (trips, members) = await seeder.members()
        let trip =
            trips.trips.first { $0.uid == uid }
            ?? Trip(uid: uid, title: "Portugal 2026", createdAt: .now, updatedAt: .now)
        return (trip, trips, members)
    }

    @Test(
        "each filter's read carries its type and order; the default sends nothing of its own",
        arguments: [
            (MediaLibraryFilter.images, MediaLibraryOrder.oldestFirst, "image", "taken_asc"),
            (.videos, .newestFirst, "video", "taken_desc"),
            (.all, .newestFirst, nil, "taken_desc"),
        ] as [(MediaLibraryFilter, MediaLibraryOrder, String?, String)])
    func theFilteredRequest(
        filter: MediaLibraryFilter, order: MediaLibraryOrder, type: String?, wire: String
    ) async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return TripWire.page([0, 1])
        }
        let (trip, _, members) = await seeded()
        let query = TripMemberQuery(filter: filter, order: order)
        await members.drainFiltered(
            trip, query: query, using: client.handle, baseURL: Stub.baseURL)
        let sent = paths.get()
        #expect(sent.count == 1, "one page, one read: \(sent)")
        let path = sent.first ?? ""
        #expect(path.hasPrefix("/api/collections/\(trip.uid)/attachments"), "\(path)")
        #expect(TripWire.query(path, "type") == type, "the kind on the wire: \(path)")
        #expect(TripWire.hasQuery(path, "type") == (type != nil), "\(path)")
        #expect(TripWire.query(path, "order") == wire, "the order on the wire: \(path)")
        #expect(members.filteredMembers(for: trip, query: query) != nil, "control: it landed")

        await members.drainFiltered(
            trip, query: .unfiltered, using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == 1, "the default sent a read of its own: \(paths.get())")
    }

    @Test("an answer to an earlier filter that lands after the filter changed is dropped")
    func aStaleFilterIsDropped() async {
        let entered = TripLatch()
        let release = TripLatch()
        let calls = LockedValue(0)
        let client = Stub.client { request, _, _ in
            let call = calls.get() + 1
            calls.set(call)
            if call == 1 {
                entered.open()
                await release.wait()
                return TripWire.page([0, 1, 2])
            }
            return TripWire.page([3])
        }
        let (trip, _, members) = await seeded()
        let newest = TripMemberQuery(filter: .all, order: .newestFirst)
        let images = TripMemberQuery(filter: .images, order: .oldestFirst)
        let first = Task {
            await members.drainFiltered(
                trip, query: newest, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        await members.drainFiltered(
            trip, query: images, using: client.handle, baseURL: Stub.baseURL)
        release.open()
        await first.value
        #expect(
            members.filteredMembers(for: trip, query: images)?.map(\.id) == [TripWire.uid(3)],
            "the later filter's answer does not stand")
        #expect(members.filteredMembers(for: trip, query: newest) == nil, "the stale one stands")

        // Back to the default while a filtered read is out: its answer lands nowhere either.
        let late = TripLatch()
        let go = TripLatch()
        let held = Stub.client { _, _, _ in
            late.open()
            await go.wait()
            return TripWire.page([4])
        }
        let again = Task {
            await members.drainFiltered(
                trip, query: newest, using: held.handle, baseURL: Stub.baseURL)
        }
        #expect(await late.wait(), "no request was sent")
        await members.drainFiltered(
            trip, query: .unfiltered, using: held.handle, baseURL: Stub.baseURL)
        go.open()
        await again.value
        #expect(members.filteredMembers(for: trip, query: newest) == nil, "a retired read landed")
    }

    @Test("the unfiltered members, their summary and their state stand through a filtered read")
    func theMembersStandThroughAFilter() async {
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            return TripWire.hasQuery(path, "type") ? TripWire.page([1]) : TripWire.page([0, 1, 2])
        }
        let (trip, _, members) = await seeded()
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        let before = members.members(for: trip).map(\.id)
        #expect(before.count == 3, "control: the drain landed")
        let images = TripMemberQuery(filter: .images, order: .newestFirst)
        await members.drainFiltered(
            trip, query: images, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.filteredMembers(for: trip, query: images)?.map(\.id) == [TripWire.uid(1)])
        #expect(members.members(for: trip).map(\.id) == before, "the members moved with a filter")
        #expect(members.summary(for: trip)?.cover?.id == before.first)
        #expect(members.state(for: trip) == .complete)
        // The default IS the unfiltered members, read by no request of its own.
        #expect(members.filteredMembers(for: trip, query: .unfiltered)?.map(\.id) == before)
    }
}
