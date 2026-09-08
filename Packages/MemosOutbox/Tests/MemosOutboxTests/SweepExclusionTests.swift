import Darwin
import Foundation
import Testing

@testable import MemosOutbox

/// `flock(2)` itself, this suite's own — not the package's, so that neutralising the seam below
/// can never move the lock a test takes on its own descriptor. The bare name `flock` resolves to
/// the record-lock struct out of `fcntl.h`; the local's type is what picks the call.
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    let call: @convention(c) (Int32, Int32) -> Int32 = flock
    return call(descriptor, operation)
}

/// The `flock(2)` these repositories exclude each other with.
///
/// Named once, and in one place, because the red-without-the-fix run has exactly one thing to
/// neutralise: replace this body with `{ _, _ in 0 }` and every acquisition succeeds, which is the
/// repository as it was before any of this existed. The suite must go red under that.
private let exclusion: @Sendable (Int32, Int32) -> Int32 = { systemFlock($0, $1) }

/// A lock that does not work here at all — what a filesystem without locking, or a process out of
/// descriptors, answers. No real filesystem on the build machine can be asked for this branch.
private let unavailableLock: @Sendable (Int32, Int32) -> Int32 = { _, _ in
    errno = ENOTSUP
    return -1
}

@Suite("The sweep and the other process")
struct SweepExclusionTests {
    /// Two repositories over ONE root is the app and the share extension exactly: separate
    /// instances, separate actors, one directory tree, and no isolation between them that means
    /// anything — which is the whole subject.
    private func repository(
        over root: URL,
        flock: @escaping @Sendable (Int32, Int32) -> Int32 = exclusion
    ) throws -> OutboxRepository {
        try OutboxRepository(root: root, flock: flock)
    }

    private func capture(
        through repository: OutboxRepository,
        source: URL,
        id: UUID
    ) async throws -> UploadJob {
        try await repository.enqueue(
            content: "from the share sheet",
            visibility: nil,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")],
            id: id
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func plantOrphanDirectory(in outbox: URL) throws -> URL {
        let url = outbox.appending(path: "media").appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func plantOrphanChunk(in outbox: URL) throws -> URL {
        let name = "\(UUID().uuidString)-\(UUID().uuidString)-0.part"
        let url = outbox.appending(path: "chunks").appending(path: name)
        try Data([1, 2, 3, 4]).write(to: url)
        return url
    }

    // MARK: - the interleaving the bug lived in

    @Test("a capture written while a sweep is parked mid-pass survives that sweep")
    func aParkedSweepNeverTakesTheOtherProcessesCapture() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let app = try repository(over: outbox)
        let extensionSide = try repository(over: outbox)
        let orphan = try plantOrphanDirectory(in: outbox)

        // Parked exactly where the loss happened: the lease taken, the live set read, nothing
        // deleted yet — and the capture below is not in that list, because it does not exist yet.
        guard let parked = try await app.beginSweep() else {
            Issue.record("the sweep could not take its own lease")
            return
        }

        let source = try Fixture.file(in: root, named: "one.heic", bytes: 2048)
        let bytes = try Data(contentsOf: source)
        let id = UUID()
        // BOTH outcomes are tolerated here. A repository without the lease accepts this capture;
        // one with it refuses. What this test claims is what survives the deletion pass, not which
        // way the attempt went — so the attempt is not the assertion.
        let accepted = try? await capture(through: extensionSide, source: source, id: id)

        let job: UploadJob
        if let accepted {
            // Kept exactly as it landed: retrying or repairing it here would hide the loss.
            _ = try await app.finishSweep(parked)
            job = accepted
        } else {
            #expect(
                !exists(outbox.appending(path: "media").appending(path: id.uuidString)),
                "a refused capture leaves nothing behind for the sweep to find"
            )
            let outcome = try await app.finishSweep(parked)
            #expect(
                outcome == .swept(media: 1, chunks: 0),
                "the pass removes the orphan it was entitled to, and nothing else"
            )
            job = try await capture(through: extensionSide, source: source, id: id)
        }

        // The claim: the capture's originals are still there, byte for byte, and its manifest
        // still resolves to it. This is what goes red when nothing excludes anything.
        for file in job.files {
            let original = app.mediaURL(job: job, file: file)
            #expect(exists(original), "the capture's originals survive the sweep it raced")
            #expect((try? Data(contentsOf: original)) == bytes, "byte for byte")
        }
        let resolved = await extensionSide.job(job.id)
        #expect(resolved != nil, "and its manifest still resolves")
        #expect(!exists(orphan), "while the orphan the pass was entitled to is gone")

        // And the contract that makes the accepted branch unreachable.
        #expect(accepted == nil, "an enqueue that meets a held sweep lease is refused")
    }

    // MARK: - the cross-process semantics, from a second descriptor

    @Test("a sweep defers to a lock another descriptor holds, and runs once it is dropped")
    func defersToAForeignSharedLock() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let queue = try repository(over: outbox)
        let orphanDirectory = try plantOrphanDirectory(in: outbox)
        let orphanChunk = try plantOrphanChunk(in: outbox)

        // The share extension's shape, held on a descriptor of this test's own. `flock` locks the
        // open file description rather than the process, so this conflicts with the repository's
        // acquisition exactly as another process would — the real call, never the seam.
        let held = Darwin.open(
            outbox.appending(path: ".lock").path(percentEncoded: false), O_RDWR
        )
        #expect(held >= 0, "the repository put its lock file at the root")
        #expect(systemFlock(held, LOCK_SH | LOCK_NB) == 0)

        #expect(try await queue.sweepOrphans() == .deferred(.contended))
        #expect(exists(orphanDirectory), "nothing is deleted without the lease")
        #expect(exists(orphanChunk), "and that covers the chunks, not only the media")

        close(held)

        #expect(try await queue.sweepOrphans() == .swept(media: 1, chunks: 1))
        #expect(!exists(orphanDirectory))
        #expect(!exists(orphanChunk))
    }

    @Test("a capture refuses to publish while another descriptor holds the root exclusively")
    func enqueueRefusesUnderAForeignExclusiveLock() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let queue = try repository(over: outbox)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1024)

        let held = Darwin.open(
            outbox.appending(path: ".lock").path(percentEncoded: false), O_RDWR
        )
        defer { close(held) }
        #expect(held >= 0)
        #expect(systemFlock(held, LOCK_EX | LOCK_NB) == 0)

        let id = UUID()
        await #expect(throws: OutboxStorageError.queueBusy(.contended)) {
            try await capture(through: queue, source: source, id: id)
        }
        #expect(
            !exists(outbox.appending(path: "media").appending(path: id.uuidString)),
            "and it refused before it wrote anything"
        )
    }

    // MARK: - the chunk half of the same pass

    @Test("a sweep that runs takes the orphaned slice and leaves a live job's slice alone")
    func aLiveJobsChunkSurvivesTheSweep() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let queue = try repository(over: outbox)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1024)
        let job = try await capture(through: queue, source: source, id: UUID())
        let live = try await queue.sliceChunk(job: job, file: job.files[0], offset: 0, length: 16)
        let orphanChunk = try plantOrphanChunk(in: outbox)

        #expect(try await queue.sweepOrphans() == .swept(media: 0, chunks: 1))
        #expect(exists(live), "a slice a live job may still be uploading is never swept")
        #expect(!exists(orphanChunk))
    }

    // MARK: - a lock that does not work here

    @Test("a lock that cannot be taken at all stops the sweep AND the capture")
    func degradesClosedWhenTheLockIsUnavailable() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let queue = try repository(over: outbox, flock: unavailableLock)
        let orphanDirectory = try plantOrphanDirectory(in: outbox)
        let orphanChunk = try plantOrphanChunk(in: outbox)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1024)

        #expect(try await queue.sweepOrphans() == .deferred(.lockUnavailable(ENOTSUP)))
        #expect(exists(orphanDirectory), "a pass with no lease deletes nothing")
        #expect(exists(orphanChunk))

        let id = UUID()
        await #expect(throws: OutboxStorageError.queueBusy(.unavailable(ENOTSUP))) {
            try await capture(through: queue, source: source, id: id)
        }
        #expect(
            !exists(outbox.appending(path: "media").appending(path: id.uuidString)),
            "a capture with no lease publishes nothing, whichever way the lease failed"
        )
    }

    @Test("a capture whose own lock is unavailable publishes nothing while a real sweep holds it")
    func refusesUnderARealLeaseWhenItsOwnLockIsUnavailable() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let app = try repository(over: outbox)
        let extensionSide = try repository(over: outbox, flock: unavailableLock)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1024)

        guard let parked = try await app.beginSweep() else {
            Issue.record("the sweep could not take its own lease")
            return
        }

        let id = UUID()
        await #expect(throws: OutboxStorageError.queueBusy(.unavailable(ENOTSUP))) {
            try await capture(through: extensionSide, source: source, id: id)
        }
        let media = outbox.appending(path: "media").appending(path: id.uuidString)
        #expect(!exists(media))

        let outcome = try await app.finishSweep(parked)
        #expect(outcome == .swept(media: 0, chunks: 0))
        #expect(!exists(media), "nothing of the refused capture existed to lose")
    }
}
