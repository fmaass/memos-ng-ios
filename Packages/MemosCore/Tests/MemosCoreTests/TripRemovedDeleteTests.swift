import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Removed list is exact or unavailable (criterion 5 of the server-trips plan): a picture
/// Delete took is no candidate on the server any more, so an exact list never names it — one
/// computed before the delete, nor one whose candidates were read before it and landed after.
@MainActor
@Suite("Trip members — Removed after a Delete")
struct TripRemovedDeleteTests {
    private static let tag = "portugal2026"

    /// The ids of an exact Removed list; nil for any other state.
    private func exact(_ state: TripRemovedState) -> [String]? {
        guard case .exact(let rows) = state else { return nil }
        return rows.map(\.id)
    }

    /// A trip of pictures 0..<3 with picture 1 removed from it, drained.
    private func removedOne(
        on server: TripServer
    ) async throws -> (trips: TripStore, members: TripMemberStore) {
        server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        let (trips, members) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        try await members.remove(
            [TripWire.uid(1)], from: trip, using: handle, baseURL: Stub.baseURL)
        return (trips, members)
    }

    @Test("a Removed list computed before a delete no longer names the deleted picture")
    func aCachedListLosesTheDeletedPicture() async throws {
        let server = TripServer()
        let (trips, members) = try await removedOne(on: server)
        let handle = server.client.handle
        let trip = try #require(trips.trips.first)
        await members.removed(for: trip, using: handle, baseURL: Stub.baseURL)
        #expect(exact(members.removedState(for: trip)) == [TripWire.uid(1)], "control")

        let outcome = await members.delete([TripWire.uid(1)], using: handle, baseURL: Stub.baseURL)

        #expect(outcome?.deleted == [TripWire.uid(1)], "control: the picture was deleted")
        let after = try #require(trips.trips.first)
        #expect(
            exact(members.removedState(for: after)) == [],
            "the exact Removed list still offers a deleted picture: \(members.removedState(for: after))"
        )
    }

    @Test("candidates read before a delete and landing after it leave the deleted picture out")
    func aHeldListLosesTheDeletedPicture() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(hold: { operation, count in
            guard operation == TripWire.library, count == 1 else { return }
            entered.open()
            await release.wait()
        })
        let (trips, members) = try await removedOne(on: server)
        let handle = server.client.handle
        let trip = try #require(trips.trips.first)

        let read = Task { await members.removed(for: trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the candidates were never read")
        let outcome = await members.delete([TripWire.uid(1)], using: handle, baseURL: Stub.baseURL)
        release.open()
        await read.value

        #expect(outcome?.deleted == [TripWire.uid(1)], "control: the picture was deleted")
        let after = try #require(trips.trips.first)
        #expect(
            exact(members.removedState(for: after)) == [],
            "a list read before the delete offers it: \(members.removedState(for: after))")
    }
}
