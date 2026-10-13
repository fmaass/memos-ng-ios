import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip's journal: `GET /api/memos?tag=<t>&sort=created_at`, drained page after page through the
/// REAL generated client over a scripted transport, oldest first as the server orders it — fenced
/// and joined the way the members are (MEMNG-718; MEMNG-754 moved it onto the `TripMemberStore` of
/// a server-listed trip, the cases' assertions kept).
@MainActor
@Suite("Trip journal")
struct TripJournalTests {
    private nonisolated static let listOperation = "list_memos_api_memos_get"
    private nonisolated static let tag = "portugal2026"

    private let seeder = TripSeeder()

    /// A trip of `tag` listed on the server, and the stores a real refresh filled over it.
    private func journalTrip(
        _ title: String, tag: String, pageSize: Int = TripMemberStore.pageSize,
        memberCap: Int = TripMemberStore.memberCap,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async -> (record: Trip, trips: TripStore, store: TripMemberStore) {
        let uid = seeder.server.seed(title: title, tag: tag)
        let (trips, store) = await seeder.members(
            pageSize: pageSize, memberCap: memberCap, onUnauthorized: onUnauthorized)
        let fallback = Trip(uid: uid, title: title, tag: tag, createdAt: .now, updatedAt: .now)
        return (trips.trips.first { $0.uid == uid } ?? fallback, trips, store)
    }

    /// The n-th memo of the trip, one day apart from 2026-03-12.
    private nonisolated static func memo(_ index: Int) -> String {
        Stub.memo(
            uid: "m\(index)",
            content: "Day \(index)",
            createdAt: "2026-03-\(12 + index)T12:00:00Z"
        )
    }

    private nonisolated static func page(_ range: Range<Int>, nextCursor: String? = nil) -> (
        HTTPResponse, HTTPBody?
    ) {
        Stub.json(Stub.page(range.map(memo), nextCursor: nextCursor))
    }

    /// The query a request carried, by name; a repeated name keeps its first value.
    private nonisolated static func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(string: request.path ?? "")?.queryItems ?? []
        return Dictionary(
            items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// Three memos over two pages: m0 m1, then m2 after the cursor `c1`.
    private nonisolated static func twoPages(_ request: HTTPRequest) -> (HTTPResponse, HTTPBody?) {
        query(request)["cursor"] == "c1" ? page(2..<3) : page(0..<2, nextCursor: "c1")
    }

    @Test("the journal reads every page oldest first, the third memo after the second")
    func pagesInOrder() async {
        let client = Stub.client { request, _, operation in
            #expect(operation == Self.listOperation)
            return Self.twoPages(request)
        }
        let (record, _, store) = await journalTrip("Portugal 2026", tag: Self.tag, pageSize: 2)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: record).map(\.uid) == ["m0", "m1", "m2"])
        #expect(store.journalState(for: record) == .complete)
        #expect(store.journalError(for: record) == nil)
        #expect(store.members(for: record).isEmpty, "the journal wrote the membership")
    }

    @Test("every journal request carries tag=<t> and sort=created_at, and follows nextCursor")
    func theJournalsRequests() async {
        let reads = LockedValue<[[String: String]]>([])
        let client = Stub.client { request, _, _ in
            reads.set(reads.get() + [Self.query(request)])
            return Self.twoPages(request)
        }
        let (record, _, store) = await journalTrip("Portugal 2026", tag: Self.tag, pageSize: 2)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        let queries = reads.get()
        #expect(queries.count == 2, "one read per page: \(queries)")
        for query in queries {
            #expect(query["tag"] == Self.tag, "\(query)")
            #expect(query["sort"] == "created_at", "\(query)")
            #expect(query["limit"] == "2", "\(query)")
            #expect(query["created_before"] == nil, "\(query)")
            #expect(query["created_after"] == nil, "\(query)")
        }
        #expect(queries.map { $0["cursor"] } == [nil, "c1"])
    }

    @Test("a tag holding the query's own syntax travels as one value, the sort untouched")
    func aTagWithQuerySyntax() async {
        let reads = LockedValue<[[String: String]]>([])
        let client = Stub.client { request, _, _ in
            reads.set(reads.get() + [Self.query(request)])
            return Self.page(0..<1)
        }
        let (record, _, store) = await journalTrip("Odd", tag: "a&sort=-created_at")

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        let first = reads.get().first
        #expect(first?["tag"] == "a&sort=-created_at")
        #expect(first?["sort"] == "created_at")
    }

    @Test("a tag no memo carries is an empty journal that is complete, not still loading")
    func anEmptyJournal() async {
        let client = Stub.client { _, _, _ in Self.page(0..<0) }
        let (record, _, store) = await journalTrip("Portugal 2026", tag: Self.tag)
        #expect(store.journalState(for: record) == .notLoaded)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: record).isEmpty)
        #expect(store.journalState(for: record) == .complete)
    }

    @Test("a journal stops at the cap and says it was truncated")
    func theCap() async {
        let client = Stub.client { request, _, _ in Self.twoPages(request) }
        let (record, _, store) = await journalTrip(
            "Portugal 2026", tag: Self.tag, pageSize: 2, memberCap: 2)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: record).map(\.uid) == ["m0", "m1"])
        #expect(store.journalState(for: record) == .truncated)
    }

    @Test("a journal page answered for a session that has ended is dropped whole")
    func aStaleGenerationIsDropped() async {
        let calls = LockedValue<Int>(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.open()
                await release.wait()
            }
            return Self.twoPages(request)
        }
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        let (record, _, store) = await journalTrip("Portugal 2026", tag: Self.tag, pageSize: 2)
        store.reports(to: session)

        let inFlight = Task {
            await store.loadJournal(record, using: issued, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "a stale answer was applied")
        #expect(store.journalState(for: record) == .notLoaded)
        #expect(calls.get() == 1, "the stale load read on: \(calls.get()) pages")
    }

    @Test("a journal that outlived a change of identity is dropped whole")
    func anIdentityChangeDropsTheJournal() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, _ in
            entered.open()
            await release.wait()
            return Self.page(0..<1)
        }
        let (record, _, store) = await journalTrip("Portugal 2026", tag: Self.tag)

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        store.sessionIdentityChanged()
        release.open()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "somebody else's journal was applied")
        #expect(store.journalState(for: record) == .notLoaded)
    }

    @Test("a second journal load of a trip in flight waits for the first and sends nothing")
    func twoLoadsAreOneChain() async {
        let calls = LockedValue<Int>(0)
        let entered = TripLatch()
        let release = TripLatch()
        let joined = TripLatch()
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.open()
                await release.wait()
            }
            return Self.twoPages(request)
        }
        let (record, _, store) = await journalTrip("Portugal 2026", tag: Self.tag, pageSize: 2)
        store.onJournalJoin = { joined.open() }
        let secondDone = LockedValue<Bool>(false)

        let first = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the first load sent nothing")
        let second = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
            secondDone.set(true)
            return store.journal(for: record).count
        }
        #expect(await joined.wait(), "the second load never reached the join")
        #expect(!secondDone.get(), "the second load returned while the first was still out")
        #expect(store.journalState(for: record) == .draining)
        release.open()
        await first.value
        let secondSaw = await second.value

        #expect(calls.get() == 2, "two overlapping loads were \(calls.get()) requests, not 2")
        #expect(secondSaw == 3, "the joined caller did not see the chain's result: \(secondSaw)")
    }

    @Test("a journal held across a change of the trip's tag lands nothing")
    func aRetaggedJournalLandsNothing() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, _ in
            entered.open()
            await release.wait()
            return Self.page(0..<1)
        }
        let (record, trips, store) = await journalTrip("Portugal 2026", tag: Self.tag)

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        // Somebody renames the tag: the trip stays, but the load was asked under the old rule.
        seeder.server.edit(record.uid) { $0.tag = "lisbon2026" }
        await trips.refresh(using: seeder.server.client.handle, baseURL: Stub.baseURL)
        let renamed = try #require(trips.trips.first { $0.uid == record.uid })
        #expect(renamed.tag == "lisbon2026", "control: the rule changed")
        release.open()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "the load in flight landed after a rule change")
        #expect(store.journal(for: renamed).isEmpty, "the old rule's memos stood for the new rule")
        #expect(store.journalState(for: renamed) == .notLoaded)
    }

    @Test("a journal loaded before the trip's tag changed is not read through the old record")
    func aRetaggedTripsOldRecordReadsNothing() async throws {
        let client = Stub.client { _, _, _ in Self.page(0..<1) }
        let (record, trips, store) = await journalTrip("Portugal 2026", tag: Self.tag)
        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: record).map(\.uid) == ["m0"], "control: the journal applied")

        // A view still holding the old record asks after the tag moved on the server.
        seeder.server.edit(record.uid) { $0.tag = "lisbon2026" }
        await trips.refresh(using: seeder.server.client.handle, baseURL: Stub.baseURL)
        let renamed = try #require(trips.trips.first { $0.uid == record.uid })
        #expect(renamed.tag == "lisbon2026", "control: the rule changed")

        #expect(store.journal(for: record).isEmpty, "the old record read the old rule's journal")
        #expect(store.journalState(for: record) == .notLoaded)
    }

    @Test("a journal answered for a trip deleted while it was out publishes nothing")
    func aDeletedTripsJournalIsDropped() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            entered.open()
            await release.wait()
            return Self.page(0..<1)
        }
        let (record, trips, store) = await journalTrip("Portugal 2026", tag: Self.tag)

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        try await trips.delete(uid: record.uid, using: seeder.server.client.handle)
        release.open()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "a deleted trip's journal came back")
        #expect(store.journalState(for: record) == .notLoaded)
    }

    @Test("a refused credential on the journal goes to the session, said on the journal alone")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let (record, _, ended) = await journalTrip(
            "Portugal 2026", tag: Self.tag,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })

        await ended.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(
            ended.journalError(for: record) != nil, "an ended session said nothing on the journal")
        #expect(ended.lastError == nil, "the journal's refusal was said over the photos")
        #expect(ended.journalState(for: record) == .notLoaded)

        let (_, superseded) = await seeder.members(onUnauthorized: { _ in .superseded })
        await superseded.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(superseded.journalError(for: record) == nil, "a stale refusal wrote a sentence")
    }

    @Test("a refusal the session decides after the trip is deleted writes nothing on the journal")
    func aRefusalDecidedAfterDeleteSaysNothing() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let (record, trips, store) = await journalTrip(
            "Portugal 2026", tag: Self.tag,
            onUnauthorized: { (_: CredentialRefusal) in
                entered.open()
                await release.wait()
                return .endedSession
            })

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the refusal never reached the session")
        try await trips.delete(uid: record.uid, using: seeder.server.client.handle)
        release.open()
        await inFlight.value

        let said = store.journalError(for: record)
        #expect(said == nil, "a deleted trip's journal said its refusal: \(said ?? "")")
    }

    @Test("a trip's journal failure is said on that trip alone, never on another")
    func aFailureStaysWithItsTrip() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, _ in
            guard Self.query(request)["tag"] == "a2026" else { return Self.page(0..<0) }
            entered.open()
            await release.wait()
            return Stub.empty(.internalServerError)
        }
        seeder.server.seed(title: "A", tag: "a2026")
        seeder.server.seed(title: "B", tag: "b2026")
        let (trips, store) = await seeder.members()
        let first = try #require(trips.trips.first)
        let second = try #require(trips.trips.last)

        let held = Task {
            await store.loadJournal(first, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "A's read was not sent")
        await store.loadJournal(second, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.journalState(for: second) == .complete, "precondition: B was read")
        release.open()
        await held.value

        #expect(store.journalError(for: first) != nil, "A's failure was not said on A")
        let leaked = store.journalError(for: second)
        #expect(leaked == nil, "A's failure was said on B: \(leaked ?? "")")
        #expect(store.journal(for: second).isEmpty)
        #expect(store.journalState(for: second) == .complete)
    }
}
