import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

/// The media library's paging, its tabs, and the fence between the two.
///
/// As everywhere in this bundle, the server is a script under the REAL generated client: the
/// request the store builds, its `?type=`/`?cursor=` and the decoding of the response are all
/// exercised. A stand-in for the store would prove only that the test agrees with itself.
///
/// The continuation token is the part worth being careful about. This endpoint answers with a bare
/// array and puts the token in the `X-Next-Cursor` HEADER, so every page here is built as a real
/// response with real header fields — a body-shaped stub would test a contract the server does not
/// have.
@MainActor
@Suite("Media library paging")
struct MediaLibraryStoreTests {
    /// One row of `GET /api/attachments`. It is `AttachmentListItem`, which is NOT the memo's
    /// `AttachmentRef`: no `duration`, and an `orphan` flag instead.
    ///
    /// `memoUid` is null by default because the interesting half of that field is the ORPHAN — a
    /// file in the library that no memo references, which is a row this list deliberately carries.
    private nonisolated static func item(
        uid: String,
        mime: String = "image/jpeg",
        status: String = "ready",
        memoUid: String? = nil
    ) -> String {
        let owner = memoUid.map { "\"\($0)\"" } ?? "null"
        return """
            {"uid":"\(uid)","mime":"\(mime)","status":"\(status)","blurhash":null,\
            "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "renditions":[],"orphan":\(memoUid == nil),"memoUid":\(owner),\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
            "previewUrl":"/api/attachments/\(uid)/mobile",\
            "webUrl":"/api/attachments/\(uid)/web",\
            "posterUrl":"/api/attachments/\(uid)/poster",\
            "downloadUrl":"/api/attachments/\(uid)/download",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    /// A page, with its continuation token where the server puts it. `nextCursor: nil` is the last
    /// page — the header is then simply absent, which is the ONLY thing that ends the list.
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

    private nonisolated static func uids(_ list: [String]) -> [String] {
        list.map { item(uid: $0) }
    }

    @Test("the first page is asked for with no cursor, and All sends no type at all")
    func firstPageOfAll() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a", "b"]))
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(store.items.map(\.uid) == ["a", "b"])
        let path = paths.get().first ?? ""
        #expect(!path.contains("cursor="), "a first page must not carry a cursor")
        // `?type=` on the All tab would be a filter matching nothing, not the absence of one.
        #expect(!path.contains("type="), "All sent a type filter")
        // A 0-hit assertion proves nothing unless the query it looked in was really there.
        #expect(path.contains("limit=2"), "control: this store did send a query")
    }

    @Test("Images and Videos each send their own type")
    func typePerTab() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page([])
        }
        let store = MediaLibraryStore(pageSize: 2, filter: .images)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        store.setFilter(.videos)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(paths.get().count == 2)
        #expect(paths.get()[0].contains("type=image"), "Images did not filter")
        #expect(paths.get()[1].contains("type=video"), "Videos did not filter")
    }

    @Test("the next page is asked for with the cursor the header handed back")
    func nextPageUsesTheHeaderCursor() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=page-2") {
                return Self.page(Self.uids(["c"]))
            }
            return Self.page(Self.uids(["a", "b"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.hasMore, "a page with X-Next-Cursor is not the last one")

        await store.loadMore(using: client, baseURL: Stub.baseURL)
        #expect(store.items.map(\.uid) == ["a", "b", "c"], "the page did not append")
        #expect(
            paths.get().contains { $0.contains("cursor=page-2") },
            "the header's token was not sent back"
        )
        #expect(!store.hasMore, "a page with no X-Next-Cursor is the last one")
    }

    @Test("a page with no X-Next-Cursor ends the list, and nothing is asked for after it")
    func absentHeaderEndsTheList() async {
        let requests = Counter()
        let client = Stub.client { _, _, _ in
            requests.increment()
            return Self.page(Self.uids(["a"]))
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(!store.hasMore)
        #expect(requests.count == 1, "control: the first page really was fetched")

        await store.loadMore(using: client, baseURL: Stub.baseURL)
        #expect(requests.count == 1, "a next page was fetched past the end of the list")
        #expect(store.items.map(\.uid) == ["a"])
    }

    @Test("a file already loaded is never shown twice")
    func overlappingPagesDeduplicate() async {
        let client = Stub.client { request, _, _ in
            // Keyed on THAT there is a cursor, not on its value: which token is sent back is
            // `nextPageUsesTheHeaderCursor`'s subject, and this test is about the merge.
            if (request.path ?? "").contains("cursor=") {
                // The boundary row again, plus a genuinely new one.
                return Self.page(Self.uids(["b", "c"]))
            }
            return Self.page(Self.uids(["a", "b"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        await store.loadMore(using: client, baseURL: Stub.baseURL)

        #expect(store.items.map(\.uid) == ["a", "b", "c"], "the overlapping row was merged twice")
    }

    @Test("a video is not shown under Images, an image is not shown under Videos")
    func rowsOutsideTheTabAreDropped() async {
        let imagesClient = Stub.client { _, _, _ in
            Self.page([
                Self.item(uid: "photo", mime: "image/jpeg"),
                Self.item(uid: "clip", mime: "video/mp4"),
            ])
        }
        let images = MediaLibraryStore(pageSize: 10, filter: .images)
        await images.refresh(using: imagesClient, baseURL: Stub.baseURL)
        #expect(images.items.map(\.uid) == ["photo"], "a video was shown under Images")

        let videosClient = Stub.client { _, _, _ in
            Self.page([
                Self.item(uid: "photo", mime: "image/jpeg"),
                Self.item(uid: "clip", mime: "video/mp4"),
            ])
        }
        let videos = MediaLibraryStore(pageSize: 10, filter: .videos)
        await videos.refresh(using: videosClient, baseURL: Stub.baseURL)
        #expect(videos.items.map(\.uid) == ["clip"], "an image was shown under Videos")
    }

    @Test("All shows what is neither a photo nor a video")
    func allKeepsOtherKinds() async {
        let client = Stub.client { _, _, _ in
            Self.page([
                Self.item(uid: "photo", mime: "image/jpeg"),
                Self.item(uid: "clip", mime: "video/mp4"),
                Self.item(uid: "paper", mime: "application/pdf"),
            ])
        }
        let store = MediaLibraryStore(pageSize: 10)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(store.items.map(\.uid) == ["photo", "clip", "paper"])
        #expect(store.items.map(\.mediaKind) == [.image, .video, .other])
    }

    @Test("changing tab empties the grid and forgets the cursor")
    func changingTabResetsThePaging() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.items.map(\.uid) == ["a"])

        store.setFilter(.videos)
        #expect(store.items.isEmpty, "the old tab's files stayed on screen under the new one")
        #expect(store.hasMore, "a tab nobody has read yet cannot be at its end")

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let last = paths.get().last ?? ""
        #expect(last.contains("type=video"))
        #expect(!last.contains("cursor="), "the old tab's cursor was carried into the new one")
    }

    @Test("a page that answers a tab nobody is on any more is dropped, cursor and all")
    func supersededPageIsDropped() async {
        let entered = Signal()
        let release = Signal()
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=") {
                entered.signal()
                await release.wait()
                // The tab as it stood when the scroll asked for it, and a cursor into that tab.
                return Self.page(Self.uids(["stale"]), nextCursor: "page-3")
            }
            if path.contains("type=video") {
                // A VIDEO, because the Videos tab drops anything else — see
                // `rowsOutsideTheTabAreDropped`. An image here would empty the tab and read as a
                // fence failure.
                return Self.page([Self.item(uid: "clip", mime: "video/mp4")])
            }
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client, baseURL: Stub.baseURL) }
        // Resumes at the moment the next page ENTERS the transport, not a moment a clock guessed
        // at — so the supersede below provably happens with that request in flight.
        await entered.wait()
        store.setFilter(.videos)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        release.signal()
        await inFlight.value

        #expect(store.items.map(\.uid) == ["clip"], "the superseded page was merged anyway")
        // The cursor is the damage that outlives the merge: had `page-3` been adopted, the store
        // would believe the Videos tab continues where the All tab left off.
        #expect(!store.hasMore, "the dropped page's cursor was adopted")
        #expect(
            !paths.get().contains { $0.contains("cursor=page-3") },
            "the dropped page's cursor was asked for"
        )
        #expect(
            paths.get().contains { $0.contains("cursor=") },
            "control: the page that was dropped is one this store really did ask for"
        )
    }

    @Test("the next page is asked for near the end of the grid, and never past it")
    func loadMoreTrigger() async {
        let client = Stub.client { _, _, _ in
            Self.page(Self.uids(["a", "b", "c", "d"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 4)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(store.shouldLoadMore(after: 3, lookahead: 2), "the last tile did not trigger")
        #expect(store.shouldLoadMore(after: 2, lookahead: 2), "the lookahead did not trigger")
        #expect(!store.shouldLoadMore(after: 1, lookahead: 2), "a tile far from the end triggered")

        let ended = MediaLibraryStore(pageSize: 4)
        let lastPage = Stub.client { _, _, _ in Self.page(Self.uids(["a"])) }
        await ended.refresh(using: lastPage, baseURL: Stub.baseURL)
        #expect(!ended.shouldLoadMore(after: 0), "a list at its end asked for more")
    }

    @Test("a rejected token ends the session rather than showing an error nobody can act on")
    func unauthorizedIsHandled() async {
        let handled = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let store = MediaLibraryStore(pageSize: 2, onUnauthorized: { handled.set(true) })
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(handled.get(), "a 401 did not reach the session")
        #expect(store.items.isEmpty)
        #expect(store.lastError != nil, "the failure was swallowed")
    }

    @Test("a tier URL is resolved against the server, and a list row has no duration to show")
    func rowsMapOntoTheSharedAttachmentModel() async throws {
        let client = Stub.client { _, _, _ in
            Self.page([Self.item(uid: "a", mime: "video/mp4")])
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let row = try #require(store.items.first)
        let poster = "https://memos.example.invalid/api/attachments/a/poster"
        #expect(row.posterURL?.absoluteString == poster)
        #expect(row.isVideo)
        // `AttachmentListItem` carries no duration, so the app has none to print. A zero here
        // would put "0:00" under every clip in the library.
        #expect(row.duration == nil)
    }

    // MARK: - MEMNG-171: which memo a file belongs to

    @Test("a row carries the memo it hangs on, and an orphan carries none")
    func rowsCarryTheirMemo() async throws {
        let client = Stub.client { _, _, _ in
            Self.page([
                Self.item(uid: "owned", memoUid: "memo-7"),
                Self.item(uid: "loose"),
            ])
        }
        let store = MediaLibraryStore(pageSize: 10)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        #expect(store.items.map(\.memoUID) == ["memo-7", nil])
    }

    // MARK: - MEMNG-190: which end of the library the grid starts at

    @Test("the direction chosen is the direction asked for")
    func orderRidesOnTheRequest() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]))
        }
        let newest = MediaLibraryStore(pageSize: 2)
        await newest.refresh(using: client, baseURL: Stub.baseURL)
        #expect(paths.get().last?.contains("order=desc") == true, "newest-first did not say so")

        let oldest = MediaLibraryStore(pageSize: 2, order: .oldestFirst)
        await oldest.refresh(using: client, baseURL: Stub.baseURL)
        #expect(
            paths.get().last?.contains("order=asc") == true,
            "Oldest First did not reach the server"
        )
        #expect(
            paths.get().last?.contains("order=desc") == false,
            "the newest-first direction was sent for a store reading the other way"
        )
    }

    @Test("turning the library round empties the grid and forgets the cursor")
    func changingOrderResetsThePaging() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(store.items.map(\.uid) == ["a"])

        store.setOrder(.oldestFirst)
        #expect(store.items.isEmpty, "the old direction's rows stayed on screen under the new one")
        #expect(store.hasMore, "a direction nobody has read yet cannot be at its end")

        await store.refresh(using: client, baseURL: Stub.baseURL)
        let last = paths.get().last ?? ""
        #expect(last.contains("order=asc"))
        // The cursor is a position inside ONE ordering; carried across a reversal it pages the
        // wrong way through the middle of the library.
        #expect(
            !last.contains("cursor="),
            "the old direction's cursor was carried into the new one"
        )
    }

    @Test("a page that answers a direction nobody is reading any more is dropped, cursor and all")
    func supersededOrderPageIsDropped() async {
        let entered = Signal()
        let release = Signal()
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=") {
                entered.signal()
                await release.wait()
                return Self.page(Self.uids(["stale"]), nextCursor: "page-3")
            }
            if path.contains("order=asc") {
                return Self.page(Self.uids(["oldest"]))
            }
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client, baseURL: Stub.baseURL) }
        await entered.wait()
        store.setOrder(.oldestFirst)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        release.signal()
        await inFlight.value

        #expect(store.items.map(\.uid) == ["oldest"], "the superseded page was merged anyway")
        #expect(!store.hasMore, "the dropped page's cursor was adopted")
        #expect(
            paths.get().contains { $0.contains("cursor=") },
            "control: the page that was dropped is one this store really did ask for"
        )
    }

    // MARK: - MEMNG-189: what the viewer asks of the same store

    @Test("nothing is asked for a second time while a page is already in flight")
    func noSecondRequestWhileOneIsOut() async {
        let entered = Signal()
        let release = Signal()
        let requests = Counter()
        let client = Stub.client { request, _, _ in
            requests.increment()
            if (request.path ?? "").contains("cursor=") {
                entered.signal()
                await release.wait()
                return Self.page(Self.uids(["c", "d"]), nextCursor: "page-3")
            }
            return Self.page(Self.uids(["a", "b"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        #expect(requests.count == 1)

        let inFlight = Task { await store.loadMore(using: client, baseURL: Stub.baseURL) }
        await entered.wait()
        // This is the swipe that lands while the fetch it triggered is still out. The trigger has
        // to say no, or one flick through the end of a loaded run fires a request per page.
        #expect(!store.shouldLoadMore(after: 1, lookahead: 1), "the trigger fired during a load")
        await store.loadMore(using: client, baseURL: Stub.baseURL)
        #expect(requests.count == 2, "a second request went out while one was in flight")

        release.signal()
        await inFlight.value
        #expect(store.items.map(\.uid) == ["a", "b", "c", "d"])
    }
}

/// A one-shot hand-off between a test and the scripted transport it is driving.
///
/// The interleaving this file is about — a page in flight while the tab changes under it — needs
/// the test to know that the request has REACHED the transport, and the transport to be held there
/// until the test says go. Both directions used to be a sleep-poll, and a poll is the same test
/// written as a race: on a loaded build host (merkur's one-minute load passed 200 the day this was
/// written) the poll's ceiling can expire before the request has started, and a fence that works
/// perfectly gets reported broken.
///
/// `AsyncStream` removes the clock from both directions. The waiter resumes when — and only when —
/// the other side signals, and because the stream buffers, a signal that arrives BEFORE anyone
/// waits is delivered rather than missed. So neither order of the two events can produce a
/// different outcome, which is what makes the interleaving a fact of the test rather than of the
/// machine it ran on.
private final class Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    /// Called from inside the transport, which the client runs off the main actor.
    func signal() { continuation.yield() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
