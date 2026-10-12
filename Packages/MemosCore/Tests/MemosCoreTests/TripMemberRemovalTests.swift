import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Trip screen's Remove (MEMNG-722), now an exclusion on the SERVER's record — one PUT per
/// picture under the trip's slot, then the record and the members read again — and Add Back its
/// DELETE. MEMNG-754 moved the cases here from the device-local exclusion list: what was "on file"
/// is now "on the server", read back through a fresh store; the memo's text and tag are never
/// written either way.
@MainActor
@Suite("Trip members — Remove and Add Back")
struct TripMemberRemovalTests {
    private let seeder = TripSeeder()
    private var server: TripServer { seeder.server }
    private nonisolated static let tag = "portugal2026"

    /// A trip of pictures 0..<3 under the tag, drained.
    private func drained(
        _ title: String = "Portugal 2026"
    ) async throws -> (trip: Trip, trips: TripStore, members: TripMemberStore) {
        let uid = server.seed(title: title, tag: Self.tag, pictures: [0, 1, 2])
        let (trips, members) = await seeder.members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 3, "control: the drain landed")
        return (trip, trips, members)
    }

    /// The ids of an exact Removed list, oldest first; nil for any other state.
    private func removedIDs(_ state: TripRemovedState) -> [String]? {
        guard case .exact(let rows) = state else { return nil }
        return rows.map(\.id)
    }

    private func current(_ trip: Trip, in trips: TripStore) throws -> Trip {
        try #require(trips.trips.first { $0.uid == trip.uid })
    }

    /// Every memo or attachment write `server` saw: what a removal must never send.
    private func contentWrites() -> [String] {
        server.calls.all.map(\.operation).filter {
            $0.contains("memo") || $0 == TripServer.deleteAttachment
        }
    }

    @Test("a removal outlives a reload: a fresh store reads the trip without the removed pictures")
    func aRemovalOutlivesAReload() async throws {
        let (trip, _, members) = try await drained()
        try await members.remove(
            [TripWire.uid(2), TripWire.uid(0)], from: trip, using: server.client.handle,
            baseURL: Stub.baseURL)

        #expect(
            server.rows.first?.exclusions == [TripWire.uid(2), TripWire.uid(0)],
            "the server lost the removal")
        let (freshTrips, fresh) = await seeder.members()
        let again = try current(trip, in: freshTrips)
        await fresh.drain(again, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(fresh.members(for: again).map(\.id) == [TripWire.uid(1)])
        await fresh.removed(for: again, using: server.client.handle, baseURL: Stub.baseURL)
        let removed = removedIDs(fresh.removedState(for: again))
        #expect(removed == [0, 2].map(TripWire.uid), "\(String(describing: removed))")
        #expect(contentWrites().isEmpty, "a removal wrote a memo or a file: \(contentWrites())")
    }

    @Test("the count is read again at the removal, the chosen cover giving way, and back")
    func theSummaryAfterARemoval() async throws {
        let (first, trips, members) = try await drained()
        let handle = server.client.handle
        try await trips.update(
            uid: first.uid, patch: TripPatch(cover: .set(TripWire.uid(0))), using: handle,
            baseURL: Stub.baseURL)
        let trip = try current(first, in: trips)
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        #expect(members.summary(for: trip)?.cover?.id == TripWire.uid(0), "control")

        try await members.remove(
            [TripWire.uid(0)], from: trip, using: handle, baseURL: Stub.baseURL)

        // Read from the RECORD the batch re-read, which the root's card draws.
        let after = try current(trip, in: trips)
        #expect(after.memberCount == 2, "the record still counts the removed picture")
        let summary = try #require(members.summary(for: after))
        #expect(summary.firstTaken == TripWire.taken(1), "the span still begins at the removed one")
        #expect(summary.lastTaken == TripWire.taken(2))
        #expect(summary.cover?.id == TripWire.uid(1), "the removed picture is still the cover")
        // The choice itself stands on the server: Add Back makes it the cover again.
        #expect(server.rows.first?.cover == TripWire.uid(0))
        try await members.addBack(
            TripWire.uid(0), to: after, using: handle, baseURL: Stub.baseURL)
        let back = try current(trip, in: trips)
        #expect(back.memberCount == 3)
        #expect(
            members.summary(for: back)?.cover?.id == TripWire.uid(0),
            "Add Back did not bring the chosen cover back")
        #expect(contentWrites().isEmpty, "\(contentWrites())")
    }

    @Test("Add Back returns the picture to the members, the list of removed ones and the server")
    func addBackReturnsAPicture() async throws {
        let (trip, trips, members) = try await drained()
        let handle = server.client.handle
        try await members.remove(
            [TripWire.uid(1), TripWire.uid(2)], from: trip, using: handle, baseURL: Stub.baseURL)
        var live = try current(trip, in: trips)
        #expect(members.members(for: live).map(\.id) == [TripWire.uid(0)])

        try await members.addBack(
            TripWire.uid(2), to: live, using: handle, baseURL: Stub.baseURL)

        live = try current(trip, in: trips)
        #expect(members.members(for: live).map(\.id) == [TripWire.uid(0), TripWire.uid(2)])
        await members.removed(for: live, using: handle, baseURL: Stub.baseURL)
        let removed = removedIDs(members.removedState(for: live))
        #expect(removed == [TripWire.uid(1)], "\(String(describing: removed))")
        #expect(server.rows.first?.exclusions == [TripWire.uid(1)])
    }

    @Test("the removed list is the tag's pictures the members lack, oldest first, and only those")
    func theRemovedList() async throws {
        let uid = server.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        // Removed before anything was read, and a stray no longer under the tag.
        server.edit(uid) { $0.exclusions = [TripWire.uid(2), "p-untagged"] }
        let (trips, members) = await seeder.members()
        let trip = try #require(trips.trips.first)
        #expect(members.removedState(for: trip) == .notRequested, "an unread trip listed rows")
        await members.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        try await members.remove(
            [TripWire.uid(0)], from: trip, using: server.client.handle, baseURL: Stub.baseURL)
        let live = try current(trip, in: trips)
        await members.removed(for: live, using: server.client.handle, baseURL: Stub.baseURL)
        let removed = removedIDs(members.removedState(for: live))
        #expect(removed == [TripWire.uid(0), TripWire.uid(2)], "\(String(describing: removed))")
        // The stray stays excluded — a picture tagged again stays out of the trip — unlisted.
        #expect(server.rows.first?.exclusions.contains("p-untagged") == true)
    }

    @Test("a removal of nothing sends no PUT, and a stranger's removal leaves the members whole")
    func aRemovalOfNothingWritesNothing() async throws {
        let (trip, trips, members) = try await drained()
        let handle = server.client.handle
        let nothing = try await members.remove(
            [], from: trip, using: handle, baseURL: Stub.baseURL)
        #expect(nothing.done.isEmpty)
        #expect(server.calls.of(TripWire.exclude).isEmpty, "a removal of nothing sent a PUT")
        #expect(server.rows.first?.exclusions == [])
        let live = try current(trip, in: trips)
        try await members.remove(
            ["p-stranger"], from: live, using: handle, baseURL: Stub.baseURL)
        let after = try current(trip, in: trips)
        #expect(members.members(for: after).count == 3, "a stranger's removal took a member")
        #expect(after.memberCount == 3)
    }

    @Test("two removals of the same picture in one turn are one request stream")
    func twoRemovalsInOneTurn() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let held = TripServer(hold: { operation, count in
            guard operation == TripWire.exclude, count == 1 else { return }
            entered.open()
            await release.wait()
        })
        let seeder = TripSeeder(server: held)
        held.seed(title: "Portugal 2026", tag: Self.tag, pictures: [0, 1, 2])
        let (trips, members) = await seeder.members()
        let trip = try #require(trips.trips.first)
        let handle = held.client.handle
        let first = Task {
            try await members.remove(
                [TripWire.uid(1)], from: trip, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first PUT never went out")
        // Main-actor work runs without a suspension from the latch to the slot, so once the
        // test sees the latch the second removal has joined or been refused.
        let started = TripLatch()
        let second = Task {
            started.open()
            return try await members.remove(
                [TripWire.uid(1)], from: trip, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await started.wait(), "the second removal never started")
        release.open()
        _ = try await first.value
        _ = try? await second.value
        #expect(held.rows.first?.exclusions == [TripWire.uid(1)])
        let puts = held.calls.of(TripWire.exclude).count
        #expect(puts == 1, "two removals of one picture sent \(puts) PUTs")
    }

    @Test("a removal from one trip leaves another trip of the same tag whole")
    func aRemovalIsThatTripsAlone() async throws {
        server.seed(title: "Kept", tag: Self.tag, pictures: [0, 1, 2])
        server.seed(title: "Cut", tag: Self.tag, pictures: [0, 1, 2])
        let (trips, members) = await seeder.members()
        let kept = try #require(trips.trips.first)
        let cut = try #require(trips.trips.last)
        let handle = server.client.handle
        await members.drain(kept, using: handle, baseURL: Stub.baseURL)
        await members.drain(cut, using: handle, baseURL: Stub.baseURL)
        try await members.remove(
            [TripWire.uid(0)], from: cut, using: handle, baseURL: Stub.baseURL)
        let liveCut = try current(cut, in: trips)
        let liveKept = try current(kept, in: trips)
        #expect(members.members(for: liveCut).count == 2, "control: the removal took")
        await members.drain(liveKept, using: handle, baseURL: Stub.baseURL)
        #expect(members.members(for: liveKept).count == 3, "the other trip lost the picture")
        #expect(liveKept.memberCount == 3)
        #expect(server.rows.first?.exclusions == [])
    }

    @Test("a removal whose PUT fails changes nothing on screen or on the server")
    func aRemovalWhoseWriteFails() async throws {
        let (trip, trips, members) = try await drained()
        server.fail([TripWire.exclude])
        let outcome = try await members.remove(
            [TripWire.uid(0)], from: trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(outcome.done.isEmpty)
        #expect(outcome.stopped == .server(status: 500))
        let live = try current(trip, in: trips)
        #expect(members.members(for: live).count == 3, "a removal the server refused took effect")
        #expect(server.rows.first?.exclusions == [])
        #expect(live.memberCount == 3)
    }

    @Test("after a removal, an Add Back and a failed removal, the count and the members agree")
    func theCountAndTheMembersAgree() async throws {
        let (trip, trips, members) = try await drained()
        let handle = server.client.handle
        func agrees() throws -> Bool {
            let live = try current(trip, in: trips)
            let rows = members.members(for: live)
            let coverOut = members.summary(for: live)?.cover.map { cover in
                server.rows.first?.exclusions.contains(cover.id) ?? false
            }
            return live.memberCount == rows.count && coverOut != true
        }
        #expect(try agrees(), "control: the drain and the record agree")
        try await members.remove(
            [TripWire.uid(0)], from: trip, using: handle, baseURL: Stub.baseURL)
        #expect(try agrees(), "the removal left the count and the members apart")
        #expect(server.rows.first?.exclusions == [TripWire.uid(0)], "control")
        try await members.addBack(
            TripWire.uid(0), to: try current(trip, in: trips), using: handle, baseURL: Stub.baseURL)
        #expect(try agrees(), "the Add Back left the count and the members apart")
        #expect(server.rows.first?.exclusions == [], "control")
        server.fail([TripWire.exclude])
        try await members.remove(
            [TripWire.uid(1)], from: try current(trip, in: trips), using: handle,
            baseURL: Stub.baseURL)
        #expect(try agrees(), "a failed removal left the count and the members apart")
        #expect(try current(trip, in: trips).memberCount == 3)
    }
}
