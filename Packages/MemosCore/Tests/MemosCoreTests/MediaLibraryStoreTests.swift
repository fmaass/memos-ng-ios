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
        memoUid: String? = nil,
        mine: Bool = true,
        takenAt: String = "2026-09-26T10:00:00Z",
        filename: String? = nil
    ) -> String {
        let owner = memoUid.map { "\"\($0)\"" } ?? "null"
        return """
            {"uid":"\(uid)","mime":"\(mime)","status":"\(status)","blurhash":null,\
            "width":1000,"height":800,"mine":\(mine),"hasPrint":false,"hasLegacyPrint":false,\
            "webReady":true,\
            "renditions":[],"tags":[],"orphan":\(memoUid == nil),"memoUid":\(owner),\
            "takenAt":"\(takenAt)","filename":"\(filename ?? "\(uid).jpg")",\
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.map(\.attachment.uid) == ["a", "b"])
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        store.setFilter(.videos)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.hasMore, "a page with X-Next-Cursor is not the last one")

        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.attachment.uid) == ["a", "b", "c"], "the page did not append")
        #expect(
            paths.get().contains { $0.contains("cursor=page-2") },
            "the header's token was not sent back"
        )
        #expect(!store.hasMore, "a page with no X-Next-Cursor is the last one")
    }

    @Test("the list's generation stays through its next page and moves with every other list")
    func listGenerationNamesTheList() async {
        let client = Stub.client { request, _, _ in
            if (request.path ?? "").contains("cursor=page-2") {
                return Self.page(Self.uids(["c"]))
            }
            return Self.page(Self.uids(["a", "b"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let listed = store.listGeneration
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.count == 3, "control: the next page appended")
        #expect(store.listGeneration == listed, "a next page of the same list moved its generation")

        var seen = [listed]
        let changes: [(String, () -> Void)] = [
            ("filter", { store.setFilter(.videos) }),
            ("tag", { store.setTag("walks") }),
            ("order", { store.setOrder(.oldestFirst) }),
            ("identity", { store.sessionIdentityChanged() }),
        ]
        for (name, change) in changes {
            change()
            #expect(
                !seen.contains(store.listGeneration), "a \(name) change kept the list's generation")
            seen.append(store.listGeneration)
        }
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(!seen.contains(store.listGeneration), "a refresh kept the list's generation")
    }

    @Test("a page with no X-Next-Cursor ends the list, and nothing is asked for after it")
    func absentHeaderEndsTheList() async {
        let requests = Counter()
        let client = Stub.client { _, _, _ in
            requests.increment()
            return Self.page(Self.uids(["a"]))
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(!store.hasMore)
        #expect(requests.count == 1, "control: the first page really was fetched")

        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(requests.count == 1, "a next page was fetched past the end of the list")
        #expect(store.items.map(\.attachment.uid) == ["a"])
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        #expect(
            store.items.map(\.attachment.uid) == ["a", "b", "c"],
            "the overlapping row was merged twice"
        )
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
        await images.refresh(using: imagesClient.handle, baseURL: Stub.baseURL)
        #expect(images.items.map(\.attachment.uid) == ["photo"], "a video was shown under Images")

        let videosClient = Stub.client { _, _, _ in
            Self.page([
                Self.item(uid: "photo", mime: "image/jpeg"),
                Self.item(uid: "clip", mime: "video/mp4"),
            ])
        }
        let videos = MediaLibraryStore(pageSize: 10, filter: .videos)
        await videos.refresh(using: videosClient.handle, baseURL: Stub.baseURL)
        #expect(videos.items.map(\.attachment.uid) == ["clip"], "an image was shown under Videos")
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.map(\.attachment.uid) == ["photo", "clip", "paper"])
        #expect(store.items.map(\.attachment.mediaKind) == [.image, .video, .other])
    }

    @Test("changing tab empties the grid and forgets the cursor")
    func changingTabResetsThePaging() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.attachment.uid) == ["a"])

        store.setFilter(.videos)
        #expect(store.items.isEmpty, "the old tab's files stayed on screen under the new one")
        #expect(store.hasMore, "a tab nobody has read yet cannot be at its end")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        // Resumes at the moment the next page ENTERS the transport, not a moment a clock guessed
        // at — so the supersede below provably happens with that request in flight.
        await entered.wait()
        store.setFilter(.videos)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        release.signal()
        await inFlight.value

        #expect(
            store.items.map(\.attachment.uid) == ["clip"],
            "the superseded page was merged anyway"
        )
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.shouldLoadMore(after: 3, lookahead: 2), "the last tile did not trigger")
        #expect(store.shouldLoadMore(after: 2, lookahead: 2), "the lookahead did not trigger")
        #expect(!store.shouldLoadMore(after: 1, lookahead: 2), "a tile far from the end triggered")

        let ended = MediaLibraryStore(pageSize: 4)
        let lastPage = Stub.client { _, _, _ in Self.page(Self.uids(["a"])) }
        await ended.refresh(using: lastPage.handle, baseURL: Stub.baseURL)
        #expect(!ended.shouldLoadMore(after: 0), "a list at its end asked for more")
    }

    @Test("a rejected token ends the session rather than showing an error nobody can act on")
    func unauthorizedIsHandled() async {
        let handled = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let store = MediaLibraryStore(
            pageSize: 2,
            onUnauthorized: { _ in
                handled.set(true)
                return .endedSession
            }
        )
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(handled.get(), "a 401 did not reach the session")
        #expect(store.items.isEmpty)
        #expect(store.lastError != nil, "the failure was swallowed")
    }

    /// A jump to a day (MEMNG-587) reads the same endpoint with the same credential, so its refusal
    /// takes the same one way to the session rather than a way of its own.
    @Test("a rejected token on a jump reaches the session the way a refresh's does")
    func unauthorizedJumpIsHandled() async {
        let handled = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }
        let store = MediaLibraryStore(
            onUnauthorized: { _ in
                handled.set(true)
                return .endedSession
            }
        )
        await store.jump(
            toDay: "2026-09-26", in: "Europe/Zurich", using: client.handle, baseURL: Stub.baseURL)

        #expect(handled.get(), "a 401 on a jump did not reach the session")
        #expect(store.items.isEmpty)
        #expect(store.landing == nil)
        #expect(store.lastError != nil, "the failure was swallowed")
    }

    @Test("a tier URL is resolved against the server, and a list row has no duration to show")
    func rowsMapOntoTheSharedAttachmentModel() async throws {
        let client = Stub.client { _, _, _ in
            Self.page([Self.item(uid: "a", mime: "video/mp4")])
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let row = try #require(store.items.first?.attachment)
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.map(\.attachment.memoUID) == ["memo-7", nil])
    }

    // MARK: - MEMNG-585: what a list row knows that the file model does not

    /// The filenames are deliberately NOT derived from the uid, and one is not a plain word: a row
    /// that rebuilt its name from anything but the wire field, or escaped it on the way, would
    /// otherwise still pass.
    @Test("a row keeps when it was taken, whose it is and what it is called, around the same file")
    func rowsKeepTheListFields() async throws {
        let wire = [
            Self.item(uid: "a", filename: "IMG_0001.HEIC"),
            Self.item(
                uid: "b",
                mime: "video/mp4",
                memoUid: "memo-7",
                mine: false,
                takenAt: "2025-01-02T03:04:05Z",
                filename: "Strand & Meer 2025.mov"
            ),
        ]
        let client = Stub.client { _, _, _ in Self.page(wire) }
        let store = MediaLibraryStore(pageSize: 10)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.map(\.id) == ["a", "b"])
        #expect(store.items.map(\.mine) == [true, false], "someone else's file read as mine")
        #expect(store.items.map(\.filename) == ["IMG_0001.HEIC", "Strand & Meer 2025.mov"])
        #expect(
            store.items.map(\.takenAt) == [
                Date(timeIntervalSince1970: 1_790_416_800),
                Date(timeIntervalSince1970: 1_735_787_045),
            ]
        )
        // The file itself is exactly what the list conversion made of the row before it had
        // anything around it: the tile, the loader and the viewer read this and nothing else.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let expected = try wire.map {
            MemoAttachment(
                try decoder.decode(Components.Schemas.AttachmentListItem.self, from: Data($0.utf8)),
                baseURL: Stub.baseURL
            )
        }
        #expect(store.items.map(\.attachment) == expected)
    }

    /// Rows are merged by the FILE, not by the whole row: a file that comes back on the next page
    /// with other fields is still the one file, and the row already on screen stays as it is.
    @Test("an overlapping row is kept once, as the page that brought it first had it")
    func overlappingRowKeepsItsFirstFields() async {
        let client = Stub.client { request, _, _ in
            if (request.path ?? "").contains("cursor=") {
                return Self.page([
                    Self.item(uid: "b", mine: false, filename: "renamed.jpg"),
                    Self.item(uid: "c"),
                ])
            }
            return Self.page(
                [Self.item(uid: "a"), Self.item(uid: "b", filename: "first.jpg")],
                nextCursor: "page-2"
            )
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.map(\.id) == ["a", "b", "c"], "the overlapping row was merged twice")
        #expect(store.items.map(\.filename) == ["a.jpg", "first.jpg", "c.jpg"])
        #expect(store.items.map(\.mine) == [true, true, true])
    }

    // MARK: - MEMNG-190: which end of the library the grid starts at

    /// Both directions are sorted by when the picture was TAKEN (MEMNG-585): the month sections
    /// the grid draws are calendar months of `takenAt`, and a list sorted by upload would scatter
    /// one month's photographs across the library. The plain `desc`/`asc` the server also accepts
    /// sort by upload, so each is asserted absent beside the one that must be there.
    @Test("the direction chosen is the direction asked for, by when the picture was taken")
    func orderRidesOnTheRequest() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]))
        }
        let newest = MediaLibraryStore(pageSize: 2)
        await newest.refresh(using: client.handle, baseURL: Stub.baseURL)
        let newestPath = paths.get().last ?? ""
        #expect(newestPath.contains("order=taken_desc"), "newest-first did not ask for taken_desc")
        #expect(!newestPath.contains("order=desc"), "newest-first asked for upload order")

        let oldest = MediaLibraryStore(pageSize: 2, order: .oldestFirst)
        await oldest.refresh(using: client.handle, baseURL: Stub.baseURL)
        let oldestPath = paths.get().last ?? ""
        #expect(oldestPath.contains("order=taken_asc"), "Oldest First did not ask for taken_asc")
        #expect(!oldestPath.contains("order=asc"), "Oldest First asked for upload order")
        #expect(
            !oldestPath.contains("order=taken_desc"),
            "the newest-first direction was sent for a store reading the other way"
        )
    }

    /// The contract: a cursor is resent "with the same `type`, `tag`, `limit` and `order`". The
    /// token is opaque, so it goes back byte for byte — the one here carries characters a query
    /// encoder would escape, and the decoded value is what the server has to see again.
    @Test("a continuation repeats its lineage's limit, direction and cursor unchanged")
    func continuationRepeatsTheLineage() async throws {
        let paths = LockedValue<[String]>([])
        let token = "t0k/en+=="
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if path.contains("cursor=") {
                return Self.page(Self.uids(["d"]))
            }
            return Self.page(Self.uids(["a", "b", "c"]), nextCursor: token)
        }
        let store = MediaLibraryStore(pageSize: 3, order: .oldestFirst)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.items.map(\.id) == ["a", "b", "c", "d"], "control: the continuation landed")
        let sent = paths.get()
        try #require(sent.count == 2)
        let first = try #require(URLComponents(string: sent[0])?.queryItems)
        let next = try #require(URLComponents(string: sent[1])?.queryItems)
        func value(_ name: String, in items: [URLQueryItem]) -> String? {
            items.first { $0.name == name }?.value
        }
        #expect(value("limit", in: first) == "3")
        #expect(value("limit", in: next) == "3", "the continuation changed the page size")
        #expect(value("order", in: next) == "taken_asc", "the continuation changed the direction")
        #expect(value("cursor", in: next) == token, "the header's token did not go back unchanged")
        #expect(value("cursor", in: first) == nil, "control: a first page carries no cursor")
    }

    @Test("turning the library round empties the grid and forgets the cursor")
    func changingOrderResetsThePaging() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.attachment.uid) == ["a"])

        store.setOrder(.oldestFirst)
        #expect(store.items.isEmpty, "the old direction's rows stayed on screen under the new one")
        #expect(store.hasMore, "a direction nobody has read yet cannot be at its end")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let last = paths.get().last ?? ""
        #expect(last.contains("order=taken_asc"))
        // The cursor is a position inside ONE ordering; carried across a reversal it pages the
        // wrong way through the middle of the library.
        #expect(
            !last.contains("cursor="),
            "the old direction's cursor was carried into the new one"
        )
    }

    /// The tab is not torn down on a subject swap — the signed-in root keeps its state — so
    /// without this the outgoing account's photographs stay on screen under the incoming one.
    @Test("signing in as somebody else empties the grid and forgets the cursor")
    func identityChangeResetsTheGrid() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1, order: .oldestFirst)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(
            store.items.map(\.attachment.uid) == ["a"],
            "the premise: the outgoing account had rows"
        )

        let asked = paths.get().count
        store.sessionIdentityChanged()

        // Asked to page on, the store must have nothing to page WITH. A refresh cannot show this
        // — it sends no cursor whether or not one was kept — so the paging call is the question,
        // and a request that goes out at all is the outgoing account's position being walked on
        // under the incoming one.
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(
            paths.get().count == asked,
            "the outgoing account's cursor was still there to be paged on"
        )
        #expect(store.items.isEmpty, "the outgoing account's files stayed under the incoming one")
        #expect(store.hasMore, "an account nobody has read yet cannot be at the end of its files")
        // Which end of the library is first is a choice about this screen, not about the account.
        #expect(store.order == .oldestFirst, "the swap turned the grid round under the person")
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
            if path.contains("order=taken_asc") {
                return Self.page(Self.uids(["oldest"]))
            }
            return Self.page(Self.uids(["a"]), nextCursor: "page-2")
        }
        let store = MediaLibraryStore(pageSize: 1)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        store.setOrder(.oldestFirst)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        release.signal()
        await inFlight.value

        #expect(
            store.items.map(\.attachment.uid) == ["oldest"],
            "the superseded page was merged anyway"
        )
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
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(requests.count == 1)

        let inFlight = Task { await store.loadMore(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        // This is the swipe that lands while the fetch it triggered is still out. The trigger has
        // to say no, or one flick through the end of a loaded run fires a request per page.
        #expect(!store.shouldLoadMore(after: 1, lookahead: 1), "the trigger fired during a load")
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(requests.count == 2, "a second request went out while one was in flight")

        release.signal()
        await inFlight.value
        #expect(store.items.map(\.attachment.uid) == ["a", "b", "c", "d"])
    }

    /// The banner owns what an unreachable server says, and a sentence the server's own answer left
    /// behind is not about a request that never reached it: left standing, the grid explains this
    /// failure with the last one's words.
    @Test("a refresh that never reached the server takes the last answer's sentence down")
    func transportFailureClearsTheAnsweredSentence() async {
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count > 1 else { return Stub.empty(.internalServerError) }
            throw URLError(.notConnectedToInternet)
        }
        let store = MediaLibraryStore(pageSize: 2)
        let session = ReportingSink(for: client.handle)
        store.reports(to: session)

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError != nil, "the premise: the server's own answer wrote a sentence")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)

        #expect(store.lastError == nil, "a server that never answered kept the 500's words")
        #expect(session.transportFailures == [.offline], "the session was never told")
    }

    /// The witness against the cheaper rule that passes the case above. Clearing the sentence when
    /// a refresh BEGINS blanks an answer the server really gave while the next request is still in
    /// the air, so the grid goes quiet about a 500 that nothing has replaced yet.
    @Test("the answered sentence stands until the request that never arrived has failed")
    func theAnsweredSentenceStandsWhileTheNextRefreshIsOut() async {
        let entered = Signal()
        let release = Signal()
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count > 1 else { return Stub.empty(.internalServerError) }
            entered.signal()
            await release.wait()
            throw URLError(.notConnectedToInternet)
        }
        let store = MediaLibraryStore(pageSize: 2)
        let session = ReportingSink(for: client.handle)
        store.reports(to: session)

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError != nil, "the premise: the server's own answer wrote a sentence")

        let inFlight = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        // Resumes at the moment the second request ENTERS the transport, so what is read below is
        // read with that request provably still out.
        await entered.wait()
        #expect(
            store.lastError != nil,
            "the answer's sentence went when a request left rather than when one failed"
        )

        release.signal()
        await inFlight.value

        #expect(store.lastError == nil, "a server that never answered kept the 500's words")
        #expect(
            session.transportFailures == [.offline],
            "control: the held request really did fail at the transport"
        )
    }
}

/// The session as the reporting stores see it, held still so a test can read back what it was told.
///
/// The protocol rather than a whole `SessionStore` (`SessionReporting`): what is asserted here is
/// that the failure reached the sink at all, and a session brings a sign-in, a credential and a
/// verification state that say nothing about that.
private final class ReportingSink: SessionReporting {
    let activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()
    private(set) var transportFailures: [ServerReachability.Reason] = []

    init(for handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }

    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool { true }

    func noteTransportFailure(
        _ failure: ServerReachability.Reason,
        issuedUnder generation: Int
    ) {
        transportFailures.append(failure)
    }

    func noteTransportSuccess(issuedUnder generation: Int) {}
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
