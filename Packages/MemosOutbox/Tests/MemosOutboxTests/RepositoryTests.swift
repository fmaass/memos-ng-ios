import CryptoKit
import Foundation
import MemosOutbox
import Testing

@Suite("The outbox on disk")
struct RepositoryTests {
    /// Every test gets its own container, removed afterwards.
    private func withRepository(
        _ body: (OutboxRepository, URL) async throws -> Void
    ) async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(OutboxRepository(root: root.appending(path: "outbox")), root)
    }

    @Test("a capture is on disk, whole, before anything else happens")
    func enqueuePersists() async throws {
        try await withRepository { repository, root in
            let first = try Fixture.file(in: root, named: "one.heic", bytes: 1234)
            let second = try Fixture.file(in: root, named: "two.mov", bytes: 4321)
            let job = try await repository.enqueue(
                content: "on the beach",
                visibility: "PRIVATE",
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
                binding: Fixture.binding(),
                sources: [
                    StagedSource(url: first, filename: "one.heic", mime: "image/heic"),
                    StagedSource(url: second, filename: "two.mov", mime: "video/quicktime"),
                ]
            )
            #expect(job.files.count == 2)
            #expect(job.files.map(\.byteSize) == [1234, 4321])
            #expect(job.files.map(\.filename) == ["one.heic", "two.mov"])

            // A different repository over the same directory is what a relaunch sees.
            let reloaded = try await OutboxRepository(root: root.appending(path: "outbox"))
                .loadJobs()
            #expect(reloaded.count == 1)
            #expect(reloaded.first == job)
            #expect(reloaded.first?.idempotencyKey == job.idempotencyKey)
        }
    }

    @Test("a capture that fails half way leaves no job and no files")
    func enqueueIsAtomic() async throws {
        try await withRepository { repository, root in
            let real = try Fixture.file(in: root, named: "one.heic", bytes: 100)
            let vanished = root.appending(path: "gone.mov")
            await #expect(throws: (any Error).self) {
                try await repository.enqueue(
                    content: "half a capture",
                    visibility: nil,
                    capturedAt: Date(),
                    binding: Fixture.binding(),
                    sources: [
                        StagedSource(url: real, filename: "one.heic", mime: "image/heic"),
                        StagedSource(url: vanished, filename: "gone.mov", mime: "video/quicktime"),
                    ]
                )
            }
            #expect(await repository.loadJobs().isEmpty)
            let media = root.appending(path: "outbox").appending(path: "media")
            let leftovers = try FileManager.default.contentsOfDirectory(
                at: media, includingPropertiesForKeys: nil
            )
            #expect(leftovers.isEmpty)
        }
    }

    @Test("a file reaches the outbox byte-identical")
    func copyIsByteIdentical() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "original.heic", bytes: 300_000)
            let before = SHA256.hash(data: try Data(contentsOf: source))
            let job = try await repository.enqueue(
                content: "",
                visibility: nil,
                capturedAt: Date(),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "original.heic", mime: "image/heic")]
            )
            let stored = repository.mediaURL(job: job, file: job.files[0])
            let after = SHA256.hash(data: try Data(contentsOf: stored))
            #expect(before == after)
            // The picker's own copy is not consumed: it is still there.
            #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        }
    }

    @Test("a slice is exactly the bytes at that offset")
    func slicesExactBytes() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "video.mov", bytes: 2500)
            let job = try await repository.enqueue(
                content: "",
                visibility: nil,
                capturedAt: Date(),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "video.mov", mime: "video/quicktime")]
            )
            let file = job.files[0]
            let whole = Fixture.content(2500)

            let first = try await repository.sliceChunk(
                job: job, file: file, offset: 0, length: 1000
            )
            #expect(try Data(contentsOf: first) == Data(whole.prefix(1000)))

            let last = try await repository.sliceChunk(
                job: job, file: file, offset: 2000, length: 500
            )
            #expect(try Data(contentsOf: last) == Data(whole.suffix(500)))

            await repository.removeChunk(at: first)
            #expect(!FileManager.default.fileExists(atPath: first.path(percentEncoded: false)))
        }
    }

    @Test("asking for more bytes than the file has is a failure, not a short chunk")
    func refusesShortRead() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "small.bin", bytes: 100)
            let job = try await repository.enqueue(
                content: "",
                visibility: nil,
                capturedAt: Date(),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "small.bin", mime: "image/heic")]
            )
            await #expect(throws: OutboxStorageError.shortRead(expected: 200, got: 100)) {
                try await repository.sliceChunk(
                    job: job, file: job.files[0], offset: 0, length: 200
                )
            }
        }
    }

    @Test("a completed job takes its originals with it, and orphans are swept")
    func deleteAndSweep() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "one.heic", bytes: 100)
            let job = try await repository.enqueue(
                content: "",
                visibility: nil,
                capturedAt: Date(),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
            )
            let media = repository.mediaURL(job: job, file: job.files[0])
            #expect(FileManager.default.fileExists(atPath: media.path(percentEncoded: false)))

            await repository.delete(job)
            #expect(await repository.loadJobs().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: media.path(percentEncoded: false)))

            // An unreferenced media directory — what a crash mid-capture leaves — is swept.
            let orphan = root.appending(path: "outbox").appending(path: "media")
                .appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            await repository.sweepOrphans()
            #expect(!FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)))
        }
    }

    @Test("a saved job round-trips through JSON with its dates and cursors intact")
    func savesAndReloads() async throws {
        try await withRepository { repository, _ in
            let file = Fixture.file(uploadUID: "u1", byteSize: 900, bytesConfirmed: 400)
            let job = Fixture.job(files: [file], state: .uploading)
            try await repository.save(job)
            let reloaded = try #require(await repository.job(job.id))
            #expect(reloaded == job)
            #expect(reloaded.capturedAt == job.capturedAt)
            #expect(reloaded.files[0].bytesConfirmed == 400)
        }
    }
}
