import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

@testable import MemosFeatures

/// MEMNG-869, Favorites and Info 2/4: the Info sheet filled from the file record — Where, Camera,
/// the File row's filename and Added by — and the record read once per file for the viewer.
private func file(_ uid: String, memoUID: String? = nil) -> MemoAttachment {
    MemoAttachment(
        uid: uid, mime: "image/jpeg", status: .ready, width: 1000, height: 800,
        thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/thumb"),
        memoUID: memoUID)
}

private let lisbon = AttachmentFacts(
    uid: "a", mime: "image/jpeg", size: 2048, latitude: 38.71, longitude: -9.14)
private let iphone = CameraFacts(
    make: "Apple", model: "iPhone 16 Pro", lensModel: "iPhone 16 Pro back camera",
    fNumber: 1.78, exposureTime: 0.0167, focalLength: 6.765, exposureBias: 0, iso: 80)

@MainActor
@Suite("Info sheet rows")
struct MediaInfoRowsTests {
    @Test(
        "which sections show, for located × camera × orphan",
        arguments: [false, true], [false, true])
    func rowPresenceMatrix(located: Bool, withCamera: Bool) throws {
        for orphan in [false, true] {
            let facts = AttachmentFacts(
                uid: "a", mime: "image/jpeg", size: 2048,
                latitude: located ? 38.71 : nil, longitude: located ? -9.14 : nil,
                camera: withCamera ? iphone : nil)
            let page = try #require(
                MediaViewerPresentation.pages(for: [file("a", memoUID: orphan ? nil : "m1")])
                    .first)
            let context = MediaViewerContext.resolve(page, carried: nil)
            let found = Memo(
                uid: "m1", owner: "fabian", mine: true, content: "Lisbon", visibility: .private,
                pinned: false, createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0))
            let card = MediaInfoRows.memoCard(context.memo, looked: found)

            var expected: [MediaInfoRows.Section] = [.taken]
            if !orphan { expected.append(.memo) }
            if located { expected.append(.location) }
            expected.append(.file)
            if withCamera { expected.append(.camera) }
            let shown = MediaInfoRows.sections(
                memo: card, location: MediaInfoRows.location(facts),
                camera: MediaInfoRows.camera(facts.camera))
            #expect(shown == expected, "located \(located) camera \(withCamera) orphan \(orphan)")
        }
    }

    @Test("a camera record with no usable field shows no Camera section")
    func emptyCameraIsNoSection() {
        #expect(MediaInfoRows.camera(CameraFacts()) == nil)
        #expect(MediaInfoRows.camera(nil) == nil)
        let lensOnly = MediaInfoRows.camera(CameraFacts(lensModel: "50mm"))
        #expect(lensOnly == MediaInfoRows.Camera(device: nil, lens: "50mm", exposure: nil))
    }

    @Test("the three camera lines")
    func cameraLines() throws {
        let camera = try #require(MediaInfoRows.camera(iphone))
        #expect(camera.device == "Apple iPhone 16 Pro")
        #expect(camera.lens == "iPhone 16 Pro back camera · 6.8 mm · ƒ1.8")
        #expect(camera.exposure == "ISO 80 · 6.8 mm · 0 ev · ƒ1.8 · 1/60 s")
    }

    @Test("shutter speeds read as a photographer writes them")
    func shutterFormatting() {
        #expect(MediaInfoRows.shutter(0.0167) == "1/60 s")
        #expect(MediaInfoRows.shutter(2.0) == "2 s")
        #expect(MediaInfoRows.shutter(0.5) == "1/2 s")
        #expect(MediaInfoRows.shutter(2.5) == "2.5 s")
    }

    @Test("exposure bias to a tenth of a stop")
    func biasFormatting() {
        #expect(MediaInfoRows.bias(0) == "0 ev")
        #expect(MediaInfoRows.bias(-0.3) == "-0.3 ev")
        #expect(MediaInfoRows.bias(-0.33) == "-0.3 ev")
        #expect(MediaInfoRows.bias(-0.01) == "0 ev", "no negative zero")
    }

    @Test("the Taken source says the photo's clock or the upload")
    func takenSourceWording() {
        #expect(MediaInfoRows.takenSource("exif") == "from the photo's clock")
        #expect(MediaInfoRows.takenSource("quicktime") == "from the photo's clock")
        #expect(MediaInfoRows.takenSource(nil) == "from the upload")
        #expect(MediaInfoRows.takenSource("upload") == "from the upload")
    }

    @Test("the File row carries the record's filename and who added it")
    func fileRowFilenameAndAddedBy() {
        var record = lisbon
        record.filename = "IMG_0001.HEIC"
        record.addedBy = "fabian"
        let row = MediaInfoRows.file(file("a"), facts: record)
        #expect(row.filename == "IMG_0001.HEIC")
        #expect(row.addedBy == "fabian")
        #expect(MediaInfoRows.file(file("a"), facts: nil).filename == nil)
    }

    @Test("a file's place name is looked up once, however often its sheet opens")
    func placeNameLookedUpOnce() async {
        let asked = Box(0)
        let cache = PlaceNameCache { _ in
            asked.value += 1
            return "Lisbon"
        }
        let location = MediaInfoRows.Location(latitude: 38.71, longitude: -9.14)
        await cache.lookUp("a", at: location)
        await cache.lookUp("a", at: location)
        #expect(asked.value == 1)
        #expect(cache.name(for: "a") == "Lisbon")
        await cache.lookUp("b", at: location)
        #expect(asked.value == 2, "control: another file is its own lookup")
    }
}

/// The file record's server, its answer held until the test lets it go. The record carries a
/// location, a camera, a filename and who added it.
final class GatedRecordTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []
    private let asked = AsyncStream<Void>.makeStream()
    private let gate = AsyncStream<Void>.makeStream()
    private var failing = false

    /// From now on every request fails before it reaches the server's answer: a lost connection.
    func fail(_ on: Bool) { lock.withLock { failing = on } }

    func count(_ operation: String) -> Int {
        lock.withLock { operations.filter { $0 == operation }.count }
    }

    func recordAsked() async { for await _ in asked.stream { break } }

    func release() {
        gate.continuation.yield()
        gate.continuation.finish()
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { operations.append(operationID) }
        if lock.withLock({ failing }) { throw URLError(.networkConnectionLost) }
        if operationID == "add_picture_tag_api_attachments__uid__tags__name__put" {
            return (HTTPResponse(status: .noContent), nil)
        }
        guard operationID == "attachment_meta_api_attachments__uid__get" else {
            return (HTTPResponse(status: .notFound), nil)
        }
        asked.continuation.yield()
        for await _ in gate.stream { break }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (
            response,
            HTTPBody(
                """
                {"uid":"a","mime":"image/jpeg","size":2048,"sha256":null,"status":"ready",\
                "width":4000,"height":3000,"duration":null,"blurhash":null,\
                "captured_at":null,"capture_instant":null,"capture_civil":null,\
                "capture_source":null,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
                "hasPoster":false,"renditions":[],"downloadUrl":"/a/a/file",\
                "printUrl":"/a/a/print","thumbnailUrl":"/a/a/thumb","previewUrl":"/a/a/m",\
                "webUrl":"/a/a/web","webReady":true,"posterUrl":"/a/a/poster",\
                "filename":"IMG_0001.HEIC","latitude":38.71,"longitude":-9.14,\
                "locationSource":"exif","addedBy":"fabian","tags":[],\
                "camera":{"make":"Apple","model":"iPhone 16 Pro",\
                "lensModel":"iPhone 16 Pro back camera","fNumber":1.78,\
                "exposureTimeS":0.0167,"focalLengthMm":6.765,"exposureBiasEv":0,"iso":80}}
                """)
        )
    }
}

@MainActor
@Suite("Info sheet record reads", .timeLimit(.minutes(1)))
struct MediaInfoRecordReadTests {
    private let base = URL(string: "https://memos.example.invalid")!
    private let record = "attachment_meta_api_attachments__uid__get"

    private func handle(_ transport: some ClientTransport, generation: Int = 1) -> SessionHandle {
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_info" },
            transport: transport)
        return SessionHandle(client: client, generation: generation)
    }

    @Test("one record read per file: paging away and back and opening again asks nothing")
    func oneReadPerFileAcrossSwipes() async throws {
        let transport = GatedRecordTransport()
        transport.release()
        let session = handle(transport)
        let store = MediaContextStore()
        let pages = MediaViewerPresentation.pages(for: [file("a"), file("b")])
        let first = try #require(pages.first)
        let context = MediaViewerContext.resolve(first, carried: nil)

        // Open on a, close, page to b and back to a — the pager never reads — and open again.
        for _ in 0..<2 {
            let opening = store.open(first.attachment.uid)
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: session, baseURL: base)
            #expect(store.facts(for: opening)?.width == 4000)
            store.close(opening)
        }
        #expect(transport.count(record) == 1)

        // The mapping of the v2.4.0 fields, read off the same record.
        let again = store.open(first.attachment.uid)
        await MediaInfoSheet.opened(
            again, context: context, store: store, handle: session, baseURL: base)
        let facts = try #require(store.facts(for: again))
        #expect(facts.filename == "IMG_0001.HEIC")
        #expect(facts.addedBy == "fabian")
        #expect(facts.latitude == 38.71 && facts.longitude == -9.14)
        #expect(facts.camera?.model == "iPhone 16 Pro")
        #expect(facts.camera?.exposureTime == 0.0167)
        #expect(facts.camera?.iso == 80)

        // Control: a favorites commit's invalidation makes the next opening read again.
        store.close(again)
        store.forget(first.attachment.uid)
        let after = store.open(first.attachment.uid)
        await MediaInfoSheet.opened(
            after, context: context, store: store, handle: session, baseURL: base)
        #expect(transport.count(record) == 2)
    }

    @Test("a record answered for the previous account is ignored and not kept")
    func staleGenerationAnswerIgnored() async throws {
        let transport = GatedRecordTransport()
        let session = handle(transport)
        let store = MediaContextStore()
        let page = try #require(MediaViewerPresentation.pages(for: [file("a")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)

        let opening = store.open("a")
        let read = Task {
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: session, baseURL: base)
        }
        await transport.recordAsked()
        store.sessionIdentityChanged()
        transport.release()
        await read.value

        #expect(store.facts(for: opening) == nil, "a stale record landed")
        // Nor was it kept for the file: the next opening asks the server again.
        let next = store.open("a")
        await MediaInfoSheet.opened(
            next, context: context, store: store, handle: session, baseURL: base)
        #expect(transport.count(record) == 2)
        #expect(store.facts(for: next)?.width == 4000)
    }
}

extension MediaInfoRowsTests {
    @Test("Taken's zone is the photo's own offset, the shown zone, or none")
    func takenZone() {
        let utc = TimeZone(identifier: "UTC")!
        var both = file("a")
        both.captureCivil = "2026-09-12T14:00:00"
        both.captureInstant = Date(timeIntervalSince1970: 1_789_214_400)  // 12:00Z
        #expect(MediaInfoRows.takenZone(both, facts: nil, timeZone: utc) == "UTC+2")
        var civilOnly = file("b")
        civilOnly.captureCivil = "2026-09-12T14:00:00"
        #expect(MediaInfoRows.takenZone(civilOnly, facts: nil, timeZone: utc) == nil)
        var instantOnly = file("c")
        instantOnly.captureInstant = Date(timeIntervalSince1970: 1_789_214_400)
        #expect(
            MediaInfoRows.takenZone(instantOnly, facts: nil, timeZone: utc)
                == utc.abbreviation(for: instantOnly.captureInstant!))
        #expect(MediaInfoRows.offset(seconds: 0) == "UTC")
        #expect(MediaInfoRows.offset(seconds: -19_800) == "UTC\u{2212}5:30")
    }
}

extension MediaInfoRecordReadTests {
    @Test("a record read in the air when its file is forgotten is shown, never kept")
    func forgetFencesAReadInTheAir() async throws {
        let transport = GatedRecordTransport()
        let session = handle(transport)
        let store = MediaContextStore()
        let page = try #require(MediaViewerPresentation.pages(for: [file("a")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)

        let opening = store.open("a")
        let read = Task {
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: session, baseURL: base)
        }
        await transport.recordAsked()
        store.forget("a")
        transport.release()
        await read.value
        #expect(store.facts(for: opening)?.width == 4000, "its own opening still shows it")
        store.close(opening)

        let next = store.open("a")
        await MediaInfoSheet.opened(
            next, context: context, store: store, handle: session, baseURL: base)
        #expect(transport.count(record) == 2, "a record read before the forget was kept")
    }

    @Test("a favorites commit, or a write whose outcome is unknown, makes the next open read again")
    func favoritesInvalidateTheRecord() async throws {
        let transport = GatedRecordTransport()
        transport.release()
        let session = handle(transport)
        let favorites = FavoriteStore()
        let store = MediaContextStore()
        store.follow(favorites)
        let page = try #require(MediaViewerPresentation.pages(for: [file("a")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)
        func openAndClose() async {
            let opening = store.open("a")
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: session, baseURL: base)
            store.close(opening)
        }

        await openAndClose()
        await openAndClose()
        #expect(transport.count(record) == 1, "control: a second open is served from the cache")

        // A commit: the PUT answers 204.
        await favorites.setFavorite(
            uid: "a", to: true, shownTags: [], using: session, baseURL: base
        ).value
        await openAndClose()
        #expect(transport.count(record) == 2, "a committed favorite left the old record cached")

        // An unknown outcome whose reconciling read fails too: nothing commits.
        transport.fail(true)
        await favorites.setFavorite(
            uid: "a", to: false, shownTags: [FavoriteTag.name], using: session, baseURL: base
        ).value
        transport.fail(false)
        let before = transport.count(record)
        await openAndClose()
        #expect(
            transport.count(record) == before + 1,
            "a write with an unknown outcome left the old record cached")
    }

    @Test("following again keeps what is held; a write made while nothing followed reads again")
    func unfollowForgetsWhatItHeld() async throws {
        let transport = GatedRecordTransport()
        transport.release()
        let session = handle(transport)
        let favorites = FavoriteStore()
        let store = MediaContextStore()
        let page = try #require(MediaViewerPresentation.pages(for: [file("a")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)
        func openAndClose() async {
            // The viewer follows on every opening (MEMNG-906).
            store.follow(favorites)
            let opening = store.open("a")
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: session, baseURL: base)
            store.close(opening)
        }

        await openAndClose()
        await openAndClose()
        #expect(transport.count(record) == 1, "following again forgot the record held")

        // The viewer goes; a write lands while this store hears nothing; the viewer comes back.
        store.unfollow()
        await favorites.setFavorite(
            uid: "a", to: true, shownTags: [], using: session, baseURL: base
        ).value
        await openAndClose()
        #expect(transport.count(record) == 2, "a write made while unfollowed left the record held")
    }
}
