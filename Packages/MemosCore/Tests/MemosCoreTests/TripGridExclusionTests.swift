import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A drain read before a removal can land inside the removal's batch, before the batch's own
/// revision bump refuses it: the picture the server has acknowledged taking out must still read as
/// out of the trip — not among the members the grid draws, and on the Removed list (MEMNG-793).
@MainActor
@Suite("Trip members — an acknowledged removal against an earlier drain")
struct TripGridExclusionTests {
    private static let tag = "portugal2026"

    @Test("a drain read before a removal and landing inside its batch keeps the removal out")
    func anEarlierDrainKeepsTheRemovalOut() async throws {
        let drainEntered = TripLatch()
        let drainRelease = TripLatch()
        let putEntered = TripLatch()
        let putRelease = TripLatch()
        let server = TripServer(hold: { operation, count in
            if operation == TripWire.members, count == 1 {
                drainEntered.open()
                await drainRelease.wait()
            }
            if operation == TripWire.exclude, count == 2 {
                putEntered.open()
                await putRelease.wait()
            }
        })
        server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle

        // The drain reads while all three are members, and answers once the first removal is
        // acknowledged and the second is still out.
        let early = Task { await store.drain(trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await drainEntered.wait(), "the early drain never read")
        let removal = Task {
            try await store.remove(
                [TripWire.uid(0), TripWire.uid(1)], from: trip, using: handle,
                baseURL: Stub.baseURL)
        }
        #expect(await putEntered.wait(), "the second removal never went out")
        drainRelease.open()
        await early.value

        let during = try #require(trips.trips.first)
        #expect(store.state(for: during) == .complete, "control: the early drain landed")
        #expect(
            store.members(for: during).map(\.id) == [TripWire.uid(1), TripWire.uid(2)],
            "the grid's members: \(store.members(for: during).map(\.id))")
        await store.removed(for: during, using: handle, baseURL: Stub.baseURL)
        let removedNow = store.removedState(for: during)
        guard case .exact(let rows) = removedNow else {
            Issue.record("the Removed list is not exact: \(removedNow)")
            putRelease.open()
            _ = try? await removal.value
            return
        }
        #expect(rows.map(\.id) == [TripWire.uid(0)], "the Removed list: \(rows.map(\.id))")

        putRelease.open()
        let outcome = try await removal.value
        #expect(outcome.done == [TripWire.uid(0), TripWire.uid(1)], "control: both were removed")
    }

    @Test("a removal from one trip leaves the picture among another trip's members")
    func aRemovalStaysOutOfOnlyItsTrip() async throws {
        let server = TripServer()
        server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        server.seed(title: "Portugal again", tag: Self.tag, pictures: [0, 1, 2])
        let (trips, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let first = try #require(trips.trips.first { $0.title == "Portugal 2026" })
        try await store.remove([TripWire.uid(0)], from: first, using: handle, baseURL: Stub.baseURL)

        let other = try #require(trips.trips.first { $0.title == "Portugal again" })
        await store.drain(other, using: handle, baseURL: Stub.baseURL)
        let removedFrom = try #require(trips.trips.first { $0.uid == first.uid })
        #expect(!store.members(for: removedFrom).contains { $0.id == TripWire.uid(0) }, "control")
        #expect(
            store.members(for: other).map(\.id) == [0, 1, 2].map(TripWire.uid),
            "a removal from one trip took the picture out of another's grid")
    }
}
