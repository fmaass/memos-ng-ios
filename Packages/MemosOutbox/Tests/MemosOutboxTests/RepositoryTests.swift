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
            #expect(try await repository.loadJobs().isEmpty)
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
            #expect(try await repository.loadJobs().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: media.path(percentEncoded: false)))

            // An unreferenced media directory — what a crash mid-capture leaves — is swept.
            let orphan = root.appending(path: "outbox").appending(path: "media")
                .appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            _ = try await repository.sweepOrphans()
            #expect(!FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)))
        }
    }

    @Test("a manifest nobody can decode is set aside, not dropped, and its files are kept")
    func quarantinesAnUndecodableManifest() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "one.heic", bytes: 4096)
            let job = try await repository.enqueue(
                content: "on the beach",
                visibility: nil,
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
            )
            let media = repository.mediaURL(job: job, file: job.files[0])
            let mediaBefore = try Data(contentsOf: media)
            let outbox = root.appending(path: "outbox")
            let manifest = outbox.appending(path: "jobs/\(job.id.uuidString).json")
            let corrupt = Data(#"{"id":"not a job"}"#.utf8)
            try corrupt.write(to: manifest)

            let jobs = try await repository.loadJobs()

            #expect(jobs.count == 1, "a capture is never dropped for being unreadable")
            #expect(jobs[0].id == job.id)
            #expect(jobs[0].state == .held)
            #expect(jobs[0].holdReason == .unreadableManifest)
            #expect(jobs[0].lastError?.isEmpty == false, "and it says WHY it could not be read")

            // Set aside, not deleted: the bytes are exactly the ones that were there.
            #expect(!FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)))
            let aside = outbox.appending(path: "quarantine/\(job.id.uuidString).json")
            #expect(try Data(contentsOf: aside) == corrupt)
            #expect(try Data(contentsOf: media) == mediaBefore)

            // It keeps saying so: the entry is not a one-off of the load that moved it.
            #expect(try await repository.loadJobs() == jobs)

            // And the sweep goes on counting those originals as spoken for, exactly as it would
            // for a job it could read. This is what "its files are kept" has to survive.
            _ = try await repository.sweepOrphans()
            #expect(try Data(contentsOf: media) == mediaBefore)
        }
    }

    @Test("what could not be read says which way it failed, whatever the file is called")
    func saysWhichWayEachOneFailed() async throws {
        try await withRepository { repository, root in
            let jobs = root.appending(path: "outbox").appending(path: "jobs")
            try Data("not json at all".utf8).write(to: jobs.appending(path: "notes.json"))
            let id = UUID()
            try Data(#"{"id":"\#(id.uuidString)"}"#.utf8)
                .write(to: jobs.appending(path: "\(id.uuidString).json"))

            let loaded = try await repository.loadJobs()

            #expect(loaded.count == 2, "a file nobody can place is still a file nobody may drop")
            #expect(loaded.allSatisfy { $0.holdReason == .unreadableManifest })
            #expect(loaded.contains { $0.id == id }, "the one that IS named after a job keeps it")
            #expect(
                Set(loaded.compactMap(\.lastError)).count == 2,
                "one sentence per way of failing, not a shrug that fits both"
            )

            // The row a person is looking at does not change identity under them on a refresh.
            let again = try await repository.loadJobs()
            #expect(Set(again.map(\.id)) == Set(loaded.map(\.id)))
        }
    }

    @Test("one capture set aside twice is one row, and both files it left are still there")
    func aTwiceQuarantinedCaptureIsOneRow() async throws {
        try await withRepository { repository, root in
            // What two launches that each failed to read the same manifest leave behind: the
            // second copy keeps the id at the front of its name, which is how the sweep knows the
            // originals under it are still spoken for.
            let quarantine = root.appending(path: "outbox").appending(path: "quarantine")
            let id = UUID()
            let first = quarantine.appending(path: "\(id.uuidString).json")
            let second = quarantine.appending(path: "\(id.uuidString).\(UUID().uuidString).json")
            let firstBytes = Data(#"{"id":"the first attempt"}"#.utf8)
            let secondBytes = Data(#"{"id":"the second attempt"}"#.utf8)
            try firstBytes.write(to: first)
            try secondBytes.write(to: second)

            let jobs = try await repository.loadJobs()

            #expect(jobs.count == 1, "two files under one id is still one capture")
            #expect(jobs[0].id == id)
            // Nothing was thrown away or merged to get there: both files are byte for byte as they
            // were, because the older one may still be worth something to somebody.
            #expect(try Data(contentsOf: first) == firstBytes)
            #expect(try Data(contentsOf: second) == secondBytes)
            // And a launch can plan over what came back — a duplicate id used to take the whole
            // queue down here rather than one row.
            #expect(OutboxReconciliation.plan(jobs: jobs, inFlight: []).drainable == [id])
        }
    }

    @Test("a capture nobody can read leaves the device whole when a person says to")
    func discardsAQuarantinedCapture() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "one.heic", bytes: 2048)
            let job = try await repository.enqueue(
                content: "on the beach",
                visibility: nil,
                capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
            )
            let media = repository.mediaURL(job: job, file: job.files[0])
            let outbox = root.appending(path: "outbox")
            let manifest = outbox.appending(path: "jobs/\(job.id.uuidString).json")
            let chunk = try await repository.sliceChunk(
                job: job, file: job.files[0], offset: 0, length: 16
            )
            // Corrupted, set aside, and corrupted again: the capture has two files in quarantine,
            // which is the state a person is actually looking at when they press Remove.
            try Data(#"{"id":"not a job"}"#.utf8).write(to: manifest)
            _ = try await repository.loadJobs()
            try Data(#"{"id":"still not a job"}"#.utf8).write(to: manifest)
            let rows = try await repository.loadJobs()
            #expect(rows.count == 1)
            #expect(rows[0].holdReason == .unreadableManifest)

            try await repository.discard(job.id)

            #expect(try await repository.loadJobs().isEmpty, "the row does not come back")
            let mediaDirectory = outbox.appending(path: "media/\(job.id.uuidString)")
            #expect(
                !FileManager.default.fileExists(atPath: media.path(percentEncoded: false)),
                "the originals go with it"
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: mediaDirectory.path(percentEncoded: false)
                )
            )
            #expect(
                !FileManager.default.fileExists(atPath: chunk.path(percentEncoded: false)),
                "and so does the slice that was in flight"
            )
            let left = try FileManager.default.contentsOfDirectory(
                at: outbox.appending(path: "quarantine"), includingPropertiesForKeys: nil
            )
            #expect(left.isEmpty, "including every copy that was set aside under that id")
        }
    }

    @Test("a jobs directory that cannot be listed is an error, never an empty queue")
    func anUnlistableQueueIsAnError() async throws {
        try await withRepository { repository, root in
            let source = try Fixture.file(in: root, named: "one.heic", bytes: 512)
            let job = try await repository.enqueue(
                content: "",
                visibility: nil,
                capturedAt: Date(),
                binding: Fixture.binding(),
                sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
            )
            let media = repository.mediaURL(job: job, file: job.files[0])
            let restore = try Fixture.permissions(
                0, on: root.appending(path: "outbox").appending(path: "jobs")
            )
            defer { restore() }

            await #expect(throws: (any Error).self) { try await repository.loadJobs() }
            // And nothing is swept on the strength of a list nobody could produce: an empty one
            // would take every capture's originals with it.
            await #expect(throws: (any Error).self) { try await repository.sweepOrphans() }
            #expect(FileManager.default.fileExists(atPath: media.path(percentEncoded: false)))
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
