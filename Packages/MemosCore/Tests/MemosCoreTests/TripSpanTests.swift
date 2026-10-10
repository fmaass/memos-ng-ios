import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip's span (MEMNG-737): a start and an end instant make every picture TAKEN in the window a
/// member, whatever its memo's tags, beside the pictures of the trip's tag.
///
/// The span is drained with no server work: `GET /api/attachments?order=taken_desc`, no tag and no
/// type, from the newest page down — rows taken after the end are skipped, rows in the window are
/// kept, and the walk stops at the first row taken before the start. The server is a script under
/// the REAL generated client (`StubTransport`); the record is a REAL `CollectionStore`.
@MainActor
@Suite("Trip span")
struct TripSpanTests {
    private nonisolated static let listOperation = "list_attachments_api_attachments_get"
    private nonisolated static let memosOperation = "list_memos_api_memos_get"
    private nonisolated static let tag = "portugal2026"
    private nonisolated static let lisbonZone = TimeZone(identifier: "Europe/Lisbon")!

    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-span")
        .appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!,
        subject: "alice"
    )

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
        "renditions":[],"orphan":false,"memoUid":"m-\(uid)",\
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

    private func collections() -> CollectionStore {
        CollectionStore(identity: alice, root: root, now: { Self.lisbon(1, 0, 0) })
    }

    private func current(
        _ record: CollectionRecord, in store: CollectionStore
    ) -> CollectionRecord? {
        store.records.first { $0.id == record.id }
    }

    // MARK: - the span drain

    @Test("a span-only trip lists exactly the pictures taken in its window, to the minute")
    func aSpanOnlyTripIsItsWindow() async throws {
        let sent = LockedValue<[[String: String]]>([])
        let operations = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            sent.set(sent.get() + [Self.query(request)])
            operations.set(operations.get() + [operation])
            return Self.library(request)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections, pageSize: 5)

        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(
            store.members(for: record).map(\.id)
                == ["first-0000", "first-0959", "first-1001", "last-1359", "last-1400"],
            "not exactly the window, oldest first")
        #expect(store.state(for: record) == .complete)
        let written = try #require(current(record, in: collections)?.lastSummary)
        #expect(written.count == 5, "the summary is not the window's")
        #expect(written.firstTaken == Self.lisbon(10, 0, 0))
        #expect(written.lastTaken == Self.lisbon(20, 14, 0))

        let queries = sent.get()
        #expect(queries.count == 2, "the walk did not stop at the first picture before the start")
        #expect(operations.get().allSatisfy { $0 == Self.listOperation })
        for query in queries {
            #expect(query["order"] == "taken_desc", "not newest first: \(query)")
            #expect(query["tag"] == nil, "the span walk named a tag: \(query)")
            #expect(query["type"] == nil, "the span walk named a kind: \(query)")
            #expect(query["limit"] == "5", "\(query)")
        }
        #expect(queries.map { $0["cursor"] } == [nil, "c1"])
    }

    @Test("a trip with a tag and a span lists the union, each picture once")
    func theUnionHoldsEachPictureOnce() async {
        let client = Stub.client { request, _, _ in
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
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [Self.tag], span: Self.span)
        let store = TripMembershipStore(collections: collections)

        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(
            store.members(for: record).map(\.id) == ["tagged-before", "both", "span-only"],
            "not the union oldest first, each once")
        #expect(current(record, in: collections)?.lastSummary?.count == 3)
    }

    @Test("an excluded span member never returns on a re-drain, nor an excluded tag member")
    func anExclusionHoldsAcrossDrains() async {
        let client = Stub.client { request, _, _ in
            if Self.query(request)["tag"] == Self.tag {
                return Self.page([Self.item("tagged", taken: Self.lisbon(5, 12, 0))])
            }
            return Self.page([
                Self.item("dami", taken: Self.lisbon(15, 12, 0)),
                Self.item("ours", taken: Self.lisbon(12, 12, 0)),
                Self.item("eve", taken: Self.lisbon(9, 12, 0)),
            ])
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [Self.tag], span: Self.span)
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 3, "control: the union before any exclusion")

        collections.exclude(id: record.id, uid: "dami")
        collections.exclude(id: record.id, uid: "tagged")
        let excluded = current(record, in: collections) ?? record
        await store.drain(excluded, using: client.handle, baseURL: Stub.baseURL)
        await store.drain(excluded, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.members(for: excluded).map(\.id) == ["ours"], "an exclusion came back")
        #expect(current(record, in: collections)?.lastSummary?.count == 1)
    }

    @Test("Remove from trip takes a span member out, and a re-drain does not bring it back")
    func removeASpanMember() async throws {
        let client = Stub.client { _, _, _ in
            Self.page([
                Self.item("dami", taken: Self.lisbon(15, 12, 0)),
                Self.item("ours", taken: Self.lisbon(12, 12, 0)),
                Self.item("eve", taken: Self.lisbon(9, 12, 0)),
            ])
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 2, "control: both are members")

        store.remove(["dami"], from: record.id)
        let after = try #require(current(record, in: collections))
        #expect(after.excludedUids == ["dami"], "the span member was not removed")
        #expect(after.lastSummary?.count == 1, "the summary was not written with the removal")

        await store.drain(after, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: after).map(\.id) == ["ours"], "a re-drain brought it back")
        #expect(store.removedMembers(for: after).map(\.id) == ["dami"])
    }

    @Test("moving the end by one minute changes the count on the next drain")
    func oneMinuteMovesTheCount() async {
        let client = Stub.client { request, _, _ in Self.library(request) }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections, pageSize: 5)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(current(record, in: collections)?.lastSummary?.count == 5, "control")

        var later = Self.span
        later.end = Self.lisbon(20, 14, 1)
        collections.setSpan(id: record.id, later)
        let moved = current(record, in: collections) ?? record
        #expect(moved.span == later, "the span was not written")
        await store.drain(moved, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.members(for: moved).last?.id == "last-1401", "14:01 did not join")
        #expect(current(record, in: collections)?.lastSummary?.count == 6)
    }

    @Test("a span whose end lies before its start is refused and writes nothing")
    func theStoreRefusesABackwardSpan() {
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        var backward = Self.span
        backward.end = Self.span.start.addingTimeInterval(-60)
        collections.setSpan(id: record.id, backward)
        #expect(current(record, in: collections)?.span == Self.span, "a backward span was written")

        var instant = Self.span
        instant.end = instant.start
        collections.setSpan(id: record.id, instant)
        #expect(current(record, in: collections)?.span == instant, "a one-instant span is a span")
        collections.setSpan(id: record.id, nil)
        #expect(current(record, in: collections)?.span == nil, "the span was not taken away")
    }

    @Test("a span drain stops at the cap with more of the window unread, and says truncated")
    func theSpanStopsAtTheCap() async {
        let sent = LockedValue<Int>(0)
        let client = Stub.client { request, _, _ in
            sent.set(sent.get() + 1)
            return Self.library(request)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections, pageSize: 4, memberCap: 2)

        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.members(for: record).count == 2)
        #expect(store.state(for: record) == .truncated)
        #expect(sent.get() == 1, "the walk read on past the cap")
    }

    @Test("a drain issued under the old span publishes nothing once the span has changed")
    func anOldSpansDrainIsDropped() async {
        let entered = SpanSignal()
        let release = SpanSignal()
        let calls = LockedValue<Int>(0)
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.library(request)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections, pageSize: 5)

        let held = Task { await store.drain(record, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        var narrower = Self.span
        narrower.start = Self.lisbon(20, 0, 0)
        collections.setSpan(id: record.id, narrower)
        release.signal()
        await held.value

        let moved = current(record, in: collections) ?? record
        #expect(store.members(for: moved).isEmpty, "the old span's drain published")
        #expect(current(record, in: collections)?.lastSummary == nil, "the old span's summary")
        #expect(store.state(for: moved) == .notLoaded)

        await store.drain(moved, using: client.handle, baseURL: Stub.baseURL)
        #expect(
            store.members(for: moved).map(\.id) == ["last-1359", "last-1400"],
            "control: the new span's drain lands")
    }

    @Test("a second drain of the same span in flight joins the first and sends nothing")
    func twoDrainsOfOneSpanAreOneChain() async {
        let entered = SpanSignal()
        let release = SpanSignal()
        let calls = LockedValue<Int>(0)
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.library(request)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections, pageSize: 5)
        let joined = SpanSignal()
        store.onJoin = { joined.signal() }

        let first = Task { await store.drain(record, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        let second = Task { await store.drain(record, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await joined.wait(), "the second drain did not join")
        release.signal()
        await first.value
        await second.value

        #expect(calls.get() == 2, "two drains were two chains: \(calls.get())")
        #expect(store.members(for: record).count == 5)
    }

    @Test("a tag spelling the query's syntax stays one value, and the span's walk names no tag")
    func aTagWithQuerySyntaxBesideASpan() async {
        let sent = LockedValue<[[String: String]]>([])
        let client = Stub.client { request, _, _ in
            sent.set(sent.get() + [Self.query(request)])
            return Self.page([])
        }
        let odd = "a&order=taken_desc&tag=b"
        let collections = collections()
        let record = collections.create(title: "Odd", tags: [odd], span: Self.span)
        let store = TripMembershipStore(collections: collections)

        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let queries = sent.get()
        #expect(queries.count == 2, "not one read per lane: \(queries)")
        #expect(queries.first?["tag"] == odd, "the tag did not travel as one value")
        #expect(queries.first?["order"] == "taken_asc")
        #expect(queries.last?["tag"] == nil, "the span's walk named a tag: \(queries)")
        #expect(queries.last?["order"] == "taken_desc")
    }

    @Test("a refusal on the span's walk after the tag's pages reaches the session and applies none")
    func aRefusalOnTheSpansWalk() async {
        let handled = LockedValue<Int>(0)
        let client = Stub.client { request, _, _ in
            if Self.query(request)["tag"] == Self.tag {
                return Self.page([Self.item("tagged", taken: Self.lisbon(5, 12, 0))])
            }
            return Stub.empty(.unauthorized)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [Self.tag], span: Self.span)
        let store = TripMembershipStore(
            collections: collections,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })

        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(store.lastError != nil, "an ended session said nothing")
        #expect(store.members(for: record).isEmpty, "the tag's half was applied alone")
        #expect(store.state(for: record) == .notLoaded)
        #expect(current(record, in: collections)?.lastSummary == nil)
    }

    // MARK: - the record

    @Test("a record written before spans existed decodes, with no span")
    func aRecordWithoutASpanDecodes() throws {
        let id = UUID()
        let file = """
            {"formatVersion":1,"records":[{"id":"\(id.uuidString)","kind":"trip",\
            "title":"Portugal 2026","tags":["portugal2026"],"order":0,\
            "excludedUids":["p1"],"createdAt":"2026-03-12T00:00:00Z"}]}
            """
        let directory = root.appending(path: CollectionStore.scopeKey(for: alice))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(file.utf8).write(to: directory.appending(path: CollectionStore.fileName))

        let collections = collections()
        let record = try #require(collections.records.first, "an old record did not decode")
        #expect(record.id == id && record.tags == ["portugal2026"])
        #expect(record.excludedUids == ["p1"])
        #expect(record.span == nil)

        collections.setSpan(id: id, Self.span)
        let reread = CollectionStore(identity: alice, root: root)
        #expect(reread.records.first?.span == Self.span, "the span did not survive a launch")
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

    @Test("a span's journal is the memos placed in the window by their earliest picture")
    func theSpansJournal() async throws {
        let queries = LockedValue<[[String: String]]>([])
        let client = Stub.client { request, _, operation in
            #expect(operation == Self.memosOperation)
            queries.set(queries.get() + [Self.query(request)])
            let memos = [
                // Posted on the first day; its picture was taken the evening before: out.
                Self.memo(
                    "eve-picture", created: Self.lisbon(10, 8, 0), taken: [Self.lisbon(9, 23, 0)]),
                // A text memo written in the window: in, by its date.
                Self.memo("text", created: Self.lisbon(11, 9, 0)),
                // Posted a week after, of the last morning: in, on the last day.
                Self.memo(
                    "later", created: Self.lisbon(27, 9, 0), taken: [Self.lisbon(20, 10, 0)]),
                // Posted in the window, its earliest picture on the second day: in.
                Self.memo(
                    "two", created: Self.lisbon(12, 9, 0),
                    taken: [Self.lisbon(12, 8, 0), Self.lisbon(11, 7, 0)]),
                // A text memo written after the end: out.
                Self.memo("after", created: Self.lisbon(21, 9, 0)),
            ]
            return Stub.json(Stub.page(memos, nextCursor: nil))
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(
            store.journal(for: record).map(\.uid) == ["two", "text", "later"],
            "not the window's memos in the order of their days")
        #expect(store.journalState(for: record) == .complete)
        let query = try #require(queries.get().first)
        #expect(queries.get().count == 1)
        #expect(query["tag"] == nil, "the span lane named a tag: \(query)")
        #expect(query["sort"] == "created_at", "\(query)")
        let after = try #require(query["created_after"], "no created_after: \(query)")
        let bound = try #require(Self.instant(after), "not an instant: \(after)")
        #expect(bound < Self.span.start, "a memo posted at the start would be left out")
        #expect(query["created_before"] == nil, "a memo posted after the end was cut: \(query)")
    }

    @Test("a journal places a memo by its earliest picture, its date only without one")
    func theJournalKeysOnTheEarliestPicture() async {
        let client = Stub.client { _, _, _ in
            Stub.json(
                Stub.page(
                    [
                        // Written first, of pictures taken on the third day.
                        Self.memo(
                            "photos", created: Self.lisbon(11, 9, 0),
                            taken: [Self.lisbon(13, 9, 0)]),
                        Self.memo("words", created: Self.lisbon(12, 9, 0)),
                    ], nextCursor: nil))
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: record).map(\.uid) == ["words", "photos"])
        let photos = store.journal(for: record).last
        #expect(photos.map(TripMembershipStore.journalInstant(of:)) == Self.lisbon(13, 9, 0))
    }

    @Test("a span memo whose every picture was removed from the trip leaves its journal")
    func aRemovedPictureTakesItsMemo() async {
        let client = Stub.client { _, _, _ in
            Stub.json(
                Stub.page(
                    [
                        Self.memo(
                            "dami", created: Self.lisbon(12, 9, 0), taken: [Self.lisbon(12, 8, 0)]),
                        Self.memo(
                            "ours", created: Self.lisbon(13, 9, 0), taken: [Self.lisbon(13, 8, 0)]),
                    ], nextCursor: nil))
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections)
        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: record).map(\.uid) == ["dami", "ours"], "control")

        collections.exclude(id: record.id, uid: "dami-a0")
        let excluded = current(record, in: collections) ?? record
        #expect(store.journal(for: excluded).map(\.uid) == ["ours"], "the removed memo stayed")
    }

    // MARK: - review round 1

    @Test("a tag lane of exactly the cap still reads the span, and a member past it is truncated")
    func anExactCapStillReadsTheSpan() async {
        let sent = LockedValue<[[String: String]]>([])
        let tagged = [
            Self.item("tagged-a", taken: Self.lisbon(11, 12, 0)),
            Self.item("tagged-b", taken: Self.lisbon(12, 12, 0)),
        ]
        let client = Stub.client { request, _, _ in
            let query = Self.query(request)
            sent.set(sent.get() + [query])
            if query["tag"] == Self.tag { return Self.page(tagged) }
            return Self.page([
                Self.item("span-new", taken: Self.lisbon(15, 12, 0)),
                Self.item("eve", taken: Self.lisbon(9, 12, 0)),
            ])
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [Self.tag], span: Self.span)
        let store = TripMembershipStore(collections: collections, memberCap: 2)

        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(sent.get().contains { $0["order"] == "taken_desc" }, "the span was never read")
        #expect(store.state(for: record) == .truncated, "a capped union said it was complete")
        #expect(store.members(for: record).count == 2)

        // Control: a span that adds nothing new leaves the union whole at the cap.
        let same = Stub.client { request, _, _ in
            if Self.query(request)["tag"] == Self.tag { return Self.page(tagged) }
            let eve = Self.item("eve", taken: Self.lisbon(9, 12, 0))
            return Self.page([tagged[1], tagged[0], eve])
        }
        let whole = TripMembershipStore(collections: collections, memberCap: 2)
        await whole.drain(record, using: same.handle, baseURL: Stub.baseURL)
        #expect(whole.state(for: record) == .complete)
    }

    @Test("a journal whose tag lane is exactly the cap still reads the span's memos")
    func anExactCapJournalStillReadsTheSpan() async {
        let client = Stub.client { request, _, _ in
            if Self.query(request)["tag"] == Self.tag {
                return Stub.json(
                    Stub.page(
                        [
                            Self.memo("t1", created: Self.lisbon(11, 9, 0)),
                            Self.memo("t2", created: Self.lisbon(12, 9, 0)),
                        ], nextCursor: nil))
            }
            return Stub.json(
                Stub.page([Self.memo("words", created: Self.lisbon(13, 9, 0))], nextCursor: nil))
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [Self.tag], span: Self.span)
        let store = TripMembershipStore(collections: collections, memberCap: 2)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journalState(for: record) == .truncated, "a capped journal said complete")
        #expect(store.journal(for: record).count == 2)
    }

    @Test("a span memo stays in the journal only while one of its pictures is a current member")
    func aSpanMemoNeedsACurrentMember() async {
        let client = Stub.client { _, _, _ in
            Stub.json(
                Stub.page(
                    [
                        // One picture in the window, one taken after it.
                        Self.memo(
                            "mixed", created: Self.lisbon(12, 9, 0),
                            taken: [Self.lisbon(12, 8, 0), Self.lisbon(25, 8, 0)]),
                        Self.memo(
                            "ours", created: Self.lisbon(13, 9, 0), taken: [Self.lisbon(13, 8, 0)]),
                    ], nextCursor: nil))
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections)
        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.journal(for: record).map(\.uid) == ["mixed", "ours"], "control")

        collections.exclude(id: record.id, uid: "mixed-a0")
        let excluded = current(record, in: collections) ?? record
        #expect(
            store.journal(for: excluded).map(\.uid) == ["ours"],
            "a picture outside the window kept its memo in the journal")
    }

    @Test("a picture deleted while the journal was read takes its span memo out of the journal")
    func aDeletedPictureLeavesTheJournal() async {
        let entered = SpanSignal()
        let release = SpanSignal()
        let client = Stub.client { _, _, operation in
            guard operation == Self.memosOperation else { return Stub.empty(.noContent) }
            entered.signal()
            await release.wait()
            return Stub.json(
                Stub.page(
                    [
                        Self.memo(
                            "gone", created: Self.lisbon(12, 9, 0), taken: [Self.lisbon(12, 8, 0)]),
                        Self.memo(
                            "kept", created: Self.lisbon(13, 9, 0), taken: [Self.lisbon(13, 8, 0)]),
                    ], nextCursor: nil))
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections)

        let held = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no journal read was sent")
        let outcome = await store.delete(["gone-a0"], using: client.handle)
        #expect(outcome?.deleted == ["gone-a0"], "control: the delete went through")
        release.signal()
        await held.value

        #expect(
            store.journal(for: record).map(\.uid) == ["kept"],
            "a memo whose only picture was deleted stayed in the journal")
    }

    @Test("a drain failure under the old span writes no sentence once the span has changed")
    func anOldSpansFailureSaysNothing() async {
        let entered = SpanSignal()
        let release = SpanSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Stub.empty(.internalServerError)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(collections: collections)

        let held = Task { await store.drain(record, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        var narrower = Self.span
        narrower.start = Self.lisbon(20, 0, 0)
        collections.setSpan(id: record.id, narrower)
        release.signal()
        await held.value

        #expect(store.lastError == nil, "the old span's failure was said over the new one")
    }

    @Test("a journal refusal under the old span reaches the session but writes no sentence")
    func anOldSpansJournalRefusal() async {
        let entered = SpanSignal()
        let release = SpanSignal()
        let handled = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Stub.empty(.unauthorized)
        }
        let collections = collections()
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let store = TripMembershipStore(
            collections: collections,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })

        let held = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        var narrower = Self.span
        narrower.start = Self.lisbon(20, 0, 0)
        collections.setSpan(id: record.id, narrower)
        release.signal()
        await held.value

        #expect(handled.get() == 1, "the refusal did not reach the session")
        let moved = current(record, in: collections) ?? record
        #expect(store.journalError(for: moved) == nil, "the old span's refusal was said")
    }
}

/// A one-shot hand-off between a test and its scripted transport, bounded so a request that never
/// comes fails the test instead of hanging it.
private final class SpanSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func signal() { continuation.yield() }

    @discardableResult
    func wait(seconds: Double = 5) async -> Bool {
        let stream = self.stream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
