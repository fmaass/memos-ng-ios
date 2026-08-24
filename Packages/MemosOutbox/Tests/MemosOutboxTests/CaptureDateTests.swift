import Foundation
import MemosOutbox
import Testing

/// A backdated capture is only backdated if the date survives the queue. It is chosen on a screen,
/// written to a manifest on disk, read back after a relaunch and finally put on the wire — so it
/// is followed from the facade's `enqueue` to the bytes of the create request, not asserted at one
/// end and assumed at the other.
@MainActor
@Suite("A chosen capture date")
struct CaptureDateTests {
    /// An unreachable server, so the drain the enqueue kicks off stops at the health probe and the
    /// job is still on disk to be read back. Nothing here is asserting on the drain.
    private func outbox(_ repository: OutboxRepository) -> Outbox {
        Outbox(
            repository: repository,
            credentials: StaticCredentials(credentials: Fixture.credentials()),
            http: ScriptedHTTP.standard(health: 500),
            scheduler: ScriptedScheduler(),
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now"))
        )
    }

    @Test("the date a capture was given is the date the create call sends")
    func chosenDateReachesTheCreateCall() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        // 14 November 2023, 22:13:20 UTC — years before this test can run, so a capture stamped
        // "now" anywhere along the way is unmistakable.
        let backdated = Date(timeIntervalSince1970: 1_700_000_000)

        let queued = await outbox(repository).enqueue(
            content: "the day we moved in",
            visibility: "PRIVATE",
            capturedAt: backdated,
            sources: []
        )
        #expect(queued)

        // Read back through a SECOND repository over the same directory: what a relaunch sees.
        let reopened = try OutboxRepository(root: root.appending(path: "outbox"))
        let job = try #require(await reopened.loadJobs().first)
        #expect(job.capturedAt == backdated)

        let request = try OutboxRequests.createMemo(
            baseURL: Fixture.server, token: "pat-token", job: job
        )
        let body = try #require(request.httpBody)
        let sent = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(sent["created_at"] as? String == "2023-11-14T22:13:20Z")
        #expect(sent["content"] as? String == "the day we moved in")
    }

    @Test("a capture with no chosen date is stamped when it is written")
    func defaultIsTheMomentOfWriting() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))

        let before = Date()
        let queued = await outbox(repository).enqueue(
            content: "kettle's broken",
            visibility: nil,
            sources: []
        )
        #expect(queued)
        let after = Date()

        let job = try #require(await repository.loadJobs().first)
        // The manifest stores ISO-8601 to the SECOND, so a stamp taken between these two instants
        // reads back rounded DOWN — the window is widened by exactly that second rather than the
        // assertion being softened to "some time this century".
        #expect(job.capturedAt >= before.addingTimeInterval(-1))
        #expect(job.capturedAt <= after)
    }
}
