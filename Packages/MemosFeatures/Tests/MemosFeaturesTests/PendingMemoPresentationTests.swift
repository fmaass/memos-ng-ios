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
