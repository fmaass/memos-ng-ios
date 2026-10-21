import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The viewer's bin in every viewer, page by page: a page whose file is mine shows it, a page
/// whose file is not shows none. Each case opens its viewer through the code its screen opens it
/// with, so a context that stops answering per file fails here.
private func picture(_ uid: String, mine: Bool?) -> MemoAttachment {
    let file = "https://memos.example.invalid/api/attachments/\(uid)"
    return MemoAttachment(
        uid: uid, mime: "image/jpeg", status: .ready, width: 1000, height: 800, mine: mine,
        thumbnailURL: URL(string: "\(file)/thumb"), previewURL: URL(string: "\(file)/mobile"),
        webURL: URL(string: "\(file)/web"))
}

private func memo(_ uid: String, mine: Bool, _ attachments: [MemoAttachment]) -> Memo {
    let date = Date(timeIntervalSince1970: 1_780_000_000)
    return Memo(
        uid: uid, owner: "fabian", mine: mine, content: "Lisbon", visibility: .protected,
        pinned: false, createdAt: date, updatedAt: date, tags: [], attachments: attachments)
}

private func row(_ attachment: MemoAttachment) -> LibraryRow {
    LibraryRow(
        attachment: attachment, takenAt: Date(timeIntervalSince1970: 1_780_000_000),
        mine: attachment.mine == true, filename: "\(attachment.uid).jpg")
}

private func marker(_ uid: String, mine: Bool) -> PlaceMarker {
    let file = "https://memos.example.invalid/api/attachments/\(uid)"
    return PlaceMarker(
        uid: uid, memoUID: "memo-\(uid)", mime: "image/jpeg", mine: mine, width: 4000,
        height: 3000, latitude: 47.2, longitude: 8.4,
        takenAt: Date(timeIntervalSince1970: 1_780_000_000),
        thumbnailURL: URL(string: "\(file)/thumb"), previewURL: URL(string: "\(file)/mobile"),
        webURL: URL(string: "\(file)/web"))
}

@MainActor
@Suite("Viewer bin per page")
struct ViewerBinTests {
    /// The bar's answer for the page showing `uid`, with the host's delete handed in.
    private func bin(_ selection: MediaViewerSelection?, on uid: String) throws -> Bool {
        let selection = try #require(selection, "the context opened no viewer")
        let page = try #require(selection.pages.first { $0.id == uid }, "no page \(uid)")
        return MediaViewerBar.binShown(
            deletable: selection.deletable(page.attachment), canDelete: true)
    }

    @Test("Timeline: a page of mine shows the bin, a page of another member's does not")
    func timeline() throws {
        let card = memo("m1", mine: false, [picture("a", mine: true), picture("b", mine: false)])
        #expect(try bin(TimelineView.viewer(for: card, startingAt: "a"), on: "a"))
        #expect(try !bin(TimelineView.viewer(for: card, startingAt: "a"), on: "b"))
    }

    @Test("Library: a page of mine shows the bin, a page of another member's does not")
    func library() throws {
        let rows = [row(picture("a", mine: true)), row(picture("b", mine: false))]
        let opened = MediaGridHosting.viewing(rows[1].attachment, in: rows)
        #expect(try bin(opened, on: "a"))
        #expect(try !bin(opened, on: "b"))
    }

    @Test("a trip's or a collection's Journal: per page, by the file, not the memo")
    func journal() throws {
        let card = memo("j1", mine: true, [picture("a", mine: true), picture("b", mine: false)])
        guard case .viewer(let opened) = TripView.journalOpening(picture("a", mine: true), of: card)
        else {
            Issue.record("the Journal's photo opened no viewer")
            return
        }
        #expect(try bin(opened, on: "a"))
        #expect(try !bin(opened, on: "b"))
    }

    @Test("Places: a pin of mine shows the bin, a pin of another member's does not")
    func places() throws {
        let markers = [marker("a", mine: true), marker("b", mine: false)]
        #expect(try bin(PlacesPresentation.open("a", in: markers), on: "a"))
        #expect(try !bin(PlacesPresentation.open("b", in: markers), on: "b"))
    }

    @Test("a file whose owner the payload never named shows no bin")
    func unnamedOwner() throws {
        let rows = [row(picture("a", mine: nil))]
        #expect(try !bin(MediaGridHosting.viewing(rows[0].attachment, in: rows), on: "a"))
    }

    @Test("memo detail is unchanged: the memo's flag decides every page")
    func memoDetailUnchanged() throws {
        let theirsOnMine = memo("m1", mine: true, [picture("a", mine: false)])
        let mine = MediaViewerPresentation.viewer(for: theirsOnMine, startingAt: "a")
        #expect(try bin(mine, on: "a"))
        let mineOnTheirs = memo("m2", mine: false, [picture("b", mine: true)])
        let theirs = MediaViewerPresentation.viewer(for: mineOnTheirs, startingAt: "b")
        #expect(try !bin(theirs, on: "b"))
    }

    @Test("the drawn viewer: the bin on a page of mine, none — not a disabled one — on another's")
    func drawnViewer() throws {
        let rows = [row(picture("a", mine: true)), row(picture("b", mine: false))]
        let label = AttachmentDeleteFlow.title(for: rows[0].attachment)
        for (tapped, shown) in [(rows[0], true), (rows[1], false)] {
            let uid = tapped.id
            let opened = try #require(MediaGridHosting.viewing(tapped.attachment, in: rows))
            let viewer = MediaViewerView(
                selection: opened, source: .fixed(opened.pages), delete: { _ in true })
            let labels = ScreenProbe.labels(of: viewer)
            #expect(labels.contains(label) == shown, "page \(uid): \(labels)")
        }
    }

    @Test("a delete whose session moved while out keeps the page, as the store keeps the row")
    func aRunThatOutlivedItsSessionIsNotGone() async {
        let stale = MediaGridHosting.deletingOne { uids in
            LibraryDeleteOutcome(
                deleted: uids, failed: nil, notAttempted: [], stoppedForSessionChange: true)
        }
        #expect(await stale("a") == false, "a page left the viewer while its row stays")
        let landed = MediaGridHosting.deletingOne { uids in
            LibraryDeleteOutcome(
                deleted: uids, failed: nil, notAttempted: [], stoppedForSessionChange: false)
        }
        #expect(await landed("a"), "control: a run that landed is gone")
        let refused = MediaGridHosting.deletingOne { _ in nil }
        #expect(await refused("a") == false, "a refused run read as gone")
    }
}
