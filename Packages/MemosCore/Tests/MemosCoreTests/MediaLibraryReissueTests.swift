import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

/// The library's answer to a lapsed signature (MEMNG-623): the pages it holds are walked again from
/// the first cursor and each held row is re-signed where it stands.
///
/// Every page goes through the real generated client over a scripted transport, so the cursor the
/// walk sends, the header it reads its continuation from and the decoding are all the store's own.
/// Four pages of two rows each are loaded first; the server then re-signs everything, which is what
/// a list read an hour later really answers.
@Suite("Media library reissue")
@MainActor
struct MediaLibraryReissueTests {
    /// The server's list: page `n` holds `p<n>a` and `p<n>b`, and its cursor is `c<n+1>`.
    nonisolated static let pages = 4

    nonisolated static func item(uid: String, sig: String) -> String {
        let query = "?exp=4102444800&scope=1&sig=\(sig)"
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "renditions":[],"orphan":true,"memoUid":null,\
            "takenAt":"2026-09-26T10:00:00Z","filename":"\(uid).jpg",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)",\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)",\
            "downloadUrl":"/api/attachments/\(uid)/download",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    /// Which page a request asked for, read off the cursor it sent: none is page 0.
    nonisolated static func pageIndex(_ request: HTTPRequest) -> Int {
        guard let path = request.path,
            let items = URLComponents(string: "https://x.invalid\(path)")?.queryItems,
            let cursor = items.first(where: { $0.name == "cursor" })?.value,
            let index = Int(cursor.dropFirst())
        else { return 0 }
        return index
    }

    nonisolated static func answer(page index: Int, sig: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if index + 1 < pages, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = "c\(index + 1)"
        }
        let rows = ["a", "b"].map { item(uid: "p\(index)\($0)", sig: sig) }
        return (response, HTTPBody("[\(rows.joined(separator: ","))]"))
    }

    /// A store with all four pages loaded under signature `old`, over a server whose next answers
    /// carry whatever `server.sig` says. Every page request is recorded, and one can be HELD.
    private func loaded(
        server: ReissueServer,
        cooldown: ReissueGate = ReissueGate(),
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) async -> (MediaLibraryStore, SessionHandle) {
        let client = Stub.client { request, _, _ in
            let index = Self.pageIndex(request)
            return await server.answer(index)
        }
        let handle = SessionHandle(client: client, generation: 1)
        let store = MediaLibraryStore(
            pageSize: 2,
            onUnauthorized: onUnauthorized,
            reissueCooldown: { await cooldown.wait() }
        )
        await store.refresh(using: handle, baseURL: Stub.baseURL)
        for _ in 1..<Self.pages { await store.loadMore(using: handle, baseURL: Stub.baseURL) }
        server.forget()
        server.sig.set("new")
        return (store, handle)
    }

    func sig(of uid: String, in store: MediaLibraryStore) -> String? {
        guard let url = store.items.first(where: { $0.id == uid })?.attachment.thumbnailURL
        else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "sig" }?.value
    }

    @Test("a row on the third page lapses: three pages are re-read and only rows change in place")
    func aThirdPageRowIsReissuedInPlace() async {
        let server = ReissueServer()
        let (store, handle) = await loaded(server: server)
        let before = store.items
        #expect(before.count == 8, "the four pages never loaded")
        let generation = store.listGeneration

        await store.reissue(uids: ["p2a"], using: handle, baseURL: Stub.baseURL)

        #expect(server.asked() == [0, 1, 2], "the walk did not re-read exactly pages one to three")
        #expect(sig(of: "p2a", in: store) == "new", "the lapsed row kept its refused URL")
        #expect(store.items.map(\.id) == before.map(\.id), "the walk moved or dropped a row")
        #expect(Array(store.items.suffix(2)) == Array(before.suffix(2)), "an unwalked page changed")
        #expect(store.listGeneration == generation, "a reissue is not a different list")
    }

    @Test("a row lapsing inside the cooldown is walked for when the cooldown ends, unasked")
    func aRowInsideTheCooldownGetsTheDeferredWalk() async {
        let server = ReissueServer()
        let cooldown = ReissueGate()
        let (store, handle) = await loaded(server: server, cooldown: cooldown)

        await store.reissue(uids: ["p0a"], using: handle, baseURL: Stub.baseURL)
        #expect(sig(of: "p0a", in: store) == "new")
        #expect(server.asked() == [0], "the first walk read past the page it needed")

        server.sig.set("newer")
        await store.reissue(uids: ["p2b"], using: handle, baseURL: Stub.baseURL)
        #expect(server.asked() == [0], "a walk went out inside the cooldown")
        #expect(sig(of: "p2b", in: store) == "old")

        cooldown.open()
        let reached = await eventually { self.sig(of: "p2b", in: store) == "newer" }
        #expect(reached, "the deferred walk never re-signed the row that lapsed in the cooldown")
        #expect(server.asked() == [0, 0, 1, 2], "the deferred walk did not reach page three")
    }

    @Test("a row named while a walk is out extends that walk, and no second walk starts")
    func aRowArrivingMidWalkExtendsIt() async {
        let server = ReissueServer()
        let (store, handle) = await loaded(server: server)
        server.hold(page: 0)

        let first = Task {
            await store.reissue(uids: ["p0b"], using: handle, baseURL: Stub.baseURL)
        }
        await server.held.wait()
        let second = Task {
            await store.reissue(uids: ["p3a"], using: handle, baseURL: Stub.baseURL)
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(store.isReissuing)
        #expect(server.asked() == [0], "a second walk went out while the first was on the wire")

        server.release()
        await first.value
        await second.value
        #expect(server.asked() == [0, 1, 2, 3], "the running walk was not extended to page four")
        #expect(sig(of: "p0b", in: store) == "new")
        #expect(sig(of: "p3a", in: store) == "new")
    }

    @Test("a walk whose page lands after the list generation moved is dropped")
    func aWalkForAMovedListIsDropped() async {
        let server = ReissueServer()
        let (store, handle) = await loaded(server: server)
        server.hold(page: 0)

        let walk = Task {
            await store.reissue(uids: ["p1a"], using: handle, baseURL: Stub.baseURL)
        }
        await server.held.wait()
        store.setOrder(.oldestFirst)
        await store.refresh(using: handle, baseURL: Stub.baseURL)
        let rebuilt = store.items
        // What the dropped page carries, so a walk that merged it anyway would be seen doing so.
        server.sig.set("stale")
        server.release()
        await walk.value

        #expect(store.items == rebuilt, "a walk for the replaced list wrote into the new one")
        #expect(server.asked().count == 2, "the dropped walk went on reading pages")
    }

    @Test("a page answered after the session was replaced is dropped, the list unchanged")
    func aPageForAReplacedSessionIsDropped() async {
        let server = ReissueServer()
        let (store, handle) = await loaded(server: server)
        let session = ReissueSession(handle)
        store.reports(to: session)
        let before = store.items
        let generation = store.listGeneration
        server.hold(page: 0)

        let walk = Task {
            await store.reissue(uids: ["p0a"], using: handle, baseURL: Stub.baseURL)
        }
        await server.held.wait()
        session.activeHandle = SessionHandle(client: handle.client, generation: 2)
        server.release()
        await walk.value

        #expect(store.listGeneration == generation)
        #expect(store.items == before, "a page for the ended session re-signed rows")
    }

    @Test("a row whose walk was dropped for a replaced session is walked for under the new one")
    func aDroppedWalkIsRetriedUnderTheRunningSession() async {
        let server = ReissueServer()
        let cooldown = ReissueGate()
        let (store, handle) = await loaded(server: server, cooldown: cooldown)
        let session = ReissueSession(handle)
        store.reports(to: session)
        server.hold(page: 0)

        let walk = Task {
            await store.reissue(uids: ["p0a"], using: handle, baseURL: Stub.baseURL)
        }
        await server.held.wait()
        let renewed = SessionHandle(client: handle.client, generation: 2)
        session.activeHandle = renewed
        server.release()
        await walk.value
        #expect(sig(of: "p0a", in: store) == "old", "the dropped page was merged after all")

        cooldown.open()
        let reached = await eventually { self.sig(of: "p0a", in: store) == "new" }
        #expect(reached, "the row stayed on its lapsed URL past the cooldown")
        #expect(server.asked() == [0, 0], "the retry was not exactly one walk of page one")
    }

    @Test("an ask issued under an ended session touches nothing, and holds back no current ask")
    func aReissueUnderAnEndedSessionTouchesNothing() async {
        let server = ReissueServer()
        let (store, handle) = await loaded(server: server)
        let session = ReissueSession(handle)
        store.reports(to: session)
        let renewed = SessionHandle(client: handle.client, generation: 2)
        session.activeHandle = renewed

        await store.reissue(uids: ["p0a"], using: handle, baseURL: Stub.baseURL)
        #expect(server.asked().isEmpty, "a walk went out for the ended session")
        #expect(!store.isReissuing)

        await store.reissue(uids: ["p0a"], using: renewed, baseURL: Stub.baseURL)
        #expect(sig(of: "p0a", in: store) == "new", "the stale ask held back the running one")
        #expect(server.asked() == [0])
    }

    @Test("a 401 answered after the session was replaced cannot touch the replacement")
    func aStaleRefusalReachesNoSession() async {
        let server = ReissueServer()
        let cooldown = ReissueGate()
        let refusals = LockedValue<Int>(0)
        let (store, handle) = await loaded(
            server: server,
            cooldown: cooldown,
            onUnauthorized: { _ in
                refusals.set(refusals.get() + 1)
                return .endedSession
            }
        )
        let session = ReissueSession(handle)
        store.reports(to: session)
        server.hold(page: 0, refusing: true)

        let walk = Task {
            await store.reissue(uids: ["p0a"], using: handle, baseURL: Stub.baseURL)
        }
        await server.held.wait()
        session.activeHandle = SessionHandle(client: handle.client, generation: 2)
        server.release()
        await walk.value

        #expect(refusals.get() == 0, "a refusal about the ended session reached the running one")
        #expect(store.lastError == nil)

        // The control: the same refusal, under the session that issued it, does reach it. The row
        // is still owed its walk, and the one after the cooldown is it.
        session.activeHandle = handle
        server.hold(page: 0, refusing: true)
        server.release()
        await store.reissue(uids: ["p1a"], using: handle, baseURL: Stub.baseURL)
        cooldown.open()
        let reached = await eventually { refusals.get() == 1 }
        #expect(reached, "the control refusal never reached the session")
    }

    func eventually(tries: Int = 200, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<tries {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// The scripted server behind the walk: which pages were asked for, what signature they answer
/// with, and one page that can be held on the wire until the test lets it go.
private final class ReissueServer: Sendable {
    let sig = LockedValue<String>("old")
    private let log = LockedValue<[Int]>([])
    private let holding = LockedValue<(page: Int, refusing: Bool)?>(nil)
    let held = ReissueGate()
    private let gate = ReissueGate()

    func asked() -> [Int] { log.get() }
    func forget() { log.set([]) }

    func hold(page: Int, refusing: Bool = false) { holding.set((page, refusing)) }
    func release() { gate.open() }

    func answer(_ index: Int) async -> (HTTPResponse, HTTPBody?) {
        log.set(log.get() + [index])
        if let hold = holding.get(), hold.page == index {
            holding.set(nil)
            held.open()
            await gate.wait()
            if hold.refusing { return Stub.empty(.unauthorized) }
        }
        return MediaLibraryReissueTests.answer(page: index, sig: sig.get())
    }
}

/// A gate a waiter passes once it is opened, whichever of the two happens first.
private final class ReissueGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func open() { continuation.yield() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// A session whose running incarnation the test replaces, the way a sign-in does.
@MainActor
private final class ReissueSession: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()

    init(_ handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }
    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        activeHandle?.generation == handle.generation
    }
    func noteTransportFailure(_ failure: ServerReachability.Reason, issuedUnder generation: Int) {}
    func noteTransportSuccess(issuedUnder generation: Int) {}
}
