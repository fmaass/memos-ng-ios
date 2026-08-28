import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

@MainActor
private func photo(_ uid: String, original: URL?) -> MemoAttachment {
    MemoAttachment(
        uid: uid,
        mime: "image/jpeg",
        status: .ready,
        webURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/web"),
        downloadURL: original
    )
}

/// A clip: the one kind of file whose shared copy is NOT its own original.
@MainActor
private func clip(_ uid: String = "v1") -> MemoAttachment {
    MemoAttachment(
        uid: uid,
        mime: "video/quicktime",
        status: .ready,
        webURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/web"),
        posterURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/poster"),
        downloadURL: URL(string: "https://memos.example.invalid/api/attachments/\(uid)/original")
    )
}

/// What the closures a menu row is handed were actually called with.
///
/// Not isolated to an actor and not locked: every call it records is made synchronously inside
/// `tapped()`, on the test's own thread, before the next line of the test runs.
private final class TapRecorder: @unchecked Sendable {
    var fetched: [(uid: String, rendition: AttachmentRendition)] = []
    var shown: [String] = []
}

/// Counts calls from a closure the test hands over.
@MainActor
private final class Calls {
    private(set) var count = 0
    func record() { count += 1 }
}

/// Handing a file to somebody else.
///
/// Three things are being held. That an action is OFFERED only where it can work — a file whose
/// payload names no original has nothing to fetch, and two rows that would fetch the same bytes
/// are one row. That the wait it starts is visible, bounded to one at a time, and cannot end in a
/// share sheet over a file that never arrived. And that what the sheet is handed is that file
/// (MEMNG-207).
@MainActor
@Suite("Handing a file on")
struct MediaSaveFlowTests {
    private let attachment = MemoAttachment(uid: "a1", mime: "image/jpeg", status: .ready)
    private let file = URL(fileURLWithPath: "/tmp/a1.jpeg")

    @Test("a file that arrives is offered, and nothing is left saying it failed")
    func successOffersTheFile() async {
        let flow = MediaSaveFlow()

        let ran = await flow.save(attachment) { _ in self.file }

        #expect(ran)
        #expect(flow.saved == FetchedFile(url: file))
        #expect(flow.lastError == nil)
        #expect(!flow.isSaving)
    }

    @Test("a download that fails says why and offers nothing")
    func failureOffersNothing() async {
        let flow = MediaSaveFlow()

        await flow.save(attachment) { _ in throw OriginalMediaError.notSignedIn }

        // The sheet is bound to `saved`, so this is what stops a failure raising an empty one.
        #expect(flow.saved == nil)
        #expect(flow.lastError == OriginalMediaError.notSignedIn.errorDescription)
        #expect(!flow.isSaving)
    }

    @Test("an error with nothing to say still says something")
    func unnamedFailureHasAMessage() async {
        struct Nameless: Error {}
        let flow = MediaSaveFlow()

        await flow.save(attachment) { _ in throw Nameless() }

        #expect(flow.lastError != nil)
        #expect(flow.saved == nil)
    }

    @Test("a second tap while a download is running does not start another")
    func oneDownloadAtATime() async {
        let flow = MediaSaveFlow()
        let calls = Calls()

        await flow.save(attachment) { _ in
            calls.record()
            // The second tap, arriving while this one is still in flight. On a video that would
            // be a second few hundred megabytes fetched for nothing.
            let second = await flow.save(self.attachment) { _ in
                calls.record()
                return self.file
            }
            #expect(!second, "a second download was started over one already running")
            return self.file
        }

        #expect(calls.count == 1)
        #expect(flow.saved == FetchedFile(url: file))
    }

    @Test("the share sheet closing stops the file being offered again")
    func finishClearsTheFile() async {
        let flow = MediaSaveFlow()
        await flow.save(attachment) { _ in self.file }
        #expect(flow.saved != nil)

        flow.finish()

        // Without this the same sheet comes straight back: the binding it is presented on would
        // still be holding a value.
        #expect(flow.saved == nil)
    }

    @Test("a new attempt clears the last failure before it starts")
    func retryClearsTheError() async {
        let flow = MediaSaveFlow()
        await flow.save(attachment) { _ in throw OriginalMediaError.unavailable }
        #expect(flow.lastError != nil)

        await flow.save(attachment) { _ in self.file }

        #expect(flow.lastError == nil)
        #expect(flow.saved != nil)
    }

    @Test("dismissing the message clears it")
    func dismissingTheError() async {
        let flow = MediaSaveFlow()
        await flow.save(attachment) { _ in throw OriginalMediaError.unavailable }

        flow.dismissError()

        #expect(flow.lastError == nil)
    }

    // MARK: - what the menu offers

    /// A clip is the one file that gets both rows, because it is the one whose shared copy and
    /// whose master are different files.
    @Test("Save Original is offered last, after the two that happen at once")
    func theMenuOffersItLast() {
        var owned = clip()
        owned.memoUID = "m7"

        #expect(
            MediaTileMenu.actions(for: owned).map(\.title)
                == ["Show Memo", "Share", "Save Original"]
        )
        #expect(MediaTileMenu.actions(for: clip()).map(\.title) == ["Share", "Save Original"])
    }

    @Test("a clip with no mp4 yet is offered one row, not two that would fetch the same file")
    func noSecondRowForTheSameFile() {
        var pending = clip()
        pending.webURL = nil

        #expect(MediaTileMenu.actions(for: pending).map(\.title) == ["Share"])
        // The control: with the derived mp4 in the payload the two rows are two different files,
        // which is the only thing that earns the second row.
        #expect(MediaTileMenu.actions(for: clip()).map(\.title) == ["Share", "Save Original"])
    }

    /// The gap this closes: the library's document branch drew a tile and offered nothing at all,
    /// so the one kind of file you would most want to KEEP — the PDF, the voice memo — was the one
    /// with no way to save it. "Cannot be opened" was being read as "cannot be acted on".
    @Test("a file that cannot be opened is still offered everything that can be done with it")
    func documentsAreOfferedTheSameActions() {
        let pdf = document()

        // Two, not three: a PDF is handed on as its own file, so a second row fetching that same
        // file under another name would be a choice with nothing behind it.
        #expect(MediaTileMenu.actions(for: pdf).map(\.title) == ["Show Memo", "Share"])
        // Both halves of the invariant, together: this file has no page in the viewer AND has
        // things that can be done with it. Either one alone is what the library got wrong.
        #expect(MediaLibraryPresentation.tileKind(for: pdf) == .document)
        #expect(!MediaLibraryPresentation.isOpenable(.document))
    }

    /// A context menu is a gesture nobody is told about. Every other tile can afford one, because
    /// its actions are reachable another way — the tap opens the file and the viewer offers them
    /// again. This tile has no tap, so the long press would be the ONLY way, which is why the
    /// actions are also on the tile where they can be seen.
    @Test("a document tile really shows a control for its actions, and an empty one shows none")
    func theDocumentTileShowsItsActions() {
        let offered = ScreenProbe.labels(
            of: DocumentTile(
                mime: "application/pdf", actions: MediaTileMenu.actions(for: document())
            )
        )
        let bare = ScreenProbe.labels(of: DocumentTile(mime: "application/pdf"))

        // The positive control first: the probe can see this tile at all.
        #expect(offered.contains("File"), "the probe found nothing of the tile: \(offered)")
        #expect(offered.contains("File actions"), "a document tile offers nothing: \(offered)")
        // A tile with nothing to offer draws no control — a button that opens an empty menu is
        // worse than none.
        #expect(bare.contains("File"))
        #expect(!bare.contains("File actions"))
    }

    private func document() -> MemoAttachment {
        var pdf = MemoAttachment(
            uid: "d1",
            mime: "application/pdf",
            status: .ready,
            webURL: URL(string: "https://memos.example.invalid/api/attachments/d1/web"),
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/d1/original")
        )
        pdf.memoUID = "m7"
        return pdf
    }

    @Test("both fetching actions carry the whole file, because a download needs more than a URL")
    func theActionsCarryTheAttachment() throws {
        let video = clip("v1")

        for action in MediaTileMenu.actions(for: video) {
            let carried: MemoAttachment
            switch action {
            case .share(let attachment), .saveOriginal(let attachment): carried = attachment
            case .showMemo: continue
            }
            // Where each file is, what it is, and what to call it — all of it comes off the
            // attachment, so neither surface has to reassemble any of it for itself.
            #expect(carried.uid == "v1")
            #expect(carried.mime == "video/quicktime")
            #expect(carried.downloadURL == video.downloadURL)
            #expect(carried.webURL == video.webURL)
        }
        // The control: there were two of them to check.
        #expect(MediaTileMenu.actions(for: video).count == 2)
    }

    // MARK: - what Share hands over (MEMNG-207)

    /// The bug: Share handed the activity sheet the file's `webUrl` — a signed derived-tier link.
    /// It expires with its signature, it only resolves for somebody who can reach the household
    /// server, and it says that server's name out loud. Whoever it was sent to had nothing to open.
    @Test("Share names the file it will fetch, never a link to the server")
    func shareNamesTheFileNotALink() throws {
        let file = photo("a1", original: URL(string: "https://memos.example.invalid/x/original"))

        for action in MediaTileMenu.actions(for: file) {
            #expect(!action.id.contains("://"), "an action carries a server URL: \(action.id)")
        }
        let share = try #require(MediaTileMenu.actions(for: file).first { $0.title == "Share" })
        #expect(share.id == "share:a1")
    }

    /// Share fetches a file now, so it is offered on the same terms as every other action that
    /// fetches one: only where there is something to fetch. A payload naming no original names
    /// nothing this app could hand anybody, and an action that would download nothing is worse
    /// than no action at all.
    @Test("a file with no original is offered no Share, because there is nothing to hand over")
    func nothingToHandOver() {
        #expect(MediaTileMenu.actions(for: photo("a", original: nil)).map(\.title) == [])
        // The control: the same file WITH an original is offered one, so the absence above is
        // about the missing file and not about an empty menu.
        #expect(
            MediaTileMenu.actions(
                for: photo("a", original: URL(string: "https://memos.example.invalid/x/original"))
            ).map(\.title) == ["Share"]
        )
    }

    /// What a tap on each row actually asks for.
    ///
    /// `MediaTileMenu.actions` says what is OFFERED and `SessionStore.download` says what a
    /// rendition costs on the wire; between them sits the row, and until this test nothing crossed
    /// it. The rendition is the whole question — `.shared` is a file, and the thing this ticket
    /// replaced was a row that handed over a link instead.
    @Test("tapping Share asks for the shared file; tapping Save Original asks for the master")
    func eachRowAsksForItsOwnFile() {
        let video = clip("v1")
        let recorder = TapRecorder()

        for action in MediaTileMenu.actions(for: video) {
            MediaTileActionItem(
                action: action,
                showMemo: { recorder.shown.append($0) },
                fetch: { recorder.fetched.append(($0.uid, $1)) }
            ).tapped()
        }

        let uids = recorder.fetched.map(\.uid)
        let renditions = recorder.fetched.map(\.rendition)
        // Two rows, in the order the menu shows them, each asking for its own file.
        #expect(uids == ["v1", "v1"])
        #expect(renditions == [.shared, .original])
        #expect(recorder.shown.isEmpty)
    }

    /// The third row, because a routing rule needs a case per input and not only the happy one:
    /// the row that navigates must not start a download.
    @Test("tapping Show Memo goes to the memo and fetches nothing")
    func theMemoRowFetchesNothing() {
        let recorder = TapRecorder()

        MediaTileActionItem(
            action: .showMemo(uid: "m7"),
            showMemo: { recorder.shown.append($0) },
            fetch: { recorder.fetched.append(($0.uid, $1)) }
        ).tapped()

        #expect(recorder.shown == ["m7"])
        #expect(recorder.fetched.isEmpty)
    }

    /// The other end of the same rule: what the activity sheet is actually handed.
    ///
    /// The sheet is presented on `saved` and on nothing else, so this is the whole payload — one
    /// item, a file on this phone. It is emphatically not the server URL the payload carries,
    /// which is what a recipient used to be sent.
    @Test("the share sheet is handed the file that arrived, and no URL")
    func theSheetIsHandedTheFile() async throws {
        let flow = MediaSaveFlow()
        let carried = photo("a1", original: URL(string: "https://memos.example.invalid/x/original"))

        await flow.save(carried) { _ in self.file }

        let offered = try #require(flow.saved)
        let items = ShareSheet.activityItems(for: offered.url)
        // Read outside the macro: `#expect` expands its argument into a `rethrows` position, so a
        // closure-taking call inside one is a compile error rather than an assertion.
        let allLocal = items.allSatisfy(\.isFileURL)
        let carriesTheDerivedLink = items.contains { $0 == carried.webURL }
        let carriesTheOriginalLink = items.contains { $0 == carried.downloadURL }

        #expect(items == [file])
        #expect(allLocal, "the share sheet was handed a remote URL: \(items)")
        #expect(!carriesTheDerivedLink, "the share sheet was handed the derived-tier link")
        #expect(!carriesTheOriginalLink, "the share sheet was handed the server's own URL")
    }

    // MARK: - what the server is holding YET (MEMNG-209)

    /// The bug: a payload names all four derived tiers whether the worker has made them or not, so
    /// a clip still being transcoded offered Share of an mp4 that is not on disk — a tap that
    /// fetches a 404 into the error alert, beside a tile that is visibly still waiting.
    @Test("a clip whose mp4 has not been made yet is offered no Share")
    func transcodingClipOffersNoShare() {
        var transcoding = clip()
        transcoding.status = .processing

        #expect(MediaTileMenu.actions(for: transcoding).map(\.title) == ["Save Original"])
        // The control: the same clip, finished, is offered both — so the absence above is about
        // the mp4 that does not exist yet, and not about clips.
        #expect(MediaTileMenu.actions(for: clip()).map(\.title) == ["Share", "Save Original"])
    }

    /// `failed` is the server's last word about the DERIVED tiers, not about the upload: the
    /// master they would have been made from is still there, so the one thing left that can be
    /// done with the file is still offered.
    @Test("a clip the server gave up on offers its master, never the mp4 it never made")
    func failedClipStillOffersItsMaster() {
        var abandoned = clip()
        abandoned.status = .failed

        #expect(MediaTileMenu.actions(for: abandoned).map(\.title) == ["Save Original"])
        // The control: a clip in the same shape whose tiers did get made is offered both.
        #expect(MediaTileMenu.actions(for: clip()).map(\.title) == ["Share", "Save Original"])
    }

    /// The other end of the same rule. Before the bytes land there is no master either: memos-ng
    /// leaves an attachment `uploading` until its file is written and moves it on afterwards, so
    /// that is the one status meaning the server holds nothing at all.
    @Test("a file whose bytes are still on their way offers nothing to hand over")
    func anUploadInFlightOffersNothing() {
        let master = URL(string: "https://memos.example.invalid/x/original")
        var arriving = photo("a1", original: master)
        arriving.status = .uploading
        var arrivingClip = clip()
        arrivingClip.status = .uploading

        #expect(MediaTileMenu.actions(for: arriving).map(\.title) == [])
        #expect(MediaTileMenu.actions(for: arrivingClip).map(\.title) == [])
        // The control: the same picture, landed, is offered its file — so the two absences above
        // are about the upload and not about an empty menu.
        #expect(MediaTileMenu.actions(for: photo("a1", original: master)).map(\.title) == ["Share"])
    }

    /// The gate is about the DERIVED file, and a picture hands over none: what Share sends for a
    /// photograph or a PDF is the master it was uploaded as, which is on disk while the tiers
    /// beside it are still being made. Taking that row away for the seconds a tile shimmers would
    /// remove an action for a file that is sitting right there.
    @Test("a picture or a document still being derived keeps the Share of its own file")
    func aFileBeingDerivedKeepsItsShare() {
        var deriving = photo("a1", original: URL(string: "https://memos.example.invalid/x/orig"))
        deriving.status = .processing
        var queued = document()
        queued.status = .pending

        #expect(MediaTileMenu.actions(for: deriving).map(\.title) == ["Share"])
        #expect(MediaTileMenu.actions(for: queued).map(\.title) == ["Show Memo", "Share"])
    }

    /// `Show Memo` is navigation, not a file: the memo an owned attachment belongs to exists for
    /// the whole time its bytes are still arriving, so the one row that hands nothing over stays.
    /// Pinned deliberately — the empty menus above are about FILES the server is not holding, and
    /// this is the row the holding question does not touch.
    @Test("an owned file still uploading keeps Show Memo — the memo exists, the bytes do not")
    func anOwnedUploadInFlightKeepsItsMemo() {
        var arriving = document()
        arriving.status = .uploading

        #expect(MediaTileMenu.actions(for: arriving).map(\.title) == ["Show Memo"])
    }

    /// A payload that names no web tier for a clip falls back to what every other kind of file
    /// does: the shared copy IS the master (`MemoAttachment.file(_:)`), and the master is held
    /// once its bytes have landed. So the one row offered is a Share handing over the original —
    /// not a second row for the same bytes, and never a derived file the server never made. The
    /// server signs a web URL for every clip today, so this pins the fallback, not a live path.
    @Test("a clip whose payload names no mp4 shares its master, once and as one row")
    func aClipWithoutAWebTierSharesItsMaster() {
        let bare = MemoAttachment(
            uid: "v9",
            mime: "video/quicktime",
            status: .processing,
            downloadURL: URL(string: "https://memos.example.invalid/api/attachments/v9/original")
        )

        #expect(MediaTileMenu.actions(for: bare).map(\.title) == ["Share"])
    }
}
