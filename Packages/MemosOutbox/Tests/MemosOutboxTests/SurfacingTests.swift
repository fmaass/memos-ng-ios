import Foundation
import MemosOutbox
import Testing

/// What the outbox SAYS when the disk fights back.
///
/// The queue's whole promise is that a capture is never lost, so the two ways the disk can refuse —
/// a queue that cannot be listed, and a write that does not land — are followed all the way to the
/// sentence a person reads, rather than asserted at the repository and assumed at the top. Both are
/// made to happen for real, by taking the permissions off the directory the queue lives in: that is
/// the shape a container that has gone away, or a disk with nothing left on it, actually has. The
/// third test is the way OUT of the one of those that never mends itself.
@MainActor
@Suite("An outbox whose disk says no")
struct SurfacingTests {
    private func facade(_ repository: OutboxRepository, http: ScriptedHTTP) -> Outbox {
        Outbox(
            repository: repository,
            credentials: StaticCredentials(credentials: Fixture.credentials()),
            http: http,
            scheduler: ScriptedScheduler(),
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now"))
        )
    }

    private func capture(in repository: OutboxRepository, root: URL, bytes: Int) async throws {
        let source = try Fixture.file(in: root, named: "one.heic", bytes: bytes)
        _ = try await repository.enqueue(
            content: "on the beach",
            visibility: nil,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
    }

    @Test("a queue that cannot be read is an error on the outbox, never an empty list")
    func anUnreadableQueueIsNotAnEmptyOne() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        try await capture(in: repository, root: root, bytes: 256)
        let outbox = facade(repository, http: .standard(health: 500))
        await outbox.refresh()
        #expect(outbox.jobs.count == 1)

        let restore = try Fixture.permissions(
            0, on: root.appending(path: "outbox").appending(path: "jobs")
        )
        defer { restore() }

        await outbox.refresh()

        #expect(outbox.jobs.count == 1, "what a person is looking at does not vanish")
        #expect(outbox.lastError?.contains("could not be read") == true)
    }

    @Test("a write the drain could not make reaches the sentence a person reads")
    func aRefusedWriteIsSaidOutLoud() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        try await capture(in: repository, root: root, bytes: 1000)
        let outbox = facade(repository, http: .standard(chunkSize: 400))
        await outbox.refresh()
        #expect(outbox.lastError == nil)

        // The queue can still be READ; it can no longer be written to.
        let restore = try Fixture.permissions(
            0o500, on: root.appending(path: "outbox").appending(path: "jobs")
        )
        defer { restore() }

        await outbox.drain()

        #expect(outbox.jobs.count == 1, "the capture is still there, whole")
        #expect(outbox.lastError?.contains("could not be saved on this device") == true)
    }

    @Test("a capture nobody can read can be thrown away from the list it is stuck in")
    func aQuarantinedCaptureCanBeRemoved() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        try await capture(in: repository, root: root, bytes: 128)
        let outbox = facade(repository, http: .standard(health: 500))
        await outbox.refresh()
        let captured = try #require(outbox.jobs.first)

        try Data(#"{"id":"not a job"}"#.utf8)
            .write(to: root.appending(path: "outbox/jobs/\(captured.id.uuidString).json"))
        await outbox.refresh()
        #expect(outbox.jobs.count == 1, "it is surfaced rather than dropped")
        #expect(outbox.jobs[0].holdReason == .unreadableManifest)

        // Nothing automatic will ever move that row: this is the recourse, and it is a person's.
        await outbox.discard(captured.id)

        #expect(outbox.jobs.isEmpty, "and it stays gone on the read that follows")
        #expect(outbox.lastError == nil)
    }
}
