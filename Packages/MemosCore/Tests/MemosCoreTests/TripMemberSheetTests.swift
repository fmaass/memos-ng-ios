import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The New trip sheet's reads — the tag counts and a tag's taken span — now kept by the
/// `TripMemberStore` (MEMNG-754 adapted the device-local membership suite's sheet cases here, their
/// assertions unchanged): through the REAL generated client over a scripted transport, every
/// overlap joined or refused, every reset fencing what was in flight.
@MainActor
@Suite("Trip members — the New trip sheet's reads")
struct TripMemberSheetTests {
    private nonisolated static let tagsOperation = "attachment_tags_api_attachments_tags_get"
    private nonisolated static let tag = "portugal2026"

    /// The taken date of the n-th picture: one hour apart, from 2026-03-12T00:00:00Z.
    private nonisolated static func taken(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_773_273_600 + Double(index) * 3600)
    }

    private nonisolated static func uid(_ index: Int) -> String { TripWire.uid(index) }

    private nonisolated static func item(
        _ uid: String, taken: Date, mime: String = "image/jpeg"
    ) -> String {
        TripWire.item(uid, taken: taken).replacingOccurrences(of: "image/jpeg", with: mime)
    }

    /// The `type` query item of a request as the log holds it (`<operation> <path>`), or nil when
    /// it is ABSENT — which is how every kind is asked for. An empty `?type=` is not absent.
    private nonisolated static func kind(_ request: String) -> String? {
        let path = request.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        let items = URLComponents(string: path)?.queryItems ?? []
        guard let item = items.first(where: { $0.name == "type" }) else { return nil }
        return item.value ?? ""
    }

    private nonisolated static func page(_ items: [String]) -> (HTTPResponse, HTTPBody?) {
        Stub.json("[\(items.joined(separator: ","))]")
    }

    /// A member store over a trip store of no trips: the sheet reads need none.
    private func sheetStore() -> TripMemberStore {
        TripMemberStore(trips: TripStore(identity: TripWire.alice, root: TripWire.root()))
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
        let store = sheetStore()
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
        let store = sheetStore()
        let first = Task { await store.loadTagCounts(using: client.handle) }
        #expect(await hold.entered[0].wait(), "the first count read was not sent")
        await store.loadTagCounts(using: client.handle)
        #expect(hold.calls == 1, "an overlapping count read was sent: \(hold.calls)")
        hold.release[0].open()
        await first.value
        #expect(hold.calls == 1)
        #expect(store.tagCountsLoaded, "control: the one read landed")
    }

    @Test("a second span read of the same tag while one is in flight joins it, not sent")
    func overlappingSpanReadsAreOne() async {
        let hold = TripHold(holding: [0])
        let client = sheetClient(hold)
        let store = sheetStore()
        let joined = TripLatch()
        store.onSpanJoin = { joined.open() }
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
        hold.release[0].open()
        await first.value
        #expect(await second.value == Self.span, "the joiner returned before the read it joined")
        #expect(hold.calls == 2, "not one read of each extremum: \(hold.calls)")
    }

    @Test("a reset lets a caller that joined the old span read go")
    func aResetLetsAJoinerGo() async {
        let hold = TripHold(holding: [0])
        let client = sheetClient(hold)
        let store = sheetStore()
        let joined = TripLatch()
        store.onSpanJoin = { joined.open() }
        let old = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the old span read was not sent")
        let gone = TripLatch()
        let joiner = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
            gone.open()
        }
        #expect(await joined.wait(), "the second read did not join the first")
        store.sessionIdentityChanged()
        let freed = await gone.wait()
        #expect(freed, "a reset left the joiner parked on a read nobody owns")
        if freed { await joiner.value }
        hold.release[0].open()
        await old.value
        #expect(store.spans.isEmpty, "the old read landed after the reset")
    }

    @Test("a change of identity discards the sheet's pending counts and span")
    func anIdentityChangeDiscardsSheetReads() async {
        let counts = TripHold(holding: [0])
        let countClient = sheetClient(counts)
        let store = sheetStore()
        let countRead = Task { await store.loadTagCounts(using: countClient.handle) }
        #expect(await counts.entered[0].wait(), "the count read was not sent")
        store.sessionIdentityChanged()
        counts.release[0].open()
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
        spans.release[0].open()
        await spanRead.value
        #expect(spans.calls == 1, "a stale first extremum asked for the second")
        #expect(store.spans.isEmpty, "the outgoing account's span was applied")
    }

    @Test("a renewed session discards the sheet's pending counts and span")
    func aRenewalDiscardsSheetReads() async {
        let counts = TripHold(holding: [0])
        let countClient = sheetClient(counts)
        let countSession = TripTestSession(for: SessionHandle(client: countClient, generation: 1))
        let store = sheetStore()
        store.reports(to: countSession)
        let countRead = Task {
            await store.loadTagCounts(using: SessionHandle(client: countClient, generation: 1))
        }
        #expect(await counts.entered[0].wait(), "the count read was not sent")
        countSession.activeHandle = SessionHandle(client: countClient, generation: 2)
        counts.release[0].open()
        await countRead.value
        #expect(store.tagCounts.isEmpty, "a renewed session got the old one's counts")
        #expect(!store.tagCountsLoaded)

        let spans = TripHold(holding: [0])
        let spanClient = sheetClient(spans)
        let spanSession = TripTestSession(for: SessionHandle(client: spanClient, generation: 1))
        let spanStore = sheetStore()
        spanStore.reports(to: spanSession)
        let spanRead = Task {
            await spanStore.loadSpan(
                ofTag: Self.tag, using: SessionHandle(client: spanClient, generation: 1),
                baseURL: Stub.baseURL)
        }
        #expect(await spans.entered[0].wait(), "the first extremum was not asked for")
        spanSession.activeHandle = SessionHandle(client: spanClient, generation: 2)
        spans.release[0].open()
        await spanRead.value
        #expect(spans.calls == 1, "a stale first extremum asked for the second")
        #expect(spanStore.spans.isEmpty, "a renewed session got the old one's span")
    }

    @Test("a renewed session's span read does not join the old session's: it reads for itself")
    func aRenewedSpanReadIsItsOwn() async {
        let hold = TripHold(holding: [0, 1])
        let client = sheetClient(hold)
        let session = TripTestSession(for: SessionHandle(client: client, generation: 1))
        let store = sheetStore()
        store.reports(to: session)
        let joined = TripLatch()
        store.onSpanJoin = { joined.open() }
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
        hold.release[0].open()
        await old.value

        // The old read's end leaves the renewed read's slot alone: a third caller joins it.
        let third = Task {
            await store.loadSpan(ofTag: Self.tag, using: renewed, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the old read's end cleared the renewed read's slot")
        hold.release[1].open()
        #expect(await current.value == Self.span, "the renewed session got no dates of its own")
        await third.value
        #expect(hold.calls == 3, "not one old extremum and one renewed pair: \(hold.calls)")
    }

    @Test("a second extremum answered for a renewed session publishes no span")
    func aStaleSecondExtremumPublishesNothing() async {
        let hold = TripHold(holding: [1])
        let client = sheetClient(hold)
        let session = TripTestSession(for: SessionHandle(client: client, generation: 1))
        let store = sheetStore()
        store.reports(to: session)
        let read = Task {
            await store.loadSpan(
                ofTag: Self.tag, using: SessionHandle(client: client, generation: 1),
                baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[1].wait(), "the second extremum was not asked for")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        hold.release[1].open()
        await read.value
        #expect(store.spans.isEmpty, "a span half read under the old session was published")
    }

    @Test("after a reset a fresh count read is sent, and the old one cannot clear its guard")
    func aFreshCountReadKeepsItsGuard() async {
        let hold = TripHold(holding: [0, 1])
        let client = sheetClient(hold)
        let store = sheetStore()
        let old = Task { await store.loadTagCounts(using: client.handle) }
        #expect(await hold.entered[0].wait(), "the old count read was not sent")
        store.sessionIdentityChanged()
        let fresh = Task { await store.loadTagCounts(using: client.handle) }
        #expect(await hold.entered[1].wait(), "the fresh read after the reset was refused")
        hold.release[0].open()
        await old.value
        await store.loadTagCounts(using: client.handle)
        #expect(hold.calls == 2, "the old read's end cleared the fresh read's guard")
        hold.release[1].open()
        await fresh.value
        #expect(store.tagCountsLoaded, "control: the fresh read landed")
    }

    @Test("after a reset a fresh span read is sent, and the old one cannot clear its guard")
    func aFreshSpanReadKeepsItsGuard() async {
        let hold = TripHold(holding: [0, 1])
        let client = sheetClient(hold)
        let store = sheetStore()
        let old = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[0].wait(), "the old span read was not sent")
        store.sessionIdentityChanged()
        let fresh = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await hold.entered[1].wait(), "the fresh read after the reset was refused")
        hold.release[0].open()
        await old.value
        let joined = TripLatch()
        store.onSpanJoin = { joined.open() }
        let joiner = Task {
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await joined.wait(), "the old read's end cleared the fresh read's guard")
        #expect(hold.calls == 2, "the old read's end cleared the fresh read's guard")
        hold.release[1].open()
        await fresh.value
        await joiner.value
        #expect(store.spans[Self.tag] == Self.span, "control: the fresh read landed")
    }

    // MARK: - a refusal decided across a change of identity (MEMNG-743)

    private typealias Read = @MainActor @Sendable (TripMemberStore, any APIProtocol) async -> Void

    /// Runs one sheet read against a server that answers it 401 and returns what the read left
    /// in `lastError`. The 401 is held until the read is in flight and let go BEFORE the session's
    /// decision (`onUnauthorized`, which ends the session) is entered; the decision is held until
    /// the test lets it go. With `reset`, the identity changes while the decision is suspended, so
    /// only the predicate the read hands `say` can keep the outgoing account's sentence off the
    /// sheet: nothing is deleted, no session is told and the credential never moves.
    private func refusedRead(reset: Bool, _ read: @escaping Read) async -> String? {
        let hold = TripHold(holding: [0])
        let client = Stub.client { request, _, _ in
            await hold.pass(request.path ?? "")
            return Stub.empty(.unauthorized)
        }
        let asked = TripLatch()
        let decided = TripLatch()
        let store = TripMemberStore(
            trips: TripStore(identity: TripWire.alice, root: TripWire.root()),
            onUnauthorized: { (_: CredentialRefusal) in
                asked.open()
                await decided.wait()
                return .endedSession
            })
        let task = Task { await read(store, client) }
        #expect(await hold.entered[0].wait(), "the read was not sent")
        hold.release[0].open()
        #expect(await asked.wait(), "the refusal never reached the session's decision")
        if reset { store.sessionIdentityChanged() }
        decided.open()
        await task.value
        #expect(hold.calls == 1, "control: one request, refused: \(hold.calls)")
        return store.lastError
    }

    @Test("a count refusal decided across a change of identity writes no sentence")
    func aCountRefusalAcrossAnIdentityChangeSaysNothing() async {
        let count: Read = { store, client in await store.loadTagCounts(using: client.handle) }
        #expect(await refusedRead(reset: false, count) != nil, "control: it said nothing")
        #expect(
            await refusedRead(reset: true, count) == nil,
            "the outgoing account's count refusal wrote a sentence")
    }

    @Test("a span refusal decided across a change of identity writes no sentence")
    func aSpanRefusalAcrossAnIdentityChangeSaysNothing() async {
        let span: Read = { store, client in
            await store.loadSpan(ofTag: Self.tag, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await refusedRead(reset: false, span) != nil, "control: it said nothing")
        #expect(
            await refusedRead(reset: true, span) == nil,
            "the outgoing account's span refusal wrote a sentence")
    }
}

/// A scripted server that holds the requests it is told to, by arrival index from 0, until the
/// test lets each one go. Every wait is bounded (`TripLatch.wait`).
final class TripHold: @unchecked Sendable {
    let entered = (0..<8).map { _ in TripLatch() }
    let release = (0..<8).map { _ in TripLatch() }
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
        entered[index].open()
        await release[index].wait()
    }
}
