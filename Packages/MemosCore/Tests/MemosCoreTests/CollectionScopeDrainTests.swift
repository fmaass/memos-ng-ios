import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// An automatic collection's members (MEMNG-817): the REAL `TripMemberStore` draining
/// `GET /api/attachments` with `tag=`, or with `bucket=` + `tz=` held to the period's interval,
/// every page through the generated client over a scripted transport.
@MainActor
@Suite("Collection scope — the automatic drain")
struct CollectionScopeDrainTests {
    private let seeder = TripSeeder()

    static func scope(
        _ kind: AutomaticCollection.Kind, count: Int = 9, cover: String? = nil
    ) -> CollectionScope {
        .automatic(
            AutomaticCollection(
                kind: kind, count: count,
                cover: cover.map { CollectionCover(uid: $0, thumbnailURL: nil) },
                zone: CollectionScopeTests.zurich))
    }

    /// The most requests any scripted walk in these suites may send. Past it the transport
    /// records an issue naming the count and answers 500, which ends the walk whether or not its
    /// cursor moved — so a walk that fails to stop fails its test instead of hanging the run.
    nonisolated static let ceiling = 16

    /// Every scripted transport here goes through this count.
    nonisolated static func bounded(_ handler: @escaping StubTransport.Handler) -> any APIProtocol {
        let sent = LockedValue(0)
        return Stub.client { request, body, operation in
            let count = sent.get() + 1
            sent.set(count)
            guard count <= ceiling else {
                Issue.record("the walk sent \(count) requests, past the ceiling of \(ceiling)")
                return Stub.detail("past the test's ceiling", status: .internalServerError)
            }
            return try await handler(request, body, operation)
        }
    }

    /// One listing page of `(uid, taken)` rows, with the continuation header when given.
    nonisolated static func rows(_ items: [(String, String)], next: String? = nil) -> (
        HTTPResponse, HTTPBody?
    ) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let next, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = next
        }
        let body = items.map { TripWire.item($0.0, taken: CollectionScopeTests.instant($0.1)) }
        return (response, HTTPBody("[\(body.joined(separator: ","))]"))
    }

    /// A transport recording every path, answering by the cursor it was sent.
    nonisolated static func recording(
        _ paths: LockedValue<[String]>,
        answer: @escaping @Sendable (String?) -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            #expect(operation == TripWire.library, "not the attachments route: \(operation)")
            return answer(TripWire.query(path, "cursor"))
        }
    }

    /// A transport whose first call waits for `release` after opening `entered`.
    nonisolated static func held(
        entered: TripLatch, release: TripLatch, calls: LockedValue<Int>,
        answer: @escaping @Sendable (Int) -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { _, _, _ in
            let call = calls.get() + 1
            calls.set(call)
            if call == 1 {
                entered.open()
                await release.wait()
            }
            return answer(call)
        }
    }

    // MARK: - the wire

    @Test("a tag's drain sends tag= oldest taken first, every kind, no bucket, cursor walked")
    func aTagDrainsByTag() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.recording(paths) { cursor in
            cursor == "c1" ? TripWire.page([2]) : TripWire.page([0, 1], next: "c1")
        }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.tag("lisbon"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.members(for: scope).map(\.id) == [0, 1, 2].map(TripWire.uid))
        #expect(members.state(for: scope) == .complete)
        let sent = paths.get()
        #expect(sent.count == 2, "not one request per page: \(sent)")
        for path in sent {
            #expect(path.hasPrefix("/api/attachments?"), "\(path)")
            #expect(TripWire.query(path, "tag") == "lisbon", "\(path)")
            #expect(TripWire.query(path, "order") == "taken_asc", "\(path)")
            #expect(TripWire.query(path, "limit") == "60", "\(path)")
            #expect(!TripWire.hasQuery(path, "type"), "the drain named a kind: \(path)")
            #expect(!TripWire.hasQuery(path, "bucket"), "a tag started at a bucket: \(path)")
        }
        #expect(!TripWire.hasQuery(sent.first ?? "", "cursor"))
        #expect(TripWire.query(sent.last ?? "", "cursor") == "c1")
    }

    @Test("a month's and a year's drain start at bucket= with tz= always sent, no tag, no type")
    func aPeriodDrainsFromItsBucket() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.recording(paths) { _ in TripWire.page([]) }
        let (_, members) = await seeder.members()
        for scope in [Self.scope(.month("2026-09")), Self.scope(.year("2026"))] {
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        }

        let sent = paths.get()
        #expect(sent.count == 2, "\(sent)")
        let month = try #require(sent.first)
        let year = try #require(sent.last)
        #expect(TripWire.query(month, "bucket") == "2026-09", "\(month)")
        #expect(TripWire.query(year, "bucket") == "2026", "\(year)")
        for path in sent {
            #expect(TripWire.query(path, "tz") == "Europe/Zurich", "tz left to the server: \(path)")
            #expect(TripWire.query(path, "order") == "taken_asc", "\(path)")
            #expect(!TripWire.hasQuery(path, "tag"), "\(path)")
            #expect(!TripWire.hasQuery(path, "type"), "\(path)")
        }
        #expect(members.state(for: Self.scope(.month("2026-09"))) == .complete)
    }

    @Test("a tag that spells a month key travels as tag=, never as a bucket or a bound")
    func aTagSpellingAMonthIsATag() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.recording(paths) { _ in
            Self.rows([("one", "2026-08-01T10:00:00Z"), ("two", "2026-11-01T10:00:00Z")])
        }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.tag("2026-09"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)

        let path = try #require(paths.get().first)
        #expect(TripWire.query(path, "tag") == "2026-09", "\(path)")
        #expect(!TripWire.hasQuery(path, "bucket"), "a tag was read as a month: \(path)")
        #expect(!TripWire.hasQuery(path, "tz"), "\(path)")
        #expect(members.members(for: scope).map(\.id) == ["one", "two"], "a tag was cut by dates")
    }

    @Test("a refused credential on the automatic drain goes to the session as one typed refusal")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue(0)
        let client = CollectionScopeDrainTests.bounded { _, _, _ in
            Stub.detail("Not authenticated", status: .unauthorized)
        }
        let (_, members) = await seeder.members(onUnauthorized: { _ in
            handled.set(handled.get() + 1)
            return .endedSession
        })
        let scope = Self.scope(.month("2026-09"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(members.lastError != nil, "an ended session said nothing")
        #expect(members.state(for: scope) == .notLoaded)
        #expect(members.members(for: scope).isEmpty)
    }

    // MARK: - the bound

    @Test("a walk started at bucket=2026-09 keeps no October row and ends at the first one")
    func aMonthEndsAtItsBound() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.recording(paths) { cursor in
            switch cursor {
            case nil:
                Self.rows(
                    [("start", "2026-08-31T22:00:00Z"), ("mid", "2026-09-15T10:00:00Z")],
                    next: "c1")
            case "c1":
                // Straddles the bound: kept up to it, and the walk ends here.
                Self.rows(
                    [
                        ("final", "2026-09-30T21:59:59Z"), ("october", "2026-09-30T22:00:00Z"),
                        ("later", "2026-10-02T10:00:00Z"),
                    ], next: "c2")
            default: Self.rows([("beyond", "2026-10-05T10:00:00Z")])
            }
        }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.month("2026-09"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.members(for: scope).map(\.id) == ["start", "mid", "final"])
        #expect(paths.get().count == 2, "the walk read past the bound: \(paths.get())")
        #expect(members.state(for: scope) == .complete)
        #expect(members.summary(for: scope)?.count == 3, "a complete drain counts its rows")
    }

    @Test("an empty bucket whose first row is past the bound has no members")
    func anEmptyBucketIsEmpty() async throws {
        let paths = LockedValue<[String]>([])
        // Every answer that names a next page differs from the last, so a walk that failed to
        // stop ends anyway and the test fails instead of hanging.
        let client = Self.recording(paths) { cursor in
            cursor == nil
                ? Self.rows([("october", "2026-10-02T10:00:00Z")], next: "c1")
                : Self.rows([("november", "2026-11-02T10:00:00Z")])
        }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.month("2026-08"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.members(for: scope).isEmpty, "the next bucket's row became a member")
        #expect(members.state(for: scope) == .complete)
        #expect(paths.get().count == 1, "the walk went on: \(paths.get())")
        #expect(members.summary(for: scope)?.count == 0)
    }

    // MARK: - keys and fences

    @Test("a trip and a tag holding the same pictures keep separate rows")
    func rowsAreKeyedByScope() async throws {
        let uid = seeder.server.seed(title: "Lisbon", tag: "lisbon", pictures: [0, 1, 2])
        let (trips, members) = await seeder.members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        await members.drain(trip, using: seeder.server.client.handle, baseURL: Stub.baseURL)
        let paths = LockedValue<[String]>([])
        let client = Self.recording(paths) { _ in TripWire.page([0, 1]) }
        let tag = Self.scope(.tag("lisbon"))
        await members.drain(tag, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.members(for: .trip(trip)).count == 3)
        #expect(members.members(for: tag).map(\.id) == [0, 1].map(TripWire.uid))
        members.invalidate(uid: trip.uid)
        #expect(members.members(for: .trip(trip)).isEmpty, "control: the trip was invalidated")
        #expect(members.members(for: tag).count == 2, "the trip's invalidation took the tag's rows")
    }

    @Test("a page answered after the trip store's revision moved is dropped whole")
    func aStaleRevisionIsDropped() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(entered: entered, release: release, calls: calls) { call in
            call == 1 ? TripWire.page([0, 1], next: "c1") : TripWire.page([2])
        }
        let (trips, members) = await seeder.members()
        let scope = Self.scope(.tag("lisbon"))
        let before = trips.revision
        let inFlight = Task {
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        await trips.refresh(using: seeder.server.client.handle, baseURL: Stub.baseURL)
        #expect(trips.revision != before, "control: the revision did not move")
        release.open()
        await inFlight.value

        #expect(members.members(for: scope).isEmpty, "a stale answer was applied")
        #expect(members.summary(for: scope) == nil)
        #expect(members.state(for: scope) == .notLoaded)
        #expect(calls.get() == 1, "the stale drain read on: \(calls.get())")
    }

    @Test("a page answered for a session that has ended is dropped whole")
    func aStaleGenerationIsDropped() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(entered: entered, release: release, calls: calls) { call in
            call == 1 ? TripWire.page([0, 1], next: "c1") : TripWire.page([2])
        }
        let (_, members) = await seeder.members()
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        members.reports(to: session)
        let scope = Self.scope(.month("2026-09"))
        let inFlight = Task { await members.drain(scope, using: issued, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        await inFlight.value

        #expect(members.members(for: scope).isEmpty, "a stale answer was applied")
        #expect(members.state(for: scope) == .notLoaded)
        #expect(calls.get() == 1, "the stale drain read on: \(calls.get())")
    }

    @Test("a second drain of a scope in flight joins the first: one request on the wire")
    func aSecondDrainJoins() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.held(entered: entered, release: release, calls: calls) { _ in
            TripWire.page([0, 1, 2])
        }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.tag("lisbon"))
        let first = Task {
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        let started = TripLatch()
        let secondDone = LockedValue(false)
        // Main-actor work runs without a suspension from the latch to the join.
        let second = Task {
            started.open()
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
            secondDone.set(true)
            return members.members(for: scope).count
        }
        #expect(await started.wait(), "the second drain never started")
        #expect(!secondDone.get(), "the second drain returned while the first was still out")
        #expect(members.state(for: scope) == .draining)
        release.open()
        await first.value
        #expect(await second.value == 3, "the joined caller did not see the drain's result")
        #expect(calls.get() == 1, "two overlapping drains were \(calls.get()) requests")
    }

    @Test("a month in another zone is another request: no join, and only its own rows show")
    func anotherZoneIsAnotherLineage() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.recording(paths) { _ in TripWire.page([0]) }
        let (_, members) = await seeder.members()
        let zurich = Self.scope(.month("2026-09"))
        let lisbon = CollectionScope.automatic(
            AutomaticCollection(
                kind: .month("2026-09"), count: 1, cover: nil,
                zone: TimeZone(identifier: "Europe/Lisbon")!))
        #expect(zurich.id == lisbon.id, "control: one display id")
        await members.drain(zurich, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: lisbon).isEmpty, "Zurich's rows answered for Lisbon's month")
        #expect(members.state(for: lisbon) == .notLoaded)
        #expect(members.members(for: zurich).count == 1, "control: Zurich's drain applied")
    }

    // MARK: - the detail line's facts

    @Test("detail: a one-page drain answers its first taken date and says it is complete")
    func detailAfterOnePage() async throws {
        let client = Self.recording(LockedValue([])) { _ in TripWire.page([3, 4]) }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.tag("lisbon"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let summary = try #require(members.summary(for: scope))
        #expect(summary.firstTaken == TripWire.taken(3))
        #expect(summary.lastTaken == TripWire.taken(4))
        #expect(summary.complete)
    }

    @Test("detail: after the final page the last taken date is the last row's, and complete")
    func detailAfterTheFinalPage() async throws {
        let client = Self.recording(LockedValue([])) { cursor in
            cursor == "c1" ? TripWire.page([5, 6]) : TripWire.page([0, 1], next: "c1")
        }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.year("2026"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let summary = try #require(members.summary(for: scope))
        #expect(summary.firstTaken == TripWire.taken(0))
        #expect(summary.lastTaken == TripWire.taken(6), "not the final page's last row")
        #expect(summary.complete)
        #expect(summary.count == 4)
    }

    @Test("detail: a truncated drain says so, its last taken date the last row it read")
    func detailOfATruncatedDrain() async throws {
        let client = Self.recording(LockedValue([])) { cursor in
            cursor == nil ? TripWire.page([0, 1, 2], next: "c1") : TripWire.page([3])
        }
        let (_, members) = await seeder.members(memberCap: 2)
        let scope = Self.scope(.month("2026-09"), count: 40)
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let summary = try #require(members.summary(for: scope))
        #expect(!summary.complete, "a truncated drain called itself complete")
        #expect(summary.firstTaken == TripWire.taken(0))
        #expect(summary.lastTaken == TripWire.taken(1), "not the last drained row")
        #expect(summary.count == 40, "a truncated drain's count is the card's")
    }

    @Test("detail: a trip's summary carries the same completeness")
    func detailOfATrip() async throws {
        let uid = seeder.server.seed(title: "Lisbon", tag: "lisbon", pictures: [0, 1, 2])
        let (trips, members) = await seeder.members(memberCap: 2)
        let trip = try #require(trips.trips.first { $0.uid == uid })
        await members.drain(trip, using: seeder.server.client.handle, baseURL: Stub.baseURL)
        #expect(members.summary(for: trip)?.complete == false)
    }

    // MARK: - the cover

    @Test("cover: the carried cover while it is a drained member")
    func coverCarriedPresent() async throws {
        let client = Self.recording(LockedValue([])) { _ in TripWire.page([0, 1, 2]) }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.tag("lisbon"), cover: TripWire.uid(1))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let summary = try #require(members.summary(for: scope))
        #expect(summary.cover?.id == TripWire.uid(1))
        #expect(summary.coverUid == TripWire.uid(1))
        #expect(summary.count == 3, "a complete drain's count is its rows, not the card's")
    }

    @Test("cover: a carried cover a complete drain does not list gives way to the newest")
    func coverCarriedGone() async throws {
        let client = Self.recording(LockedValue([])) { _ in TripWire.page([0, 1, 2]) }
        let (_, members) = await seeder.members()
        let scope = Self.scope(.month("2026-09"), cover: "deleted")
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let summary = try #require(members.summary(for: scope))
        #expect(summary.cover?.id == TripWire.uid(2), "not the newest drained picture")
        #expect(summary.coverUid == TripWire.uid(2))
    }

    @Test("cover: a drain truncated short of the carried cover keeps the carried one")
    func coverCarriedPastATruncatedDrain() async throws {
        let client = Self.recording(LockedValue([])) { cursor in
            cursor == nil ? TripWire.page([0, 1, 2], next: "c1") : TripWire.page([3])
        }
        let (_, members) = await seeder.members(memberCap: 2)
        let scope = Self.scope(.tag("lisbon"), count: 9, cover: TripWire.uid(7))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.state(for: scope) == .truncated)
        let summary = try #require(members.summary(for: scope))
        #expect(summary.cover == nil, "a drained row stood in for the carried cover")
        #expect(summary.coverUid == TripWire.uid(7))
        #expect(summary.count == 9, "a truncated drain's count is the card's")
    }

    @Test("cover: a trip keeps its oldest member, through the scope")
    func coverOfATripIsTheOldest() async throws {
        let uid = seeder.server.seed(title: "Lisbon", tag: "lisbon", pictures: [0, 1, 2])
        let (trips, members) = await seeder.members()
        let trip = try #require(trips.trips.first { $0.uid == uid })
        await members.drain(.trip(trip), using: seeder.server.client.handle, baseURL: Stub.baseURL)
        #expect(members.summary(for: .trip(trip))?.cover?.id == TripWire.uid(0))
    }
}
