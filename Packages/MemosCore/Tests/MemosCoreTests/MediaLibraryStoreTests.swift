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
    private nonisolated static func item(
        uid: String,
        mime: String = "image/jpeg",
        status: String = "ready"
    ) -> String {
        """
        {"uid":"\(uid)","mime":"\(mime)","status":"\(status)","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":false,\
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

    /// Waits for the scripted transport to reach the request the test is about — and gives up.
    ///
    /// Bounded rather than a bare spin: a change that stops the next page from being asked for at
    /// all would otherwise hang this test forever on the build host every run after it, and a gate
    /// that never returns is worse than one that fails.
    private static func reached(_ flag: LockedValue<Bool>) async -> Bool {
        for _ in 0..<5_000 {
            if flag.get() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return flag.get()
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
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=") {
                entered.set(true)
                while !release.get() {
                    try await Task.sleep(for: .milliseconds(1))
                }
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
        let asked = await Self.reached(entered)
        #expect(asked, "the next page was never asked for, so nothing could be superseded")
        store.setFilter(.videos)
        await store.refresh(using: client, baseURL: Stub.baseURL)
        release.set(true)
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
}
