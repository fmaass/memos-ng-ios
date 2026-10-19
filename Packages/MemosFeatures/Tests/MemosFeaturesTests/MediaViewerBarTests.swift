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
    captureInstant: Date? = nil
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
        memoUID: memoUID
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

/// A library that holds exactly the rows it was given.
@MainActor
private final class Rows: MediaLibraryPaging {
    let items: [LibraryRow]
    let pageSize = 50
    let hasMore = false
    init(_ items: [LibraryRow]) { self.items = items }
    func shouldLoadMore(after index: Int, lookahead: Int) -> Bool { false }
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
        #expect(MediaTileMenu.viewerControl(for: file) == .direct(.showMemo(uid: "m7")))
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
        #expect(MediaViewerBar.binShown(deletable: selection.deletable, canDelete: true))
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
    func takenAtOnBothConstructions() throws {
        let row = LibraryRow(
            attachment: picture("l1", memoUID: "m1"), takenAt: memoDate, mine: false,
            filename: "l1.jpg")
        let library = MediaViewerSource.library(Rows([row]), more: {})
        #expect(library.pages.first?.takenAt == memoDate)

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
@Suite("Info sheet reads")
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

        await MediaInfoSheet.opened(
            page, context: context, store: store, handle: handle, baseURL: base)
        await MediaInfoSheet.opened(
            page, context: context, store: store, handle: handle, baseURL: base)

        #expect(transport.count("get_memo_api_memos__uid__get") == 1)
        #expect(store.memo("m1")?.uid == "m1")
        #expect(MediaInfoRows.memoCard(context.memo, looked: store.memo("m1"))?.showable == true)
    }
}
