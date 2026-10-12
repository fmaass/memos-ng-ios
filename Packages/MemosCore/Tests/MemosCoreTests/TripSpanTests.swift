import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip's span on the server-backed trip (MEMNG-737, moved by MEMNG-754): the SERVER now lists a
/// span's members, so the window walk this suite held the device's drain to is the Removed list's
/// walk (`TripMemberStore.removed`) — the same newest-first library walk, the same window to the
/// minute, the same fences — and the span's journal is read beside the tag's (decision 9: a trip
/// without a tag has no journal, so the journal cases give the trip a tag as well as its span).
@MainActor
@Suite("Trip span")
struct TripSpanTests {
    private nonisolated static let memosOperation = "list_memos_api_memos_get"
    private nonisolated static let tag = "portugal2026"
    private nonisolated static let lisbonZone = TimeZone(identifier: "Europe/Lisbon")!

    // MARK: - fixtures

    /// An instant given as Lisbon's wall clock in July 2026 (UTC+1).
    private nonisolated static func lisbon(
        _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0, month: Int = 7
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbonZone
        let parts = DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: parts)!
    }

    /// The owner's example: 10 July 00:00 to 20 July 14:00, Lisbon time.
    private nonisolated static let span = TripSpan(
        start: lisbon(10, 0, 0), end: lisbon(20, 14, 0), zone: "Europe/Lisbon")

    private nonisolated static func item(_ uid: String, taken: Date) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":false,"memoUid":"m-\(uid)",\
        "takenAt":"\(taken.formatted(.iso8601))","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private nonisolated static func page(
        _ items: [String], nextCursor: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let nextCursor, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = nextCursor
        }
        return (response, HTTPBody("[\(items.joined(separator: ","))]"))
    }

    /// An ISO-8601 instant as a query carries it, with or without fractional seconds.
    private nonisolated static func instant(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    /// The query a request carried, by name.
    private nonisolated static func query(_ request: HTTPRequest) -> [String: String] {
        let items = URLComponents(string: request.path ?? "")?.queryItems ?? []
        return Dictionary(
            items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// The library newest first around the owner's window, as `taken_desc` pages it: a picture
    /// after the window, the last day's 13:59, 14:00 and 14:01, the first day's 00:00, 09:59 and
    /// 10:01, the evening before, and one more page that only a walk past the start would read.
    private nonisolated static func library(_ request: HTTPRequest) -> (HTTPResponse, HTTPBody?) {
        switch query(request)["cursor"] {
        case nil:
            return page(
                [
                    item("after", taken: lisbon(25, 12, 0)),
                    item("last-1401", taken: lisbon(20, 14, 1)),
                    item("last-1400", taken: lisbon(20, 14, 0)),
                    item("last-1359", taken: lisbon(20, 13, 59)),
                ], nextCursor: "c1")
        case "c1":
            return page(
                [
                    item("first-1001", taken: lisbon(10, 10, 1)),
                    item("first-0959", taken: lisbon(10, 9, 59)),
                    item("first-0000", taken: lisbon(10, 0, 0)),
                    item("eve-2359", taken: lisbon(9, 23, 59)),
                    item("older", taken: lisbon(1, 12, 0)),
                ], nextCursor: "c2")
        default:
            return page([item("past-the-start", taken: lisbon(15, 12, 0))])
        }
    }

    /// The query a recorded path carried, by name.
    private nonisolated static func query(path: String) -> [String: String] {
        let items = URLComponents(string: path)?.queryItems ?? []
        return Dictionary(
            items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// The trip `server` lists first, and the stores a real refresh filled over it.
    private func stores(
        _ server: TripServer, pageSize: Int = TripMemberStore.pageSize,
        memberCap: Int = TripMemberStore.memberCap,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async throws -> (trip: Trip, trips: TripStore, members: TripMemberStore) {
        let (trips, members) = await TripSeeder(server: server).members(
            pageSize: pageSize, memberCap: memberCap, onUnauthorized: onUnauthorized)
        return (try #require(trips.trips.first), trips, members)
    }

    /// A member listing of `named` pictures (uid and taken), less what `server` has excluded.
    private nonisolated static func members(
        _ named: [(String, Date)], excluding server: LockedValue<TripServer?>
    ) -> (HTTPResponse, HTTPBody?) {
        let excluded = Set(server.get()?.rows.first?.exclusions ?? [])
        return page(named.filter { !excluded.contains($0.0) }.map { item($0.0, taken: $0.1) })
    }

    /// The ids of an exact Removed list; nil for any other state.
    private func removedIDs(_ state: TripRemovedState) -> [String]? {
        guard case .exact(let rows) = state else { return nil }
        return rows.map(\.id)
    }

    /// Narrows the trip's span on the server, through the trip store's own PATCH.
    private func narrow(
        _ trip: Trip, in trips: TripStore, on server: TripServer, start: Date
    ) async throws -> Trip {
        try await trips.update(
            uid: trip.uid, patch: TripPatch(spanStart: .set(start)), using: server.client.handle,
            baseURL: Stub.baseURL)
    }

    // MARK: - the span's walk

    @Test("a span-only trip's Removed walk takes exactly the pictures taken in its window")
    func aSpanOnlyTripIsItsWindow() async throws {
        let server = TripServer(answer: { request, operation in
            operation == TripWire.library ? Self.library(request) : nil
        })
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, _, members) = try await stores(server, pageSize: 5)

        await members.removed(for: trip, using: server.client.handle, baseURL: Stub.baseURL)

        #expect(
            removedIDs(members.removedState(for: trip))
                == ["first-0000", "first-0959", "first-1001", "last-1359", "last-1400"],
            "not exactly the window, oldest first")
        let walk = server.calls.of(TripWire.library).map { Self.query(path: $0.path) }
        #expect(walk.count == 2, "the walk did not stop at the first picture before the start")
        for query in walk {
            #expect(query["order"] == "taken_desc", "not newest first: \(query)")
            #expect(query["tag"] == nil, "the span walk named a tag: \(query)")
            #expect(query["type"] == nil, "the span walk named a kind: \(query)")
            #expect(query["limit"] == "5", "\(query)")
        }
        #expect(walk.map { $0["cursor"] } == [nil, "c1"])
    }

    @Test("a trip with a tag and a span walks the union, each picture once")
    func theUnionHoldsEachPictureOnce() async throws {
        let server = TripServer(answer: { request, operation in
            guard operation == TripWire.library else { return nil }
            let query = Self.query(request)
            if query["tag"] == Self.tag {
                #expect(query["order"] == "taken_asc", "the tag lane changed its order")
                return Self.page([
                    Self.item("tagged-before", taken: Self.lisbon(5, 12, 0)),
                    Self.item("both", taken: Self.lisbon(12, 12, 0)),
                ])
            }
            return Self.page([
                Self.item("span-only", taken: Self.lisbon(15, 12, 0)),
                Self.item("both", taken: Self.lisbon(12, 12, 0)),
                Self.item("eve", taken: Self.lisbon(9, 12, 0)),
            ])
        })
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, _, members) = try await stores(server)

        await members.removed(for: trip, using: server.client.handle, baseURL: Stub.baseURL)

        #expect(
            removedIDs(members.removedState(for: trip)) == ["tagged-before", "both", "span-only"],
            "not the union oldest first, each once")
    }

    @Test("an excluded span member never returns on a re-drain, nor an excluded tag member")
    func anExclusionHoldsAcrossDrains() async throws {
        let box = LockedValue<TripServer?>(nil)
        let named = [
            ("tagged", Self.lisbon(5, 12, 0)), ("ours", Self.lisbon(12, 12, 0)),
            ("dami", Self.lisbon(15, 12, 0)),
        ]
        let server = TripServer(answer: { _, operation in
            operation == TripWire.members ? Self.members(named, excluding: box) : nil
        })
        box.set(server)
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, trips, members) = try await stores(server)
        let handle = server.client.handle
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 3, "control: the union before any exclusion")

        try await members.remove(
            ["dami", "tagged"], from: trip, using: handle, baseURL: Stub.baseURL)
        let excluded = try #require(trips.trips.first)
        await members.drain(excluded, using: handle, baseURL: Stub.baseURL)
        await members.drain(excluded, using: handle, baseURL: Stub.baseURL)

        #expect(members.members(for: excluded).map(\.id) == ["ours"], "an exclusion came back")
        #expect(server.rows.first?.exclusions == ["dami", "tagged"])
    }

    @Test("Remove from trip takes a span member out, and a re-drain does not bring it back")
    func removeASpanMember() async throws {
        let box = LockedValue<TripServer?>(nil)
        let named = [("ours", Self.lisbon(12, 12, 0)), ("dami", Self.lisbon(15, 12, 0))]
        let server = TripServer(answer: { request, operation in
            if operation == TripWire.members { return Self.members(named, excluding: box) }
            guard operation == TripWire.library else { return nil }
            return Self.page([
                Self.item("dami", taken: Self.lisbon(15, 12, 0)),
                Self.item("ours", taken: Self.lisbon(12, 12, 0)),
                Self.item("eve", taken: Self.lisbon(9, 12, 0)),
            ])
        })
        box.set(server)
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, trips, members) = try await stores(server)
        let handle = server.client.handle
        await members.drain(trip, using: handle, baseURL: Stub.baseURL)
        #expect(members.members(for: trip).count == 2, "control: both are members")

        try await members.remove(["dami"], from: trip, using: handle, baseURL: Stub.baseURL)
        #expect(server.rows.first?.exclusions == ["dami"], "the span member was not removed")

        let after = try #require(trips.trips.first)
        await members.drain(after, using: handle, baseURL: Stub.baseURL)
        #expect(members.members(for: after).map(\.id) == ["ours"], "a re-drain brought it back")
        await members.removed(for: after, using: handle, baseURL: Stub.baseURL)
        #expect(removedIDs(members.removedState(for: after)) == ["dami"])
    }

    @Test("moving the end by one minute changes the window on the next walk")
    func oneMinuteMovesTheCount() async throws {
        let server = TripServer(answer: { request, operation in
            operation == TripWire.library ? Self.library(request) : nil
        })
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, trips, members) = try await stores(server, pageSize: 5)
        let handle = server.client.handle
        await members.removed(for: trip, using: handle, baseURL: Stub.baseURL)
        #expect(removedIDs(members.removedState(for: trip))?.count == 5, "control")

        let later = Self.lisbon(20, 14, 1)
        let moved = try await trips.update(
            uid: trip.uid, patch: TripPatch(spanEnd: .set(later)), using: handle,
            baseURL: Stub.baseURL)
        #expect(moved.spanEnd == later, "the span was not written")
        #expect(members.removedState(for: moved) == .notRequested, "the old walk's list stood")
        await members.removed(for: moved, using: handle, baseURL: Stub.baseURL)
        let window = removedIDs(members.removedState(for: moved))
        #expect(window?.last == "last-1401", "14:01 did not join")
        #expect(window?.count == 6)
    }

    @Test("a span walk past the cap stops reading, and the list says it is not available")
    func theSpanStopsAtTheCap() async throws {
        let server = TripServer(answer: { request, operation in
            operation == TripWire.library ? Self.library(request) : nil
        })
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, _, members) = try await stores(server, pageSize: 4, memberCap: 1)
        await members.removed(for: trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(members.removedState(for: trip) == .unavailable)
        let pages = server.calls.of(TripWire.library).count
        #expect(pages == 1, "the walk read on past the cap: \(pages)")
    }

    @Test("a walk issued under the old span publishes nothing once the span has changed")
    func anOldSpansDrainIsDropped() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(
            answer: { request, operation in
                operation == TripWire.library ? Self.library(request) : nil
            },
            hold: { operation, count in
                guard operation == TripWire.library, count == 1 else { return }
                entered.open()
                await release.wait()
            })
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, trips, members) = try await stores(server, pageSize: 5)
        let handle = server.client.handle
        let held = Task { await members.removed(for: trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        let moved = try await narrow(trip, in: trips, on: server, start: Self.lisbon(20, 0, 0))
        release.open()
        await held.value

        #expect(members.removedState(for: moved) == .notRequested, "the old span's walk published")
        await members.removed(for: moved, using: handle, baseURL: Stub.baseURL)
        #expect(
            removedIDs(members.removedState(for: moved)) == ["last-1359", "last-1400"],
            "control: the new span's walk lands")
    }

    @Test("a second Removed of the same span in flight joins the first and sends nothing")
    func twoDrainsOfOneSpanAreOneChain() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(
            answer: { request, operation in
                operation == TripWire.library ? Self.library(request) : nil
            },
            hold: { operation, count in
                guard operation == TripWire.library, count == 1 else { return }
                entered.open()
                await release.wait()
            })
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, _, members) = try await stores(server, pageSize: 5)
        let handle = server.client.handle
        let first = Task { await members.removed(for: trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        // Main-actor work runs without a suspension from the latch to the join.
        let started = TripLatch()
        let second = Task {
            started.open()
            await members.removed(for: trip, using: handle, baseURL: Stub.baseURL)
        }
        #expect(await started.wait(), "the second walk never started")
        release.open()
        await first.value
        await second.value
        let pages = server.calls.of(TripWire.library).count
        #expect(pages == 2, "two walks were two chains: \(pages)")
        #expect(removedIDs(members.removedState(for: trip))?.count == 5)
    }

    @Test("a tag spelling the query's syntax stays one value, and the span's walk names no tag")
    func aTagWithQuerySyntaxBesideASpan() async throws {
        let server = TripServer(answer: { _, operation in
            operation == TripWire.library ? Self.page([]) : nil
        })
        let odd = "a&order=taken_desc&tag=b"
        server.seed(title: "Odd", tag: odd, span: Self.span)
        let (trip, _, members) = try await stores(server)
        await members.removed(for: trip, using: server.client.handle, baseURL: Stub.baseURL)
        let queries = server.calls.of(TripWire.library).map { Self.query(path: $0.path) }
        #expect(queries.count == 2, "not one read per lane: \(queries)")
        #expect(queries.first?["tag"] == odd, "the tag did not travel as one value")
        #expect(queries.first?["order"] == "taken_asc")
        #expect(queries.last?["tag"] == nil, "the span's walk named a tag: \(queries)")
        #expect(queries.last?["order"] == "taken_desc")
    }

    @Test("a refusal on the span's walk after the tag's pages reaches the session, lists nothing")
    func aRefusalOnTheSpansWalk() async throws {
        let handled = LockedValue(0)
        let server = TripServer(answer: { request, operation in
            guard operation == TripWire.library else { return nil }
            if Self.query(request)["tag"] == Self.tag {
                return Self.page([Self.item("tagged", taken: Self.lisbon(5, 12, 0))])
            }
            return Stub.empty(.unauthorized)
        })
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, _, members) = try await stores(
            server,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })
        await members.removed(for: trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(members.lastError != nil, "an ended session said nothing")
        #expect(removedIDs(members.removedState(for: trip)) == nil, "the tag's half was listed")
    }

    // MARK: - the record

    @Test("a trip listed with no span has none, and a span set on it reads back on a fresh list")
    func aRecordWithoutASpanDecodes() async throws {
        let server = TripServer()
        server.seed(title: "Portugal 2026", tag: Self.tag)
        let (trip, trips, _) = try await stores(server)
        #expect(trip.span == nil && trip.tripSpan == nil)
        #expect(trip.tag == "portugal2026")

        let span = Self.span
        let patch = TripPatch(
            spanStart: .set(span.start), spanEnd: .set(span.end), tz: .set(span.zone))
        try await trips.update(
            uid: trip.uid, patch: patch, using: server.client.handle, baseURL: Stub.baseURL)
        let (reread, _, _) = try await stores(server)
        #expect(reread.tripSpan == Self.span, "the span did not survive a fresh list")
    }

    @Test("a span set by its dates runs from 00:00 of the first day to 23:59:59 of the last")
    func aSpanByDays() throws {
        let zone = Self.lisbonZone
        let days = try #require(
            TripSpan.days(from: Self.lisbon(10, 9, 30), to: Self.lisbon(20, 18, 5), in: zone))
        #expect(days.start == Self.lisbon(10, 0, 0))
        #expect(days.end == Self.lisbon(20, 23, 59, 59))
        #expect(days.zone == "Europe/Lisbon")
        // One day: its own midnight to its own last second.
        let one = try #require(
            TripSpan.days(from: Self.lisbon(10, 9, 30), to: Self.lisbon(10, 9, 30), in: zone))
        #expect(one.end.timeIntervalSince(one.start) == 86_399)
        #expect(
            TripSpan.days(from: Self.lisbon(10, 9, 30), to: Self.lisbon(9, 9, 30), in: zone) == nil,
            "a backward span was made")
    }

    // MARK: - the journal

    /// One memo of the journal lane, with pictures taken at `taken` (none: a text memo).
    private nonisolated static func memo(
        _ uid: String, created: Date, taken: [Date] = []
    ) -> String {
        Stub.memo(
            uid: uid,
            createdAt: created.formatted(.iso8601),
            attachments: taken.enumerated().map { index, date in
                Stub.attachment(
                    uid: "\(uid)-a\(index)", status: "ready",
                    captureInstant: date.formatted(.iso8601))
            }
        )
    }

    /// A server whose journal answers `tagged` on the tag lane and `spanned` on the span lane.
    private nonisolated static func journalServer(
        tagged: [String] = [], spanned: [String], box: LockedValue<TripServer?>? = nil,
        named: [(String, Date)] = [], hold: TripServer.Hold? = nil
    ) -> TripServer {
        TripServer(
            answer: { request, operation in
                if operation == TripWire.members, let box { return members(named, excluding: box) }
                guard operation == memosOperation else { return nil }
                let lane = query(request)["tag"] == nil ? spanned : tagged
                return Stub.json(Stub.page(lane, nextCursor: nil))
            }, hold: hold)
    }

    @Test("a span's journal is the memos placed in the window by their earliest picture")
    func theSpansJournal() async throws {
        let server = Self.journalServer(spanned: [
            // Posted on the first day; its picture was taken the evening before: out.
            Self.memo(
                "eve-picture", created: Self.lisbon(10, 8, 0), taken: [Self.lisbon(9, 23, 0)]),
            // A text memo written in the window: in, by its date.
            Self.memo("text", created: Self.lisbon(11, 9, 0)),
            // Posted a week after, of the last morning: in, on the last day.
            Self.memo("later", created: Self.lisbon(27, 9, 0), taken: [Self.lisbon(20, 10, 0)]),
            // Posted in the window, its earliest picture on the second day: in.
            Self.memo(
                "two", created: Self.lisbon(12, 9, 0),
                taken: [Self.lisbon(12, 8, 0), Self.lisbon(11, 7, 0)]),
            // A text memo written after the end: out.
            Self.memo("after", created: Self.lisbon(21, 9, 0)),
        ])
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, _, store) = try await stores(server)
        await store.loadJournal(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(
            store.journal(for: trip).map(\.uid) == ["two", "text", "later"],
            "not the window's memos in the order of their days")
        #expect(store.journalState(for: trip) == .complete)
        let reads = server.calls.of(Self.memosOperation).map { Self.query(path: $0.path) }
        let query = try #require(reads.first { $0["tag"] == nil }, "the span lane was not read")
        #expect(reads.count == 2, "not one read per lane: \(reads)")
        #expect(query["sort"] == "created_at", "\(query)")
        let after = try #require(query["created_after"], "no created_after: \(query)")
        let bound = try #require(Self.instant(after), "not an instant: \(after)")
        #expect(bound < Self.span.start, "a memo posted at the start would be left out")
        #expect(query["created_before"] == nil, "a memo posted after the end was cut: \(query)")
    }

    @Test("a journal places a memo by its earliest picture, its date only without one")
    func theJournalKeysOnTheEarliestPicture() async throws {
        let server = Self.journalServer(
            tagged: [
                // Written first, of pictures taken on the third day.
                Self.memo("photos", created: Self.lisbon(11, 9, 0), taken: [Self.lisbon(13, 9, 0)]),
                Self.memo("words", created: Self.lisbon(12, 9, 0)),
            ], spanned: [])
        server.seed(title: "Portugal 2026", tag: Self.tag)
        let (trip, _, store) = try await stores(server)
        await store.loadJournal(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: trip).map(\.uid) == ["words", "photos"])
        let photos = store.journal(for: trip).last
        #expect(photos.map(TripMemberStore.journalInstant(of:)) == Self.lisbon(13, 9, 0))
    }

    @Test("a span memo whose every picture was removed from the trip leaves its journal")
    func aRemovedPictureTakesItsMemo() async throws {
        let box = LockedValue<TripServer?>(nil)
        let server = Self.journalServer(
            spanned: [
                Self.memo("dami", created: Self.lisbon(12, 9, 0), taken: [Self.lisbon(12, 8, 0)]),
                Self.memo("ours", created: Self.lisbon(13, 9, 0), taken: [Self.lisbon(13, 8, 0)]),
            ], box: box,
            named: [("dami-a0", Self.lisbon(12, 8, 0)), ("ours-a0", Self.lisbon(13, 8, 0))])
        box.set(server)
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, trips, store) = try await stores(server)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: trip).map(\.uid) == ["dami", "ours"], "control")
        try await store.remove(["dami-a0"], from: trip, using: handle, baseURL: Stub.baseURL)
        let excluded = try #require(trips.trips.first)
        #expect(store.state(for: excluded) == .complete, "control: the members were read again")
        #expect(store.journal(for: excluded).map(\.uid) == ["ours"], "the removed memo stayed")
    }

    // MARK: - review round 1

    @Test("a tag lane of exactly the cap still walks the span, and lists the picture past it")
    func anExactCapStillReadsTheSpan() async throws {
        let tagged = [
            Self.item("tagged-a", taken: Self.lisbon(11, 12, 0)),
            Self.item("tagged-b", taken: Self.lisbon(12, 12, 0)),
        ]
        let server = TripServer(answer: { request, operation in
            guard operation == TripWire.library else { return nil }
            if Self.query(request)["tag"] == Self.tag { return Self.page(tagged) }
            return Self.page([
                Self.item("span-new", taken: Self.lisbon(15, 12, 0)),
                Self.item("eve", taken: Self.lisbon(9, 12, 0)),
            ])
        })
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, _, store) = try await stores(server, memberCap: 2)
        await store.removed(for: trip, using: server.client.handle, baseURL: Stub.baseURL)
        let walk = server.calls.of(TripWire.library).map { Self.query(path: $0.path) }
        #expect(walk.contains { $0["order"] == "taken_desc" }, "the span was never read")
        // Each lane is held to the cap on its own; the union of the two is exact.
        #expect(
            removedIDs(store.removedState(for: trip)) == ["tagged-a", "tagged-b", "span-new"],
            "the span's picture past a full tag lane was not listed")

        // Control: a span that adds nothing new leaves the union whole at the cap.
        let same = TripServer(answer: { request, operation in
            guard operation == TripWire.library else { return nil }
            if Self.query(request)["tag"] == Self.tag { return Self.page(tagged) }
            let eve = Self.item("eve", taken: Self.lisbon(9, 12, 0))
            return Self.page([tagged[1], tagged[0], eve])
        })
        same.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (wholeTrip, _, whole) = try await stores(same, memberCap: 2)
        await whole.removed(for: wholeTrip, using: same.client.handle, baseURL: Stub.baseURL)
        #expect(removedIDs(whole.removedState(for: wholeTrip)) == ["tagged-a", "tagged-b"])
    }

    @Test("a journal whose tag lane is exactly the cap still reads the span's memos")
    func anExactCapJournalStillReadsTheSpan() async throws {
        let server = Self.journalServer(
            tagged: [
                Self.memo("t1", created: Self.lisbon(11, 9, 0)),
                Self.memo("t2", created: Self.lisbon(12, 9, 0)),
            ], spanned: [Self.memo("words", created: Self.lisbon(13, 9, 0))])
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, _, store) = try await stores(server, memberCap: 2)
        await store.loadJournal(trip, using: server.client.handle, baseURL: Stub.baseURL)
        #expect(store.journalState(for: trip) == .truncated, "a capped journal said complete")
        #expect(store.journal(for: trip).count == 2)
    }

    @Test("a span memo stays in the journal only while one of its pictures is a current member")
    func aSpanMemoNeedsACurrentMember() async throws {
        let box = LockedValue<TripServer?>(nil)
        let server = Self.journalServer(
            spanned: [
                // One picture in the window, one taken after it.
                Self.memo(
                    "mixed", created: Self.lisbon(12, 9, 0),
                    taken: [Self.lisbon(12, 8, 0), Self.lisbon(25, 8, 0)]),
                Self.memo("ours", created: Self.lisbon(13, 9, 0), taken: [Self.lisbon(13, 8, 0)]),
            ], box: box,
            named: [("mixed-a0", Self.lisbon(12, 8, 0)), ("ours-a0", Self.lisbon(13, 8, 0))])
        box.set(server)
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, trips, store) = try await stores(server)
        let handle = server.client.handle
        await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: trip).map(\.uid) == ["mixed", "ours"], "control")
        try await store.remove(["mixed-a0"], from: trip, using: handle, baseURL: Stub.baseURL)
        let excluded = try #require(trips.trips.first)
        #expect(
            store.journal(for: excluded).map(\.uid) == ["ours"],
            "a picture outside the window kept its memo in the journal")
    }

    @Test("a picture deleted while the journal was read takes its span memo out of the journal")
    func aDeletedPictureLeavesTheJournal() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = Self.journalServer(
            spanned: [
                Self.memo("gone", created: Self.lisbon(12, 9, 0), taken: [Self.lisbon(12, 8, 0)]),
                Self.memo("kept", created: Self.lisbon(13, 9, 0), taken: [Self.lisbon(13, 8, 0)]),
            ],
            hold: { operation, count in
                guard operation == Self.memosOperation, count == 1 else { return }
                entered.open()
                await release.wait()
            })
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, _, store) = try await stores(server)
        let handle = server.client.handle
        let held = Task { await store.loadJournal(trip, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no journal read was sent")
        let outcome = await store.delete(["gone-a0"], using: handle, baseURL: Stub.baseURL)
        #expect(outcome?.deleted == ["gone-a0"], "control: the delete went through")
        release.open()
        await held.value
        #expect(
            store.journal(for: trip).map(\.uid) == ["kept"],
            "a memo whose only picture was deleted stayed in the journal")
    }

    @Test("a drain failure under the old span writes no sentence once the span has changed")
    func anOldSpansFailureSaysNothing() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let server = TripServer(
            answer: { _, operation in
                operation == TripWire.members ? Stub.empty(.internalServerError) : nil
            },
            hold: { operation, _ in
                guard operation == TripWire.members else { return }
                entered.open()
                await release.wait()
            })
        server.seed(title: "Lisbon", span: Self.span)
        let (trip, trips, store) = try await stores(server)
        let held = Task {
            await store.drain(trip, using: server.client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        _ = try await narrow(trip, in: trips, on: server, start: Self.lisbon(20, 0, 0))
        release.open()
        await held.value
        #expect(store.lastError == nil, "the old span's failure was said over the new one")
    }

    @Test("a journal refusal under the old span reaches the session but writes no sentence")
    func anOldSpansJournalRefusal() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let handled = LockedValue(0)
        let server = TripServer(
            answer: { _, operation in
                operation == Self.memosOperation ? Stub.empty(.unauthorized) : nil
            },
            hold: { operation, count in
                guard operation == Self.memosOperation, count == 1 else { return }
                entered.open()
                await release.wait()
            })
        server.seed(title: "Lisbon", tag: Self.tag, span: Self.span)
        let (trip, trips, store) = try await stores(
            server,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })
        let held = Task {
            await store.loadJournal(trip, using: server.client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        let moved = try await narrow(trip, in: trips, on: server, start: Self.lisbon(20, 0, 0))
        release.open()
        await held.value
        #expect(handled.get() >= 1, "the refusal did not reach the session")
        #expect(store.journalError(for: moved) == nil, "the old span's refusal was said")
    }
}
