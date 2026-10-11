import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip's membership: drained from `GET /api/attachments` under the trip's tag, every kind of
/// file, oldest first, to the end of the cursor chain or the cap — then filtered by the record's
/// exclusions and summed up onto the record.
///
/// The server is a script under the REAL generated client (`StubTransport`), so the query the
/// store builds, the `X-Next-Cursor` header it follows and the decoding are all exercised; the
/// record is a REAL `CollectionStore` over a fresh temporary root, so the summary asserted is the
/// one that reached the record. `@testable` for `TripMembershipStore.summary(of:cover:)` only.
@MainActor
@Suite("Trip membership")
struct TripMembershipStoreTests {
    private nonisolated static let listOperation = "list_attachments_api_attachments_get"
    private nonisolated static let tagsOperation = "attachment_tags_api_attachments_tags_get"
    private nonisolated static let tag = "portugal2026"

    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-membership")
        .appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!,
        subject: "alice"
    )

    // MARK: - fixtures

    /// The taken date of the n-th picture: one hour apart, from 2026-03-12T00:00:00Z.
    private nonisolated static func taken(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_773_273_600 + Double(index) * 3600)
    }

    private nonisolated static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private nonisolated static func item(
        _ uid: String,
        taken: Date,
        mime: String = "image/jpeg"
    ) -> String {
        """
        {"uid":"\(uid)","mime":"\(mime)","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":false,"memoUid":"m-\(uid)",\
        "takenAt":"\(stamp(taken))","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private nonisolated static func uid(_ index: Int) -> String {
        "p" + String(format: "%04d", index)
    }

    /// The `type` query item of a request as the log holds it (`<operation> <path>`), or nil when
    /// it is ABSENT — which is how every kind is asked for. An empty `?type=` is not absent.
    private nonisolated static func kind(_ request: String) -> String? {
        let path = request.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        let items = URLComponents(string: path)?.queryItems ?? []
        guard let item = items.first(where: { $0.name == "type" }) else { return nil }
        return item.value ?? ""
    }

    /// Pictures `range` as one page, with its continuation token where the server puts it.
    private nonisolated static func page(
        _ range: Range<Int>,
        nextCursor: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        page(range.map { item(uid($0), taken: taken($0)) }, nextCursor: nextCursor)
    }

    private nonisolated static func page(
        _ items: [String],
        nextCursor: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let nextCursor, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = nextCursor
        }
        return (response, HTTPBody("[\(items.joined(separator: ","))]"))
    }

    private func collections() -> CollectionStore {
        CollectionStore(identity: alice, root: root, now: { Self.taken(0) })
    }

    /// The record as the collection store holds it NOW.
    private func current(
        _ record: CollectionRecord,
        in store: CollectionStore
    ) -> CollectionRecord? {
        store.records.first { $0.id == record.id }
    }

    // MARK: - the drain

    @Test("three pages are drained in order, the 61st picture after the 60th")
    func threePagesInOrder() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + ["\(operation) \(path)"])
            if path.contains("cursor=c2") { return Self.page(120..<125) }
            if path.contains("cursor=c1") { return Self.page(60..<120, nextCursor: "c2") }
            return Self.page(0..<60, nextCursor: "c1")
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let other = collections.create(title: "Another trip", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let members = store.members(for: record)
        #expect(members.map(\.id) == (0..<125).map(Self.uid), "not the three pages in order")
        // The summary reaches the record that was drained and no other.
        #expect(current(other, in: collections)?.lastSummary == nil, "another record was written")
        #expect(store.state(for: other) == .notLoaded)
        let sixtieth = try #require(members[59].takenAt)
        let sixtyFirst = try #require(members[60].takenAt)
        #expect(sixtyFirst > sixtieth, "the second page did not follow the first")
        #expect(store.state(for: record) == .complete)
        #expect(store.lastError == nil)

        let sent = paths.get()
        #expect(sent.count == 3, "not one request per page: \(sent)")
        for request in sent {
            #expect(request.hasPrefix(Self.listOperation), "not the list operation: \(request)")
            #expect(request.contains("tag=\(Self.tag)"), "no tag: \(request)")
            #expect(Self.kind(request) == nil, "not every kind of file: \(request)")
            #expect(request.contains("order=taken_asc"), "not oldest first: \(request)")
            #expect(request.contains("limit=60"), "not pages of 60: \(request)")
        }
        #expect(!sent[0].contains("cursor="), "the first page carried a cursor: \(sent[0])")
        #expect(sent[1].contains("cursor=c1") && sent[2].contains("cursor=c2"))

        let expected = TripSummary(
            count: 125, firstTaken: Self.taken(0), lastTaken: Self.taken(124),
            coverUid: Self.uid(0))
        #expect(store.summary(for: record) == expected)
        #expect(current(record, in: collections)?.lastSummary == expected, "no summary written")
    }

    /// The owner's rule (2026-10-09): a trip is the Library's All under its tag, every picture
    /// AND every video of a member memo. The server answers by the kind asked for, so a drain that
    /// asked for images alone, or dropped the clip on arrival, would leave the clip out.
    @Test("a video of a tagged memo is a member, and the drain asks with no type at all")
    func aVideoIsAMember() async {
        let paths = LockedValue<[String]>([])
        let clip = Self.item("clip", taken: Self.taken(0), mime: "video/mp4")
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + ["\(operation) \(path)"])
            let pictures = [1, 2].map { Self.item(Self.uid($0), taken: Self.taken($0)) }
            return Self.page(Self.kind(path) == nil ? [clip] + pictures : pictures)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let members = store.members(for: record)
        #expect(members.map(\.id) == ["clip", Self.uid(1), Self.uid(2)], "\(members.map(\.id))")
        #expect(members.first?.attachment.mediaKind == .video, "the clip is not a video")
        // The clip is taken first, so the cover the summary falls back to is its poster's.
        #expect(store.summary(for: record)?.coverUid == "clip")
        #expect(store.summary(for: record)?.count == 3, "the clip is not counted")
        let sent = paths.get()
        #expect(sent.count == 1, "not one page: \(sent)")
        for request in sent {
            #expect(request.contains("tag=\(Self.tag)"), "control: the query was read: \(request)")
            #expect(Self.kind(request) == nil, "the drain named a kind: \(request)")
        }
    }

    @Test("a tag that spells a kind is still one tag, and the drain still names no kind")
    func aTagSpellingAKind() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(0..<1)
        }
        let collections = collections()
        let record = collections.create(title: "Odd", tags: ["x&type=image"])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let sent = paths.get()
        let items = sent.first.flatMap { URLComponents(string: $0)?.queryItems } ?? []
        #expect(
            items.filter { $0.name == "tag" }.map(\.value) == ["x&type=image"], "\(sent)")
        #expect(Self.kind(sent.first ?? "") == nil, "the tag's text stood in for a kind: \(sent)")
        #expect(store.members(for: record).count == 1, "control: the drain landed")
    }

    @Test("a drain stops at 2000 members and says it was truncated")
    func theCap() async {
        #expect(TripMembershipStore.memberCap == 2000)
        #expect(TripMembershipStore.pageSize == 60)
        let calls = LockedValue<Int>(0)
        // A server that never runs out: every page is 60 new pictures and another cursor.
        let client = Stub.client { _, _, _ in
            let index = calls.get()
            calls.set(index + 1)
            return Self.page(index * 60..<(index + 1) * 60, nextCursor: "c\(index + 1)")
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let members = store.members(for: record)
        #expect(members.count == 2000, "not capped at 2000: \(members.count)")
        #expect(members.last?.id == Self.uid(1999), "the cap kept the wrong end")
        #expect(store.state(for: record) == .truncated)
        #expect(calls.get() == 34, "the drain read past the cap: \(calls.get()) pages")
        #expect(current(record, in: collections)?.lastSummary?.count == 2000)
    }

    @Test("exactly the cap with no cursor after it is complete, not truncated")
    func exactlyTheCapIsComplete() async {
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            let index = calls.get()
            calls.set(index + 1)
            let end = min((index + 1) * 60, 120)
            return Self.page(index * 60..<end, nextCursor: end < 120 ? "c\(index + 1)" : nil)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections, memberCap: 120)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.members(for: record).count == 120)
        #expect(store.state(for: record) == .complete, "the last page was called a truncation")
    }

    @Test("a record with no tag has no members and sends nothing")
    func noTagNoRequest() async {
        let calls = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return Self.page(0..<3)
        }
        let collections = collections()
        let record = collections.create(title: "Untagged", tags: [])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(calls.get() == 0, "a trip with no tag read the whole library")
        #expect(store.members(for: record).isEmpty)
        #expect(store.state(for: record) == .notLoaded)
    }

    @Test("a failure on a later page applies nothing and leaves the previous list standing")
    func aLaterPageFailureAppliesNothing() async {
        let failing = LockedValue<Bool>(false)
        let client = Stub.client { request, _, _ in
            guard (request.path ?? "").contains("cursor=c1") else {
                return Self.page(0..<60, nextCursor: "c1")
            }
            return failing.get() ? Stub.empty(.internalServerError) : Self.page(60..<70)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 70, "control: the first drain landed")

        failing.set(true)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 70, "a failed drain replaced the list")
        #expect(store.state(for: record) == .complete)
        #expect(store.lastError != nil, "the failure was swallowed")
        #expect(current(record, in: collections)?.lastSummary?.count == 70)
    }

    // MARK: - exclusions and the cover

    @Test("an excluded picture is absent from the members and from the summary")
    func anExclusionIsAbsentEverywhere() async throws {
        let client = Stub.client { _, _, _ in Self.page(0..<3) }
        let collections = collections()
        var record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        collections.exclude(id: record.id, uid: Self.uid(0))
        record = try #require(current(record, in: collections))
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.members(for: record).map(\.id) == [Self.uid(1), Self.uid(2)])
        let summary = try #require(current(record, in: collections)?.lastSummary)
        #expect(summary.count == 2, "the excluded picture was counted")
        #expect(summary.firstTaken == Self.taken(1), "the span began at the excluded picture")
        #expect(summary.lastTaken == Self.taken(2))
        #expect(summary.coverUid == Self.uid(1), "the excluded picture is the cover")

        // An exclusion made after the drain is absent at once, without another read.
        collections.exclude(id: record.id, uid: Self.uid(2))
        record = try #require(current(record, in: collections))
        #expect(store.members(for: record).map(\.id) == [Self.uid(1)])
        #expect(store.summary(for: record)?.count == 1)
    }

    @Test("the chosen cover stands while it is a member and falls back to the first when excluded")
    func theCoverFallsBack() async throws {
        let client = Stub.client { _, _, _ in Self.page(0..<3) }
        let collections = collections()
        var kept = collections.create(title: "Kept", tags: [Self.tag])
        collections.setCover(id: kept.id, uid: Self.uid(2))
        kept = try #require(current(kept, in: collections))
        var dropped = collections.create(title: "Dropped", tags: [Self.tag])
        collections.setCover(id: dropped.id, uid: Self.uid(2))
        collections.exclude(id: dropped.id, uid: Self.uid(2))
        dropped = try #require(current(dropped, in: collections))
        let store = TripMembershipStore(collections: collections)
        await store.drain(kept, using: client.handle, baseURL: Stub.baseURL)
        await store.drain(dropped, using: client.handle, baseURL: Stub.baseURL)

        #expect(current(kept, in: collections)?.lastSummary?.coverUid == Self.uid(2), "control")
        #expect(
            current(dropped, in: collections)?.lastSummary?.coverUid == Self.uid(0),
            "an excluded cover is still the cover")
    }

    @Test("the summary of no members is a zero count with no span and no cover")
    func theSummaryOfNothing() {
        #expect(
            TripMembershipStore.summary(of: [], cover: "gone")
                == TripSummary(count: 0, firstTaken: nil, lastTaken: nil, coverUid: nil))
    }

    // MARK: - fences

    @Test("a page answered for a session that has ended is dropped whole")
    func aStaleGenerationIsDropped() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return calls.get() == 1 ? Self.page(0..<60, nextCursor: "c1") : Self.page(60..<61)
        }
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripSession(for: issued)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        store.reports(to: session)

        let inFlight = Task { await store.drain(record, using: issued, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        // A renewal or a sign-in in between: the session running now is not the one that asked.
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.signal()
        await inFlight.value

        #expect(store.members(for: record).isEmpty, "a stale answer was applied")
        #expect(store.state(for: record) == .notLoaded)
        #expect(current(record, in: collections)?.lastSummary == nil, "a stale summary was written")
        #expect(calls.get() == 1, "the stale drain read on: \(calls.get()) pages")
    }

    @Test("a page answered for a trip deleted while it was out publishes nothing")
    func aDeletedTripsPageIsDropped() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return calls.get() == 1 ? Self.page(0..<60, nextCursor: "c1") : Self.page(60..<61)
        }
        let handle = SessionHandle(client: client, generation: 1)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let inFlight = Task { await store.drain(record, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        collections.delete(id: record.id)
        release.signal()
        await inFlight.value

        // The snapshot the caller still holds is the only way left to ask about the trip.
        #expect(store.members(for: record).isEmpty, "a deleted trip's members came back")
        #expect(store.summary(for: record) == nil, "a deleted trip's summary came back")
        #expect(store.state(for: record) == .notLoaded)
        #expect(calls.get() == 1, "the drain read on for a trip that is gone: \(calls.get())")
    }

    @Test("a trip deleted after its drain keeps no readable membership")
    func aDeletedTripsMembershipIsForgotten() async {
        let client = Stub.client { _, _, _ in Self.page(0..<3) }
        let handle = SessionHandle(client: client, generation: 1)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 3, "precondition: the drain applied")

        collections.delete(id: record.id)

        #expect(store.members(for: record).isEmpty, "a deleted trip's members are still readable")
        #expect(store.summary(for: record) == nil)
        #expect(store.state(for: record) == .notLoaded)
    }

    @Test("a forgotten trip's membership is gone, and its drain in flight lands nothing")
    func aForgottenTripHoldsNothing() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 2 {
                entered.signal()
                await release.wait()
            }
            return Self.page(0..<3)
        }
        let handle = SessionHandle(client: client, generation: 1)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 3, "precondition: the drain applied")

        let again = Task { await store.drain(record, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the second drain was not sent")
        store.forget(record.id)
        #expect(store.members(for: record).isEmpty, "a forgotten trip's members are readable")
        #expect(store.state(for: record) == .notLoaded, "a forgotten trip still reads as draining")
        collections.delete(id: record.id)
        release.signal()
        await again.value
        #expect(
            store.members(for: record).isEmpty, "the drain in flight landed for a forgotten trip")
    }

    @Test("a drain held across a forget of a trip that stays publishes nothing")
    func aForgottenDrainOfAKeptTripPublishesNothing() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.page(0..<3)
        }
        let handle = SessionHandle(client: client, generation: 1)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let held = Task { await store.drain(record, using: handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        store.forget(record.id)
        release.signal()
        await held.value

        // The trip is still in the store: only the forget can refuse what the drain brought.
        #expect(collections.records.contains { $0.id == record.id }, "precondition: kept")
        #expect(store.members(for: record).isEmpty, "a forgotten drain repopulated the trip")
        #expect(store.summary(for: record) == nil)
        #expect(store.state(for: record) == .notLoaded)
    }

    @Test("a drain after a forget supersedes the held one, which neither publishes nor clears it")
    func aDrainAfterForgetSupersedes() async {
        let calls = LockedValue<Int>(0)
        let firstIn = TripSignal()
        let firstOut = TripSignal()
        let secondIn = TripSignal()
        let secondOut = TripSignal()
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            switch calls.get() {
            case 1:
                firstIn.signal()
                await firstOut.wait()
                return Self.page(0..<3)
            default:
                secondIn.signal()
                await secondOut.wait()
                return Self.page(0..<5)
            }
        }
        let handle = SessionHandle(client: client, generation: 1)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let old = Task { await store.drain(record, using: handle, baseURL: Stub.baseURL) }
        #expect(await firstIn.wait(), "the first drain sent nothing")
        store.forget(record.id)
        let new = Task { await store.drain(record, using: handle, baseURL: Stub.baseURL) }
        #expect(await secondIn.wait(), "the drain after the forget sent nothing")
        firstOut.signal()
        await old.value

        #expect(store.members(for: record).isEmpty, "the superseded drain published")
        #expect(store.state(for: record) == .draining, "the superseded drain cleared the new slot")
        secondOut.signal()
        await new.value
        #expect(store.members(for: record).count == 5, "the drain after the forget did not land")
        #expect(store.state(for: record) == .complete)
    }

    @Test("forgetting one trip leaves every other trip's membership as it was")
    func forgettingIsPerTrip() async {
        let client = Stub.client { _, _, _ in Self.page(0..<3) }
        let handle = SessionHandle(client: client, generation: 1)
        let collections = collections()
        let gone = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let kept = collections.create(title: "Spain 2025", tags: ["spain2025"])
        let store = TripMembershipStore(collections: collections)
        await store.drain(gone, using: handle, baseURL: Stub.baseURL)
        await store.drain(kept, using: handle, baseURL: Stub.baseURL)

        store.forget(gone.id)

        #expect(store.members(for: gone).isEmpty)
        #expect(store.members(for: kept).count == 3, "forgetting one trip took another's")
        #expect(store.state(for: kept) == .complete)
    }

    @Test("a drain that outlived a change of identity is dropped whole")
    func anIdentityChangeDropsTheDrain() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Self.page(0..<3)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let inFlight = Task {
            await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        store.sessionIdentityChanged()
        release.signal()
        await inFlight.value

        #expect(store.members(for: record).isEmpty, "the outgoing account's pictures came back")
        #expect(current(record, in: collections)?.lastSummary == nil)
    }

    @Test("a second drain of a trip in flight waits for the first and sends nothing of its own")
    func twoDrainsAreOneChain() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let joined = TripSignal()
        // Only the first request is held: a second chain, if the store starts one, answers at
        // once and shows up in the count.
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return (request.path ?? "").contains("cursor=c1")
                ? Self.page(60..<70) : Self.page(0..<60, nextCursor: "c1")
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        store.onJoin = { joined.signal() }
        let secondDone = LockedValue<Bool>(false)

        let first = Task { await store.drain(record, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the first drain sent nothing")
        let second = Task {
            await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
            secondDone.set(true)
            return store.members(for: record).count
        }
        #expect(await joined.wait(), "the second drain never reached the join")
        // The first chain is still held, so a caller that joined it cannot have finished.
        #expect(!secondDone.get(), "the second drain returned while the first was still out")
        #expect(store.state(for: record) == .draining)
        release.signal()
        await first.value
        let secondSaw = await second.value

        #expect(calls.get() == 2, "two overlapping drains were \(calls.get()) requests, not 2")
        #expect(secondSaw == 70, "the joined caller did not see the chain's result: \(secondSaw)")
        #expect(store.members(for: record).count == 70, "control: the one chain landed")
        #expect(store.state(for: record) == .complete)
    }

    @Test("a refused credential goes to the session as one typed refusal")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let ended = TripMembershipStore(
            collections: collections,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })
        await ended.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(ended.lastError != nil, "an ended session said nothing")
        #expect(ended.state(for: record) == .notLoaded)
        #expect(current(record, in: collections)?.lastSummary == nil)

        // A refusal of a credential already replaced ends nothing and earns no sentence.
        let superseded = TripMembershipStore(
            collections: collections, onUnauthorized: { _ in .superseded })
        await superseded.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(superseded.lastError == nil, "a stale refusal wrote a sentence")
    }

    @Test("a refusal the session decides after a forget writes nothing over the photos")
    func aRefusalDecidedAfterForgetSaysNothing() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(
            collections: collections,
            onUnauthorized: { (_: CredentialRefusal) in
                entered.signal()
                await release.wait()
                return .endedSession
            })

        let inFlight = Task {
            await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the refusal never reached the session")
        store.forget(record.id)
        release.signal()
        await inFlight.value

        let said = store.lastError
        #expect(said == nil, "a forgotten drain said its refusal: \(said ?? "")")
    }

    // MARK: - the New trip sheet

    @Test("the sheet's count and span take in a video the tag carries, with no type asked")
    func theSheetCountsEveryKind() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + ["\(operation) \(path)"])
            // Two pictures and a clip carry the tag: the count of the images alone would say 2,
            // and the clip, taken at hour 9, is the last thing the tag holds.
            let images = Self.kind(path) == "image"
            if operation == Self.tagsOperation {
                return Stub.json(#"[{"name":"portugal2026","count":\#(images ? 2 : 3)}]"#)
            }
            let clip = Self.item("clip", taken: Self.taken(9), mime: "video/mp4")
            if path.contains("order=taken_desc") {
                return Self.page([images ? Self.item(Self.uid(5), taken: Self.taken(5)) : clip])
            }
            return Self.page([Self.item(Self.uid(1), taken: Self.taken(1))])
        }
        let collections = collections()
        let store = TripMembershipStore(collections: collections)
        await store.loadTagCounts(using: client.handle)
        await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 3)], "\(store.tagCounts)")
        #expect(store.tagCountsLoaded)
        #expect(
            store.spans[Self.tag]
                == TripTagSpan(firstTaken: Self.taken(1), lastTaken: Self.taken(9)),
            "the span is not every kind's span")
        let sent = paths.get()
        #expect(sent.count == 3, "not one count read and two extrema: \(sent)")
        #expect(sent.first?.hasPrefix(Self.tagsOperation) == true, "control: the counts were read")
        for request in sent { #expect(Self.kind(request) == nil, "a kind was named: \(request)") }
        for request in sent.dropFirst() {
            #expect(request.contains("limit=1"), "an extremum read more than one: \(request)")
            #expect(request.contains("tag=\(Self.tag)"))
        }
        #expect(sent.dropFirst().contains { $0.contains("order=taken_asc") })
        #expect(sent.dropFirst().contains { $0.contains("order=taken_desc") })
    }

    // MARK: - the New trip sheet's fences

    /// The sheet's server: two pictures carry the tag, the first taken at hour 1, the last at
    /// hour 5. Every request passes through `hold` first.
    private func sheetClient(_ hold: TripHold) -> any APIProtocol {
        Stub.client { request, _, operation in
            let path = request.path ?? ""
            await hold.pass(path)
            if operation == Self.tagsOperation {
                return Stub.json(#"[{"name":"portugal2026","count":2}]"#)
            }
            let index = path.contains("order=taken_desc") ? 5 : 1
            return Self.page([Self.item(Self.uid(index), taken: Self.taken(index))])
        }
    }

    private static let span = TripTagSpan(firstTaken: taken(1), lastTaken: taken(5))

    @Test("a second count read while one is in flight is refused, not sent")
    func overlappingCountReadsAreOne() async {
        let hold = TripHold(holding: [0])
        let client = sheetClient(hold)
        let store = TripMembershipStore(collections: collections())
        let first = Task { await store.loadTagCounts(using: client.handle) }
        #expect(await hold.entered[0].wait(), "the first count read was not sent")
        await store.loadTagCounts(using: client.handle)
        #expect(hold.calls == 1, "an overlapping count read was sent: \(hold.calls)")
        hold.release[0].signal()
        await first.value
        #expect(hold.calls == 1)
        #expect(store.tagCountsLoaded, "control: the one read landed")
    }

    @Test("a second span read of the same tag while one is in flight joins it, not sent")
    func overlappingSpanReadsAreOne() async {
        let hold = TripHold(holding: [0])
        let client = sheetClient(hold)
        let store = TripMembershipStore(collections: collections())
        let joined = TripSignal()
        store.onSpanJoin = { joined.signal() }
        let first = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the first extremum was not asked for")
        let second = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
            return store.spans[Self.tag]
        }
        #expect(await joined.wait(), "the second read did not join the first")
        #expect(hold.calls == 1, "an overlapping span read was sent: \(hold.calls)")
        hold.release[0].signal()
        await first.value
        #expect(await second.value == Self.span, "the joiner returned before the read it joined")
        #expect(hold.calls == 2, "not one read of each extremum: \(hold.calls)")
    }

    @Test("a reset lets a caller that joined the old span read go")
    func aResetLetsAJoinerGo() async {
        let hold = TripHold(holding: [0])
        let client = sheetClient(hold)
        let store = TripMembershipStore(collections: collections())
        let joined = TripSignal()
        store.onSpanJoin = { joined.signal() }
        let old = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the old span read was not sent")
        let gone = TripSignal()
        let joiner = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
            gone.signal()
        }
        #expect(await joined.wait(), "the second read did not join the first")
        store.sessionIdentityChanged()
        let freed = await gone.wait()
        #expect(freed, "a reset left the joiner parked on a read nobody owns")
        if freed { await joiner.value }
        hold.release[0].signal()
        await old.value
        #expect(store.spans.isEmpty, "the old read landed after the reset")
    }

    @Test("a change of identity discards the sheet's pending counts and span")
    func anIdentityChangeDiscardsSheetReads() async {
        let counts = TripHold(holding: [0])
        let countClient = sheetClient(counts)
        let store = TripMembershipStore(collections: collections())
        let countRead = Task { await store.loadTagCounts(using: countClient.handle) }
        #expect(await counts.entered[0].wait(), "the count read was not sent")
        store.sessionIdentityChanged()
        counts.release[0].signal()
        await countRead.value
        #expect(store.tagCounts.isEmpty, "the outgoing account's counts were applied")
        #expect(!store.tagCountsLoaded)

        let spans = TripHold(holding: [0])
        let client = sheetClient(spans)
        let spanRead = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await spans.entered[0].wait(), "the first extremum was not asked for")
        store.sessionIdentityChanged()
        spans.release[0].signal()
        await spanRead.value
        #expect(spans.calls == 1, "a stale first extremum asked for the second")
        #expect(store.spans.isEmpty, "the outgoing account's span was applied")
    }

    @Test("a renewed session discards the sheet's pending counts and span")
    func aRenewalDiscardsSheetReads() async {
        let counts = TripHold(holding: [0])
        let countClient = sheetClient(counts)
        let countSession = TripSession(for: SessionHandle(client: countClient, generation: 1))
        let store = TripMembershipStore(collections: collections())
        store.reports(to: countSession)
        let countRead = Task {
            await store.loadTagCounts(using: SessionHandle(client: countClient, generation: 1))
        }
        #expect(await counts.entered[0].wait(), "the count read was not sent")
        countSession.activeHandle = SessionHandle(client: countClient, generation: 2)
        counts.release[0].signal()
        await countRead.value
        #expect(store.tagCounts.isEmpty, "a renewed session got the old one's counts")
        #expect(!store.tagCountsLoaded)

        let spans = TripHold(holding: [0])
        let spanClient = sheetClient(spans)
        let spanSession = TripSession(for: SessionHandle(client: spanClient, generation: 1))
        let spanStore = TripMembershipStore(collections: collections())
        spanStore.reports(to: spanSession)
        let spanRead = Task {
            await spanStore.loadSpan(
                ofTag: Self.tag, using: SessionHandle(client: spanClient, generation: 1),
                baseURL: Stub.baseURL)
        }
        #expect(await spans.entered[0].wait(), "the first extremum was not asked for")
        spanSession.activeHandle = SessionHandle(client: spanClient, generation: 2)
        spans.release[0].signal()
        await spanRead.value
        #expect(spans.calls == 1, "a stale first extremum asked for the second")
        #expect(spanStore.spans.isEmpty, "a renewed session got the old one's span")
    }

    @Test("a renewed session's span read does not join the old session's: it reads for itself")
    func aRenewedSpanReadIsItsOwn() async {
        let hold = TripHold(holding: [0, 1])
        let client = sheetClient(hold)
        let session = TripSession(for: SessionHandle(client: client, generation: 1))
        let store = TripMembershipStore(collections: collections())
        store.reports(to: session)
        let joined = TripSignal()
        store.onSpanJoin = { joined.signal() }
        let old = Task {
            await store.loadSpan(
                ofTag: Self.tag, using: SessionHandle(client: client, generation: 1),
                baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the old session's read was not sent")
        let renewed = SessionHandle(client: client, generation: 2)
        session.activeHandle = renewed
        let current = Task {
            await store.loadSpan(ofTag: Self.tag, using: renewed, baseURL: Stub.baseURL)
            return store.spans[Self.tag]
        }
        #expect(
            await hold.entered[1].wait(), "the renewed session joined the old session's read")
        hold.release[0].signal()
        await old.value

        // The old read's end leaves the renewed read's slot alone: a third caller joins it.
        let third = Task {
            await store.loadSpan(ofTag: Self.tag, using: renewed, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the old read's end cleared the renewed read's slot")
        hold.release[1].signal()
        #expect(await current.value == Self.span, "the renewed session got no dates of its own")
        await third.value
        #expect(hold.calls == 3, "not one old extremum and one renewed pair: \(hold.calls)")
    }

    @Test("a second extremum answered for a renewed session publishes no span")
    func aStaleSecondExtremumPublishesNothing() async {
        let hold = TripHold(holding: [1])
        let client = sheetClient(hold)
        let session = TripSession(for: SessionHandle(client: client, generation: 1))
        let store = TripMembershipStore(collections: collections())
        store.reports(to: session)
        let read = Task {
            await store.loadSpan(
                ofTag: Self.tag, using: SessionHandle(client: client, generation: 1),
                baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[1].wait(), "the second extremum was not asked for")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        hold.release[1].signal()
        await read.value
        #expect(store.spans.isEmpty, "a span half read under the old session was published")
    }

    @Test("after a reset a fresh count read is sent, and the old one cannot clear its guard")
    func aFreshCountReadKeepsItsGuard() async {
        let hold = TripHold(holding: [0, 1])
        let client = sheetClient(hold)
        let store = TripMembershipStore(collections: collections())
        let old = Task { await store.loadTagCounts(using: client.handle) }
        #expect(await hold.entered[0].wait(), "the old count read was not sent")
        store.sessionIdentityChanged()
        let fresh = Task { await store.loadTagCounts(using: client.handle) }
        #expect(await hold.entered[1].wait(), "the fresh read after the reset was refused")
        hold.release[0].signal()
        await old.value
        await store.loadTagCounts(using: client.handle)
        #expect(hold.calls == 2, "the old read's end cleared the fresh read's guard")
        hold.release[1].signal()
        await fresh.value
        #expect(store.tagCountsLoaded, "control: the fresh read landed")
    }

    @Test("after a reset a fresh span read is sent, and the old one cannot clear its guard")
    func aFreshSpanReadKeepsItsGuard() async {
        let hold = TripHold(holding: [0, 1])
        let client = sheetClient(hold)
        let store = TripMembershipStore(collections: collections())
        let old = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the old span read was not sent")
        store.sessionIdentityChanged()
        let fresh = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[1].wait(), "the fresh read after the reset was refused")
        hold.release[0].signal()
        await old.value
        let joined = TripSignal()
        store.onSpanJoin = { joined.signal() }
        let joiner = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the old read's end cleared the fresh read's guard")
        #expect(hold.calls == 2, "the old read's end cleared the fresh read's guard")
        hold.release[1].signal()
        await fresh.value
        await joiner.value
        #expect(store.spans[Self.tag] == Self.span, "control: the fresh read landed")
    }
}

/// A session whose active handle the test can replace, which is what a renewal or a sign-in does.
private final class TripSession: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()

    init(for handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }

    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }

    func noteTransportFailure(
        _ failure: ServerReachability.Reason,
        issuedUnder generation: Int
    ) {}

    func noteTransportSuccess(issuedUnder generation: Int) {}
}

/// A one-shot hand-off between the test and its scripted transport — a signal, not a clock.
private final class TripSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func signal() { continuation.yield() }

    /// Waits for the signal, but never longer than `seconds`: a request that never comes FAILS
    /// the test that waits for it, and a held answer is let go, instead of the run hanging.
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

/// A scripted server that holds the requests it is told to, by arrival index from 0, until the
/// test lets each one go. Every wait is bounded (`TripSignal.wait`).
private final class TripHold: @unchecked Sendable {
    let entered = (0..<8).map { _ in TripSignal() }
    let release = (0..<8).map { _ in TripSignal() }
    private let held: Set<Int>
    private let lock = NSLock()
    private var count = 0

    init(holding held: Set<Int>) { self.held = held }

    var calls: Int { lock.withLock { count } }

    func pass(_ path: String) async {
        let index = lock.withLock {
            defer { count += 1 }
            return count
        }
        guard held.contains(index) else { return }
        entered[index].signal()
        await release[index].wait()
    }
}

/// A trip's journal: `GET /api/memos?tag=<t>&sort=created_at`, drained page after page through the
/// REAL generated client over a scripted transport, oldest first as the server orders it — fenced,
/// joined and forgotten the way the membership is (MEMNG-718).
@MainActor
@Suite("Trip journal")
struct TripJournalTests {
    private nonisolated static let listOperation = "list_memos_api_memos_get"
    private nonisolated static let tag = "portugal2026"

    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-journal")
        .appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.org")!,
        subject: "alice"
    )

    private func collections() -> CollectionStore {
        CollectionStore(identity: alice, root: root)
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
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections, pageSize: 2)

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
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections, pageSize: 2)

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
        let collections = collections()
        let record = collections.create(title: "Odd", tags: ["a&sort=-created_at"])
        let store = TripMembershipStore(collections: collections)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        let first = reads.get().first
        #expect(first?["tag"] == "a&sort=-created_at")
        #expect(first?["sort"] == "created_at")
    }

    @Test("a tag no memo carries is an empty journal that is complete, not still loading")
    func anEmptyJournal() async {
        let client = Stub.client { _, _, _ in Self.page(0..<0) }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        #expect(store.journalState(for: record) == .notLoaded)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: record).isEmpty)
        #expect(store.journalState(for: record) == .complete)
    }

    @Test("a journal stops at the cap and says it was truncated")
    func theCap() async {
        let client = Stub.client { request, _, _ in Self.twoPages(request) }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections, pageSize: 2, memberCap: 2)

        await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: record).map(\.uid) == ["m0", "m1"])
        #expect(store.journalState(for: record) == .truncated)
    }

    @Test("a journal page answered for a session that has ended is dropped whole")
    func aStaleGenerationIsDropped() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.twoPages(request)
        }
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripSession(for: issued)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections, pageSize: 2)
        store.reports(to: session)

        let inFlight = Task {
            await store.loadJournal(record, using: issued, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.signal()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "a stale answer was applied")
        #expect(store.journalState(for: record) == .notLoaded)
        #expect(calls.get() == 1, "the stale load read on: \(calls.get()) pages")
    }

    @Test("a journal that outlived a change of identity is dropped whole")
    func anIdentityChangeDropsTheJournal() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { request, _, _ in
            entered.signal()
            await release.wait()
            return Self.page(0..<1)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        store.sessionIdentityChanged()
        release.signal()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "somebody else's journal was applied")
        #expect(store.journalState(for: record) == .notLoaded)
    }

    @Test("a second journal load of a trip in flight waits for the first and sends nothing")
    func twoLoadsAreOneChain() async {
        let calls = LockedValue<Int>(0)
        let entered = TripSignal()
        let release = TripSignal()
        let joined = TripSignal()
        let client = Stub.client { request, _, _ in
            calls.set(calls.get() + 1)
            if calls.get() == 1 {
                entered.signal()
                await release.wait()
            }
            return Self.twoPages(request)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections, pageSize: 2)
        store.onJournalJoin = { joined.signal() }
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
        release.signal()
        await first.value
        let secondSaw = await second.value

        #expect(calls.get() == 2, "two overlapping loads were \(calls.get()) requests, not 2")
        #expect(secondSaw == 3, "the joined caller did not see the chain's result: \(secondSaw)")
    }

    @Test("a journal held across a forget of a trip that stays lands nothing")
    func aForgottenJournalLandsNothing() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { request, _, _ in
            entered.signal()
            await release.wait()
            return Self.page(0..<1)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        store.forget(record.id)
        #expect(store.journalState(for: record) == .notLoaded, "a forgotten load still reads on")
        release.signal()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "the load in flight landed after a forget")
        #expect(store.journalState(for: record) == .notLoaded)
    }

    @Test("a journal answered for a trip deleted while it was out publishes nothing")
    func aDeletedTripsJournalIsDropped() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in
            entered.signal()
            await release.wait()
            return Self.page(0..<1)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        collections.delete(id: record.id)
        release.signal()
        await inFlight.value

        #expect(store.journal(for: record).isEmpty, "a deleted trip's journal came back")
        #expect(store.journalState(for: record) == .notLoaded)
    }

    @Test("a refused credential on the journal goes to the session, said on the journal alone")
    func aRefusalReachesTheSession() async {
        let handled = LockedValue<Int>(0)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let ended = TripMembershipStore(
            collections: collections,
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

        let superseded = TripMembershipStore(
            collections: collections, onUnauthorized: { _ in .superseded })
        await superseded.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(superseded.journalError(for: record) == nil, "a stale refusal wrote a sentence")
    }

    @Test("a refusal the session decides after a forget writes nothing on the journal")
    func aRefusalDecidedAfterForgetSaysNothing() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(
            collections: collections,
            onUnauthorized: { (_: CredentialRefusal) in
                entered.signal()
                await release.wait()
                return .endedSession
            })

        let inFlight = Task {
            await store.loadJournal(record, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "the refusal never reached the session")
        store.forget(record.id)
        release.signal()
        await inFlight.value

        let said = store.journalError(for: record)
        #expect(said == nil, "a forgotten journal said its refusal: \(said ?? "")")
    }

    @Test("a trip's journal failure is said on that trip alone, never on another")
    func aFailureStaysWithItsTrip() async {
        let entered = TripSignal()
        let release = TripSignal()
        let client = Stub.client { request, _, _ in
            guard Self.query(request)["tag"] == "a2026" else { return Self.page(0..<0) }
            entered.signal()
            await release.wait()
            return Stub.empty(.internalServerError)
        }
        let collections = collections()
        let first = collections.create(title: "A", tags: ["a2026"])
        let second = collections.create(title: "B", tags: ["b2026"])
        let store = TripMembershipStore(collections: collections)

        let held = Task {
            await store.loadJournal(first, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "A's read was not sent")
        await store.loadJournal(second, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.journalState(for: second) == .complete, "precondition: B was read")
        release.signal()
        await held.value

        #expect(store.journalError(for: first) != nil, "A's failure was not said on A")
        let leaked = store.journalError(for: second)
        #expect(leaked == nil, "A's failure was said on B: \(leaked ?? "")")
        #expect(store.journal(for: second).isEmpty)
        #expect(store.journalState(for: second) == .complete)
    }
}

// MARK: - Select mode's Delete on a trip (MEMNG-721)

/// The Trip screen's Delete: the Library's one-at-a-time run (`MediaLibraryStore.delete`), sent
/// through the same generated client, and what it took leaves the trip's members and summary.
extension TripMembershipStoreTests {
    private nonisolated static let deleteOperation =
        "delete_attachment_api_attachments__uid__delete"

    /// A server holding pictures 0..<3 under the trip's tag, recording every DELETE it is sent.
    /// `hold`, when given, is waited on inside each DELETE after it is recorded.
    private nonisolated static func deletingClient(
        seen: LockedValue<[String]>, entered: TripSignal? = nil, hold: TripSignal? = nil,
        answer: HTTPResponse.Status = .noContent
    ) -> any APIProtocol {
        Stub.client { request, _, operation in
            guard operation == deleteOperation else { return Self.page(0..<3) }
            seen.set(seen.get() + [request.path ?? ""])
            entered?.signal()
            if let hold { await hold.wait() }
            return Stub.empty(answer)
        }
    }

    /// The paths of the DELETEs for pictures `indices`, in that order.
    private nonisolated static func deletes(_ indices: [Int]) -> [String] {
        indices.map { "/api/attachments/\(uid($0))" }
    }

    @Test("a trip's delete sends one DELETE per picture in order, and they leave the trip")
    func aDeleteLeavesTheTrip() async throws {
        let seen = LockedValue<[String]>([])
        let client = Self.deletingClient(seen: seen)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 3, "control: the drain landed")

        let outcome = await store.delete([Self.uid(2), Self.uid(0)], using: client.handle)

        #expect(seen.get() == Self.deletes([2, 0]), "sent \(seen.get())")
        #expect(outcome?.deleted == [Self.uid(2), Self.uid(0)])
        #expect(store.members(for: record).map(\.id) == [Self.uid(1)])
        let summary = try #require(current(record, in: collections)?.lastSummary)
        #expect(summary.count == 1, "the record's summary still counts the deleted pictures")
        #expect(summary.coverUid == Self.uid(1))
        #expect(!store.isDeleting)
    }

    @Test("a second trip delete while one runs is refused and sends nothing")
    func aSecondTripDeleteIsRefused() async {
        let seen = LockedValue<[String]>([])
        let entered = TripSignal()
        let hold = TripSignal()
        let client = Self.deletingClient(seen: seen, entered: entered, hold: hold)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let first = Task { await store.delete([Self.uid(0)], using: client.handle) }
        #expect(await entered.wait(), "the first DELETE never went out")
        #expect(store.isDeleting)
        let second = await store.delete([Self.uid(1)], using: client.handle)
        hold.signal()
        let outcome = await first.value

        #expect(second == nil, "the second run was not refused")
        #expect(outcome?.deleted == [Self.uid(0)])
        #expect(seen.get() == Self.deletes([0]), "sent \(seen.get())")
        #expect(store.members(for: record).map(\.id) == [Self.uid(1), Self.uid(2)])
    }

    @Test("a drain read before a trip delete cannot bring the deleted picture back")
    func aLateDrainDoesNotResurrect() async {
        let reads = LockedValue<Int>(0)
        let entered = TripSignal()
        let hold = TripSignal()
        let client = Stub.client { _, _, operation in
            if operation == Self.deleteOperation { return Stub.empty(.noContent) }
            reads.set(reads.get() + 1)
            if reads.get() == 2 {
                entered.signal()
                await hold.wait()
            }
            return Self.page(0..<3)
        }
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        // A second drain reads the page while the picture is still on the server, and answers
        // after the delete has taken it.
        let late = Task { await store.drain(record, using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "the second drain never read")
        _ = await store.delete([Self.uid(1)], using: client.handle)
        hold.signal()
        await late.value

        #expect(store.members(for: record).map(\.id) == [Self.uid(0), Self.uid(2)])
        #expect(current(record, in: collections)?.lastSummary?.count == 2)
    }

    @Test("a session change during a trip delete sends nothing further and applies nothing")
    func aSessionChangeStopsTheTripDelete() async {
        let seen = LockedValue<[String]>([])
        let entered = TripSignal()
        let hold = TripSignal()
        let client = Self.deletingClient(seen: seen, entered: entered, hold: hold)
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripSession(for: issued)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        store.reports(to: session)
        await store.drain(record, using: issued, baseURL: Stub.baseURL)

        let run = Task { await store.delete([Self.uid(0), Self.uid(1)], using: issued) }
        #expect(await entered.wait(), "the first DELETE never went out")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        hold.signal()
        let outcome = await run.value

        #expect(seen.get() == Self.deletes([0]), "sent \(seen.get())")
        #expect(outcome?.stoppedForSessionChange == true)
        #expect(outcome?.notAttempted == [Self.uid(1)])
        #expect(store.members(for: record).count == 3, "a stale run changed the trip")
    }

    @Test("a refused trip delete goes to the session's funnel and writes no sentence")
    func aRefusedTripDeleteReachesTheSession() async {
        let seen = LockedValue<[String]>([])
        let handled = LockedValue<Int>(0)
        let client = Self.deletingClient(seen: seen, answer: .unauthorized)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(
            collections: collections,
            onUnauthorized: { (_: CredentialRefusal) in
                handled.set(handled.get() + 1)
                return .endedSession
            })
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        let outcome = await store.delete([Self.uid(0), Self.uid(1)], using: client.handle)

        #expect(handled.get() == 1, "the refusal did not reach the session")
        #expect(seen.get().count == 1, "the run went on past a refusal: \(seen.get())")
        #expect(outcome?.failed == Self.uid(0))
        #expect(outcome?.deleted.isEmpty == true)
        #expect(store.lastError == nil, "the delete wrote a sentence over the photos")
        #expect(store.members(for: record).count == 3)
    }
}

// MARK: - Select mode's Remove from trip (MEMNG-722)

/// The Trip screen's Remove: an exclusion on this device's record, never a write to the server —
/// the memo keeps its text and its tag — and what it took leaves the members, the summary and the
/// viewer of that trip alone, until Add Back returns it.
extension TripMembershipStoreTests {
    /// A server holding pictures 0..<3 under the trip's tag, recording every request as its method
    /// and operation, so a test can say the removal sent nothing but reads.
    private nonisolated static func recordingClient(
        seen: LockedValue<[String]>
    ) -> any APIProtocol {
        Stub.client { request, _, operation in
            seen.set(seen.get() + ["\(request.method) \(operation)"])
            return Self.page(0..<3)
        }
    }

    /// Every request `seen` holds that is not a read: what a removal must never send.
    private nonisolated static func writes(_ seen: LockedValue<[String]>) -> [String] {
        seen.get().filter { !$0.hasPrefix("GET ") }
    }

    @Test("a removal outlives a reload: a fresh store reads the trip without the removed pictures")
    func aRemovalOutlivesAReload() async throws {
        let seen = LockedValue<[String]>([])
        let client = Self.recordingClient(seen: seen)
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.members(for: record).count == 3, "control: the drain landed")

        store.remove([Self.uid(2), Self.uid(0)], from: record.id)

        let reloaded = self.collections()
        let again = try #require(current(record, in: reloaded))
        #expect(again.excludedUids == [Self.uid(2), Self.uid(0)], "the file lost the removal")
        let fresh = TripMembershipStore(collections: reloaded)
        await fresh.drain(again, using: client.handle, baseURL: Stub.baseURL)
        #expect(fresh.members(for: again).map(\.id) == [Self.uid(1)])
        #expect(fresh.removedMembers(for: again).map(\.id) == [Self.uid(0), Self.uid(2)])
        #expect(seen.get().count == 2, "control: two drains were read, \(seen.get())")
        #expect(Self.writes(seen).isEmpty, "a removal wrote to the server: \(Self.writes(seen))")
    }

    @Test("the summary is written again at the removal, the chosen cover giving way, and back")
    func theSummaryAfterARemoval() async throws {
        let seen = LockedValue<[String]>([])
        let client = Self.recordingClient(seen: seen)
        let collections = collections()
        var record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        collections.setCover(id: record.id, uid: Self.uid(0))
        record = try #require(current(record, in: collections))
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(current(record, in: collections)?.lastSummary?.count == 3, "control")

        store.remove([Self.uid(0)], from: record.id)

        // Read from the RECORD, which the root's card draws, with no second drain.
        let summary = try #require(current(record, in: collections)?.lastSummary)
        #expect(summary.count == 2, "the record still counts the removed picture")
        #expect(summary.firstTaken == Self.taken(1), "the span still begins at the removed one")
        #expect(summary.lastTaken == Self.taken(2))
        #expect(summary.coverUid == Self.uid(1), "the removed picture is still the cover")
        // The choice itself stands: Add Back makes it the cover again.
        #expect(current(record, in: collections)?.coverUid == Self.uid(0))
        store.addBack(Self.uid(0), to: record.id)
        let back = try #require(current(record, in: collections)?.lastSummary)
        #expect(back.count == 3)
        #expect(back.coverUid == Self.uid(0), "Add Back did not bring the chosen cover back")
        #expect(Self.writes(seen).isEmpty, "\(Self.writes(seen))")
    }

    @Test("Add Back returns the picture to the members, the list of removed ones and the file")
    func addBackReturnsAPicture() async throws {
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = collections()
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        store.remove([Self.uid(1), Self.uid(2)], from: record.id)
        var live = try #require(current(record, in: collections))
        #expect(store.members(for: live).map(\.id) == [Self.uid(0)])

        store.addBack(Self.uid(2), to: record.id)

        live = try #require(current(record, in: collections))
        #expect(store.members(for: live).map(\.id) == [Self.uid(0), Self.uid(2)])
        #expect(store.removedMembers(for: live).map(\.id) == [Self.uid(1)])
        #expect(self.collections().records.first?.excludedUids == [Self.uid(1)])
    }

    @Test("the removed list is the drain's own rows, oldest first, and only those it still holds")
    func theRemovedList() async throws {
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = collections()
        var record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        // Removed before anything was read: the list has no row to show for it yet.
        collections.exclude(id: record.id, uid: Self.uid(2))
        // Removed once, and no longer under the tag: the drain holds no row for it.
        collections.exclude(id: record.id, uid: "p-untagged")
        record = try #require(current(record, in: collections))
        let store = TripMembershipStore(collections: collections)
        #expect(store.removedMembers(for: record).isEmpty, "an unread trip listed removed rows")
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)

        store.remove([Self.uid(0)], from: record.id)

        record = try #require(current(record, in: collections))
        #expect(store.removedMembers(for: record).map(\.id) == [Self.uid(0), Self.uid(2)])
        // The stray stays excluded — a picture tagged again stays out of the trip — unlisted.
        #expect(record.excludedUids.contains("p-untagged"))
    }

    @Test("a removal of nothing, or of a picture that is not a member, writes nothing")
    func aRemovalOfNothingWritesNothing() async throws {
        let writes = LockedValue(0)
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = CollectionStore(
            identity: alice, root: root, now: { Self.taken(0) },
            writeBytes: { data, url in
                writes.set(writes.get() + 1)
                try data.write(to: url)
            })
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        let before = writes.get()

        store.remove([], from: record.id)
        store.remove(["p-stranger"], from: record.id)
        store.remove([Self.uid(0)], from: UUID())

        #expect(writes.get() == before, "a removal of nothing wrote the file")
        #expect(current(record, in: collections)?.excludedUids == [])
        #expect(store.members(for: record).count == 3)
    }

    @Test("two removals of the same picture in one turn exclude it once and write once")
    func twoRemovalsInOneTurn() async throws {
        let writes = LockedValue(0)
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = CollectionStore(
            identity: alice, root: root, now: { Self.taken(0) },
            writeBytes: { data, url in
                writes.set(writes.get() + 1)
                try data.write(to: url)
            })
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        let before = writes.get()

        store.remove([Self.uid(1), Self.uid(1)], from: record.id)
        store.remove([Self.uid(1)], from: record.id)

        #expect(current(record, in: collections)?.excludedUids == [Self.uid(1)])
        // One write carries the exclusion and the summary it changed; the repeats wrote nothing.
        #expect(writes.get() - before == 1, "wrote \(writes.get() - before) times")
    }

    @Test("a removal from one trip leaves another trip of the same tag whole")
    func aRemovalIsThatTripsAlone() async throws {
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = collections()
        let kept = collections.create(title: "Kept", tags: [Self.tag])
        let cut = collections.create(title: "Cut", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(kept, using: client.handle, baseURL: Stub.baseURL)
        await store.drain(cut, using: client.handle, baseURL: Stub.baseURL)

        store.remove([Self.uid(0)], from: cut.id)

        let liveCut = try #require(current(cut, in: collections))
        let liveKept = try #require(current(kept, in: collections))
        #expect(store.members(for: liveCut).count == 2, "control: the removal took")
        #expect(store.members(for: liveKept).count == 3, "the other trip lost the picture")
        #expect(liveKept.lastSummary?.count == 3)
        #expect(store.removedMembers(for: liveKept).isEmpty)
    }

    @Test("a removal whose write fails changes nothing on screen or on disk")
    func aRemovalWhoseWriteFails() async throws {
        struct WriteDied: Error {}
        let failing = LockedValue(false)
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = CollectionStore(
            identity: alice, root: root, now: { Self.taken(0) },
            writeBytes: { data, url in
                if failing.get() { throw WriteDied() }
                try data.write(to: url)
            })
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        failing.set(true)

        store.remove([Self.uid(0)], from: record.id)

        let live = try #require(current(record, in: collections))
        #expect(live.excludedUids.isEmpty)
        #expect(store.members(for: live).count == 3, "a removal the file refused took effect")
        #expect(self.collections().records.first?.excludedUids == [])
    }

    /// Whether the file holds an exclusion list and a summary that agree: the summary counts the
    /// three drained pictures minus the excluded ones, and its cover is not one of them.
    private func fileAgrees() -> Bool {
        guard let record = self.collections().records.first, let summary = record.lastSummary
        else { return false }
        let coverOut = summary.coverUid.map { record.excludedUids.contains($0) } ?? false
        return summary.count == 3 - record.excludedUids.count && !coverOut
    }

    @Test("a removal and an Add Back are ONE write: a failing next write never splits them")
    func aRemovalIsOneWrite() async throws {
        struct WriteDied: Error {}
        let writes = LockedValue(0)
        let failing = LockedValue<Int?>(nil)
        let client = Self.recordingClient(seen: LockedValue([]))
        let collections = CollectionStore(
            identity: alice, root: root, now: { Self.taken(0) },
            writeBytes: { data, url in
                writes.set(writes.get() + 1)
                if writes.get() == failing.get() { throw WriteDied() }
                try data.write(to: url)
            })
        let record = collections.create(title: "Portugal 2026", tags: [Self.tag])
        let store = TripMembershipStore(collections: collections)
        await store.drain(record, using: client.handle, baseURL: Stub.baseURL)
        #expect(fileAgrees(), "control: the drain's summary is on file")

        // The write after the removal's first one dies: whatever reached the file agrees.
        failing.set(writes.get() + 2)
        store.remove([Self.uid(0)], from: record.id)
        #expect(fileAgrees(), "the exclusion reached the file without its summary")
        #expect(self.collections().records.first?.excludedUids == [Self.uid(0)], "control")

        failing.set(writes.get() + 2)
        store.addBack(Self.uid(0), to: record.id)
        #expect(fileAgrees(), "the Add Back reached the file without its summary")
        #expect(self.collections().records.first?.excludedUids == [], "control")

        // The one write dies: both stay as they were, in memory and on file.
        failing.set(writes.get() + 1)
        store.remove([Self.uid(1)], from: record.id)
        let live = try #require(current(record, in: collections))
        #expect(live.excludedUids == [] && live.lastSummary?.count == 3)
        #expect(fileAgrees() && self.collections().records.first?.excludedUids == [])
    }
}
