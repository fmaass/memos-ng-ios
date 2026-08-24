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
        #expect(row.action == .remove)
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
        #expect(PendingMemoPresentation.rows(for: [unwritable])[0].action == .retry)
    }

    @Test("every hold offers exactly one thing, and only the unreadable one offers Remove")
    func actionPerHoldReason() {
        // The switch is what makes this exhaustive: a hold reason added later does not compile
        // until someone has said what its row lets a person do about it.
        for reason in HoldReason.allCases {
            let held = job(state: .held, holdReason: reason)
            switch reason {
            case .unreadableManifest:
                #expect(PendingMemoPresentation.action(for: held) == .remove)
                #expect(PendingMemoPresentation.rows(for: [held])[0].action == .remove)
            case .accountMismatch, .serverRefused, .storageFailed:
                #expect(PendingMemoPresentation.action(for: held) == .retry)
                #expect(PendingMemoPresentation.rows(for: [held])[0].action == .retry)
            }
        }
        // A hold with no reason recorded is still a hold a person may clear.
        #expect(PendingMemoPresentation.action(for: job(state: .held)) == .retry)
        // Nothing that is still moving asks anything of anybody.
        for state in [JobState.waiting, .uploading, .creating] {
            let moving = job(state: state)
            #expect(PendingMemoPresentation.action(for: moving) == .none)
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
        #expect(ComposeAttachments.canPost(text: "hi", imported: 0, failed: 0, isBusy: false))
        #expect(ComposeAttachments.canPost(text: "", imported: 1, failed: 0, isBusy: false))
        #expect(!ComposeAttachments.canPost(text: "", imported: 0, failed: 0, isBusy: false))
        #expect(!ComposeAttachments.canPost(text: "   ", imported: 0, failed: 0, isBusy: false))
        // The one that matters: words plus a photo that did not arrive is NOT postable.
        #expect(!ComposeAttachments.canPost(text: "hi", imported: 1, failed: 1, isBusy: false))
        #expect(!ComposeAttachments.canPost(text: "hi", imported: 1, failed: 0, isBusy: true))
    }
}
