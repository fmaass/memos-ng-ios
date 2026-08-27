import Foundation
import MemosCore
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

/// Counts calls from a closure the test hands over.
@MainActor
private final class Calls {
    private(set) var count = 0
    func record() { count += 1 }
}

/// Saving the file somebody actually uploaded.
///
/// Two things are being held. That the action is OFFERED only where it can work — a file whose
/// payload carries no original has nothing to fetch — and that the wait it starts is visible,
/// bounded to one at a time, and cannot end in a share sheet over a file that never arrived.
@MainActor
@Suite("Saving an original")
struct MediaSaveFlowTests {
    private let attachment = MemoAttachment(uid: "a1", mime: "image/jpeg", status: .ready)
    private let file = URL(fileURLWithPath: "/tmp/a1.jpeg")

    @Test("a file that arrives is offered, and nothing is left saying it failed")
    func successOffersTheFile() async {
        let flow = MediaSaveFlow()

        let ran = await flow.save(attachment) { _ in self.file }

        #expect(ran)
        #expect(flow.saved == SavedOriginal(url: file))
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
        #expect(flow.saved == SavedOriginal(url: file))
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

    @Test("Save Original is offered last, after the two that happen at once")
    func theMenuOffersItLast() {
        let full = photo("a", original: URL(string: "https://memos.example.invalid/x/original"))
        var owned = full
        owned.memoUID = "m7"

        #expect(
            MediaTileMenu.actions(for: owned).map(\.title)
                == ["Show Memo", "Share", "Save Original"]
        )
        #expect(MediaTileMenu.actions(for: full).map(\.title) == ["Share", "Save Original"])
    }

    @Test("a file with no original is not offered a download that would fetch nothing")
    func nothingToDownload() {
        let bare = photo("a", original: nil)

        #expect(MediaTileMenu.actions(for: bare).map(\.title) == ["Share"])
        // The control: the same file WITH an original does get the row, so the absence above is
        // about the missing URL and not about an empty menu.
        #expect(
            MediaTileMenu.actions(
                for: photo("a", original: URL(string: "https://memos.example.invalid/x/original"))
            ).count == 2
        )
    }

    @Test("the action carries the whole file, because a download needs more than a URL")
    func theActionCarriesTheAttachment() throws {
        let original = URL(string: "https://memos.example.invalid/x/original")
        let file = photo("a1", original: original)

        let action = try #require(
            MediaTileMenu.actions(for: file).first {
                if case .saveOriginal = $0 { return true }
                return false
            }
        )
        guard case .saveOriginal(let carried) = action else {
            Issue.record("the action did not carry the file")
            return
        }
        // Where the original is, what it is, and what to call it — all three come off the
        // attachment, so neither surface has to reassemble them for itself.
        #expect(carried.downloadURL == original)
        #expect(carried.mime == "image/jpeg")
        #expect(carried.uid == "a1")
    }
}
