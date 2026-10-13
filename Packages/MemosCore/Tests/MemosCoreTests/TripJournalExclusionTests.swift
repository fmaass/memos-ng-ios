import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A span memo whose one picture the owner removed from the trip stays out of its journal
/// (MEMNG-793), whatever drops the member drain meanwhile — a list, a pin, an unpin — until the
/// server says otherwise: Add Back, or a drain asked for after the removal that lists the picture.
@MainActor
@Suite("Trip journal — a removed picture")
struct TripJournalExclusionTests {
    private typealias Wire = TripJournalWire

    /// `dami` and `ours`, span memos of one picture each, both members.
    private func journalServer(hold: TripServer.Hold? = nil) -> TripServer {
        let server = Wire.server(
            spanned: [
                Wire.memo("dami", created: Wire.lisbon(12, 9), taken: [Wire.lisbon(12, 8)]),
                Wire.memo("ours", created: Wire.lisbon(13, 9), taken: [Wire.lisbon(13, 8)]),
            ],
            named: [("dami-a0", Wire.lisbon(12, 8)), ("ours-a0", Wire.lisbon(13, 8))],
            hold: hold)
        server.seed(title: "Lisbon", tag: Wire.tag, span: Wire.span)
        return server
    }

    /// The trip's journal loaded, then `dami`'s picture removed through the member store.
    private func removed() async throws -> (TripServer, TripStore, TripMemberStore) {
        let server = journalServer()
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: trip).map(\.uid) == ["dami", "ours"], "control")
        try await store.remove(["dami-a0"], from: trip, using: handle, baseURL: Stub.baseURL)
        let after = try #require(trips.trips.first)
        #expect(store.journal(for: after).map(\.uid) == ["ours"], "control: the memo left")
        return (server, trips, store)
    }

    @Test("a list refresh after a removal does not bring the span memo back")
    func aListKeepsTheRemovalOut() async throws {
        let (server, trips, store) = try await removed()

        await trips.refresh(using: server.client.handle, baseURL: Stub.baseURL)

        let after = try #require(trips.trips.first)
        #expect(store.state(for: after) == .notLoaded, "control: the list dropped the drain")
        #expect(store.journal(for: after).map(\.uid) == ["ours"], "the removed memo came back")
    }

    @Test("a pin and an unpin after a removal do not bring the span memo back")
    func aPinKeepsTheRemovalOut() async throws {
        let (_, trips, store) = try await removed()
        let uid = try #require(trips.trips.first).uid

        trips.pin(uid: uid, lastTaken: Wire.lisbon(20, 12), now: Wire.lisbon(15, 12))
        let pinned = try #require(trips.trips.first)
        #expect(store.state(for: pinned) == .notLoaded, "control: the pin dropped the drain")
        #expect(store.journal(for: pinned).map(\.uid) == ["ours"], "back after the pin")

        trips.unpin(uid: uid)
        let unpinned = try #require(trips.trips.first)
        #expect(store.journal(for: unpinned).map(\.uid) == ["ours"], "back after the unpin")
    }

    @Test("Add Back lists the memo again, and a list refresh after it keeps it")
    func addBackListsTheMemoAgain() async throws {
        let (server, trips, store) = try await removed()
        let handle = server.client.handle
        await trips.refresh(using: handle, baseURL: Stub.baseURL)

        try await store.addBack(
            "dami-a0", to: try #require(trips.trips.first), using: handle, baseURL: Stub.baseURL)
        #expect(
            store.journal(for: try #require(trips.trips.first)).map(\.uid) == ["dami", "ours"],
            "Add Back left the memo out")

        await trips.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(
            store.journal(for: try #require(trips.trips.first)).map(\.uid) == ["dami", "ours"],
            "a list refresh after Add Back took the memo out again")
    }

    @Test("a drain asked for after the removal that lists the picture again gives the memo back")
    func theServersLaterAnswerWins() async throws {
        let (server, trips, store) = try await removed()
        let handle = server.client.handle
        // Somebody else's Add Back, on another device.
        server.edit(try #require(trips.trips.first).uid) { $0.exclusions = [] }

        await store.drain(try #require(trips.trips.first), using: handle, baseURL: Stub.baseURL)
        #expect(
            store.journal(for: try #require(trips.trips.first)).map(\.uid) == ["dami", "ours"],
            "the server lists the picture again, and the journal still leaves its memo out")

        await trips.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(
            store.journal(for: try #require(trips.trips.first)).map(\.uid) == ["dami", "ours"],
            "a list refresh took the memo out again")
    }

    @Test("a drain asked for before the removal and landing after it does not undo the record")
    func anEarlierDrainDoesNotUndoTheRemoval() async throws {
        let drainEntered = TripLatch()
        let drainRelease = TripLatch()
        let putEntered = TripLatch()
        let putRelease = TripLatch()
        let server = journalServer(hold: { operation, count in
            if operation == TripWire.members, count == 1 {
                drainEntered.open()
                await drainRelease.wait()
            }
            if operation == TripWire.exclude, count == 2 {
                putEntered.open()
                await putRelease.wait()
            }
        })
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)

        // The drain reads its page while both pictures are members, and answers once the first
        // removal is acknowledged and the second is still out.
        let early = Task { await store.drain(trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await drainEntered.wait(), "the early drain never read")
        let removal = Task {
            try await store.remove(
                ["dami-a0", "ours-a0"], from: trip, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await putEntered.wait(), "the second removal never went out")
        drainRelease.open()
        await early.value
        putRelease.open()
        let outcome = try await removal.value
        #expect(outcome.done == ["dami-a0", "ours-a0"], "control: both were removed")

        await trips.refresh(using: handle, baseURL: Stub.baseURL)
        #expect(
            store.journal(for: try #require(trips.trips.first)).map(\.uid) == [],
            "an answer read before the removal brought its memo back")
    }

    @Test("a removal the server refused records nothing: a list refresh shows the memo")
    func aRefusedRemovalRecordsNothing() async throws {
        let server = journalServer()
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)
        // The re-drain fails as well, so no answer of the server's stands in for the record.
        server.fail([TripWire.exclude, TripWire.members])

        let outcome = try? await store.remove(
            ["dami-a0"], from: trip, using: handle, baseURL: Stub.baseURL)
        #expect(outcome?.done ?? [] == [], "control: the server took nothing out")
        await trips.refresh(using: handle, baseURL: Stub.baseURL)

        #expect(
            store.journal(for: try #require(trips.trips.first)).map(\.uid) == ["dami", "ours"],
            "a removal the server never made hides the memo")
    }

    @Test("a removal from one trip leaves another trip of the same tag and window whole")
    func aRemovalStaysWithItsTrip() async throws {
        let server = journalServer()
        server.seed(title: "Lisbon again", tag: Wire.tag, span: Wire.span)
        let (trips, store) = await TripSeeder(server: server).members()
        let handle = server.client.handle
        let first = try #require(trips.trips.first { $0.title == "Lisbon" })
        let other = try #require(trips.trips.first { $0.title == "Lisbon again" })
        await store.loadJournal(first, using: handle, baseURL: Stub.baseURL)
        await store.loadJournal(other, using: handle, baseURL: Stub.baseURL)

        try await store.remove(["dami-a0"], from: first, using: handle, baseURL: Stub.baseURL)
        await trips.refresh(using: handle, baseURL: Stub.baseURL)

        let removedFrom = try #require(trips.trips.first { $0.uid == first.uid })
        let untouched = try #require(trips.trips.first { $0.uid == other.uid })
        #expect(store.journal(for: removedFrom).map(\.uid) == ["ours"], "control")
        #expect(
            store.journal(for: untouched).map(\.uid) == ["dami", "ours"],
            "a removal from one trip took the memo out of another")
    }

    @Test("Add Back lists the memo again even when the members cannot be read after it")
    func addBackWithoutADrain() async throws {
        let (server, trips, store) = try await removed()
        let handle = server.client.handle
        // No drain answers after the Add Back: only its acknowledgement can end the record.
        server.fail([TripWire.members])

        try await store.addBack(
            "dami-a0", to: try #require(trips.trips.first), using: handle, baseURL: Stub.baseURL)

        let after = try #require(trips.trips.first)
        #expect(store.state(for: after) == .notLoaded, "control: no drain landed")
        #expect(
            store.journal(for: after).map(\.uid) == ["dami", "ours"], "Add Back left the memo out")
    }
}
