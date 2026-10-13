import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// What a trip write may deliver and what a cached member answer may show: a write's caller is
/// answered only while the slot it waited on is still the latest one on that trip, a removal
/// batch holds its slot through its record re-read and member re-drain, every cached result is
/// fenced by the lineage that produced it, every answered request is reported to the session, a
/// and a change re-reads its record. `@testable` for the join and delivery seams.
@MainActor
@Suite("Trip authority")
struct TripAuthorityTests {
    typealias Answer = (HTTPResponse, HTTPBody?)

    private let root = TripWire.root()

    /// A holder a main-actor seam can park a task in.
    private final class Parked {
        var task: Task<Trip, any Error>?
    }

    private func client(
        _ calls: TripCalls,
        trips: [String] = [TripWire.collection("t1", tag: "lisbon", memberCount: 2)],
        members: @escaping @Sendable (String?) async -> Answer = { _ in TripWire.page([1, 2]) },
        library: @escaping @Sendable (String) async -> Answer = { _ in TripWire.page([]) },
        exclusion: @escaping @Sendable (String) async -> Answer = { _ in Stub.empty(.noContent) },
        record: @escaping @Sendable (String) async -> Answer = { uid in
            Stub.json(TripWire.collection(uid, tag: uid == "t1" ? "lisbon" : nil, memberCount: 1))
        }
    ) -> any APIProtocol {
        Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let path = request.path ?? ""
            let last = String(path.split(separator: "?").first?.split(separator: "/").last ?? "")
            switch operation {
            case TripWire.list: return Stub.json("[\(trips.joined(separator: ","))]")
            case TripWire.get: return await record(last)
            case TripWire.members: return await members(TripWire.query(path, "cursor"))
            case TripWire.library: return await library(path)
            case TripWire.exclude, TripWire.include: return await exclusion(last)
            case TripWire.patch: return Stub.json(TripWire.collection(last, title: "x"))
            default: return Stub.empty(.notFound)
            }
        }
    }

    private func stores(_ client: any APIProtocol) async -> (TripStore, TripMemberStore) {
        let trips = TripStore(identity: TripWire.alice, root: root)
        let members = TripMemberStore(trips: trips)
        await trips.refresh(using: client.handle, baseURL: Stub.baseURL)
        return (trips, members)
    }

    private func trip(_ store: TripStore, _ uid: String = "t1") throws -> Trip {
        try #require(store.trips.first { $0.uid == uid }, "control: the list did not land")
    }

    // MARK: - (1) the caller's authority at delivery

    @Test("a joiner delivered after another write took the slot is superseded")
    func delayedJoinerIsSuperseded() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let joined = TripLatch()
        let taken = TripLatch()
        let client = Stub.client { request, body, operation in
            let index = await calls.record(request, body, operation)
            switch operation {
            case TripWire.list: return Stub.json("[\(TripWire.collection("t1"))]")
            case TripWire.patch:
                let sent = String(decoding: calls.all[index].body, as: UTF8.self)
                if sent.contains("Other") {
                    taken.open()
                    return Stub.json(TripWire.collection("t1", title: "Other"))
                }
                entered.open()
                await release.wait()
                return Stub.json(TripWire.collection("t1", title: "Same"))
            default: return Stub.json(TripWire.collection("t1", title: "Same"))
            }
        }
        let store = TripStore(identity: TripWire.alice, root: root)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let parked = Parked()
        let first = Task {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("Same")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first PATCH never reached the wire")
        store.onJoin = { joined.open() }
        let joiner = Task {
            try await store.update(
                uid: "t1", patch: TripPatch(title: .set("Same")), using: client.handle,
                baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the second caller never joined")
        store.onDelivery = { _, isJoiner in
            guard isJoiner else { return }
            parked.task = Task {
                try await store.update(
                    uid: "t1", patch: TripPatch(title: .set("Other")), using: client.handle,
                    baseURL: Stub.baseURL)
            }
            await taken.wait()
        }
        release.open()
        _ = await first.result
        let delivered = await joiner.result

        #expect(calls.of(TripWire.patch).count == 2, "control: the other write took the slot")
        guard case .failure(let error) = delivered else {
            Issue.record("a joiner was answered after another write took its slot")
            return
        }
        #expect(error as? TripStore.Failure == .superseded)
        _ = await parked.task?.result
    }

    @Test("authority lost during the final PUT applies nothing and moves no revision")
    func authorityLostDuringTheFinalPut() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = client(
            calls,
            exclusion: { uid in
                if uid == "p0002" {
                    entered.open()
                    await release.wait()
                }
                return Stub.empty(.noContent)
            })
        let handle = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: handle)
        let (trips, members) = await stores(client)
        trips.reports(to: session)
        members.reports(to: session)
        let trip = try trip(trips)
        let before = trips.revision
        let removing = Task {
            try await members.remove(
                ["p0001", "p0002"], from: trip, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the final PUT never reached the wire")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        let result = await removing.result

        #expect(calls.of(TripWire.exclude).count == 2, "control: both PUTs were sent")
        guard case .failure(let error) = result else {
            Issue.record("a batch whose session moved during its last PUT reported an outcome")
            return
        }
        #expect(error as? TripStore.Failure == .superseded)
        #expect(trips.revision == before, "a batch past its authority still moved the revision")
    }

    // MARK: - (2) the batch's slot covers its reconciliation

    @Test("a batch holds its slot through the record re-read; an identical one shares it")
    func batchHoldsItsSlotThroughTheReread() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let joined = TripLatch()
        let client = client(
            calls,
            record: { uid in
                entered.open()
                await release.wait()
                return Stub.json(TripWire.collection(uid, tag: "lisbon", memberCount: 1))
            })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        let first = Task {
            try await members.remove(
                ["p0001"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the record re-read never reached the wire")
        await #expect(throws: TripStore.Failure.busy) {
            try await members.remove(
                ["p0002"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        trips.onJoin = { joined.open() }
        let second = Task {
            try await members.remove(
                ["p0001"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "an identical batch did not join the one re-reading")
        release.open()
        let one = try await first.value
        let other = try await second.value

        #expect(one == other, "the joiner did not share the whole outcome")
        #expect(one.recordFresh)
        #expect(calls.of(TripWire.exclude).count == 1, "a refused or joined batch sent a PUT")
        #expect(calls.of(TripWire.get).count == 1, "the joiner re-read the record on its own")
        #expect(calls.of(TripWire.members).count == 1, "the joiner re-drained on its own")
    }

    @Test("a batch holds its slot through the member re-drain")
    func batchHoldsItsSlotThroughTheRedrain() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = client(
            calls,
            members: { _ in
                entered.open()
                await release.wait()
                return TripWire.page([2])
            })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        let first = Task {
            try await members.remove(
                ["p0001"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the member re-drain never reached the wire")
        await #expect(throws: TripStore.Failure.busy) {
            try await members.remove(
                ["p0002"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        release.open()
        let outcome = try await first.value

        #expect(outcome.done == ["p0001"])
        #expect(calls.of(TripWire.exclude).count == 1, "a batch was admitted during the re-drain")
        #expect(members.members(for: try self.trip(trips)).map(\.id) == ["p0002"])
    }

    // MARK: - (3) completed caches are fenced by their lineage

    @Test("a completed Removed list is dropped when another trip changes")
    func removedDroppedWhenAnotherTripChanges() async throws {
        let calls = TripCalls()
        let client = client(
            calls,
            trips: [
                TripWire.collection("t1", tag: "lisbon"), TripWire.collection("t2", tag: "porto"),
            ],
            library: { _ in TripWire.page([1, 2, 3]) })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.removedState(for: trip) == .exact(members.removedRows(["p0003"])))

        let before = trips.revision
        try await trips.update(
            uid: "t2", patch: TripPatch(title: .set("x")), using: client.handle,
            baseURL: Stub.baseURL)
        #expect(trips.revision != before, "control: the change moved the revision")
        #expect(
            members.removedState(for: trip) == .notRequested,
            "a Removed list of an earlier revision is still shown")
        #expect(members.state(for: trip) == .notLoaded, "a drain of an earlier revision is shown")
    }

    @Test("a drain of an earlier session generation is neither shown nor subtracted")
    func drainOfAnEarlierGenerationIsFenced() async throws {
        let calls = TripCalls()
        let drains = LockedValue(0)
        let client = client(
            calls,
            members: { _ in
                drains.set(drains.get() + 1)
                return drains.get() == 1 ? TripWire.page([1, 2]) : TripWire.page([1])
            },
            library: { _ in TripWire.page([1, 2]) })
        let first = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: first)
        let (trips, members) = await stores(client)
        trips.reports(to: session)
        members.reports(to: session)
        let trip = try trip(trips)
        await members.drain(trip, using: first, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 2, "control: generation 1's drain landed")

        let second = SessionHandle(client: client, generation: 2)
        session.activeHandle = second
        #expect(members.members(for: trip).isEmpty, "generation 1's members are shown under 2")
        #expect(members.state(for: trip) == .notLoaded)
        await members.removed(for: trip, using: second, baseURL: Stub.baseURL)

        #expect(calls.of(TripWire.members).count == 2, "generation 2 reused generation 1's drain")
        #expect(members.removedState(for: trip) == .exact(members.removedRows(["p0002"])))
    }

    // MARK: - (4) every answered request is reported

    @Test("noteTransportSuccess per answered candidate page, a later-page failure included")
    func transportSuccessPerCandidatePage() async throws {
        let calls = TripCalls()
        let client = client(
            calls,
            library: { path in
                switch TripWire.query(path, "cursor") {
                case nil: return TripWire.page([1], next: "c1")
                case "c1": return TripWire.page([2], next: "c2")
                default: return Stub.empty(.internalServerError)
                }
            })
        let handle = SessionHandle(client: client, generation: 3)
        let session = TripTestSession(for: handle)
        let (trips, members) = await stores(client)
        trips.reports(to: session)
        members.reports(to: session)
        let trip = try trip(trips)
        await members.removed(for: trip, using: handle, baseURL: Stub.baseURL)

        #expect(calls.of(TripWire.library).count == 3, "control: three candidate pages were read")
        #expect(
            session.successes == [3, 3, 3, 3],
            "one member page, two candidate pages and one answered failure: \(session.successes)")
        #expect(session.failures == 0)
        #expect(members.lastError != nil, "control: the failed page was reported")
    }

    // MARK: - (5) a change re-reads its record

    @Test("PATCH re-reads the record; a failed re-read keeps the acknowledged change")
    func patchRereadsTheRecord() async throws {
        for rereadFails in [false, true] {
            let calls = TripCalls()
            let client = Stub.client { request, body, operation in
                _ = await calls.record(request, body, operation)
                switch operation {
                case TripWire.list:
                    return Stub.json("[\(TripWire.collection("t1", memberCount: 3))]")
                case TripWire.patch:
                    return Stub.json(TripWire.collection("t1", title: "Renamed", memberCount: 3))
                case TripWire.get where rereadFails: return Stub.empty(.internalServerError)
                case TripWire.get:
                    return Stub.json(TripWire.collection("t1", title: "Renamed", memberCount: 5))
                default: return Stub.empty(.notFound)
                }
            }
            let store = TripStore(identity: TripWire.alice, root: root)
            await store.refresh(using: client.handle, baseURL: Stub.baseURL)
            let trip = try await store.update(
                uid: "t1", patch: TripPatch(title: .set("Renamed")), using: client.handle,
                baseURL: Stub.baseURL)

            #expect(calls.all.map(\.operation) == [TripWire.list, TripWire.patch, TripWire.get])
            #expect(trip.title == "Renamed")
            #expect(trip.memberCount == (rereadFails ? 3 : 5))
            #expect(store.trips.first { $0.uid == "t1" }?.memberCount == (rereadFails ? 3 : 5))
        }
    }

    @Test("create re-reads the record; a failed re-read keeps the created trip")
    func createRereadsTheRecord() async throws {
        for rereadFails in [false, true] {
            let calls = TripCalls()
            let client = Stub.client { request, body, operation in
                _ = await calls.record(request, body, operation)
                switch operation {
                case TripWire.create:
                    return Stub.json(
                        TripWire.collection("t9", title: "Porto", memberCount: 0), status: .created)
                case TripWire.get where rereadFails: return Stub.empty(.internalServerError)
                case TripWire.get:
                    return Stub.json(TripWire.collection("t9", title: "Porto", memberCount: 12))
                default: return Stub.empty(.notFound)
                }
            }
            let store = TripStore(identity: TripWire.alice, root: root)
            let trip = try await store.create(
                NewTripRequest(scope: TripWire.alice, title: "Porto"), using: client.handle,
                baseURL: Stub.baseURL)

            #expect(calls.all.map(\.operation) == [TripWire.create, TripWire.get])
            #expect(trip.memberCount == (rereadFails ? 0 : 12))
            #expect(store.trips.map(\.uid) == ["t9"], "the created trip is not listed")
        }
    }

    // MARK: - R2: the empty Removed answer and a pin that cannot extend

    @Test("an empty Removed answer issued before a change adds criteria is not current after it")
    func emptyRemovedIssuedBeforeACriteriaChange() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let calls = TripCalls()
        let client = client(
            calls,
            trips: [TripWire.collection("t1", tag: "lisbon"), TripWire.collection("t2")],
            record: { uid in Stub.json(TripWire.collection(uid, tag: "porto")) })
        let (trips, members) = await stores(client)
        let bare = try trip(trips, "t2")
        members.onRemovedStart = { _ in
            entered.open()
            await release.wait()
        }
        let reading = Task {
            await members.removed(for: bare, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the Removed read never started")
        #expect(members.removedState(for: bare) == .loading, "control: the read holds its slot")
        try await trips.update(
            uid: "t2", patch: TripPatch(tag: .set("porto")), using: client.handle,
            baseURL: Stub.baseURL)
        let tagged = try trip(trips, "t2")
        #expect(tagged.tag == "porto", "control: the change added criteria")
        release.open()
        await reading.value

        #expect(
            members.removedState(for: tagged) == .notRequested,
            "the empty answer of the trip before its change is shown as current")
        #expect(calls.of(TripWire.members).isEmpty, "control: the bare trip read no members")
    }

    @Test("an empty Removed answer issued before another trip changes is not current after it")
    func emptyRemovedIssuedBeforeAnotherTripChanges() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let calls = TripCalls()
        let client = client(
            calls, trips: [TripWire.collection("t1", tag: "lisbon"), TripWire.collection("t2")])
        let (trips, members) = await stores(client)
        let bare = try trip(trips, "t2")
        members.onRemovedStart = { _ in
            entered.open()
            await release.wait()
        }
        let reading = Task {
            await members.removed(for: bare, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the Removed read never started")
        let before = trips.revision
        try await trips.update(
            uid: "t1", patch: TripPatch(title: .set("x")), using: client.handle,
            baseURL: Stub.baseURL)
        #expect(trips.revision != before, "control: the other trip's change moved the revision")
        #expect(members.removedState(for: bare) == .loading, "control: t2's slot is untouched")
        release.open()
        await reading.value

        #expect(
            members.removedState(for: bare) == .notRequested,
            "an empty answer of an earlier revision is shown as current")
    }
}
