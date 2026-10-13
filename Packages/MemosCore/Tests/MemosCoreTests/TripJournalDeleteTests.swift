import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A picture Delete took leaves every file list the journal hands out (MEMNG-794): a tagged memo
/// keeps its text and its other pictures, a span memo kept by another picture keeps that one, and
/// a memo whose one picture went still leaves the span.
@MainActor
@Suite("Trip journal — a deleted picture")
struct TripJournalDeleteTests {
    private typealias Wire = TripJournalWire

    /// The files of memo `uid` as the trip's journal hands it out now; nil when it is not listed.
    private func files(of uid: String, in store: TripMemberStore, _ trip: Trip) -> [String]? {
        store.journal(for: trip).first { $0.uid == uid }?.attachments.map(\.uid)
    }

    @Test("a tagged memo of two pictures keeps one file once the other is deleted")
    func aTaggedMemoLosesTheDeletedFile() async throws {
        let server = Wire.server(tagged: [
            Wire.memo(
                "both", created: Wire.lisbon(12, 9),
                taken: [Wire.lisbon(12, 8), Wire.lisbon(12, 10)])
        ])
        server.seed(title: "Portugal 2026", tag: Wire.tag)
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)
        #expect(files(of: "both", in: store, trip) == ["both-a0", "both-a1"], "control")

        let outcome = await store.delete(["both-a1"], using: handle, baseURL: Stub.baseURL)

        #expect(outcome?.deleted == ["both-a1"], "control: the picture was deleted")
        #expect(
            files(of: "both", in: store, trip) == ["both-a0"],
            "the deleted picture is still among the tagged memo's files")
    }

    @Test("a tagged memo read while its picture is deleted lands without that picture")
    func aJournalHeldAcrossTheDeleteLandsWithoutIt() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = Wire.server(
            tagged: [
                Wire.memo(
                    "both", created: Wire.lisbon(12, 9),
                    taken: [Wire.lisbon(12, 8), Wire.lisbon(12, 10)])
            ],
            hold: { operation, count in
                guard operation == Wire.memos, count == 1 else { return }
                entered.open()
                await release.wait()
            })
        server.seed(title: "Lisbon", tag: Wire.tag, span: Wire.span)
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle

        let load = Task { await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the tag lane was never read")
        let outcome = await store.delete(["both-a0"], using: handle, baseURL: Stub.baseURL)
        release.open()
        await load.value

        #expect(outcome?.deleted == ["both-a0"], "control: the picture was deleted")
        #expect(
            files(of: "both", in: store, trip) == ["both-a1"],
            "a page read before the delete put the deleted picture back")
    }

    @Test("a span memo kept by its other picture loses the deleted one; a lone one leaves")
    func aSpanMemoKeepsOnlyWhatSurvives() async throws {
        let server = Wire.server(spanned: [
            Wire.memo(
                "pair", created: Wire.lisbon(12, 9),
                taken: [Wire.lisbon(12, 8), Wire.lisbon(12, 10)]),
            Wire.memo("lone", created: Wire.lisbon(13, 9), taken: [Wire.lisbon(13, 8)]),
        ])
        server.seed(title: "Lisbon", tag: Wire.tag, span: Wire.span)
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: trip).map(\.uid) == ["pair", "lone"], "control")

        let outcome = await store.delete(
            ["pair-a1", "lone-a0"], using: handle, baseURL: Stub.baseURL)

        #expect(outcome?.deleted == ["pair-a1", "lone-a0"], "control: both were deleted")
        #expect(
            store.journal(for: trip).map(\.uid) == ["pair"],
            "a memo of nothing but a deleted picture stayed")
        #expect(
            files(of: "pair", in: store, trip) == ["pair-a0"],
            "the deleted picture is still among the kept span memo's files")
    }
}
