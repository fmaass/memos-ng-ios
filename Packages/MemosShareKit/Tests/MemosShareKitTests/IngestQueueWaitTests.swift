import Foundation
import MemosOutbox
import MemosShareKit
import Testing

/// The share extension meeting a queue the app is holding.
///
/// Taken through `ShareIngest.commit` and nothing smaller. The wait is a helper anybody can call
/// correctly in a test and forget at the one call site that matters, so what is asserted here is
/// the extension's own entry point: the thing `ShareRootView.post()` calls.
@Suite("A share that meets a busy queue")
struct IngestQueueWaitTests {
    private func staged(in root: URL) throws -> SharedItem {
        let file = try Fixture.file(in: root, named: "IMG_0007.heic", bytes: 1024)
        return .file(try SharedFile.imported(file, into: root))
    }

    private func mediaDirectories(in outbox: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: outbox.appending(path: "media"), includingPropertiesForKeys: nil
        )
    }

    @Test("a queue held for two waits is waited out, and the share is kept on the third attempt")
    func waitsOutABriefHoldAndKeepsTheShare() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let repository = try OutboxRepository(root: outbox)
        let item = try staged(in: root)

        // The app's shape: the root held exclusively, from a descriptor of this suite's own.
        let held = try #require(
            ForeignRootLock(exclusiveOn: outbox),
            "the repository put its lock file at the root"
        )
        defer { held.release() }
        // Dropped INSIDE the second wait, so the attempt that succeeds is the third and the count
        // is not a race with a timer.
        let clock = FakeWaitClock { count in if count == 2 { held.release() } }

        let outcome = try await ShareIngest.commit(
            items: [item],
            note: "on the beach",
            visibility: nil,
            binding: { Fixture.binding() },
            expecting: Fixture.binding(),
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            waitingOn: clock,
            into: repository
        )

        guard case .enqueued(let id) = outcome else {
            Issue.record("expected the share to be queued once the hold dropped, got \(outcome)")
            return
        }
        #expect(
            clock.sleeps == [.milliseconds(100), .milliseconds(100)],
            "two waits of the configured interval — attempt one, attempt two, then the capture"
        )
        let job = try #require(await repository.job(id))
        #expect(job.content == "on the beach")
        #expect(job.binding == Fixture.binding(), "the licence is re-read on the attempt that wins")
        #expect(job.files.count == 1)
        #expect(
            try mediaDirectories(in: outbox).map(\.lastPathComponent) == [id.uuidString],
            "and the refused attempts left nothing behind to be swept"
        )
    }

    @Test("a queue held for the whole budget refuses the share and writes nothing at all")
    func givesUpOnTheDeadlineAndWritesNothing() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = root.appending(path: "outbox")
        let repository = try OutboxRepository(root: outbox)
        let item = try staged(in: root)

        let held = try #require(ForeignRootLock(exclusiveOn: outbox))
        defer { held.release() }
        let clock = FakeWaitClock()

        // The typed refusal, not a substitute for it: this is what `ShareRootView.post()` shows.
        await #expect(throws: OutboxStorageError.queueBusy(.contended)) {
            try await ShareIngest.commit(
                items: [item],
                note: "on the beach",
                visibility: nil,
                binding: { Fixture.binding() },
                expecting: Fixture.binding(),
                waitingOn: clock,
                into: repository
            )
        }

        // Three seconds of budget spent a hundred milliseconds at a time: attempt one is made at
        // nothing spent, and each refusal after it waits while the clock is still short of the
        // deadline. The clock reaches it after the thirtieth wait, so attempt thirty-one is the one
        // that rethrows — thirty waits, thirty-one attempts.
        #expect(clock.sleeps.count == 30)
        #expect(
            clock.sleeps.allSatisfy { $0 == .milliseconds(100) },
            "every wait is the configured interval, not a backoff nobody asked for"
        )
        #expect(
            try mediaDirectories(in: outbox).isEmpty,
            "a share refused for the whole budget leaves no media directory behind"
        )
    }
}
