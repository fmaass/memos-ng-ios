import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The trip record's operations on the server, held to what the device-local record was held to
/// (MEMNG-754 adapted the device-local trip store's record cases here): every case drives the REAL
/// `TripStore` over a `TripServer` that keeps its rows, and reads the result back through a SECOND
/// store refreshing from that server, so nothing passes on what one instance merely remembers.
@MainActor
@Suite("Trip records on the server")
struct TripRecordTests {
    private let seeder = TripSeeder()
    private var server: TripServer { seeder.server }

    private func request(_ title: String, tag: String?) -> NewTripRequest {
        NewTripRequest(scope: TripWire.alice, title: title, tag: tag)
    }

    @Test("create appends the answered trip at the end of the list, with nothing chosen yet")
    func createAppends() async throws {
        server.seed(title: "Earlier", tag: "earlier")
        let writer = await seeder.store()
        let first = try await writer.create(
            request("Portugal 2026", tag: "portugal2026"), using: server.client.handle,
            baseURL: Stub.baseURL)
        #expect(writer.trips.map(\.title) == ["Earlier", "Portugal 2026"])
        #expect(first.tag == "portugal2026")
        #expect(first.cover == nil && first.memberCount == 0)
        #expect(await seeder.store().trips == writer.trips)
    }

    @Test("two creates in one turn are two POSTs and two trips, both listed on read-back")
    func twoCreatesInOneTurn() async throws {
        let writer = await seeder.store()
        async let one = writer.create(
            request("One", tag: "one"), using: server.client.handle, baseURL: Stub.baseURL)
        async let two = writer.create(
            request("Two", tag: "two"), using: server.client.handle, baseURL: Stub.baseURL)
        let made = try await [one, two]
        #expect(made[0].uid != made[1].uid)
        #expect(server.calls.of(TripWire.create).count == 2)
        #expect(Set(writer.trips.map(\.title)) == ["One", "Two"])
        #expect(Set(await seeder.store().trips.map(\.title)) == ["One", "Two"])
    }

    @Test("rename sends the title alone and changes nothing else")
    func renameChangesTitle() async throws {
        let uid = server.seed(title: "Portugal", tag: "portugal2026")
        let writer = await seeder.store()
        let before = try #require(writer.trips.first)
        try await writer.update(
            uid: uid, patch: TripPatch(title: .set("Portugal 2026")), using: server.client.handle,
            baseURL: Stub.baseURL)
        #expect(
            Set(Stub.object(server.calls.of(TripWire.patch).first?.body).keys) == ["title"],
            "the rename sent more than its title")
        var expected = before
        expected.title = "Portugal 2026"
        #expect(writer.trips == [expected])
        #expect(await seeder.store().trips == [expected])
    }

    @Test("delete removes the trip from the store and the server, leaving the others")
    func deleteRemoves() async throws {
        let one = server.seed(title: "One", tag: "one")
        server.seed(title: "Two", tag: "two")
        let writer = await seeder.store()
        try await writer.delete(uid: one, using: server.client.handle)
        #expect(writer.trips.map(\.title) == ["Two"])
        #expect(await seeder.store().trips.map(\.title) == ["Two"])
    }

    @Test("the order is the server's list order, stable across reads with no change between")
    func orderStableAcrossReload() async {
        for title in ["A", "B", "C", "D"] { server.seed(title: title, tag: title) }
        let first = await seeder.store().trips
        let second = await seeder.store().trips
        #expect(first.map(\.title) == ["A", "B", "C", "D"])
        #expect(first == second)
    }

    @Test("a change, delete or pin of a trip the server does not have changes nothing here")
    func unknownTripChangesNothing() async throws {
        server.seed(title: "Only", tag: "only")
        let writer = await seeder.store()
        let before = writer.trips
        await #expect(throws: TripStore.Failure.server(status: 404)) {
            try await writer.update(
                uid: "ghost", patch: TripPatch(title: .set("Ghost")), using: server.client.handle,
                baseURL: Stub.baseURL)
        }
        await #expect(throws: TripStore.Failure.server(status: 404)) {
            try await writer.delete(uid: "ghost", using: server.client.handle)
        }
        #expect(writer.trips == before)
        #expect(await seeder.store().trips == before)
    }

    @Test("a cover is chosen by its uid and a clear sends null, back to the first member")
    func setCover() async throws {
        let uid = server.seed(title: "Trip", tag: "trip")
        let writer = await seeder.store()
        try await writer.update(
            uid: uid, patch: TripPatch(cover: .set("att-7")), using: server.client.handle,
            baseURL: Stub.baseURL)
        #expect(await seeder.store().trips.first?.cover?.id == "att-7")
        try await writer.update(
            uid: uid, patch: TripPatch(cover: .clear), using: server.client.handle,
            baseURL: Stub.baseURL)
        let cleared = try #require(server.calls.of(TripWire.patch).last?.body)
        #expect(String(decoding: cleared, as: UTF8.self).contains("\"coverAttachmentUid\":null"))
        #expect(await seeder.store().trips.first?.cover == nil)
    }

    @Test("exclude puts a uid out once, include gives it back, each a request of its own")
    func excludeAndInclude() async throws {
        let uid = server.seed(title: "Trip", tag: "trip")
        let writer = await seeder.store()
        let handle = server.client.handle
        let base = Stub.baseURL
        try await writer.exclude(uid: uid, attachment: "att-1", using: handle, baseURL: base)
        try await writer.exclude(uid: uid, attachment: "att-2", using: handle, baseURL: base)
        try await writer.exclude(uid: uid, attachment: "att-1", using: handle, baseURL: base)
        #expect(Set(server.rows.first?.exclusions ?? []) == ["att-1", "att-2"])
        #expect(server.rows.first?.exclusions.count == 2, "a uid was excluded twice")
        try await writer.include(uid: uid, attachment: "att-1", using: handle, baseURL: base)
        #expect(server.rows.first?.exclusions == ["att-2"])
        #expect(
            server.calls.of(TripWire.exclude).map(\.path)
                == ["att-1", "att-2", "att-1"].map { "/api/collections/\(uid)/exclusions/\($0)" })
        #expect(
            server.calls.of(TripWire.include).map(\.path)
                == ["/api/collections/\(uid)/exclusions/att-1"])
    }

    @Test("signing out of A and in to B lists nothing of A; back to A lists A's again")
    func identitySwitch() async throws {
        let bobServer = TripServer()
        server.seed(title: "Portugal 2026", tag: "portugal2026")
        let session = await seeder.store()
        let aliceTrips = session.trips
        #expect(aliceTrips.map(\.title) == ["Portugal 2026"])

        session.sessionIdentityChanged(to: nil)
        #expect(session.trips.isEmpty)
        #expect(session.identity == nil)

        session.sessionIdentityChanged(to: TripWire.bob)
        #expect(session.trips.isEmpty)
        bobServer.seed(title: "Bob's", tag: "bob")
        await session.refresh(using: bobServer.client.handle, baseURL: Stub.baseURL)
        #expect(session.trips.map(\.title) == ["Bob's"])

        session.sessionIdentityChanged(to: TripWire.alice)
        await session.refresh(using: server.client.handle, baseURL: Stub.baseURL)
        #expect(session.trips == aliceTrips)
    }
}
