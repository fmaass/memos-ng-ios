import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The edges of the trip stores' authority rules: a summary that moves no pin moves no revision,
/// a create key never collides with a trip's slot, a refusal met by a re-read still reaches the
/// session, a batch reconciles only its own trip, and a create's joiner is held to its slot as a
/// write's is. `@testable` for the join and delivery seams.
@MainActor
@Suite("Trip authority edges")
struct TripAuthorityEdgeTests {
    private let root = TripWire.root()

    /// A holder a main-actor seam can park a task in.
    private final class Parked {
        var task: Task<Trip, any Error>?
    }

    private nonisolated static func uid(_ path: String) -> String {
        String(path.split(separator: "?").first?.split(separator: "/").last ?? "")
    }

    private nonisolated static func answer(
        _ operation: String, _ path: String, members: [Int] = [1, 2]
    ) -> (HTTPResponse, HTTPBody?) {
        let name = Self.uid(path)
        switch operation {
        case TripWire.list:
            return Stub.json(
                "[\(TripWire.collection("t1", tag: "lisbon")),\(TripWire.collection("t2"))]")
        case TripWire.get, TripWire.patch: return Stub.json(TripWire.collection(name))
        case TripWire.members: return TripWire.page(members)
        case TripWire.exclude, TripWire.include: return Stub.empty(.noContent)
        default: return Stub.empty(.notFound)
        }
    }

    @Test("a fresh summary that moves no pin moves no revision")
    func summaryWithoutAPinMovesNothing() async throws {
        let client = Stub.client { request, _, operation in
            Self.answer(operation, request.path ?? "", members: [1, 2])
        }
        let trips = TripStore(identity: TripWire.alice, root: root)
        let members = TripMemberStore(trips: trips)
        await trips.refresh(using: client.handle, baseURL: Stub.baseURL)
        let trip = try #require(trips.trips.first { $0.uid == "t1" })
        let before = trips.revision
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)

        #expect(trips.revision == before, "an unpinned trip's summary moved the revision")
        #expect(members.state(for: trip) == .complete)
    }

    @Test("a create key equal to a trip uid does not supersede that trip's write")
    func createKeyDoesNotCollideWithATripSlot() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, operation in
            switch operation {
            case TripWire.patch:
                entered.open()
                await release.wait()
                return Stub.json(TripWire.collection("k1", title: "Patched"))
            case TripWire.create:
                return Stub.json(TripWire.collection("t9"), status: .created)
            default: return Stub.json(TripWire.collection(Self.uid(request.path ?? "")))
            }
        }
        let store = TripStore(identity: TripWire.alice, root: root)
        let patching = Task {
            try await store.update(
                uid: "k1", patch: TripPatch(title: .set("Patched")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the PATCH never reached the wire")
        let created = try await store.create(
            NewTripRequest(scope: TripWire.alice, title: "New", idempotencyKey: "k1"),
            using: client.handle, baseURL: Stub.baseURL)
        release.open()

        #expect(created.uid == "t9")
        #expect(try await patching.value.title == "Patched", "a create key took a trip's slot")
    }

    @Test("a refusal met by a change's re-read still reaches the session's rule")
    func rereadRefusalReachesTheFunnel() async throws {
        let seen = LockedValue(0)
        let client = Stub.client { _, _, operation in
            switch operation {
            case TripWire.patch: return Stub.json(TripWire.collection("t1", title: "x"))
            case TripWire.get: return Stub.detail("Not authenticated", status: .unauthorized)
            default: return Stub.json("[\(TripWire.collection("t1"))]")
            }
        }
        let store = TripStore(
            identity: TripWire.alice, root: root,
            onUnauthorized: { _ in
                seen.set(seen.get() + 1)
                return .superseded
            })
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let trip = try await store.update(
            uid: "t1", patch: TripPatch(title: .set("x")), using: client.handle,
            baseURL: Stub.baseURL)

        #expect(trip.title == "x", "control: the acknowledged change was kept")
        #expect(seen.get() == 1, "the re-read's refusal never reached the rule acting on it")
    }

    @Test("a batch reconciles only its own trip")
    func batchReconcilesOnlyItsTrip() async throws {
        let calls = TripCalls()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            return Self.answer(operation, request.path ?? "")
        }
        let trips = TripStore(identity: TripWire.alice, root: root)
        let members = TripMemberStore(trips: trips)
        await trips.refresh(using: client.handle, baseURL: Stub.baseURL)
        let trip = try #require(trips.trips.first { $0.uid == "t1" })
        _ = try await members.remove(
            ["p0001"], from: trip, using: client.handle, baseURL: Stub.baseURL)

        let drained = calls.of(TripWire.members).map(\.path)
        #expect(drained.count == 1, "the batch drained \(drained)")
        #expect(drained.allSatisfy { $0.contains("/t1/") }, "another trip was drained: \(drained)")
        #expect(calls.of(TripWire.get).map(\.path).allSatisfy { $0.hasSuffix("/t1") })
    }

    @Test("a create's joiner delivered after a retry took its slot is superseded")
    func delayedCreateJoinerIsSuperseded() async throws {
        let posts = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let joined = TripLatch()
        let taken = TripLatch()
        let client = Stub.client { _, _, operation in
            guard operation == TripWire.create else { return Stub.empty(.notFound) }
            posts.set(posts.get() + 1)
            if posts.get() == 1 {
                entered.open()
                await release.wait()
            } else {
                taken.open()
            }
            return Stub.json(TripWire.collection("t9"), status: .created)
        }
        let store = TripStore(identity: TripWire.alice, root: root)
        let frozen = NewTripRequest(scope: TripWire.alice, title: "New", idempotencyKey: "key-1")
        let parked = Parked()
        let first = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the POST never reached the wire")
        store.onJoin = { joined.open() }
        let joiner = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the second caller never joined")
        store.onDelivery = { _, isJoiner in
            guard isJoiner else { return }
            parked.task = Task {
                try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
            }
            await taken.wait()
        }
        release.open()
        _ = await first.result
        let delivered = await joiner.result

        #expect(posts.get() == 2, "control: the retry took the slot")
        guard case .failure(let error) = delivered else {
            Issue.record("a create's joiner was answered after a retry took its slot")
            return
        }
        #expect(error as? TripStore.Failure == .superseded)
        _ = await parked.task?.result
    }
}
