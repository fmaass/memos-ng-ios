import CryptoKit
import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import Testing

@testable import MemosFeatures

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
            PendingMemoPresentation.status(
                for: job(), verdict: .refused(.cellularWhileMobileDataOff))
                == "Waiting for your home network — turn on Upload over mobile data in Settings"
                + " to send it now"
        )
    }

    /// The reason beats the attempt count. A capture refused by the network was never tried, so
    /// "Waiting to try again" would be describing a retry that is not happening.
    @Test("a held capture that had also failed before still says what it is waiting for")
    func theReasonBeatsTheAttemptCount() {
        let status = PendingMemoPresentation.status(
            for: job(attemptCount: 3), verdict: .refused(.cellularWhileMobileDataOff)
        )
        #expect(status.contains("home network"))
        #expect(!status.contains("try again"))
    }

    /// The refused sentence names the reason, and it comes from the queue's live verdict rather
    /// than from a marker on the job: the drain writes `waitReason` when it gets as far as trying,
    /// and a capture the network never let it start on has nothing written on it at all.
    @Test("a capture the network refuses reads the reason it was refused for")
    func theRefusedRowNamesTheReason() {
        let moving = job(files: [file(size: 1000, confirmed: 250)], state: .uploading)

        #expect(
            PendingMemoPresentation.rows(
                for: [moving], verdict: .refused(.cellularWhileMobileDataOff))[0].status
                == "Waiting for your home network — turn on Upload over mobile data in Settings"
                + " to send it now"
        )
        // A hotspot is the same hold under a different name for the radio, and the same switch
        // would send the capture now — so it is the same sentence.
        #expect(
            PendingMemoPresentation.rows(
                for: [moving], verdict: .refused(.expensiveWhileMobileDataOff))[0].status
                == "Waiting for your home network — turn on Upload over mobile data in Settings"
                + " to send it now"
        )
        // Low Data Mode is not that switch's business, so its sentence does not send a person to
        // a setting that would not help.
        #expect(
            PendingMemoPresentation.rows(for: [moving], verdict: .refused(.lowDataMode))[0].status
                == "Low Data Mode is on for this network — turn it off in Settings to send it now"
        )
        // The verdict decides, not the marker: a job still carrying `homeNetwork` on a network
        // that permits the upload is a capture waiting its turn, not one being held.
        #expect(
            PendingMemoPresentation.rows(
                for: [job(waitReason: .homeNetwork)], verdict: .permitted)[0].status
                == "Waiting for home wifi"
        )
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

    /// An edit already on the wire cannot be taken back, so the row stops offering to take it
    /// back. The queue is what refuses the cancel, where the job's state is owned; what this
    /// fences is the row promising something the queue would then have to refuse.
    @Test("a capture whose edit is already on the wire offers no Cancel")
    func anEditOnTheWireOffersNoCancel() {
        var sending = job(state: .uploading)
        sending.editSentAt = capture

        #expect(PendingMemoPresentation.action(for: sending) == [.retry])
        #expect(
            PendingMemoPresentation.action(for: job(state: .uploading)) == [.cancel, .retry],
            "the same capture with nothing on the wire still offers Cancel")
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
            lastProgressAt: progress, verdict: .permitted)[0]
        #expect(permitted.status == "No progress confirmed for 90 s")
        #expect(
            !permitted.status.localizedCaseInsensitiveContains("failed"),
            "nothing here knows that anything failed")

        // The same capture, on a network it may not use: the reason is known, so the row says the
        // reason rather than announcing a silence the network fully explains.
        let refused = PendingMemoPresentation.rows(
            for: [stalled], now: capture.addingTimeInterval(91),
            lastProgressAt: progress, verdict: .refused(.cellularWhileMobileDataOff))[0]
        #expect(
            refused.status
                == "Waiting for your home network — turn on Upload over mobile data in Settings"
                + " to send it now")

        // Under the interval the percentage still stands: a slow chunk is not a stalled one.
        let early = PendingMemoPresentation.rows(
            for: [stalled], now: capture.addingTimeInterval(89),
            lastProgressAt: progress, verdict: .permitted)[0]
        #expect(early.status == "Uploading 25%")
    }

    /// What cancel hands back, and what the editor does with it. The words have to come back
    /// exactly as they were written, and the pictures have to be the very same files — a restored
    /// draft that re-encoded anything would quietly replace the archive master with a copy of it.
    @Test("a cancelled capture opens the editor on its own words and its own files")
    @MainActor
    func theRestoredDraftReachesTheEditor() async throws {
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

        let mode = ComposeView.Mode.create(restoring: ComposeRestore(draft))
        let imports = ComposeImports()

        await PressProbe.withScreen(
            ComposeView(mode: mode, imports: imports) { _ in .saved },
            height: 852
        ) { screen in
            await screen.settle(turns: 200, until: { imports.attachments.count == 2 })
            #expect(screen.says("on the beach"))
        }

        // Read off the sheet's own import list rather than off the value handed to it: what a
        // person then sends is what the sheet took in, and a mapping that never ran leaves this
        // empty.
        let carried = imports.attachments
        // The ids are the outbox's own file ids, carried through unchanged: that is what lets a
        // re-submit say which pictures the memo keeps, and in what order.
        #expect(carried.map(\.id) == [firstID, secondID])
        #expect(carried.map(\.filename) == ["IMG_1.HEIC", "IMG_2.MOV"])
        #expect(carried.map(\.mime) == ["image/heic", "video/quicktime"])

        for (picture, source) in zip(carried, [first, second]) {
            let carriedBytes = try Data(contentsOf: picture.url)
            #expect(
                SHA256.hash(data: carriedBytes) == SHA256.hash(data: source),
                "the editor was handed a different file than the queue was holding")
        }
    }

    /// A cancelled capture nobody finished with. The bytes are kept on this device, and the row
    /// keeps saying so until a person either sends it again or throws it away.
    @Test("a cancelled capture left alone is kept, says so, and offers both ways out")
    func aCancelledCaptureIsKept() {
        var cancelled = job(state: .waiting)
        cancelled.cancelledAt = capture
        let row = PendingMemoPresentation.rows(for: [cancelled])[0]
        #expect(row.status == "Cancelled — kept on this device")
        #expect(row.actions == [.reopen, .remove])
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

/// What Post does with a create, and the one place that decides it.
///
/// A capture the editor was HANDED goes back to the job it came out of: same manifest, same key,
/// so a create that already committed resolves to its own memo rather than posting a second one.
/// The branch in the view holds no conditional of its own, which is what lets this be asked here.
@MainActor
@Suite("What Post does with a create")
struct TimelinePostRoutingTests {
    private let capture = Date(timeIntervalSince1970: 1_750_000_000)

    /// Which way out was taken, and with what. Local to this suite: what a recorder is has to be
    /// decided once per case, and a shared one would have to answer everything.
    private final class Routing {
        var resubmitted: [(UUID, RestoredDraft)] = []
        var enqueued: [ComposeSubmission] = []
        var answer = true
    }

    private func draft(_ jobID: UUID, visibility: MemoVisibility?) -> ComposeRestore {
        ComposeRestore(
            jobID: jobID, content: "on the beach", visibility: visibility, capturedAt: capture,
            pictures: [])
    }

    private func post(
        _ routing: Routing,
        _ submission: ComposeSubmission,
        restoring restored: ComposeRestore?,
        accountDefault: MemoVisibility? = nil
    ) async -> Bool {
        await TimelineView.post(
            submission,
            restoring: restored,
            accountDefault: accountDefault,
            resubmit: {
                routing.resubmitted.append(($0, $1))
                return routing.answer
            },
            enqueue: {
                routing.enqueued.append($0)
                return true
            }
        )
    }

    @Test("a restored draft goes back to the job it came out of")
    func postSendsARestoredDraftBackToItsJob() async {
        let routing = Routing()
        let jobID = UUID()
        let submission = ComposeSubmission(
            content: "on the beach", visibility: .private, attachments: [])

        let sent = await post(routing, submission, restoring: draft(jobID, visibility: .private))

        #expect(sent)
        #expect(
            routing.enqueued.isEmpty,
            "a restored draft goes back to its job, never out as a second capture")
        #expect(routing.resubmitted.count == 1)
        #expect(routing.resubmitted.first?.0 == jobID)
        #expect(routing.resubmitted.first?.1.jobID == jobID)
        #expect(routing.resubmitted.first?.1.content == "on the beach")
    }

    /// The job the editor was opened on is gone by the time Post is pressed. The words and the
    /// files on this screen are not thrown away for that — they become a new capture. This is an
    /// assumption stated rather than a rule anything else already holds.
    @Test("a capture whose job vanished under the editor becomes a fresh one")
    func aVanishedJobBecomesAFreshCapture() async {
        let routing = Routing()
        routing.answer = false
        let jobID = UUID()
        let submission = ComposeSubmission(
            content: "on the beach", visibility: .private, attachments: [])

        let sent = await post(routing, submission, restoring: draft(jobID, visibility: .private))

        #expect(sent)
        #expect(routing.resubmitted.count == 1, "the job was asked for first")
        #expect(routing.enqueued.count == 1)
    }

    @Test("a capture the editor was not handed is a new one, and is enqueued")
    func aNewCaptureIsEnqueued() async {
        let routing = Routing()
        let submission = ComposeSubmission(
            content: "on the beach", visibility: .private, attachments: [])

        let sent = await post(routing, submission, restoring: nil)

        #expect(sent)
        #expect(routing.resubmitted.isEmpty)
        #expect(routing.enqueued.count == 1)
    }

    /// "Default" is a word on a picker, not a value a memo can carry. A capture created PUBLIC and
    /// then edited to Default has to reach the server as the account's own default, because the
    /// queue's fallback for an edit that states nothing is the visibility the job already has —
    /// which is exactly the one the person just stopped choosing.
    @Test("Default resolves to the account's own visibility, not to what the capture had")
    func defaultResolvesToTheAccountsOwnChoice() async {
        let routing = Routing()
        let jobID = UUID()
        let unmarked = ComposeSubmission(content: "on the beach", visibility: nil, attachments: [])

        _ = await post(
            routing, unmarked, restoring: draft(jobID, visibility: .public),
            accountDefault: .private)
        #expect(routing.resubmitted.last?.1.visibility == "PRIVATE")

        // No account default known yet: the edit states nothing, and the queue's own fallback to
        // what the job already carries is the right answer rather than a guess made here.
        _ = await post(
            routing, unmarked, restoring: draft(jobID, visibility: .public), accountDefault: nil)
        #expect(routing.resubmitted.last?.1.visibility == nil)

        // A picked visibility is the person's own answer; the account default never overrides it.
        let picked = ComposeSubmission(
            content: "on the beach", visibility: .public, attachments: [])
        _ = await post(
            routing, picked, restoring: draft(jobID, visibility: .private),
            accountDefault: .private)
        #expect(routing.resubmitted.last?.1.visibility == "PUBLIC")
    }
}

/// The one place on the timeline whose sentence changes because time passed rather than because
/// something happened.
///
/// The clock is injected by CHOOSING `lastProgressAt`: the real 90 s constant with a last-progress
/// instant 90 s less a moment ago, so the deadline falls a fraction of a second into the case.
/// Nothing is faked, and no clock is handed to the section.
@MainActor
@Suite("The pending section wakes at the stall deadline")
struct PendingSectionDeadlineTests {
    private let capture = Date(timeIntervalSince1970: 1_750_000_000)

    private func job(confirmed: Int64, state: JobState = .uploading) -> UploadJob {
        UploadJob(
            content: "on the beach",
            capturedAt: capture,
            files: [
                OutboxFile(
                    relativePath: "a.heic",
                    filename: "IMG_1.HEIC",
                    mime: "image/heic",
                    byteSize: 1000,
                    uploadUID: "u1",
                    bytesConfirmed: confirmed
                )
            ],
            binding: AccountBinding(
                serverBaseURL: URL(string: "https://memos.example.invalid")!,
                ownerSubject: "fabian"
            ),
            state: state
        )
    }

    @Test("the row stops counting at the deadline, with nothing else having happened")
    func theRowStopsCountingWhenTheDeadlinePasses() async {
        let moving = job(confirmed: 250)
        let due = Date().addingTimeInterval(0.15)
        let progress = [moving.id: due.addingTimeInterval(-PendingMemoPresentation.stallInterval)]

        await PressProbe.withScreen(
            List {
                PendingSection(
                    jobs: [moving],
                    lastProgressAt: progress,
                    verdict: .permitted,
                    retry: { _ in },
                    remove: { _ in },
                    restore: { _ in }
                )
            },
            height: 400
        ) { screen in
            await screen.settle(turns: 5)
            #expect(screen.says("Uploading 25%"), "under the interval the percentage stands")
            await screen.settle(
                turns: 400, until: { screen.says("No progress confirmed for 90 s") })
            #expect(
                screen.says("No progress confirmed for 90 s"),
                "the sentence changed with no event but the deadline")
            #expect(!screen.says("Uploading 25%"))
        }
    }

    /// One wake, at the first instant any row would start saying something else — never a tick.
    @Test("the earliest deadline wins, and a capture that is not uploading has none")
    func theEarliestDeadlineWins() {
        let first = job(confirmed: 250)
        let second = job(confirmed: 500)
        let progress = [first.id: capture, second.id: capture.addingTimeInterval(10)]

        #expect(
            PendingMemoPresentation.stallDeadline(
                for: [first, second], lastProgressAt: progress, after: capture)
                == capture.addingTimeInterval(PendingMemoPresentation.stallInterval)
        )
        // A deadline already behind the instant it is measured from is not a wake to arm.
        #expect(
            PendingMemoPresentation.stallDeadline(
                for: [first], lastProgressAt: progress,
                after: capture.addingTimeInterval(PendingMemoPresentation.stallInterval + 1))
                == nil
        )
        // Nothing is counting on a capture whose bytes are not moving.
        let waiting = job(confirmed: 250, state: .waiting)
        #expect(
            PendingMemoPresentation.stallDeadline(
                for: [waiting], lastProgressAt: [waiting.id: capture], after: capture) == nil
        )
    }
}
