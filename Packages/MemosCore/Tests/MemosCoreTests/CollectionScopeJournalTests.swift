import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// An automatic collection's journal (MEMNG-817, decision 3): a tag's is the tag lane alone; a
/// month's or a year's is every memo CREATED inside the period, `[start, nextStart)` in the
/// bucket's zone — no picture date moves a memo in or out.
@MainActor
@Suite("Collection scope — the journal")
struct CollectionScopeJournalTests {
    private let seeder = TripSeeder()

    nonisolated static func at(_ text: String) -> Date { CollectionScopeTests.instant(text) }

    nonisolated static func parsed(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    nonisolated static func memo(_ uid: String, _ created: String, taken: [String] = []) -> String {
        TripJournalWire.memo(uid, created: at(created), taken: taken.map(at))
    }

    /// A transport recording every memo-list path and answering by its cursor.
    nonisolated static func memos(
        _ paths: LockedValue<[String]>,
        answer: @escaping @Sendable (String?) -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            #expect(operation == TripJournalWire.memos, "not the memo list: \(operation)")
            return answer(TripWire.query(path, "cursor"))
        }
    }

    static func month(_ key: String, zone: String = "Europe/Zurich") -> CollectionScope {
        .automatic(
            AutomaticCollection(
                kind: .month(key), count: 1, cover: nil, zone: TimeZone(identifier: zone)!))
    }

    @Test("a tag's journal is the tag lane alone: tag=, oldest first, no date bound")
    func aTagsJournal() async {
        let paths = LockedValue<[String]>([])
        let client = Self.memos(paths) { _ in
            Stub.json(
                Stub.page([
                    Self.memo("one", "2026-05-01T10:00:00Z"),
                    Self.memo("two", "2026-06-01T10:00:00Z", taken: ["2026-06-01T09:00:00Z"]),
                ]))
        }
        let (_, store) = await seeder.members()
        let scope = CollectionScope.automatic(
            AutomaticCollection(
                kind: .tag("lisbon"), count: 2, cover: nil, zone: CollectionScopeTests.zurich))
        await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: scope).map(\.uid) == ["one", "two"])
        #expect(store.journalState(for: scope) == .complete)
        let sent = paths.get()
        #expect(sent.count == 1, "not one lane: \(sent)")
        let path = sent.first ?? ""
        #expect(TripWire.query(path, "tag") == "lisbon", "\(path)")
        #expect(TripWire.query(path, "sort") == "created_at", "\(path)")
        #expect(!TripWire.hasQuery(path, "created_after"), "\(path)")
        #expect(!TripWire.hasQuery(path, "created_before"), "\(path)")
    }

    @Test("October's journal: bounds on every page, start and last second in, nextStart out")
    func octobersBoundsAcrossDST() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.memos(paths) { cursor in
            switch cursor {
            case nil:
                Stub.json(
                    Stub.page(
                        [
                            // Overfetched: `created_after` is strict, so the wire asks from a
                            // second before the start and the client cuts.
                            Self.memo("before", "2026-09-30T21:59:59Z"),
                            Self.memo("start", "2026-09-30T22:00:00Z"),
                            Self.memo("text", "2026-10-12T08:00:00Z"),
                        ], nextCursor: "c1"))
            case "c1":
                Stub.json(
                    Stub.page(
                        [
                            Self.memo("final", "2026-10-31T22:59:59Z"),
                            Self.memo("november", "2026-10-31T23:00:00Z"),
                        ], nextCursor: "c2"))
            default: Stub.json(Stub.page([Self.memo("later", "2026-11-05T10:00:00Z")]))
            }
        }
        let (_, store) = await seeder.members()
        let scope = Self.month("2026-10")
        await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: scope).map(\.uid) == ["start", "text", "final"])
        #expect(store.journalState(for: scope) == .complete)
        let sent = paths.get()
        #expect(sent.count == 2, "the walk read past nextStart: \(sent)")
        for path in sent {
            #expect(!TripWire.hasQuery(path, "tag"), "a month's journal named a tag: \(path)")
            #expect(TripWire.query(path, "sort") == "created_at", "\(path)")
            let after = Self.parsed(TripWire.query(path, "created_after"))
            let before = Self.parsed(TripWire.query(path, "created_before"))
            #expect(
                after == Self.at("2026-09-30T21:59:59Z"),
                "not one second before 1 October 00:00 CEST: \(path)")
            #expect(
                before == Self.at("2026-10-31T23:00:00Z"),
                "not 1 November 00:00 CET, exclusive: \(path)")
        }
    }

    @Test("March's journal holds a memo of February photographs, and nothing of 1 April")
    func marchByCreationNotByPicture() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.memos(paths) { _ in
            Stub.json(
                Stub.page([
                    Self.memo("february", "2026-02-28T22:30:00Z"),
                    Self.memo(
                        "late-upload", "2026-03-02T10:00:00Z", taken: ["2026-02-20T12:00:00Z"]),
                    Self.memo("final", "2026-03-31T21:59:59Z"),
                    Self.memo("april", "2026-03-31T22:00:00Z"),
                ]))
        }
        let (_, store) = await seeder.members()
        let scope = Self.month("2026-03")
        await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)

        let uids = Set(store.journal(for: scope).map(\.uid))
        #expect(uids == ["late-upload", "final"], "\(uids)")
        let path = paths.get().first ?? ""
        #expect(
            Self.parsed(TripWire.query(path, "created_after")) == Self.at("2026-02-28T22:59:59Z"),
            "\(path)")
        #expect(
            Self.parsed(TripWire.query(path, "created_before")) == Self.at("2026-03-31T22:00:00Z"),
            "\(path)")
    }

    @Test("a trip's journal through its scope reads both lanes as it always has")
    func aTripsJournalThroughTheScope() async throws {
        let server = TripJournalWire.server(
            tagged: [Self.memo("tagged", "2026-07-11T10:00:00Z")],
            spanned: [Self.memo("spanned", "2026-07-12T10:00:00Z")])
        server.seed(title: "Lisbon", tag: TripJournalWire.tag, span: TripJournalWire.span)
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        await store.loadJournal(.trip(trip), using: server.client.handle, baseURL: Stub.baseURL)

        let reads = server.calls.of(TripJournalWire.memos).map(\.path)
        #expect(reads.count == 2, "not the tag lane and the span lane: \(reads)")
        #expect(reads.contains { TripWire.query($0, "tag") == TripJournalWire.tag })
        #expect(store.journal(for: .trip(trip)).map(\.uid) == store.journal(for: trip).map(\.uid))
        #expect(Set(store.journal(for: .trip(trip)).map(\.uid)) == ["tagged", "spanned"])
    }
}

/// The zone a month is cut in is the one its bucket was counted in, carried by
/// `AutomaticCollection.zone` into `tz=`, the drain's bound and the journal's bounds. The same
/// instants under the same key, one collection counted in Zurich and one in UTC, cut apart — and
/// neither by the device's own zone, which no step of the automatic path reads.
extension CollectionScopeJournalTests {
    /// Answers the drain with the rows from the start of the bucket in the zone it was sent, and
    /// the journal with every memo, so each cut is the store's own.
    nonisolated static func around(_ paths: LockedValue<[String]>) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if operation == TripJournalWire.memos {
                return Stub.json(
                    Stub.page([
                        CollectionScopeJournalTests.memo("first-hour", "2026-08-31T22:30:00Z"),
                        CollectionScopeJournalTests.memo("october", "2026-09-30T22:30:00Z"),
                    ]))
            }
            let rows: [(String, String)] =
                TripWire.query(path, "tz") != "Europe/Zurich"
                ? [
                    ("last-hour", "2026-09-30T21:30:00Z"), ("october", "2026-09-30T22:30:00Z"),
                    ("utc-october", "2026-10-01T00:30:00Z"),
                ]
                : [
                    ("first-hour", "2026-08-31T22:30:00Z"), ("last-hour", "2026-09-30T21:30:00Z"),
                    ("october", "2026-09-30T22:30:00Z"),
                ]
            return CollectionScopeDrainTests.rows(rows)
        }
    }

    @Test("September in Zurich and September in UTC cut the same instants where each bucket did")
    func eachBucketItsOwnZone() async throws {
        for (zone, members, journal) in [
            ("Europe/Zurich", ["first-hour", "last-hour"], ["first-hour"]),
            ("UTC", ["last-hour", "october"], ["october"]),
        ] {
            let paths = LockedValue<[String]>([])
            let client = Self.around(paths)
            let (_, store) = await seeder.members()
            let scope = CollectionScopeJournalTests.month("2026-09", zone: zone)
            await store.drain(scope, using: client.handle, baseURL: Stub.baseURL)
            await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)

            #expect(store.members(for: scope).map(\.id) == members, "\(zone)")
            #expect(store.journal(for: scope).map(\.uid) == journal, "\(zone)")
            let drain = try #require(paths.get().first { $0.hasPrefix("/api/attachments") })
            // Foundation names the zone made from "UTC" "GMT"; the wire carries its identifier.
            let sent = TimeZone(identifier: zone)?.identifier
            #expect(TripWire.query(drain, "tz") == sent, "\(drain)")
        }
    }
}

/// Forgetting a scope: an automatic collection has no record whose removal fences its loads, so
/// `forget(_:)` retires the scope's members, its journal, its sentence and the ownership of its
/// load in flight — an answer that outlived the forget lands nothing.
extension CollectionScopeJournalTests {
    /// A memo-list transport whose first request waits for `release` after opening `entered`;
    /// the first page names a next one.
    nonisolated static func heldJournal(
        _ paths: LockedValue<[String]>, entered: TripLatch, release: TripLatch
    ) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            guard TripWire.hasQuery(path, "cursor") else {
                entered.open()
                await release.wait()
                return Stub.json(
                    Stub.page([Self.memo("one", "2026-09-10T10:00:00Z")], nextCursor: "c1"))
            }
            return Stub.json(Stub.page([Self.memo("two", "2026-09-11T10:00:00Z")]))
        }
    }

    @Test("a journal page answered after its scope was forgotten lands nothing and reads no more")
    func aForgottenScopesLateJournalLandsNothing() async throws {
        let paths = LockedValue<[String]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.heldJournal(paths, entered: entered, release: release)
        let (_, store) = await seeder.members()
        let scope = Self.month("2026-09")

        let inFlight = Task {
            await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        store.forget(scope)
        #expect(store.journalState(for: scope) == .notLoaded, "the forgotten load still drains")
        release.open()
        await inFlight.value

        let landed = store.journal(for: scope).map(\.uid)
        #expect(landed.isEmpty, "a forgotten scope's journal came back: \(landed)")
        #expect(store.journalState(for: scope) == .notLoaded)
        #expect(store.journalError(for: scope) == nil)
        #expect(paths.get().count == 1, "the forgotten walk read on: \(paths.get())")

        // Control: forgetting is not a fence against the scope's next load.
        let again = Self.memos(LockedValue([])) { _ in
            Stub.json(Stub.page([Self.memo("one", "2026-09-10T10:00:00Z")]))
        }
        await store.loadJournal(scope, using: again.handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: scope).map(\.uid) == ["one"])
    }

    @Test("a refusal the session decides after its scope was forgotten writes no sentence")
    func aRefusalDecidedAfterForgetSaysNothing() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let handled = LockedValue(0)
        let client = CollectionScopeDrainTests.bounded { _, _, _ in Stub.empty(.unauthorized) }
        let (_, store) = await seeder.members(onUnauthorized: { (_: CredentialRefusal) in
            handled.set(handled.get() + 1)
            entered.open()
            await release.wait()
            return .endedSession
        })
        let scope = Self.month("2026-09")

        let inFlight = Task {
            await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the refusal never reached the session")
        store.forget(scope)
        release.open()
        await inFlight.value

        #expect(handled.get() == 1, "control: the refusal reached the session once")
        let said = store.journalError(for: scope)
        #expect(said == nil, "a forgotten scope said its refusal: \(said ?? "")")
        #expect(store.journalState(for: scope) == .notLoaded)
    }

    @Test("forgetting one scope drops its members, journal and sentence, and leaves another's")
    func forgettingIsKeyedByScope() async throws {
        let client = CollectionScopeDrainTests.bounded { _, _, operation in
            if operation == TripJournalWire.memos {
                return Stub.json(Stub.page([Self.memo("one", "2026-09-10T10:00:00Z")]))
            }
            return CollectionScopeDrainTests.rows([("one", "2026-09-10T10:00:00Z")])
        }
        let (_, store) = await seeder.members()
        let september = Self.month("2026-09")
        // A tag spelling the month's key is another scope all the same.
        let tagged = CollectionScopeDrainTests.scope(.tag("2026-09"))
        for scope in [september, tagged] {
            await store.drain(scope, using: client.handle, baseURL: Stub.baseURL)
            await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)
        }

        store.forget(september)

        #expect(store.members(for: september).isEmpty)
        #expect(store.state(for: september) == .notLoaded)
        #expect(store.journal(for: september).isEmpty, "the forgotten journal stayed")
        #expect(store.journalState(for: september) == .notLoaded)
        #expect(store.members(for: tagged).map(\.id) == ["one"], "another scope's members went")
        #expect(store.journal(for: tagged).map(\.uid) == ["one"], "another scope's journal went")
    }
}
