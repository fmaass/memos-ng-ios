import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A trip's membership: drained from `GET /api/attachments` under the trip's tag, images only,
/// oldest first, to the end of the cursor chain or the cap — then filtered by the record's
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
        "renditions":[],"orphan":false,"memoUid":"m-\(uid)",\
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
            #expect(request.contains("type=image"), "not images only: \(request)")
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

    // MARK: - the New trip sheet

    @Test("the sheet's count is the image count when the tag also carries a video")
    func theSheetCountsImagesOnly() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + ["\(operation) \(path)"])
            // Two pictures and a clip carry the tag: the count with no type would say 3.
            let images = path.contains("type=image")
            if operation == Self.tagsOperation {
                return Stub.json(#"[{"name":"portugal2026","count":\#(images ? 2 : 3)}]"#)
            }
            let clip = Self.item("clip", taken: Self.taken(9), mime: "video/mp4")
            if !images { return Self.page([clip]) }
            let index = path.contains("order=taken_desc") ? 5 : 1
            return Self.page([Self.item(Self.uid(index), taken: Self.taken(index))])
        }
        let collections = collections()
        let store = TripMembershipStore(collections: collections)
        await store.loadTagCounts(using: client.handle)
        await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.tagCounts == [LibraryTag(name: Self.tag, count: 2)], "\(store.tagCounts)")
        #expect(store.tagCountsLoaded)
        #expect(
            store.spans[Self.tag]
                == TripTagSpan(firstTaken: Self.taken(1), lastTaken: Self.taken(5)),
            "the span is not the images' span")
        let sent = paths.get()
        #expect(sent.count == 3, "not one count read and two extrema: \(sent)")
        #expect(sent.first?.hasPrefix(Self.tagsOperation) == true, "control: the counts were read")
        for request in sent { #expect(request.contains("type=image"), "not images: \(request)") }
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

    @Test("a second span read of the same tag while one is in flight is refused, not sent")
    func overlappingSpanReadsAreOne() async {
        let hold = TripHold(holding: [0])
        let client = sheetClient(hold)
        let store = TripMembershipStore(collections: collections())
        let first = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the first extremum was not asked for")
        await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(hold.calls == 1, "an overlapping span read was sent: \(hold.calls)")
        hold.release[0].signal()
        await first.value
        #expect(hold.calls == 2, "not one read of each extremum: \(hold.calls)")
        #expect(store.spans[Self.tag] == Self.span, "control: the one read landed")
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
        await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        #expect(hold.calls == 2, "the old read's end cleared the fresh read's guard")
        hold.release[1].signal()
        await fresh.value
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
