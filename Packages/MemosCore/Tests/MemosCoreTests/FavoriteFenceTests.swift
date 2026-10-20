import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// A favorite committed by `FavoriteStore` reaches every copy of the picture (MEMNG-867), and a
/// read that LEFT before the commit cannot put the old tags back when it lands — the fence is the
/// ledger's revision stamped at issue, separate from the credential generation, which no case
/// here moves. Every read is the real store's, through the generated client.
@MainActor
@Suite("Favorite store — copies and the fence")
struct FavoriteFenceTests {
    nonisolated static let library = "list_attachments_api_attachments_get"
    nonisolated static let memos = "list_memos_api_memos_get"
    nonisolated static let pictureTags = "attachment_picture_tags_api_attachments_picture_tags_get"
    nonisolated static let patch = "patch_memo_api_memos__uid__patch"
    nonisolated static let pin = "pin_memo_api_memos__uid__pin_post"

    private nonisolated static func names(_ tags: [String]) -> String {
        tags.map { "\"\($0)\"" }.joined(separator: ",")
    }

    /// One `AttachmentListItem` with the memo's tags and the picture's own, apart.
    nonisolated static func listItem(
        _ uid: String, pictureTags: [String], memoTags: [String] = []
    ) -> String {
        TripWire.item(uid, taken: TripWire.taken(0)).replacingOccurrences(
            of: #""tags":[]"#,
            with: #""tags":[\#(names(memoTags))],"pictureTags":[\#(names(pictureTags))]"#)
    }

    nonisolated static func rows(_ uid: String, pictureTags: [String]) -> (
        HTTPResponse, HTTPBody?
    ) {
        Stub.json("[\(listItem(uid, pictureTags: pictureTags))]")
    }

    /// A memo `m-<uid>` carrying one picture (`AttachmentRef`) with its own tags.
    nonisolated static func memo(
        _ uid: String, pictureTags: [String], content: String = "hello", pinned: Bool = false
    ) -> String {
        let reference = Stub.attachment(uid: uid, status: "ready").replacingOccurrences(
            of: #""renditions":[]"#, with: #""renditions":[],"tags":[\#(names(pictureTags))]"#)
        return Stub.memo(
            uid: "m-\(uid)", content: content, pinned: pinned, attachments: [reference])
    }

    nonisolated static func memoPage(_ uid: String, pictureTags: [String]) -> String {
        Stub.page([memo(uid, pictureTags: pictureTags)])
    }

    /// Answers a favorite write with 204 and hands every other operation to `rest`.
    private nonisolated static func server(
        _ rest: @escaping @Sendable (String) async throws -> (HTTPResponse, HTTPBody?)
    ) -> any APIProtocol {
        Stub.client { _, _, operation in
            if operation == FavoriteStoreTests.put || operation == FavoriteStoreTests.delete {
                return Stub.empty(.noContent)
            }
            return try await rest(operation)
        }
    }

    private func favorite(_ store: FavoriteStore, _ client: any APIProtocol) async {
        await store.setFavorite(
            uid: "p1", to: true, shownTags: [], using: client.handle, baseURL: Stub.baseURL
        ).value
    }

    // MARK: - every copy is told

    @Test("after a commit the timeline and the library show the new tags; the snapshot keeps them")
    func aCommitReachesEveryCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = TimelineSnapshotIdentity(server: Stub.baseURL, subject: "fabian")
        let client = Self.server { operation in
            operation == Self.memos
                ? Stub.json(Self.memoPage("p1", pictureTags: []))
                : Self.rows("p1", pictureTags: [])
        }
        let favorites = FavoriteStore()
        let timeline = TimelineStore(
            pageSize: 2,
            snapshots: TimelineSnapshotWriter(
                store: TimelineSnapshotStore(root: root), epoch: SessionEpoch()),
            snapshotIdentity: identity,
            persists: true
        )
        let library = MediaLibraryStore(pageSize: 2)
        timeline.follow(favorites)
        library.follow(favorites)
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        await library.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(timeline.memos.first?.attachments.first?.tags == [], "control: loaded unmarked")
        #expect(library.items.first?.attachment.tags == [], "control: loaded unmarked")

        await favorite(favorites, client)

        #expect(timeline.memos.first?.attachments.first?.tags == ["favorites"])
        #expect(library.items.first?.attachment.tags == ["favorites"])
        let onDisk = try #require(TimelineSnapshotStore(root: root).read(identity: identity))
        #expect(onDisk.memos.first?.attachments.first?.tags == ["favorites"])
    }

    private static func timeline(
        persistingTo root: URL, as identity: TimelineSnapshotIdentity
    ) -> TimelineStore {
        TimelineStore(
            pageSize: 2,
            snapshots: TimelineSnapshotWriter(
                store: TimelineSnapshotStore(root: root), epoch: SessionEpoch()),
            snapshotIdentity: identity,
            persists: true
        )
    }

    // MARK: - the fence

    @Test("a library page held open across a commit lands with the favorite, no credential moved")
    func aHeldLibraryPageIsFenced() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { _ in
            entered.open()
            _ = await release.wait()
            return Self.rows("p1", pictureTags: [])
        }
        let favorites = FavoriteStore()
        let library = MediaLibraryStore(pageSize: 2)
        library.follow(favorites)
        let reading = Task { await library.refresh(using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no page was asked for")
        await favorite(favorites, client)
        release.open()
        await reading.value

        #expect(library.items.map(\.id) == ["p1"], "control: the page landed")
        #expect(library.items.first?.attachment.tags == ["favorites"], "the stale page won")
    }

    @Test("a reissue walk held open across a commit leaves the row favorited")
    func aHeldReissueIsFenced() async {
        let reads = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { _ in
            reads.set(reads.get() + 1)
            if reads.get() == 2 {
                entered.open()
                _ = await release.wait()
            }
            return Self.rows("p1", pictureTags: [])
        }
        let favorites = FavoriteStore()
        let library = MediaLibraryStore(pageSize: 2)
        library.follow(favorites)
        await library.refresh(using: client.handle, baseURL: Stub.baseURL)
        let walking = Task {
            await library.reissue(uids: ["p1"], using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no reissue page was asked for")
        await favorite(favorites, client)
        #expect(library.items.first?.attachment.tags == ["favorites"], "control: the commit")
        release.open()
        await walking.value

        #expect(reads.get() == 2)
        #expect(library.items.first?.attachment.tags == ["favorites"], "the reissued row won")
    }

    @Test("a tag collection's drain held open across a commit lands with the favorite")
    func aHeldTagDrainIsFenced() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { _ in
            entered.open()
            _ = await release.wait()
            return Self.rows("p1", pictureTags: [])
        }
        let favorites = FavoriteStore()
        let (_, members) = await TripSeeder().members()
        members.follow(favorites)
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let draining = Task {
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no member page was asked for")
        await favorite(favorites, client)
        release.open()
        await draining.value

        #expect(members.members(for: scope).map(\.id) == ["p1"], "control: the drain landed")
        #expect(members.members(for: scope).first?.attachment.tags == ["favorites"])
    }

    // MARK: - the timeline's own writes (round 1, finding 1)

    @Test("a refused tick held across a commit rolls back WITH the favorite, in memory and on disk")
    func aRefusedTickRollsBackWithTheFavorite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = TimelineSnapshotIdentity(server: Stub.baseURL, subject: "fabian")
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { operation in
            switch operation {
            case Self.memos:
                return Stub.json(Stub.page([Self.memo("p1", pictureTags: [], content: "- [ ] a")]))
            case Self.patch:
                entered.open()
                _ = await release.wait()
                return Stub.empty(.internalServerError)
            default:
                return Self.rows("p1", pictureTags: [])
            }
        }
        let favorites = FavoriteStore()
        let timeline = Self.timeline(persistingTo: root, as: identity)
        timeline.follow(favorites)
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        let ticking = Task {
            await timeline.toggleTask(
                at: 0, in: "m-p1", using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no tick was sent")
        await favorite(favorites, client)
        #expect(timeline.memos.first?.attachments.first?.tags == ["favorites"], "control: commit")
        release.open()

        #expect(await ticking.value == false, "control: the tick was refused")
        #expect(timeline.memos.first?.content == "- [ ] a", "control: the tick rolled back")
        #expect(timeline.memos.first?.attachments.first?.tags == ["favorites"], "favorite erased")
        let onDisk = try #require(TimelineSnapshotStore(root: root).read(identity: identity))
        #expect(onDisk.memos.first?.attachments.first?.tags == ["favorites"], "erased on disk")
    }

    @Test("a pin answer held across a commit lands with the favorite")
    func aHeldPinAnswerKeepsTheFavorite() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { operation in
            switch operation {
            case Self.memos:
                return Stub.json(Self.memoPage("p1", pictureTags: []))
            case Self.pin:
                entered.open()
                _ = await release.wait()
                return Stub.json(Self.memo("p1", pictureTags: [], pinned: true))
            default:
                return Self.rows("p1", pictureTags: [])
            }
        }
        let favorites = FavoriteStore()
        let timeline = TimelineStore(pageSize: 2)
        timeline.follow(favorites)
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        let pinning = Task {
            await timeline.setPinned(true, uid: "m-p1", using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no pin was sent")
        await favorite(favorites, client)
        release.open()

        #expect(await pinning.value, "control: the pin was saved")
        #expect(timeline.memos.first?.pinned == true, "control: the answer landed")
        #expect(timeline.memos.first?.attachments.first?.tags == ["favorites"], "favorite erased")
    }

    @Test("a snapshot older than a commit is restored with the favorite")
    func aRestoredSnapshotTakesTheLedger() async {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = TimelineSnapshotIdentity(server: Stub.baseURL, subject: "fabian")
        let client = Self.server { operation in
            operation == Self.memos
                ? Stub.json(Self.memoPage("p1", pictureTags: []))
                : Self.rows("p1", pictureTags: [])
        }
        await Self.timeline(persistingTo: root, as: identity)
            .refresh(using: client.handle, baseURL: Stub.baseURL)
        let favorites = FavoriteStore()
        let timeline = Self.timeline(persistingTo: root, as: identity)
        timeline.follow(favorites)
        await favorite(favorites, client)
        await timeline.restoreSnapshot()

        #expect(timeline.memos.map(\.uid) == ["m-p1"], "control: the snapshot was restored")
        #expect(timeline.memos.first?.attachments.first?.tags == ["favorites"], "the file won")
    }

    // MARK: - picture counts

    @Test("picture counts read before a commit are discarded and read again exactly once")
    func aStaleCountIsReadAgainOnce() async {
        let reads = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { _ in
            reads.set(reads.get() + 1)
            if reads.get() == 1 {
                entered.open()
                _ = await release.wait()
                return Stub.json(#"[{"name":"trip","count":2}]"#)
            }
            return Stub.json(#"[{"name":"favorites","count":1},{"name":"trip","count":2}]"#)
        }
        let favorites = FavoriteStore()
        let counts = PictureTagStore()
        counts.follow(favorites)
        let reading = Task { await counts.load(for: .all, using: client.handle) }
        #expect(await entered.wait(), "no count was asked for")
        await favorite(favorites, client)
        #expect(counts.isStale, "a commit did not mark the counts stale")
        release.open()
        await reading.value

        #expect(reads.get() == 2, "the stale answer was not re-requested exactly once")
        #expect(counts.tags.map(\.name) == ["favorites", "trip"])
        #expect(!counts.isStale)
    }

    @Test("a count that is stale again after its one re-read is not shown, and stays stale")
    func aSecondStaleCountIsNotShown() async {
        let reads = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server { _ in
            reads.set(reads.get() + 1)
            entered.open()
            _ = await release.wait()
            return Stub.json(#"[{"name":"favorites","count":\#(reads.get())}]"#)
        }
        let favorites = FavoriteStore()
        let counts = PictureTagStore()
        counts.follow(favorites)
        let reading = Task { await counts.load(for: .all, using: client.handle) }
        #expect(await entered.wait(), "no count was asked for")
        await favorite(favorites, client)
        release.open()
        #expect(await entered.wait(), "the stale count was not read again")
        await favorites.setFavorite(
            uid: "p1", to: false, shownTags: [], using: client.handle, baseURL: Stub.baseURL
        ).value
        release.open()
        await reading.value

        #expect(reads.get() == 2, "the count was read more than once again")
        #expect(favorites.revision == 2, "control: two commits")
        #expect(counts.tags.isEmpty, "a count known to be stale was shown")
        #expect(counts.isStale)
    }

    @Test("picture counts with no commit in between are read once (control)")
    func aCurrentCountIsReadOnce() async {
        let log = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            log.set(log.get() + ["\(operation) \(request.path ?? "")"])
            return Stub.json(#"[{"name":"favorites","count":1}]"#)
        }
        let counts = PictureTagStore()
        counts.follow(FavoriteStore())
        await counts.load(for: .videos, using: client.handle)

        #expect(log.get().count == 1)
        #expect(log.get().first?.hasPrefix(Self.pictureTags) == true, "\(log.get())")
        #expect(log.get().first?.contains("/api/attachments/picture-tags") == true)
        #expect(log.get().first?.contains("type=video") == true)
        #expect(counts.tags == [LibraryTag(name: "favorites", count: 1)])
    }

    // MARK: - the four payload shapes

    @Test("AttachmentRef: a memo's picture carries its own tags")
    func referenceTags() async {
        let client = Stub.client { _, _, _ in
            Stub.json(Self.memoPage("p1", pictureTags: ["favorites", "trip"]))
        }
        let timeline = TimelineStore(pageSize: 2)
        await timeline.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(timeline.memos.first?.attachments.first?.tags == ["favorites", "trip"])
    }

    @Test("AttachmentListItem: the row reads pictureTags, never the memo's tags")
    func listItemTags() async {
        let client = Stub.client { _, _, _ in
            Stub.json("[\(Self.listItem("p1", pictureTags: ["favorites"], memoTags: ["trip"]))]")
        }
        let library = MediaLibraryStore(pageSize: 2)
        await library.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(library.items.map(\.id) == ["p1"], "control: the row decoded")
        #expect(library.items.first?.attachment.tags == ["favorites"])
    }

    @Test("AttachmentMeta: a picture's own record carries its own tags")
    func metaTags() async throws {
        let client = Stub.client { _, _, _ in
            Stub.json(FavoriteStoreTests.record("p1", tags: ["favorites"]))
        }
        let read = try await TripMemberStore.attachment(client, uid: "p1", baseURL: Stub.baseURL)
        #expect(read.tags == ["favorites"])
    }

    @Test("MapMarker: a pin, and the viewer attachment it opens, carry the picture's own tags")
    func markerTags() async throws {
        let marker = """
            {"uid":"p1","mime":"image/jpeg","status":"ready","blurhash":null,"width":1000,\
            "height":800,"duration":null,"sha256":null,"capture_instant":null,\
            "capture_civil":null,"capture_source":null,"mine":true,"hasPrint":false,\
            "hasLegacyPrint":false,"webReady":true,"renditions":[],"position":null,\
            "thumbnailUrl":"/api/attachments/p1/thumb","previewUrl":"/api/attachments/p1/mobile",\
            "webUrl":"/api/attachments/p1/web","posterUrl":"/api/attachments/p1/poster",\
            "downloadUrl":"/api/attachments/p1/download","printUrl":"/api/attachments/p1/print",\
            "memo_uid":"m1","latitude":47.37,"longitude":8.54,"taken_at":"2026-09-18T10:11:12Z",\
            "tags":["favorites"]}
            """
        let client = Stub.client { _, _, _ in Stub.json("{\"markers\":[\(marker)]}") }
        let pins = try await PlacesStore.markers(client, baseURL: Stub.baseURL)
        #expect(pins.map(\.uid) == ["p1"], "control: the marker decoded")
        #expect(pins.first?.tags == ["favorites"])
        #expect(pins.first.map { MemoAttachment($0).tags } == ["favorites"])
    }
}
