import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Trip screen's Delete (MEMNG-721): the Library's one-at-a-time run
/// (`MediaLibraryStore.deleteRun`) through the same generated client, and what it took leaves the
/// trip's members and, once its record is read again, its count. MEMNG-754 moved the cases onto the
/// `TripMemberStore` of a server-listed trip, their assertions kept.
@MainActor
@Suite("Trip members — Delete")
struct TripMemberDeleteTests {
    /// The paths of the DELETEs for pictures `indices`, in that order.
    private nonisolated static func deletes(_ indices: [Int]) -> [String] {
        indices.map { "/api/attachments/\(TripWire.uid($0))" }
    }

    /// A trip holding pictures 0..<3 on `server`, drained.
    private func drained(
        on server: TripServer, handle: SessionHandle? = nil,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async throws -> (trip: Trip, trips: TripStore, members: TripMemberStore) {
        let seeder = TripSeeder(server: server)
        server.seed(title: "Portugal 2026", tag: "portugal2026", pictures: [0, 1, 2])
        let (trips, members) = await seeder.members(onUnauthorized: onUnauthorized)
        let trip = try #require(trips.trips.first)
        await members.drain(trip, using: handle ?? server.client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 3, "control: the drain landed")
        return (trip, trips, members)
    }

    @Test("a trip's delete sends one DELETE per picture in order, and they leave the trip")
    func aDeleteLeavesTheTrip() async throws {
        let server = TripServer()
        let (trip, trips, members) = try await drained(on: server)

        let outcome = await members.delete(
            [TripWire.uid(2), TripWire.uid(0)], using: server.client.handle, baseURL: Stub.baseURL)

        let sent = server.calls.of(TripServer.deleteAttachment).map(\.path)
        #expect(sent == Self.deletes([2, 0]), "sent \(sent)")
        #expect(outcome?.deleted == [TripWire.uid(2), TripWire.uid(0)])
        #expect(members.members(for: trip).map(\.id) == [TripWire.uid(1)])
        #expect(server.calls.of(TripWire.get).count == 1, "the record was not read again")
        let current = try #require(trips.trips.first)
        #expect(current.memberCount == 1, "the trip's count still counts the deleted pictures")
        await members.drain(current, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(members.summary(for: current)?.cover?.id == TripWire.uid(1))
        #expect(!members.isDeleting)
    }

    @Test("a second trip delete while one runs is refused and sends nothing")
    func aSecondTripDeleteIsRefused() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(hold: { operation, _ in
            guard operation == TripServer.deleteAttachment else { return }
            entered.open()
            await release.wait()
        })
        let (trip, _, members) = try await drained(on: server)
        let handle = server.client.handle

        let first = Task {
            await members.delete([TripWire.uid(0)], using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first DELETE never went out")
        #expect(members.isDeleting)
        let second = await members.delete([TripWire.uid(1)], using: handle, baseURL: Stub.baseURL)
        release.open()
        let outcome = await first.value

        #expect(second == nil, "the second run was not refused")
        #expect(outcome?.deleted == [TripWire.uid(0)])
        let sent = server.calls.of(TripServer.deleteAttachment).map(\.path)
        #expect(sent == Self.deletes([0]), "sent \(sent)")
        #expect(members.members(for: trip).map(\.id) == [TripWire.uid(1), TripWire.uid(2)])
    }

    @Test("a drain read before a trip delete cannot bring the deleted picture back")
    func aLateDrainDoesNotResurrect() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(hold: { operation, count in
            guard operation == TripWire.members, count == 2 else { return }
            entered.open()
            await release.wait()
        })
        let (trip, _, members) = try await drained(on: server)
        let handle = server.client.handle

        // A second drain reads the page while the picture is still on the server, and answers
        // after the delete has taken it.
        let late = Task { await members.drain(trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the second drain never read")
        _ = await members.delete([TripWire.uid(1)], using: handle, baseURL: Stub.baseURL)
        release.open()
        await late.value

        let current = trips(of: members).first { $0.uid == trip.uid } ?? trip
        #expect(members.members(for: current).map(\.id) == [TripWire.uid(0), TripWire.uid(2)])
        #expect(members.members(for: trip).map(\.id) == [TripWire.uid(0), TripWire.uid(2)])
    }

    @Test("a session change during a trip delete sends nothing further and applies nothing")
    func aSessionChangeStopsTheTripDelete() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(hold: { operation, _ in
            guard operation == TripServer.deleteAttachment else { return }
            entered.open()
            await release.wait()
        })
        let client = server.client
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        let (trip, _, members) = try await drained(on: server, handle: issued)
        members.reports(to: session)

        let run = Task {
            await members.delete(
                [TripWire.uid(0), TripWire.uid(1)], using: issued, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first DELETE never went out")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        let outcome = await run.value

        let sent = server.calls.of(TripServer.deleteAttachment).map(\.path)
        #expect(sent == Self.deletes([0]), "sent \(sent)")
        #expect(outcome?.stoppedForSessionChange == true)
        #expect(outcome?.notAttempted == [TripWire.uid(1)])
        // The drain belongs to generation 1, which the session's own fence now hides, so the
        // trip is read here by what the run applied: no picture it deleted is taken from it.
        #expect(members.deleted.isEmpty, "a stale run changed the trip: \(members.deleted)")
    }

    @Test("a refused trip delete goes to the session's funnel and writes no sentence")
    func aRefusedTripDeleteReachesTheSession() async throws {
        let handled = LockedValue(0)
        let server = TripServer(deleteStatus: .unauthorized)
        let (trip, _, members) = try await drained(
            on: server,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })

        let outcome = await members.delete(
            [TripWire.uid(0), TripWire.uid(1)], using: server.client.handle, baseURL: Stub.baseURL)

        #expect(handled.get() == 1, "the refusal did not reach the session")
        let sent = server.calls.of(TripServer.deleteAttachment)
        #expect(sent.count == 1, "the run went on past a refusal: \(sent.map(\.path))")
        #expect(outcome?.failed == TripWire.uid(0))
        #expect(outcome?.deleted.isEmpty == true)
        #expect(members.lastError == nil, "the delete wrote a sentence over the photos")
        #expect(members.members(for: trip).count == 3)
    }

    private func trips(of members: TripMemberStore) -> [Trip] { members.trips.trips }
}
