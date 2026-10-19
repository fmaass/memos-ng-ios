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
@Suite("Viewer context store", .timeLimit(.minutes(1)))
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

    @Test("a file record is read once per opening, holds the size and the capture fields")
    func factsAreReadOncePerOpening() async {
        let sent = Box<Int>(0)
        let client = Stub.client { _, _, operation in
            #expect(operation == "attachment_meta_api_attachments__uid__get")
            sent.value += 1
            return Stub.json(fileRecord(size: 2048))
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        let first = store.open("p1")
        await store.loadFacts(for: first, using: handle)
        await store.loadFacts(for: first, using: handle)
        #expect(sent.value == 1, "one opening asked twice")
        #expect(store.facts(for: first)?.size == 2048)
        #expect(store.facts(for: first)?.captureCivil == "2026-01-01T13:00:00")

        store.close(first)
        #expect(store.facts(for: first) == nil, "a closed opening still shows its record")
        let second = store.open("p1")
        await store.loadFacts(for: second, using: handle)
        #expect(sent.value == 2, "a new opening did not read the record again")
    }

    @Test("a record still in the air when its sheet closes lands nowhere, even after a reopen")
    func closedOpeningsLateAnswerIsDropped() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let sent = Box<Int>(0)
        let client = Stub.client { _, _, _ in
            sent.value += 1
            guard sent.value == 1 else { return Stub.json(fileRecord(size: 2)) }
            started.continuation.yield()
            for await _ in gate.stream { break }
            return Stub.json(fileRecord(size: 1))
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        let first = store.open("p1")
        let late = Task { await store.loadFacts(for: first, using: handle) }
        for await _ in started.stream { break }
        store.close(first)
        let second = store.open("p1")
        await store.loadFacts(for: second, using: handle)
        #expect(sent.value == 2, "the reopened sheet joined the closed one's read")
        #expect(store.facts(for: second)?.size == 2)

        gate.continuation.yield()
        gate.continuation.finish()
        await late.value
        #expect(store.facts(for: second)?.size == 2, "the closed opening's answer replaced it")
        #expect(store.facts(for: first) == nil)
    }

    @Test("nothing is read for an opening that has already closed")
    func closedOpeningStartsNothing() async {
        let sent = Box<Int>(0)
        let client = Stub.client { _, _, _ in
            sent.value += 1
            return Stub.json(fileRecord(size: 1))
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        let opening = store.open("p1")
        store.close(opening)
        await store.loadFacts(for: opening, using: handle)
        #expect(sent.value == 0, "a dismissed sheet's record was asked for")
    }

    @Test("two overlapping asks for one memo are one request")
    func overlappingAsksJoin() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let sent = Box<Int>(0)
        let client = Stub.client { _, _, _ in
            sent.value += 1
            started.continuation.yield()
            for await _ in gate.stream { break }
            return Stub.json(Stub.memo(uid: "m1"))
        }
        let store = MediaContextStore()
        let handle = SessionHandle(client: client, generation: 1)

        let one = Task { await store.loadMemo(uid: "m1", using: handle, baseURL: Stub.baseURL) }
        for await _ in started.stream { break }
        let two = Task { await store.loadMemo(uid: "m1", using: handle, baseURL: Stub.baseURL) }
        for _ in 0..<20 { await Task.yield() }
        gate.continuation.yield()
        gate.continuation.finish()
        await one.value
        await two.value
        #expect(sent.value == 1, "two overlapping asks sent \(sent.value) requests")
        #expect(store.memo("m1")?.uid == "m1")
    }

    @Test("a memo held for one account is never another's: the session moving is enough")
    func heldMemoFollowsTheSession() async {
        let sent = Box<[String]>([])
        let client = Stub.client { _, _, operation in
            sent.value.append(operation)
            return Stub.json(Stub.memo(uid: "m1", content: sent.value.count == 1 ? "A" : "B"))
        }
        let first = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: first)
        let store = MediaContextStore()
        store.reports(to: session)

        await store.loadMemo(uid: "m1", using: first, baseURL: Stub.baseURL)
        #expect(store.memo("m1")?.content == "A")

        // Another account signs in. Nobody tells the store.
        let second = SessionHandle(client: client, generation: 2)
        session.activeHandle = second
        #expect(store.memo("m1") == nil, "the first account's memo is still handed out")

        await store.loadMemo(uid: "m1", using: first, baseURL: Stub.baseURL)
        #expect(sent.value.count == 1, "the departed session's handle still reads")

        await store.loadMemo(uid: "m1", using: second, baseURL: Stub.baseURL)
        #expect(sent.value.count == 2, "the new account was handed the old one's memo")
        #expect(store.memo("m1")?.content == "B")
    }

    @Test("a memo read in the air for one account is not joined by the next")
    func flightIsNotJoinedAcrossSessions() async {
        let started = AsyncStream<Void>.makeStream()
        let gate = AsyncStream<Void>.makeStream()
        let sent = Box<Int>(0)
        let client = Stub.client { _, _, _ in
            sent.value += 1
            guard sent.value == 1 else { return Stub.json(Stub.memo(uid: "m1", content: "B")) }
            started.continuation.yield()
            for await _ in gate.stream { break }
            return Stub.json(Stub.memo(uid: "m1", content: "A"))
        }
        let first = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: first)
        let store = MediaContextStore()
        store.reports(to: session)

        let late = Task { await store.loadMemo(uid: "m1", using: first, baseURL: Stub.baseURL) }
        for await _ in started.stream { break }
        let second = SessionHandle(client: client, generation: 2)
        session.activeHandle = second
        await store.loadMemo(uid: "m1", using: second, baseURL: Stub.baseURL)
        #expect(sent.value == 2, "the new account joined the old account's read")

        gate.continuation.yield()
        gate.continuation.finish()
        await late.value
        #expect(store.memo("m1")?.content == "B", "the old account's late memo landed")
    }
}

private func fileRecord(size: Int) -> String {
    """
    {"uid":"p1","mime":"image/png","size":\(size),"sha256":null,"status":"ready",\
    "width":10,"height":20,"duration":null,"blurhash":null,"captured_at":null,\
    "capture_instant":null,"capture_civil":"2026-01-01T13:00:00",\
    "capture_source":"exif","mine":true,"hasPrint":false,"hasLegacyPrint":false,\
    "hasPoster":false,"renditions":[],"downloadUrl":"/a/p1/file",\
    "printUrl":"/a/p1/print","thumbnailUrl":"/a/p1/thumb","previewUrl":"/a/p1/m",\
    "webUrl":"/a/p1/web","webReady":true,"posterUrl":"/a/p1/poster"}
    """
}
