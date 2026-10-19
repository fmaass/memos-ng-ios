import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

/// One attachment of a memo payload whose capture fields and owner flag are SET — and the file
/// owner's flag false while the memo around it is the reader's own.
private let ownedElsewhere = """
    {"uid":"p1","mime":"image/jpeg","status":"ready","blurhash":null,\
    "width":1000,"height":800,"duration":null,"mine":false,"hasPrint":false,\
    "hasLegacyPrint":false,"webReady":true,"renditions":[],"position":0,\
    "sha256":null,"capture_instant":null,"capture_civil":"2026-01-01T13:00:00",\
    "capture_source":"exif",\
    "thumbnailUrl":"/api/attachments/p1/thumb","previewUrl":"/api/attachments/p1/mobile",\
    "webUrl":"/api/attachments/p1/web","posterUrl":"/api/attachments/p1/poster",\
    "downloadUrl":"/api/attachments/p1/file","printUrl":"/api/attachments/p1/print"}
    """

/// One library row: no capture fields on this payload at all, `takenAt` (a display date) set, and
/// the file not the reader's.
private let libraryRow = """
    {"uid":"l1","mime":"image/jpeg","status":"ready","blurhash":null,\
    "width":1000,"height":1000,"mine":false,"hasPrint":false,"hasLegacyPrint":false,\
    "webReady":true,"renditions":[],"tags":[],"orphan":false,"memoUid":"m9","visibility":null,\
    "takenAt":"2026-09-26T10:00:00Z","filename":"l1.jpg",\
    "thumbnailUrl":"/api/attachments/l1/thumb","previewUrl":"/api/attachments/l1/mobile",\
    "webUrl":"/api/attachments/l1/web","posterUrl":"/api/attachments/l1/poster",\
    "downloadUrl":"/api/attachments/l1/file","printUrl":"/api/attachments/l1/print"}
    """

@Suite("Viewer context: the attachment's capture fields and owner on every source")
struct MediaContextMappingTests {
    @Test("a memo payload's attachment keeps its civil clock, its source and the FILE's owner")
    func memoPayloadMapsCaptureCivilAndMine() async throws {
        let client = Stub.client { _, _, operation in
            #expect(operation == "get_memo_api_memos__uid__get")
            return Stub.json(Stub.memo(uid: "m1", attachments: [ownedElsewhere]))
        }
        let memo = try await MediaContextStore.memo(client, uid: "m1", baseURL: Stub.baseURL)

        #expect(memo.mine, "precondition: the memo is the reader's own")
        let attachment = try #require(memo.attachments.first)
        #expect(attachment.captureCivil == "2026-01-01T13:00:00")
        #expect(attachment.captureSource == "exif")
        #expect(attachment.mine == false, "the memo's flag was taken for the file's")
        #expect(attachment.captureInstant == nil)
    }

    @Test("a library row's attachment carries the file's owner and no capture date from takenAt")
    func libraryRowMapsMineAndLeavesCaptureNil() async throws {
        let client = Stub.client { _, _, _ in
            Stub.json("[" + libraryRow + "]")
        }
        let page = try await MediaLibraryStore.page(
            client, filter: .images, order: .newestFirst, tag: nil, cursor: nil, limit: 10,
            baseURL: Stub.baseURL)
        let row = try #require(page.items.first)

        #expect(row.takenAt != nil, "precondition: the row has a display date")
        #expect(row.attachment.mine == false)
        #expect(row.attachment.captureInstant == nil, "takenAt was filed as capture metadata")
        #expect(row.attachment.captureCivil == nil)
        #expect(row.attachment.captureSource == nil)
    }

    @Test("a Places marker's attachment carries the marker's owner and no capture date")
    func placeMarkerMapsMine() {
        let theirs = PlaceMarker(
            uid: "g1", memoUID: "m3", mime: "image/jpeg", mine: false, latitude: 38.7,
            longitude: -9.1, takenAt: Date(timeIntervalSince1970: 1_780_000_000))
        let attachment = MemoAttachment(theirs)
        #expect(attachment.mine == false)
        #expect(attachment.captureInstant == nil, "the marker's takenAt was filed as capture")
        #expect(attachment.captureCivil == nil)

        var mine = theirs
        mine.mine = true
        #expect(MemoAttachment(mine).mine == true, "control: the flag is read, not constant")
    }
}

@MainActor
@Suite("Viewer context store")
struct MediaContextStoreTests {
    @Test("a memo is read once per uid, however often it is asked for")
    func memoIsReadOncePerUID() async {
        let sent = Box<[String]>([])
        let client = Stub.client { _, _, operation in
            sent.value.append(operation)
            return Stub.json(Stub.memo(uid: "m1", attachments: [ownedElsewhere]))
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        await store.loadMemo(uid: "m1", using: handle, baseURL: Stub.baseURL)
        await store.loadMemo(uid: "m1", using: handle, baseURL: Stub.baseURL)

        #expect(sent.value == ["get_memo_api_memos__uid__get"])
        #expect(store.memo("m1")?.uid == "m1")
    }

    @Test("an answer issued before an identity change lands nowhere")
    func staleAnswerIsDropped() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let client = Stub.client { _, _, _ in
            started.continuation.yield()
            for await _ in gate.stream { break }
            return Stub.json(Stub.memo(uid: "m1"))
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        let read = Task { await store.loadMemo(uid: "m1", using: handle, baseURL: Stub.baseURL) }
        // The request is on the wire before the account changes under it.
        for await _ in started.stream { break }
        store.sessionIdentityChanged()
        gate.continuation.yield()
        gate.continuation.finish()
        await read.value

        #expect(store.memo("m1") == nil, "a memo read for the old account repopulated the store")
    }

    @Test("a file record is read on every ask, and holds the size and the capture fields")
    func factsAreReadPerAsk() async {
        let sent = Box<Int>(0)
        let client = Stub.client { _, _, operation in
            #expect(operation == "attachment_meta_api_attachments__uid__get")
            sent.value += 1
            return Stub.json(
                """
                {"uid":"p1","mime":"image/png","size":2048,"sha256":null,"status":"ready",\
                "width":10,"height":20,"duration":null,"blurhash":null,"captured_at":null,\
                "capture_instant":null,"capture_civil":"2026-01-01T13:00:00",\
                "capture_source":"exif","mine":true,"hasPrint":false,"hasLegacyPrint":false,\
                "hasPoster":false,"renditions":[],"downloadUrl":"/a/p1/file",\
                "printUrl":"/a/p1/print","thumbnailUrl":"/a/p1/thumb","previewUrl":"/a/p1/m",\
                "webUrl":"/a/p1/web","webReady":true,"posterUrl":"/a/p1/poster"}
                """)
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        await store.loadFacts(uid: "p1", using: handle, baseURL: Stub.baseURL)
        await store.loadFacts(uid: "p1", using: handle, baseURL: Stub.baseURL)

        #expect(sent.value == 2)
        #expect(store.facts(of: "p1")?.size == 2048)
        #expect(store.facts(of: "p1")?.captureCivil == "2026-01-01T13:00:00")
    }
}
