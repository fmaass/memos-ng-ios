import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// An album's members (MEMNG-804): the cover it falls back to, and Remove from Album — the member
/// DELETE, acknowledged into the record of the app's own removals (MEMNG-793) as an exclusion is,
/// joined when the same removal is asked for twice, and refused by the server on a trip.
@MainActor
@Suite("Album members — cover fallback and Remove from Album")
struct AlbumMemberTests {
    private static let tag = "portugal2026"

    @Test("an album without a chosen cover summarises its newest drained member, a trip its oldest")
    func theFallbackCoverIsKindSwitched() async throws {
        let server = TripServer()
        server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2, 3, 4])
        server.seed(title: "At the sea", pictures: [0, 1, 2, 3, 4], kind: "album")
        // Three of five: the drain stops short, so the newest drained row is not the album's own.
        let (trips, store) = await TripSeeder(server: server).members(pageSize: 2, memberCap: 3)
        let handle = server.client.handle
        let trip = try #require(trips.trips.first { $0.kind == .trip })
        let album = try #require(trips.trips.first { $0.kind == .album })
        await store.drain(trip, using: handle, baseURL: Stub.baseURL)
        await store.drain(album, using: handle, baseURL: Stub.baseURL)

        #expect(store.state(for: album) == .truncated, "precondition: the drain was cut short")
        #expect(store.state(for: trip) == .truncated, "precondition: the drain was cut short")
        #expect(
            store.summary(for: trip)?.cover?.id == TripWire.uid(0),
            "a trip's cover: \(String(describing: store.summary(for: trip)?.cover?.id))")
        #expect(
            store.summary(for: album)?.cover?.id == TripWire.uid(2),
            "an album's cover: \(String(describing: store.summary(for: album)?.cover?.id))")
    }

    @Test("removeMember sends the member DELETE, bumps the revision and records the removal")
    func removeMemberIsAcknowledged() async throws {
        let server = TripServer()
        let uid = server.seed(title: "At the sea", pictures: [0, 1, 2], kind: "album")
        let (trips, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let album = try #require(trips.trips.first)
        await store.drain(album, using: handle, baseURL: Stub.baseURL)
        let before = trips.revision

        let outcome = try await trips.removeMember(
            uid: uid, attachments: [TripWire.uid(1)], using: handle, baseURL: Stub.baseURL)

        #expect(outcome.done == [TripWire.uid(1)], "the outcome: \(outcome)")
        #expect(
            server.calls.of(TripServer.removeMember).map(\.path)
                == ["/api/collections/\(uid)/members/\(TripWire.uid(1))"],
            "the DELETEs: \(server.calls.of(TripServer.removeMember).map(\.path))")
        #expect(server.calls.of(TripWire.exclude).isEmpty, "an album was sent an exclusion")
        #expect(trips.revision > before, "the list revision did not move")
        #expect(
            store.ownExclusions[uid]?[TripWire.uid(1)] != nil,
            "the removal is not in the record: \(store.ownExclusions)")
        let now = try #require(trips.trips.first)
        #expect(!store.members(for: now).contains { $0.id == TripWire.uid(1) })
    }

    @Test("a drain read before a removal and landing inside it keeps the removed picture out")
    func anEarlierDrainKeepsTheRemovalOut() async throws {
        let drainEntered = TripLatch()
        let drainRelease = TripLatch()
        let deleteEntered = TripLatch()
        let deleteRelease = TripLatch()
        let server = TripServer(hold: { operation, count in
            if operation == TripWire.members, count == 1 {
                drainEntered.open()
                await drainRelease.wait()
            }
            if operation == TripServer.removeMember, count == 2 {
                deleteEntered.open()
                await deleteRelease.wait()
            }
        })
        let uid = server.seed(title: "At the sea", pictures: [0, 1, 2], kind: "album")
        let (trips, store) = await TripSeeder(server: server).members()
        let album = try #require(trips.trips.first)
        let handle = server.client.handle

        // The drain reads while all three are members, and answers once the first removal is
        // acknowledged and the second is still out — before the batch moves the revision.
        let early = Task { await store.drain(album, using: handle, baseURL: Stub.baseURL) }
        #expect(await drainEntered.wait(), "the early drain never read")
        let removal = Task {
            try await trips.removeMember(
                uid: uid, attachments: [TripWire.uid(0), TripWire.uid(1)], using: handle,
                baseURL: Stub.baseURL)
        }
        #expect(await deleteEntered.wait(), "the second removal never went out")
        drainRelease.open()
        await early.value

        let during = try #require(trips.trips.first)
        #expect(store.state(for: during) == .complete, "control: the early drain landed")
        #expect(
            store.members(for: during).map(\.id) == [TripWire.uid(1), TripWire.uid(2)],
            "the album's members: \(store.members(for: during).map(\.id))")

        deleteRelease.open()
        let outcome = try await removal.value
        #expect(outcome.done == [TripWire.uid(0), TripWire.uid(1)], "control: both were removed")
    }

    @Test("a 409 on the member DELETE surfaces as the store's refusal, and records nothing")
    func aConflictIsTheStoresRefusal() async throws {
        let server = TripServer()
        let uid = server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1])
        let (trips, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        await #expect(throws: TripStore.Failure.server(status: 409)) {
            try await trips.removeMember(
                uid: uid, attachments: [TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        }
        #expect(server.calls.of(TripServer.removeMember).count == 1, "control: it was sent")
        #expect(store.ownExclusions[uid] == nil, "a refused removal was recorded")
    }

    @Test("two overlapping removes of one picture are one request; another picture is refused")
    func overlappingRemovesJoin() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(hold: { operation, count in
            guard operation == TripServer.removeMember, count == 1 else { return }
            entered.open()
            await release.wait()
        })
        let uid = server.seed(title: "At the sea", pictures: [0, 1, 2], kind: "album")
        let (trips, _) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        var joins = 0
        trips.onJoin = { joins += 1 }

        let first = Task {
            try await trips.removeMember(
                uid: uid, attachments: [TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first removal never went out")
        let second = Task {
            try await trips.removeMember(
                uid: uid, attachments: [TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        }
        for _ in 0..<100_000 where joins == 0 { await Task.yield() }
        #expect(joins == 1, "the second removal did not join the first")
        await #expect(throws: TripStore.Failure.busy) {
            try await trips.removeMember(
                uid: uid, attachments: [TripWire.uid(1)], using: handle, baseURL: Stub.baseURL)
        }
        release.open()
        let one = try await first.value
        let two = try await second.value

        #expect(one.done == [TripWire.uid(0)] && two.done == [TripWire.uid(0)], "\(one) \(two)")
        #expect(
            server.calls.of(TripServer.removeMember).count == 1,
            "requests on the wire: \(server.calls.of(TripServer.removeMember).map(\.path))")
    }
}
