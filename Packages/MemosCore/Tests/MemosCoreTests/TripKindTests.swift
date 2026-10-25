import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A collection's kind through the store (memos-ng 2.6.0, MEMNG-803): read from the record the
/// server answers, never assumed, and sent with every create, over the REAL generated client and a
/// scripted transport.
@MainActor
@Suite("Trip kind")
struct TripKindTests {
    private let root = TripWire.root()

    private func store() -> TripStore {
        TripStore(identity: TripWire.alice, root: root)
    }

    @Test(
        "a listed record decodes with its own kind",
        arguments: [("trip", Trip.Kind.trip), ("album", Trip.Kind.album)])
    func aRecordDecodesItsKind(wire: String, expected: Trip.Kind) async throws {
        let record = TripWire.collection("c1", title: "At the sea", kind: wire)
        let client = Stub.client { _, _, operation in
            operation == TripWire.list ? Stub.json("[\(record)]") : Stub.empty(.notFound)
        }
        let store = store()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let trip = try #require(store.trips.first, "the list applied nothing")
        #expect(trip.kind == expected)
    }

    @Test("a record without a kind is refused, never taken for a trip")
    func aRecordWithoutAKindIsRefused() async {
        let record = TripWire.collection("c1", title: "At the sea", kind: nil)
        let client = Stub.client { _, _, operation in
            operation == TripWire.list ? Stub.json("[\(record)]") : Stub.empty(.notFound)
        }
        let store = store()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.trips.isEmpty, "a record without a kind was listed as \(store.trips)")
    }

    @Test("an album's create sends kind album and no tag, span or zone")
    func anAlbumCreateSendsItsKind() async throws {
        let calls = TripCalls()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let album = TripWire.collection("a1", title: "At the sea", kind: "album")
            return operation == TripWire.create
                ? Stub.json(album, status: .created) : Stub.json(album)
        }
        let store = store()
        let frozen = NewTripRequest(
            scope: TripWire.alice, title: "At the sea", kind: .album, idempotencyKey: "key-a001")
        _ = try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)

        let posts = calls.of(TripWire.create)
        try #require(posts.count == 1, "the create sent \(posts.count) POSTs")
        #expect(posts[0].path == "/api/collections", "the POST went to \(posts[0].path)")
        let sent = Stub.object(posts[0].body)
        #expect(sent["kind"] as? String == "album", "the body said \(sent)")
        #expect(sent["title"] as? String == "At the sea")
        for absent in ["tag", "spanStart", "spanEnd", "tz"] {
            #expect(sent[absent] == nil, "the album's body carried \(absent)")
        }
    }

    @Test("a second Create under the same key as another kind sends nothing and is busy")
    func anotherKindUnderOneKeyRefuses() async throws {
        let calls = TripCalls()
        let entered = TripLatch()
        let release = TripLatch()
        let settled = TripLatch()
        let client = Stub.client { request, body, operation in
            _ = await calls.record(request, body, operation)
            let trip = TripWire.collection("t1", title: "Lisbon")
            // Only the POST is held; the re-read after it answers at once.
            guard operation == TripWire.create else { return Stub.json(trip) }
            entered.open()
            await release.wait()
            return Stub.json(trip, status: .created)
        }
        let store = store()
        let frozen = NewTripRequest(
            scope: TripWire.alice, title: "Lisbon", kind: .trip, idempotencyKey: "key-a002")
        let other = NewTripRequest(
            scope: TripWire.alice, title: "Lisbon", kind: .album, idempotencyKey: "key-a002")
        let first = Task {
            try await store.create(frozen, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first POST never reached the wire")
        let second = Task {
            defer { settled.open() }
            return try await store.create(other, using: client.handle, baseURL: Stub.baseURL)
        }
        // Waited on before the first POST is released: a joined caller would only settle after it.
        #expect(await settled.wait(), "the album Create waited on the trip's instead of refusing")
        release.open()
        _ = try await first.value
        await #expect(throws: TripStore.Failure.busy) { try await second.value }

        #expect(calls.of(TripWire.create).count == 1, "the refused Create reached the wire")
    }
}
