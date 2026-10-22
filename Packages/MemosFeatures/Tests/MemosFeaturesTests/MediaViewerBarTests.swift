import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// MEMNG-860, viewer chrome 1/3: the bottom bar, the date capsule, hide-on-tap and the context
/// resolver behind them.
private func picture(
    _ uid: String,
    memoUID: String? = nil,
    mine: Bool? = nil,
    captureCivil: String? = nil,
    captureInstant: Date? = nil,
    tags: [String] = []
) -> MemoAttachment {
    MemoAttachment(
        uid: uid,
        mime: "image/jpeg",
        status: .ready,
        width: 1000,
        height: 800,
        captureInstant: captureInstant,
        captureCivil: captureCivil,
        mine: mine,
        thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/thumb"),
        previewURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/mobile"),
        webURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/web"),
        memoUID: memoUID,
        tags: tags
    )
}

private func memo(_ uid: String, mine: Bool, createdAt: Date, _ attachments: [MemoAttachment])
    -> Memo
{
    Memo(
        uid: uid, owner: "fabian", mine: mine, content: "Lisbon, day two\n#portugal",
        visibility: .protected, pinned: false, createdAt: createdAt, updatedAt: createdAt,
        tags: ["portugal"], attachments: attachments)
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let posix = Locale(identifier: "en_US_POSIX")
/// Monday 2026-10-19 12:00 UTC.
private let now = Date(timeIntervalSince1970: 1_792_411_200)
private let memoDate = Date(timeIntervalSince1970: 1_780_000_000)
private let uploadDate = Date(timeIntervalSince1970: 1_790_000_000)

@MainActor
@Suite("Viewer bar")
struct MediaViewerBarTests {
    @Test("the bin follows today's rule; without it the capsule still stands in the middle")
    func binSlotPerCombination() throws {
        #expect(MediaViewerBar.binShown(deletable: true, canDelete: true))
        #expect(!MediaViewerBar.binShown(deletable: true, canDelete: false))
        #expect(!MediaViewerBar.binShown(deletable: false, canDelete: true))
        #expect(!MediaViewerBar.binShown(deletable: false, canDelete: false))
        #expect(MediaViewerBar.slots(binShown: false) == [.share, .capsule])
        #expect(MediaViewerBar.slots(binShown: true) == [.share, .capsule, .bin])

        let file = picture("a")
        let without = ScreenProbe.labels(of: MediaViewerBar(attachment: file, binShown: false))
        let with = ScreenProbe.labels(of: MediaViewerBar(attachment: file, binShown: true))
        #expect(!without.contains("Delete Photo"), "a bin was drawn where nothing can delete")
        #expect(with.contains("Delete Photo"), "control: the bin is drawn when the rule allows it")

        for binShown in [false, true] {
            let bar = MediaViewerBar(attachment: file, binShown: binShown)
            let heart = PressProbe.withElement(labelled: "Favorite", in: bar) {
                $0?.accessibilityFrame.midX
            }
            let info = PressProbe.withElement(labelled: "Info", in: bar) {
                $0?.accessibilityFrame.midX
            }
            // The capsule's two halves are the same width, so its middle is between their middles.
            let edge = try #require(heart.flatMap { h in info.map { (h + $0) / 2 } }, "no capsule")
            #expect(abs(edge - 393 / 2) <= 1, "capsule off centre (\(edge)), bin \(binShown)")
        }
    }

    @Test("Share is off the viewer's menu rows and on the bar")
    func shareMovedToTheBar() {
        let file = picture("a", memoUID: "m7")
        #expect(MediaTileMenu.viewerActions(for: file) == [.showMemo(uid: "m7")])
        // The viewer's top-right is the ⋯ menu even for one row; the tile keeps its own rule, and
        // there a picture's mobile tier is a Share of its own (MEMNG-874).
        #expect(MediaTileMenu.viewerControl(for: file) == .menu([.showMemo(uid: "m7")]))
        #expect(MediaTileMenu.control(for: file) == .menu([.showMemo(uid: "m7"), .share(file)]))
        let top = ScreenProbe.labels(
            of: MediaViewerActions(
                control: MediaTileMenu.viewerControl(for: file), showMemo: { _ in }))
        #expect(top.contains("More"), "the viewer's top row has no ⋯: \(top)")
        #expect(!top.contains("Show Memo"), "the lone row was drawn as a button: \(top)")
        // A file WITH something to share, whose tile list keeps Share while the viewer's rows
        // drop it, is `MediaTileMenuTests.overlayOffersTheWholeActionSet`.
        let labels = ScreenProbe.labels(of: MediaViewerBar(attachment: file, binShown: false))
        #expect(labels.contains("Share"), "the bar has no Share: \(labels)")
        #expect(labels.contains("Info"))
    }

    @Test("one tap hides the top row, the capsule and the bar; the next shows all three")
    func chromeToggles() {
        var chrome = MediaViewerChrome()
        #expect(chrome.shown == [.topRow, .dateCapsule, .bar])
        chrome.tapped()
        #expect(chrome.shown.isEmpty)
        chrome.tapped()
        #expect(chrome.shown == [.topRow, .dateCapsule, .bar])
    }

    @Test("ownership is the file's: a memo of mine holding a picture that is not keeps the bin")
    func ownershipIsReadFromTheAttachment() throws {
        let theirs = picture("a", mine: false)
        let mine = memo("m1", mine: true, createdAt: memoDate, [theirs])
        let selection = try #require(MediaViewerPresentation.viewer(for: mine, startingAt: "a"))
        let context = MediaViewerContext.resolve(selection.startPage, carried: mine)

        #expect(context.ownedByMe == false, "the memo's flag was read for the file's")
        #expect(
            MediaViewerBar.binShown(
                deletable: selection.deletable(selection.startPage.attachment), canDelete: true))
        let heartEnabled = PressProbe.withElement(
            labelled: "Favorite", in: MediaViewerBar(attachment: theirs, binShown: true)
        ) { heart in heart.map { !$0.accessibilityTraits.contains(.notEnabled) } }
        #expect(heartEnabled == false, "the heart is live, or was not drawn")
    }
}

@MainActor
@Suite("Viewer date capsule and context")
struct MediaViewerContextTests {
    @Test("the capsule's day reads Today, Yesterday, a weekday, then a date")
    func dayLines() {
        let hour: TimeInterval = 3600
        let day = 24 * hour
        func line(_ date: Date) -> String {
            MediaViewerDateCapsule.dayLine(for: date, now: now, calendar: utc, locale: posix)
        }
        #expect(line(now - 3 * hour) == "Today")
        #expect(line(now - day) == "Yesterday")
        #expect(line(now - 3 * day) == "Friday")
        #expect(line(now - 6 * day) == "Tuesday")
        #expect(line(now - 7 * day) == "Oct 12, 2026")
        // The formatter puts a narrow no-break space before the period; compared as a space.
        let time = MediaViewerDateCapsule.timeLine(for: now, calendar: utc, locale: posix)
        #expect(time.replacingOccurrences(of: "\u{202F}", with: " ") == "12:00 PM")
    }

    @Test("a memo page is dated by the camera's civil clock")
    func memoPageUsesCivil() throws {
        let file = picture("a", captureCivil: "2026-01-01T13:00:00")
        let owner = memo("m1", mine: true, createdAt: memoDate, [file])
        let page = try #require(MediaViewerPresentation.pages(for: owner.attachments).first)
        let context = MediaViewerContext.resolve(page, carried: owner, timeZone: utc.timeZone)

        #expect(context.dateOrigin == .civil)
        #expect(context.date == Date(timeIntervalSince1970: 1_767_272_400))
        #expect(context.memo == .carried(owner))
    }

    @Test("a library page is dated by the list's takenAt")
    func libraryPageUsesTakenAt() throws {
        let row = LibraryRow(
            attachment: picture("a", memoUID: "m1"), takenAt: memoDate, mine: true,
            filename: "a.jpg")
        let page = try #require(MediaViewerPresentation.pages(for: [row]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)

        #expect(context.dateOrigin == .listed)
        #expect(context.date == memoDate)
        #expect(context.memo == .lookup("m1"))
    }

    @Test("an orphan with no date anywhere has no capsule")
    func orphanWithoutDateHasNone() throws {
        let page = try #require(MediaViewerPresentation.pages(for: [picture("a")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)

        #expect(context.date == nil)
        #expect(context.dateOrigin == nil)
        #expect(context.memo == .orphan)
    }

    @Test("the date is takenAt, else the civil clock, else the capture instant, else the memo's")
    func datePrecedence() throws {
        let civilDate = Date(timeIntervalSince1970: 1_767_272_400)
        let listed = Date(timeIntervalSince1970: 1_700_000_000)
        func resolved(_ file: MemoAttachment, takenAt: Date? = nil) throws -> MediaViewerContext {
            let owner = memo("m1", mine: true, createdAt: memoDate, [file])
            var page = try #require(MediaViewerPresentation.pages(for: owner.attachments).first)
            page.takenAt = takenAt
            return MediaViewerContext.resolve(page, carried: owner, timeZone: utc.timeZone)
        }
        var file = picture("a", captureCivil: "2026-01-01T13:00:00", captureInstant: uploadDate)

        let all = try resolved(file, takenAt: listed)
        #expect(all.date == listed && all.dateOrigin == .listed)
        let civil = try resolved(file)
        #expect(civil.date == civilDate && civil.dateOrigin == .civil)
        file.captureCivil = "not a clock"
        let unreadable = try resolved(file)
        #expect(unreadable.date == uploadDate && unreadable.dateOrigin == .captured)
        file.captureCivil = nil
        let instant = try resolved(file)
        #expect(instant.date == uploadDate && instant.dateOrigin == .captured)
        file.captureInstant = nil
        let fromMemo = try resolved(file)
        #expect(fromMemo.date == memoDate && fromMemo.dateOrigin == .memo)
    }

    @Test("an undated picture shows its memo's date and says it has no capture data, either way")
    func provenanceKeptApart() throws {
        // The server's takenAt for a file the camera did not date is its memo's date — not the
        // upload's, which differs.
        #expect(memoDate != uploadDate)
        let file = picture("a", memoUID: "m1")
        let row = LibraryRow(attachment: file, takenAt: memoDate, mine: true, filename: "a.jpg")
        let fromLibrary = try #require(MediaViewerPresentation.pages(for: [row]).first)
        let libraryContext = MediaViewerContext.resolve(fromLibrary, carried: nil)

        #expect(libraryContext.date == memoDate)
        #expect(fromLibrary.attachment.captureInstant == nil)
        #expect(MediaInfoRows.taken(fromLibrary.attachment, facts: nil) == .noCaptureData)

        var own = file
        own.memoUID = nil
        let owner = memo("m1", mine: true, createdAt: memoDate, [own])
        let fromMemo = try #require(MediaViewerPresentation.pages(for: owner.attachments).first)
        let memoContext = MediaViewerContext.resolve(fromMemo, carried: owner)

        #expect(memoContext.date == memoDate, "the memo's own viewer dated the picture otherwise")
        #expect(memoContext.dateOrigin == .memo)
        #expect(MediaInfoRows.taken(fromMemo.attachment, facts: nil) == .noCaptureData)
        // The control: capture data, where there is some, IS what the Taken row reads.
        let dated = picture("b", captureInstant: uploadDate)
        #expect(MediaInfoRows.taken(dated, facts: nil) == .captured(uploadDate, source: nil))
    }

    @Test("takenAt rides on library and Places pages and is nil on a memo's")
    func takenAtOnBothConstructions() async throws {
        // The library's own store, read over the wire: the row's takenAt is 2026-09-26T10:00:00Z.
        let base = URL(string: "https://memos.example.invalid")!
        let handle = SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_library" },
                transport: ResigningLibraryServer()),
            generation: 1)
        let store = MediaLibraryStore(pageSize: 2, reissueCooldown: {})
        await store.refresh(using: handle, baseURL: base)
        let library = MediaViewerSource.library(store, more: {})
        #expect(library.pages.map(\.id) == ["la"], "the library store never loaded its row")
        #expect(library.pages.first?.takenAt == Date(timeIntervalSince1970: 1_790_416_800))

        let marker = PlaceMarker(
            uid: "g1", memoUID: "m3", mime: "image/jpeg", mine: true, latitude: 38.7,
            longitude: -9.1, takenAt: uploadDate,
            thumbnailURL: URL(string: "https://memos.example.invalid/g1/thumb"),
            previewURL: URL(string: "https://memos.example.invalid/g1/mobile"))
        let places = try #require(PlacesPresentation.open("g1", in: [marker]))
        #expect(places.startPage.takenAt == uploadDate)

        let owner = memo("m1", mine: true, createdAt: memoDate, [picture("p1")])
        let fromMemo = try #require(MediaViewerPresentation.viewer(for: owner, startingAt: "p1"))
        #expect(fromMemo.startPage.takenAt == nil)
    }
}

/// The scripted server for the Info sheet's reads: every request counted by operation.
final class InfoSheetTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []

    func count(_ operation: String) -> Int {
        lock.withLock { operations.filter { $0 == operation }.count }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { operations.append(operationID) }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        switch operationID {
        case "get_memo_api_memos__uid__get":
            return (
                response,
                HTTPBody(
                    #"{"uid":"m1","owner":"fabian","mine":true,"content":"hello","#
                        + #""visibility":"PRIVATE","pinned":false,"#
                        + #""created_at":"2026-08-23T09:00:00Z","#
                        + #""updated_at":"2026-08-23T09:00:00Z","archived_at":null,"#
                        + #""tags":[],"attachments":[]}"#)
            )
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }
}

@MainActor
@Suite("Info sheet reads", .timeLimit(.minutes(1)))
struct MediaInfoSheetReadTests {
    @Test("the memo is fetched only when the sheet opens, and once for two opens")
    func memoFetchedOnceOnOpen() async throws {
        let transport = InfoSheetTransport()
        let base = URL(string: "https://memos.example.invalid")!
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_info" },
            transport: transport)
        let handle = SessionHandle(client: client, generation: 1)
        let store = MediaContextStore()
        let page = try #require(
            MediaViewerPresentation.pages(for: [picture("a", memoUID: "m1")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)
        _ = ScreenProbe.labels(of: MediaViewerBar(attachment: page.attachment, binShown: false))

        #expect(transport.count("get_memo_api_memos__uid__get") == 0, "read before any open")

        for _ in 0..<2 {
            let opening = store.open(page.attachment.uid)
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: handle, baseURL: base)
            store.close(opening)
        }

        #expect(transport.count("get_memo_api_memos__uid__get") == 1)
        #expect(store.memo("m1")?.uid == "m1")
        #expect(MediaInfoRows.memoCard(context.memo, looked: store.memo("m1"))?.showable == true)
    }

    @Test("a sheet dismissed while its memo is read asks for no file record afterwards")
    func dismissedSheetStartsNoRecordRead() async throws {
        let transport = GatedMemoTransport()
        let base = URL(string: "https://memos.example.invalid")!
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_info" },
            transport: transport)
        let handle = SessionHandle(client: client, generation: 1)
        let store = MediaContextStore()
        let page = try #require(
            MediaViewerPresentation.pages(for: [picture("a", memoUID: "m1")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)

        let opening = store.open(page.attachment.uid)
        let read = Task {
            await MediaInfoSheet.opened(
                opening, context: context, store: store, handle: handle, baseURL: base)
        }
        await transport.memoAsked()
        store.close(opening)
        transport.release()
        await read.value

        #expect(transport.count("attachment_meta_api_attachments__uid__get") == 0)
        // The control: an opening still live does read it.
        let live = store.open(page.attachment.uid)
        await MediaInfoSheet.opened(
            live, context: context, store: store, handle: handle, baseURL: base)
        #expect(transport.count("attachment_meta_api_attachments__uid__get") == 1)
        #expect(store.facts(for: live)?.width == 4000)
    }

    @Test("a dismissed sheet's late cleanup ends its own opening, never the next sheet's")
    func lateCleanupEndsOnlyItsOwnSheet() async throws {
        let transport = GatedMemoTransport()
        transport.release()
        let base = URL(string: "https://memos.example.invalid")!
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_info" },
            transport: transport)
        let handle = SessionHandle(client: client, generation: 1)
        let store = MediaContextStore()
        let page = try #require(MediaViewerPresentation.pages(for: [picture("a")]).first)
        let context = MediaViewerContext.resolve(page, carried: nil)
        func sheet(_ subject: MediaInfoSubject) -> MediaInfoSheet {
            MediaInfoSheet(
                page: subject.page, context: context, store: subject.store,
                opening: subject.opening, handle: handle, baseURL: base)
        }

        let first = sheet(MediaInfoSubject(page: page, store: store, opening: store.open("a")))
        // The second sheet is presented before the first one's onDisappear has run.
        let second = sheet(MediaInfoSubject(page: page, store: store, opening: store.open("a")))
        first.disappeared()
        await second.appeared()

        #expect(transport.count("attachment_meta_api_attachments__uid__get") == 1)
        #expect(store.facts(for: second.opening)?.width == 4000, "the first closed the second")
        #expect(store.facts(for: first.opening) == nil)
    }

    @Test("the File row's dimensions and duration are the file record's when it has them")
    func fileRowPrefersTheRecord() {
        let file = picture("a")
        let record = AttachmentFacts(
            uid: "a", mime: "image/heic", size: 1_000_000, width: 4000, height: 3000,
            duration: 75)
        let fromRecord = MediaInfoRows.file(file, facts: record)
        #expect(fromRecord.dimensions == "4000 × 3000")
        #expect(fromRecord.duration == "1:15")
        #expect(fromRecord.type == "image/heic")
        let withoutRecord = MediaInfoRows.file(file, facts: nil)
        #expect(withoutRecord.dimensions == "1000 × 800", "control: the page's own when no record")
        #expect(withoutRecord.size == nil)
    }
}

/// The Info sheet's server with the memo read held until the test lets it go; the file record
/// answers at once. Every request counted by operation.
final class GatedMemoTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []
    private let asked = AsyncStream<Void>.makeStream()
    private let gate = AsyncStream<Void>.makeStream()

    func count(_ operation: String) -> Int {
        lock.withLock { operations.filter { $0 == operation }.count }
    }

    func memoAsked() async { for await _ in asked.stream { break } }

    func release() {
        gate.continuation.yield()
        gate.continuation.finish()
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { operations.append(operationID) }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        switch operationID {
        case "get_memo_api_memos__uid__get":
            asked.continuation.yield()
            for await _ in gate.stream { break }
            return (
                response,
                HTTPBody(
                    #"{"uid":"m1","owner":"fabian","mine":true,"content":"hello","#
                        + #""visibility":"PRIVATE","pinned":false,"#
                        + #""created_at":"2026-08-23T09:00:00Z","#
                        + #""updated_at":"2026-08-23T09:00:00Z","archived_at":null,"#
                        + #""tags":[],"attachments":[]}"#)
            )
        case "attachment_meta_api_attachments__uid__get":
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
                    "filename":null,"latitude":null,"longitude":null,"locationSource":null,\
                    "addedBy":null,"camera":null,"tags":[]}
                    """)
            )
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }
}

// MARK: - The heart (MEMNG-867)

private let heartBase = URL(string: "https://memos.example.invalid")!
private let putFavorite = "add_picture_tag_api_attachments__uid__tags__name__put"
private let deleteFavorite = "remove_picture_tag_api_attachments__uid__tags__name__delete"
private let readRecord = "attachment_meta_api_attachments__uid__get"

/// The favorites server behind the heart: PUT and DELETE answer an empty 204, or the PUT's answer
/// is lost; the record read that reconciles a lost answer is held until the test lets it go.
/// Every request counted by operation.
final class HeartTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [String] = []
    private var paths: [String: [String]] = [:]
    private let losesPut: Bool
    private let refusesPut: Bool
    private let recordAsked = AsyncStream<Void>.makeStream()
    private let recordGate = AsyncStream<Void>.makeStream()

    init(losesPut: Bool = false, refusesPut: Bool = false) {
        self.losesPut = losesPut
        self.refusesPut = refusesPut
    }

    func count(_ operation: String) -> Int {
        lock.withLock { operations.filter { $0 == operation }.count }
    }

    /// The paths `operation` was sent to, in order.
    func paths(_ operation: String) -> [String] {
        lock.withLock { paths[operation] ?? [] }
    }

    func releaseRecord() {
        recordGate.continuation.yield()
        recordGate.continuation.finish()
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock {
            operations.append(operationID)
            paths[operationID, default: []].append(request.path ?? "")
        }
        switch operationID {
        case putFavorite where losesPut:
            throw URLError(.networkConnectionLost)
        case putFavorite where refusesPut:
            return (HTTPResponse(status: .notFound), nil)
        case putFavorite, deleteFavorite:
            return (HTTPResponse(status: .noContent), nil)
        case readRecord:
            recordAsked.continuation.yield()
            for await _ in recordGate.stream { break }
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (
                response,
                HTTPBody(
                    """
                    {"uid":"h","mime":"image/jpeg","size":2048,"sha256":null,"status":"ready",\
                    "width":1000,"height":800,"duration":null,"blurhash":null,\
                    "captured_at":null,"capture_instant":null,"capture_civil":null,\
                    "capture_source":null,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
                    "hasPoster":false,"renditions":[],"downloadUrl":"/a/h/file",\
                    "printUrl":"/a/h/print","thumbnailUrl":"/a/h/thumb","previewUrl":"/a/h/m",\
                    "webUrl":"/a/h/web","webReady":true,"posterUrl":"/a/h/poster",\
                    "filename":null,"latitude":null,"longitude":null,"locationSource":null,\
                    "addedBy":null,"camera":null,"tags":["favorites"]}
                    """)
            )
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }
}

/// Whether the heart on `screen` comes to read `value` within the `eventually` deadline.
@MainActor
private func shows(_ screen: PressProbe.Screen, _ value: String) async -> Bool {
    await eventually { screen.element(labelled: "Favorite")?.accessibilityValue == value }
}

/// Lets the main actor run until `condition` holds, or two seconds pass.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
@Suite("Viewer bar heart", .timeLimit(.minutes(1)))
struct MediaViewerBarHeartTests {
    private func session(_ transport: HeartTransport) -> SessionHandle {
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: heartBase), token: { "memos_pat_heart" },
            transport: transport)
        return SessionHandle(client: client, generation: 1)
    }

    private func bar(
        _ file: MemoAttachment, _ favorites: FavoriteStore, _ handle: SessionHandle? = nil
    ) -> MediaViewerBar {
        MediaViewerBar(
            attachment: file, binShown: false, favorites: favorites, handle: handle,
            baseURL: heartBase)
    }

    /// The heart as VoiceOver reads it: its value, its hint, and whether it takes a press.
    private struct Read: Equatable {
        let value: String?
        let hint: String?
        let enabled: Bool
    }

    private func read(_ view: MediaViewerBar) -> Read? {
        PressProbe.withElement(labelled: "Favorite", in: view) { heart in
            heart.map {
                Read(
                    value: $0.accessibilityValue, hint: $0.accessibilityHint,
                    enabled: !$0.accessibilityTraits.contains(.notEnabled))
            }
        }
    }

    @Test(
        "the bar shows the heart's state, and it writes on every picture, mine × tagged",
        arguments: [(true, true), (true, false), (false, true), (false, false)])
    func heartMatrixInTheBar(mine: Bool, tagged: Bool) throws {
        let file = picture("h", mine: mine, tags: tagged ? [FavoriteTag.name] : [])
        let shown = try #require(read(bar(file, FavoriteStore())), "no heart drawn")

        #expect(shown.value == (tagged ? "On" : "Off"))
        // A family app: whoever's picture it is, the heart is the same live button with nothing
        // to explain (owner, 2026-10-21).
        #expect((shown.hint ?? "") == "")
        #expect(shown.enabled)
        let heart = MediaViewerBar.heart(for: file, in: FavoriteStore())
        #expect(heart.target == !tagged, "a tap asks for the other state")
    }

    @Test("a tap on my picture's heart writes the favorite, and the next tap takes it back")
    func aTapTogglesTheFavorite() async throws {
        let transport = HeartTransport()
        let handle = session(transport)
        let favorites = FavoriteStore()
        let file = picture("h", mine: true)

        await PressProbe.withScreen(bar(file, favorites, handle)) { screen in
            #expect(screen.element(labelled: "Favorite")?.accessibilityValue == "Off")

            #expect(screen.press("Favorite"))
            #expect(await eventually { transport.count(putFavorite) == 1 })
            #expect(await shows(screen, "On"))

            #expect(screen.press("Favorite"))
            #expect(await eventually { transport.count(deleteFavorite) == 1 })
            #expect(await shows(screen, "Off"))
        }
        #expect(transport.count(putFavorite) == 1, "one tap, one request on the wire")
        #expect(favorites.tags(for: "h", shown: []).contains(FavoriteTag.name) == false)
    }

    @Test("a tap on somebody else's picture writes the favorite: one PUT, and the heart fills")
    func aTapOnTheirsWritesTheFavorite() async throws {
        let transport = HeartTransport()
        let handle = session(transport)
        let favorites = FavoriteStore()
        let file = picture("h", mine: false)

        await PressProbe.withScreen(bar(file, favorites, handle)) { screen in
            #expect(screen.element(labelled: "Favorite")?.accessibilityValue == "Off")
            #expect(screen.press("Favorite"))
            #expect(await eventually { transport.count(putFavorite) == 1 })
            #expect(await shows(screen, "On"))
        }
        #expect(transport.paths(putFavorite) == ["/api/attachments/h/tags/favorites"])
        #expect(transport.count(deleteFavorite) == 0)
        #expect(favorites.tags(for: "h", shown: []).contains(FavoriteTag.name))
        #expect(favorites.notice == nil)
    }

    @Test("a refused write on somebody else's picture goes back and says nothing changed")
    func aRefusalOnTheirsIsSaid() async throws {
        // A server that still keeps favorites per owner answers not-found: the store's confirmed
        // rejection, never a silent no-op.
        let transport = HeartTransport(refusesPut: true)
        let handle = session(transport)
        let favorites = FavoriteStore()

        await PressProbe.withScreen(bar(picture("h", mine: false), favorites, handle)) { screen in
            #expect(screen.press("Favorite"))
            #expect(await eventually { favorites.notice != nil })
            #expect(await shows(screen, "Off"))
        }
        #expect(transport.count(putFavorite) == 1)
        #expect(favorites.notice == FavoriteStore.nothingChangedNotice)
    }

    @Test("a write whose answer was lost shows pending until the record read settles it")
    func pendingShowsInTheBar() async throws {
        let transport = HeartTransport(losesPut: true)
        let handle = session(transport)
        let favorites = FavoriteStore()
        let file = picture("h", mine: true)

        await PressProbe.withScreen(bar(file, favorites, handle)) { screen in
            #expect(screen.press("Favorite"))
            #expect(await eventually { transport.count(readRecord) == 1 })
            #expect(favorites.isPending("h"))
            #expect(await shows(screen, "Confirming"))

            transport.releaseRecord()
            #expect(await shows(screen, "On"))
        }
        #expect(favorites.notice == nil, "a confirmed outcome says nothing")
    }
}
