import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A server-backed trip's members (the member route), its removal batches and its Removed list,
/// through the REAL generated client over a scripted transport and a REAL `TripStore`.
@MainActor
@Suite("Trip members")
struct TripMemberStoreTests {
    typealias Answer = (HTTPResponse, HTTPBody?)

    private let root = TripWire.root()

    private func client(
        _ calls: TripCalls,
        trips: [String] = [TripWire.collection("t1", tag: "lisbon", memberCount: 2)],
        members: @escaping @Sendable (String?) async -> Answer = { _ in TripWire.page([1, 2]) },
        library: @escaping @Sendable (String) async -> Answer = { _ in TripWire.page([]) },
        exclusion: @escaping @Sendable (String) async -> Answer = { _ in Stub.empty(.noContent) },
        record: @escaping @Sendable (String) async -> Answer = { uid in
            Stub.json(TripWire.collection(uid, tag: uid == "t1" ? "lisbon" : nil, memberCount: 2))
        }
    ) -> any APIProtocol {
        Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let path = request.path ?? ""
            switch operation {
            case TripWire.list: return Stub.json("[\(trips.joined(separator: ","))]")
            case TripWire.get: return await record(String(path.split(separator: "/").last ?? ""))
            case TripWire.members: return await members(TripWire.query(path, "cursor"))
            case TripWire.library: return await library(path)
            case TripWire.exclude, TripWire.include:
                return await exclusion(String(path.split(separator: "/").last ?? ""))
            case TripWire.patch: return Stub.json(TripWire.collection("t2", title: "x"))
            default: return Stub.empty(.notFound)
            }
        }
    }

    private func stores(
        _ client: any APIProtocol, cap: Int = TripMemberStore.memberCap
    ) async -> (TripStore, TripMemberStore) {
        let trips = TripStore(identity: TripWire.alice, root: root)
        let members = TripMemberStore(trips: trips, memberCap: cap)
        await trips.refresh(using: client.handle, baseURL: Stub.baseURL)
        return (trips, members)
    }

    private func trip(_ store: TripStore, _ uid: String = "t1") throws -> Trip {
        try #require(store.trips.first { $0.uid == uid }, "control: the list did not land")
    }

    private nonisolated static func span(_ first: Int, _ last: Int) -> (String, String) {
        (TripWire.stamp(TripWire.taken(first)), TripWire.stamp(TripWire.taken(last)))
    }

    // MARK: - drain

    @Test("member drain path and query: taken_asc, the page size, no type")
    func drainPathAndQuery() async throws {
        let calls = TripCalls()
        let client = client(calls)
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)

        let sent = try #require(calls.of(TripWire.members).first, "no member page was asked")
        #expect(sent.path.hasPrefix("/api/collections/t1/attachments?"))
        #expect(TripWire.query(sent.path, "order") == "taken_asc")
        #expect(TripWire.query(sent.path, "limit") == "60")
        #expect(!TripWire.hasQuery(sent.path, "type"), "a type filter was sent")
        #expect(members.members(for: trip).map(\.id) == ["p0001", "p0002"])
        #expect(members.state(for: trip) == .complete)
    }

    @Test("a three-page cursor chain completes on an empty cursor")
    func threePageChain() async throws {
        let calls = TripCalls()
        let client = client(calls) { cursor in
            switch cursor {
            case nil: TripWire.page(Array(0..<60), next: "c1")
            case "c1": TripWire.page(Array(60..<120), next: "c2")
            default: TripWire.page(Array(120..<130))
            }
        }
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)

        let cursors = calls.of(TripWire.members).map { TripWire.query($0.path, "cursor") }
        #expect(cursors == [nil, "c1", "c2"])
        #expect(members.members(for: trip).count == 130)
        #expect(members.state(for: trip) == .complete)
    }

    @Test("complete is false at the cap")
    func truncatedAtTheCap() async throws {
        let calls = TripCalls()
        let client = client(calls) { cursor in
            cursor == nil
                ? TripWire.page(Array(0..<60), next: "c1")
                : TripWire.page(Array(60..<120), next: "c2")
        }
        let (trips, members) = await stores(client, cap: 100)
        let trip = try trip(trips)
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)

        #expect(calls.of(TripWire.members).count == 2)
        #expect(members.members(for: trip).count == 100)
        #expect(members.state(for: trip) == .truncated)
    }

    @Test("a page under a moved revision is dropped")
    func pageUnderMovedRevision() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let pages = LockedValue(0)
        let client = client(calls) { _ in
            pages.set(pages.get() + 1)
            if pages.get() == 1 {
                entered.open()
                await release.wait()
            }
            return TripWire.page([1, 2])
        }
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        let draining = Task {
            await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the page never reached the wire")
        trips.pin(uid: "t1", lastTaken: nil, now: Date())
        release.open()
        await draining.value
        #expect(members.members(for: trip).isEmpty, "a page of the old revision was applied")
        #expect(members.state(for: trip) == .notLoaded)

        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 2, "control: a fresh drain lands")
    }

    // MARK: - remove

    @Test("remove sends one PUT per uid in order")
    func removeSendsPutsInOrder() async throws {
        let calls = TripCalls()
        let client = client(calls)
        let (trips, members) = await stores(client)
        let outcome = try await members.remove(
            ["p0001", "p0002", "p0003"], from: try trip(trips), using: client.handle,
            baseURL: Stub.baseURL)

        #expect(
            calls.of(TripWire.exclude).map(\.path) == [
                "/api/collections/t1/exclusions/p0001", "/api/collections/t1/exclusions/p0002",
                "/api/collections/t1/exclusions/p0003",
            ])
        #expect(outcome.done == ["p0001", "p0002", "p0003"])
        #expect(outcome.stopped == nil)
        #expect(outcome.recordFresh)
    }

    @Test("remove stops at the first failure with the earlier ones acknowledged")
    func removeStopsAtFirstFailure() async throws {
        let calls = TripCalls()
        let client = client(
            calls,
            exclusion: { uid in
                uid == "p0002" ? Stub.validationError("no") : Stub.empty(.noContent)
            })
        let (trips, members) = await stores(client)
        let outcome = try await members.remove(
            ["p0001", "p0002", "p0003"], from: try trip(trips), using: client.handle,
            baseURL: Stub.baseURL)

        #expect(calls.of(TripWire.exclude).count == 2, "the batch went on past its failure")
        #expect(outcome.done == ["p0001"])
        #expect(outcome.stopped == .server(status: 422))
    }

    @Test("a stale authority before the second PUT stops the batch")
    func staleAuthorityStopsTheBatch() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = client(
            calls,
            exclusion: { uid in
                if uid == "p0001" {
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
        let removing = Task {
            try await members.remove(
                ["p0001", "p0002"], from: trip, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first PUT never reached the wire")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        let result = await removing.result

        #expect(calls.of(TripWire.exclude).count == 1, "a PUT was sent under a stale authority")
        guard case .failure(let error) = result else {
            Issue.record("a batch whose session moved reported an outcome")
            return
        }
        #expect(error as? TripStore.Failure == .superseded)
    }

    @Test("PUT ok and GET fail is a success with a stale count")
    func putOkGetFail() async throws {
        let calls = TripCalls()
        let client = client(calls, record: { _ in Stub.validationError("no") })
        let (trips, members) = await stores(client)
        let outcome = try await members.remove(
            ["p0001"], from: try trip(trips), using: client.handle, baseURL: Stub.baseURL)

        #expect(calls.of(TripWire.exclude).count == 1)
        #expect(outcome.done == ["p0001"], "an acknowledged exclusion was not reported done")
        #expect(outcome.stopped == nil)
        #expect(!outcome.recordFresh, "a failed re-read was reported fresh")
    }

    @Test("two overlapping batches are one request stream and one busy")
    func overlappingBatches() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = client(
            calls,
            exclusion: { uid in
                if uid == "p0001" {
                    entered.open()
                    await release.wait()
                }
                return Stub.empty(.noContent)
            })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        let first = Task {
            try await members.remove(
                ["p0001", "p0002"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first batch never reached the wire")
        await #expect(throws: TripStore.Failure.busy) {
            try await members.remove(
                ["p0003"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        release.open()
        let outcome = try await first.value

        #expect(outcome.done == ["p0001", "p0002"])
        #expect(calls.of(TripWire.exclude).map(\.path).allSatisfy { !$0.hasSuffix("p0003") })
        #expect(calls.of(TripWire.exclude).count == 2)
    }

    @Test("record re-read and re-drain after every batch end")
    func rereadAndRedrainAfterEveryBatch() async throws {
        let calls = TripCalls()
        let client = client(
            calls,
            exclusion: { uid in
                uid == "p0009" ? Stub.validationError("no") : Stub.empty(.noContent)
            })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)

        _ = try await members.remove(
            ["p0001"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.of(TripWire.get).count == 1, "a whole batch was not re-read")
        #expect(calls.of(TripWire.members).count == 1, "a whole batch was not re-drained")

        let failed = try await members.remove(
            ["p0009"], from: trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(failed.done.isEmpty)
        #expect(calls.of(TripWire.get).count == 2, "a failed batch was not re-read")
        #expect(calls.of(TripWire.members).count == 2, "a failed batch was not re-drained")
    }

    // MARK: - Removed

    @Test("tag-only Removed sends the trip's tag")
    func removedTagOnly() async throws {
        let calls = TripCalls()
        let client = client(calls, library: { _ in TripWire.page([1, 2, 3]) })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)

        let listings = calls.of(TripWire.library)
        #expect(!listings.isEmpty, "no candidate listing was asked")
        #expect(listings.allSatisfy { TripWire.query($0.path, "tag") == "lisbon" })
        #expect(members.removedState(for: trip) == .exact(members.removedRows(["p0003"])))
    }

    @Test("span-only Removed walks the untagged taken-order listing and sends no tag")
    func removedSpanOnly() async throws {
        let calls = TripCalls()
        let (start, end) = Self.span(0, 10)
        let client = client(
            calls, trips: [TripWire.collection("t1", spanStart: start, spanEnd: end)],
            library: { _ in TripWire.page([12, 10, 5, 2, 1, 0, -1], next: "more") })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)

        let listings = calls.of(TripWire.library)
        #expect(listings.count == 1, "the walk went past the span's start")
        #expect(listings.allSatisfy { !TripWire.hasQuery($0.path, "tag") })
        #expect(listings.allSatisfy { TripWire.query($0.path, "order") == "taken_desc" })
        #expect(
            members.removedState(for: trip)
                == .exact(members.removedRows(["p0000", "p0005", "p0010"])))
    }

    @Test("tag and span Removed lists an overlap once")
    func removedBothOverlapOnce() async throws {
        let calls = TripCalls()
        let (start, end) = Self.span(3, 4)
        let client = client(
            calls,
            trips: [TripWire.collection("t1", tag: "lisbon", spanStart: start, spanEnd: end)],
            members: { _ in TripWire.page([1]) },
            library: { path in
                TripWire.hasQuery(path, "tag") ? TripWire.page([1, 3]) : TripWire.page([4, 3, 2])
            })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.removedState(for: trip) == .exact(members.removedRows(["p0003", "p0004"])))
    }

    @Test("a trip with neither tag nor span requests nothing for Removed")
    func removedNeither() async throws {
        let calls = TripCalls()
        let client = client(calls, trips: [TripWire.collection("t1")])
        let (trips, members) = await stores(client)
        let before = calls.all.count
        await members.removed(for: try trip(trips), using: client.handle, baseURL: Stub.baseURL)

        #expect(calls.all.count == before, "a trip with no rule sent \(calls.all.count - before)")
        #expect(members.removedState(for: try trip(trips)) == .exact([]))
    }

    @Test("the span boundary is inclusive")
    func removedSpanBoundaryInclusive() async throws {
        let calls = TripCalls()
        let (start, end) = Self.span(2, 5)
        let client = client(
            calls, trips: [TripWire.collection("t1", spanStart: start, spanEnd: end)],
            members: { _ in TripWire.page([]) },
            library: { _ in TripWire.page([6, 5, 3, 2, 1]) })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)

        #expect(
            members.removedState(for: trip)
                == .exact(members.removedRows(["p0002", "p0003", "p0005"])))
    }

    @Test("Removed is exact for a complete drain")
    func removedExactForCompleteDrain() async throws {
        let calls = TripCalls()
        let client = client(
            calls, members: { _ in TripWire.page([1, 4]) },
            library: { _ in TripWire.page([1, 2, 3, 4]) })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.state(for: trip) == .complete)
        #expect(members.removedState(for: trip) == .exact(members.removedRows(["p0002", "p0003"])))
    }

    @Test("Removed is unavailable for a truncated drain")
    func removedUnavailableWhenTruncated() async throws {
        let calls = TripCalls()
        let client = client(
            calls, members: { _ in TripWire.page([1, 2, 3], next: "more") },
            library: { _ in TripWire.page([1, 2, 3, 4]) })
        let (trips, members) = await stores(client, cap: 2)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.state(for: trip) == .truncated, "control: the drain hit the cap")
        #expect(members.removedState(for: trip) == .unavailable)
    }

    @Test("Removed is unavailable for a stale drain")
    func removedUnavailableWhenStale() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let client = client(
            calls,
            trips: [
                TripWire.collection("t1", tag: "lisbon"), TripWire.collection("t2", tag: "porto"),
            ],
            library: { _ in
                entered.open()
                await release.wait()
                return TripWire.page([1, 2, 3])
            })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        let computing = Task {
            await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the candidate listing never reached the wire")
        try await trips.update(
            uid: "t2", patch: TripPatch(title: .set("x")), using: client.handle,
            baseURL: Stub.baseURL)
        release.open()
        await computing.value

        #expect(members.removedState(for: trip) == .unavailable)
    }

    @Test("nothing is requested for Removed until asked")
    func removedIsLazy() async throws {
        let calls = TripCalls()
        let client = client(calls, library: { _ in TripWire.page([1, 2, 3]) })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        await trips.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(calls.of(TripWire.library).isEmpty, "a candidate listing was asked unasked")
        #expect(members.removedState(for: try self.trip(trips)) == .notRequested)
        let current = try self.trip(trips)
        await members.removed(for: current, using: client.handle, baseURL: Stub.baseURL)
        #expect(!calls.of(TripWire.library).isEmpty, "control: asking reads the candidates")
    }

    @Test("Removed is invalidated by an exclusion with unchanged updatedAt")
    func removedInvalidatedByExclusion() async throws {
        let calls = TripCalls()
        let client = client(calls, library: { _ in TripWire.page([1, 2, 3]) })
        let (trips, members) = await stores(client)
        let trip = try trip(trips)
        await members.removed(for: trip, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.removedState(for: trip) == .exact(members.removedRows(["p0003"])))

        try await trips.exclude(
            uid: "t1", attachment: "p0001", using: client.handle, baseURL: Stub.baseURL)
        #expect(try self.trip(trips).updatedAt == trip.updatedAt, "control: updatedAt unchanged")
        #expect(members.removedState(for: trip) == .notRequested, "a stale Removed list stayed")
    }

    // MARK: - cover

    @Test("a chosen cover outside the members falls back to the first member")
    func coverFallsBackToFirstMember() async throws {
        let calls = TripCalls()
        let outside = TripWire.item("p0099", taken: TripWire.taken(99))
        let inside = TripWire.item("p0002", taken: TripWire.taken(2))
        let client = client(
            calls,
            trips: [
                TripWire.collection("t1", tag: "a", cover: outside, memberCount: 157),
                TripWire.collection("t2", tag: "b", cover: inside, memberCount: 3),
            ])
        let (trips, members) = await stores(client)
        let one = try trip(trips, "t1")
        let two = try trip(trips, "t2")
        #expect(one.cover?.id == "p0099", "control: the cover decoded")
        await members.drain(one, using: client.handle, baseURL: Stub.baseURL)
        await members.drain(two, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.summary(for: one)?.cover?.id == "p0001")
        #expect(members.summary(for: one)?.count == 157, "the count is not the server's")
        #expect(members.summary(for: two)?.cover?.id == "p0002", "a member cover was replaced")
    }
}

extension TripMemberStore {
    /// The rows the Removed list should hold, by uid, as the fixtures build them.
    func removedRows(_ uids: [String]) -> [LibraryRow] {
        uids.compactMap { uid in
            let index = Int(uid.dropFirst()) ?? 0
            let json = TripWire.item(uid, taken: TripWire.taken(index))
            guard let data = json.data(using: .utf8),
                let item = try? Self.decoder.decode(
                    Components.Schemas.AttachmentListItem.self, from: data)
            else { return nil }
            return LibraryRow(item, baseURL: Stub.baseURL)
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
