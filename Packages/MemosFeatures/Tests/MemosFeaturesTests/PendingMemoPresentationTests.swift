import CryptoKit
import Foundation
import MemosFeatures
import MemosOutbox
import Testing

@Suite("The pending section")
struct PendingMemoPresentationTests {
    private let capture = Date(timeIntervalSince1970: 1_750_000_000)

    private func job(
        content: String = "on the beach",
        files: [OutboxFile] = [],
        state: JobState = .waiting,
        holdReason: HoldReason? = nil,
        waitReason: WaitReason? = nil,
        attemptCount: Int = 0,
        lastError: String? = nil,
        capturedAt: Date? = nil
    ) -> UploadJob {
        UploadJob(
            content: content,
            capturedAt: capturedAt ?? capture,
            files: files,
            binding: AccountBinding(
                serverBaseURL: URL(string: "https://memos.example.invalid")!,
                ownerSubject: "fabian"
            ),
            state: state,
            holdReason: holdReason,
            waitReason: waitReason,
            attemptCount: attemptCount,
            lastError: lastError
        )
    }

    private func file(size: Int64, confirmed: Int64) -> OutboxFile {
        OutboxFile(
            relativePath: "a.heic",
            filename: "IMG_1.HEIC",
            mime: "image/heic",
            byteSize: size,
            uploadUID: "u1",
            bytesConfirmed: confirmed
        )
    }

    /// The sentence a phone away from home reads. It has to say what would send the capture NOW,
    /// because the honest alternative — a row that says "uploading 0 %" for a deliberate hold — is
    /// what this label replaces, and it is what made someone force-quit the app on 2026-08-25.
    @Test("a capture held for the home network says so, and says what would send it")
    func waitingForTheHomeNetwork() {
        #expect(
            PendingMemoPresentation.status(for: job(waitReason: .homeNetwork))
                == "Waiting for your home network — turn on Upload over mobile data in Settings"
                + " to send it now"
        )
    }

    /// The reason beats the attempt count. A capture refused by the network was never tried, so
    /// "Waiting to try again" would be describing a retry that is not happening.
    @Test("a held capture that had also failed before still says what it is waiting for")
    func theReasonBeatsTheAttemptCount() {
        let status = PendingMemoPresentation.status(
            for: job(waitReason: .homeNetwork, attemptCount: 3)
        )
        #expect(status.contains("home network"))
        #expect(!status.contains("try again"))
    }

    @Test("every state a job can be in has its own sentence")
    func statusLines() {
        #expect(PendingMemoPresentation.status(for: job()) == "Waiting for home wifi")
        #expect(
            PendingMemoPresentation.status(for: job(attemptCount: 3))
                == "Waiting to try again"
        )
        #expect(
            PendingMemoPresentation.status(
                for: job(files: [file(size: 1000, confirmed: 400)], state: .uploading)
            ) == "Uploading 40%"
        )
        #expect(PendingMemoPresentation.status(for: job(state: .creating)) == "Finishing up")
        #expect(
            PendingMemoPresentation.status(
                for: job(state: .held, holdReason: .accountMismatch)
            ) == "Captured under another account"
        )
        #expect(
            PendingMemoPresentation.status(
                for: job(state: .held, holdReason: .serverRefused, lastError: "File too large")
            ) == "File too large"
        )
        #expect(
            PendingMemoPresentation.status(for: job(state: .held, holdReason: .serverRefused))
                == "Needs attention"
        )
    }

    @Test("a capture the queue could not read says so, and offers nothing that would do nothing")
    func theUnreadableCaptureHasItsOwnSentence() {
        let defective = job(
            content: "", state: .held, holdReason: .unreadableManifest,
            lastError: "dataCorrupted(...)"
        )
        #expect(
            PendingMemoPresentation.status(for: defective)
                == "This capture could not be read — its files are kept"
        )
        // "Try again" would clear a hold that is not the queue's to clear, so the row does not
        // offer it — what it offers is the one move left on a capture nothing else can move.
        let row = PendingMemoPresentation.rows(for: [defective])[0]
        #expect(row.actions == [.remove])
        #expect(row.needsAttention, "a row only a person can end still asks for that person")

        let unwritable = job(
            state: .held, holdReason: .storageFailed,
            lastError: "This capture could not be saved on this device: no space left"
        )
        #expect(
            PendingMemoPresentation.status(for: unwritable)
                == "This capture could not be saved on this device: no space left"
        )
        #expect(PendingMemoPresentation.rows(for: [unwritable])[0].needsAttention)
        #expect(PendingMemoPresentation.rows(for: [unwritable])[0].actions == [.retry])
    }

    @Test("every hold offers exactly one thing, and only the unreadable one offers Remove")
    func actionPerHoldReason() {
        // The switch is what makes this exhaustive: a hold reason added later does not compile
        // until someone has said what its row lets a person do about it.
        for reason in HoldReason.allCases {
            let held = job(state: .held, holdReason: reason)
            switch reason {
            case .unreadableManifest:
                #expect(PendingMemoPresentation.action(for: held) == [.remove])
                #expect(PendingMemoPresentation.rows(for: [held])[0].actions == [.remove])
            case .accountMismatch, .serverRefused, .storageFailed:
                #expect(PendingMemoPresentation.action(for: held) == [.retry])
                #expect(PendingMemoPresentation.rows(for: [held])[0].actions == [.retry])
            }
        }
        // A hold with no reason recorded is still a hold a person may clear.
        #expect(PendingMemoPresentation.action(for: job(state: .held)) == [.retry])
        // Nothing that is still moving asks anything of anybody, whatever it offers.
        for state in [JobState.waiting, .uploading, .creating] {
            let moving = job(state: state)
            #expect(
                PendingMemoPresentation.action(for: moving)
                    == (state == .creating ? [] : [.cancel, .retry]))
            #expect(!PendingMemoPresentation.rows(for: [moving])[0].needsAttention)
        }
    }

    @Test("a text-only capture is not stuck at 0 %")
    func textOnlyProgress() {
        #expect(PendingMemoPresentation.status(for: job(state: .uploading)) == "Uploading 100%")
    }

    @Test("rows are newest capture first, and a held one asks for attention")
    func ordering() {
        let older = job(content: "older", capturedAt: capture)
        let newer = job(
            content: "newer", state: .held, holdReason: .accountMismatch,
            capturedAt: capture.addingTimeInterval(60)
        )
        let rows = PendingMemoPresentation.rows(for: [older, newer])
        #expect(rows.map(\.snippet) == ["newer", "older"])
        #expect(rows.map(\.id) == [newer.id, older.id])
        #expect(rows[0].needsAttention)
        #expect(!rows[1].needsAttention)
    }

    @Test("a snippet is one line, trimmed, and never blank-looking for a photo-only capture")
    func snippets() {
        #expect(PendingMemoPresentation.snippet("one\ntwo") == "one two")
        #expect(PendingMemoPresentation.snippet("   ") == "")
        let long = String(repeating: "a", count: 200)
        let snippet = PendingMemoPresentation.snippet(long, limit: 10)
        #expect(snippet == String(repeating: "a", count: 10) + "…")
        let row = PendingMemoPresentation.rows(
            for: [job(content: "", files: [file(size: 10, confirmed: 0)])]
        )[0]
        #expect(row.snippet.isEmpty)
        #expect(row.attachmentCount == 1)
    }

    /// An upload in flight is something a person may stop, and stopping it is not an emergency.
    ///
    /// Cancel sits beside Try again on every capture the queue is still working on, and the row
    /// stays calm while it does: a control being offered is not the same as a row asking to be
    /// dealt with, and painting every uploading capture orange would teach people that the colour
    /// means nothing.
    @Test("a capture still moving offers Cancel and Try again without asking for attention")
    func anUploadingRowOffersCancelAndRetry() {
        #expect(PendingMemoPresentation.action(for: job(state: .uploading)) == [.cancel, .retry])
        #expect(PendingMemoPresentation.action(for: job(state: .waiting)) == [.cancel, .retry])
        #expect(
            PendingMemoPresentation.action(
                for: job(state: .held, holdReason: .unreadableManifest)) == [.remove])
        // Nothing to press on a capture whose bytes are already at the server: what is left is the
        // memo being written, and cancelling that is not something this screen can promise.
        #expect(PendingMemoPresentation.action(for: job(state: .creating)) == [])

        let row = PendingMemoPresentation.rows(for: [job(state: .uploading)])[0]
        #expect(row.actions == [.cancel, .retry])
        #expect(!row.needsAttention, "an upload doing its job is not a row asking for a person")
    }

    /// The frozen percentage, named. A capture whose bytes stopped moving is the one thing the
    /// pending section used to lie about — it went on counting a percentage nothing was adding
    /// to — and the sentence that replaces it says what is known and no more: nothing has been
    /// confirmed for a while. It is not a failure, and it must never read as one.
    @Test("an upload whose bytes stopped moving says so, and blames the network when that is why")
    func aStalledUploadSaysWhatIsKnown() {
        let stalled = job(files: [file(size: 1000, confirmed: 250)], state: .uploading)
        let progress = [stalled.id: capture]

        let permitted = PendingMemoPresentation.rows(
            for: [stalled], now: capture.addingTimeInterval(91),
            lastProgressAt: progress, uploadsPermitted: true)[0]
        #expect(permitted.status == "No progress confirmed for 90 s")
        #expect(
            !permitted.status.localizedCaseInsensitiveContains("failed"),
            "nothing here knows that anything failed")

        // The same capture, on a network it may not use: the reason is known, so the row says the
        // reason rather than announcing a silence the network fully explains.
        let refused = PendingMemoPresentation.rows(
            for: [stalled], now: capture.addingTimeInterval(91),
            lastProgressAt: progress, uploadsPermitted: false)[0]
        #expect(
            refused.status
                == "Waiting for your home network — turn on Upload over mobile data in Settings"
                + " to send it now")

        // Under the interval the percentage still stands: a slow chunk is not a stalled one.
        let early = PendingMemoPresentation.rows(
            for: [stalled], now: capture.addingTimeInterval(89),
            lastProgressAt: progress, uploadsPermitted: true)[0]
        #expect(early.status == "Uploading 25%")
    }

    /// What cancel hands back, and what the editor does with it. The words have to come back
    /// exactly as they were written, and the pictures have to be the very same files — a restored
    /// draft that re-encoded anything would quietly replace the archive master with a copy of it.
    @Test("a cancelled capture opens the editor on its own words and its own files")
    func theRestoredDraftReachesTheEditor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "restored-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = Data((0..<4096).map { UInt8($0 % 251) })
        let second = Data((0..<8192).map { UInt8(($0 &* 7) % 253) })
        let firstURL = directory.appending(path: "a.heic")
        let secondURL = directory.appending(path: "b.mov")
        try first.write(to: firstURL)
        try second.write(to: secondURL)

        let firstID = UUID()
        let secondID = UUID()
        let draft = RestoredDraft(
            jobID: UUID(),
            content: "on the beach\nwith the dog",
            visibility: "PRIVATE",
            capturedAt: capture,
            pictures: [
                RestoredDraft.Picture(
                    id: firstID, url: firstURL, filename: "IMG_1.HEIC", mime: "image/heic"),
                RestoredDraft.Picture(
                    id: secondID, url: secondURL, filename: "IMG_2.MOV", mime: "video/quicktime"),
            ])

        guard case .create(let carried) = ComposeView.Mode.create(restoring: ComposeRestore(draft))
        else {
            Issue.record("a cancelled capture reopens as a create, not as anything else")
            return
        }
        let restored = try #require(carried, "the create carries the draft it was restored from")
        #expect(restored.content == "on the beach\nwith the dog")
        #expect(restored.visibility == .private)
        #expect(restored.capturedAt == capture)
        // The ids are the outbox's own file ids, carried through unchanged: that is what lets a
        // re-submit say which pictures the memo keeps, and in what order.
        #expect(restored.pictures.map(\.id) == [firstID, secondID])
        #expect(restored.pictures.map(\.filename) == ["IMG_1.HEIC", "IMG_2.MOV"])
        #expect(restored.pictures.map(\.mime) == ["image/heic", "video/quicktime"])

        for (picture, source) in zip(restored.pictures, [first, second]) {
            let carriedBytes = try Data(contentsOf: picture.url)
            #expect(
                SHA256.hash(data: carriedBytes) == SHA256.hash(data: source),
                "the editor was handed a different file than the queue was holding")
        }
    }

    /// A cancelled capture nobody finished with. The bytes are on this device and nothing else
    /// has them, so the row keeps saying so until a person either sends it or throws it away.
    @Test("a cancelled capture left alone is kept, says so, and offers both ways out")
    func aCancelledCaptureIsKept() {
        var cancelled = job(state: .waiting)
        cancelled.cancelledAt = capture
        let row = PendingMemoPresentation.rows(for: [cancelled])[0]
        #expect(row.status == "Cancelled — kept on this device")
        #expect(row.actions == [.retry, .remove])
        #expect(row.needsAttention, "a capture waiting on a person says so")
    }

}

@Suite("The picker boundary")
struct PickedMediaTests {
    @Test("a file imported through the picker boundary is byte-identical")
    func importIsByteIdentical() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "picked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "IMG_0001.HEIC")
        var bytes = Data(capacity: 200_000)
        for index in 0..<200_000 { bytes.append(UInt8((index &* 31 &+ 7) % 251)) }
        try bytes.write(to: source)

        let media = try PickedMedia.imported(source, into: directory)

        #expect(media.filename == "IMG_0001.HEIC")
        #expect(media.mime == "image/heic")
        #expect(media.url != source)
        #expect(
            SHA256.hash(data: try Data(contentsOf: media.url)) == SHA256.hash(data: bytes)
        )
        // The export the picker handed over is not consumed.
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        // What the outbox is handed carries the real name and type, not the storage name.
        #expect(media.stagedSource.filename == "IMG_0001.HEIC")
        #expect(media.stagedSource.mime == "image/heic")
        #expect(media.stagedSource.url == media.url)
    }

    @Test("the stored name comes from an id, never from the name that arrived")
    func storedNameIsDerived() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "picked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "holiday.mov")
        try Data("frames".utf8).write(to: source)

        let media = try PickedMedia.imported(source, into: directory)
        #expect(media.url.lastPathComponent == "\(media.id.uuidString).mov")
        #expect(media.mime == "video/quicktime")
    }

    @Test("a type the system does not know is declared honestly")
    func unknownType() {
        #expect(PickedMedia.mimeType(forExtension: "heic") == "image/heic")
        #expect(PickedMedia.mimeType(forExtension: "MOV") == "video/quicktime")
        #expect(PickedMedia.mimeType(forExtension: "") == "application/octet-stream")
        #expect(
            PickedMedia.mimeType(forExtension: "zzzznotathing") == "application/octet-stream"
        )
    }
}

@Suite("Attaching files")
struct ComposeAttachmentsTests {
    @Test("what the attach row says about what was picked")
    func summaries() {
        #expect(ComposeAttachments.summary(imported: 0, failed: 0) == nil)
        #expect(ComposeAttachments.summary(imported: 1, failed: 0) == "1 file attached")
        #expect(ComposeAttachments.summary(imported: 3, failed: 0) == "3 files attached")
        #expect(
            ComposeAttachments.summary(imported: 2, failed: 1)
                == "1 of 3 could not be read. Remove them, or pick them again."
        )
    }

    @Test("a file that could not be read blocks Post rather than being dropped quietly")
    func failedImportBlocksPost() {
        #expect(ComposeAttachments.canPost(text: "hi", imported: 0, isBusy: false))
        #expect(ComposeAttachments.canPost(text: "", imported: 1, isBusy: false))
        #expect(!ComposeAttachments.canPost(text: "", imported: 0, isBusy: false))
        #expect(!ComposeAttachments.canPost(text: "   ", imported: 0, isBusy: false))
        #expect(!ComposeAttachments.canPost(text: "hi", imported: 1, isBusy: true))

        // The one that matters, and it is a REFUSAL now rather than a grey button: words plus a
        // photograph that did not arrive is not postable, and what stops it is a sentence naming
        // the file rather than a control that has gone quiet.
        let failed = ComposeAttachment(
            id: UUID(), media: nil, load: .failed(.transport), capture: .settled(.empty),
            label: "holiday.jpg")
        #expect(ComposeAttachments.postRefusal(items: [failed])?.contains("holiday.jpg") == true)
        #expect(ComposeAttachments.postRefusal(items: []) == nil)
    }
}
