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
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now")),
            // The home wifi: nothing here is about the network policy, and a stub that refused
            // would stop these drains before the thing they are about.
            network: StubNetworkPath(),
            preferences: Fixture.preferences(name: "memosng.outbox.tests.facade").store
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
        let reloaded = try await reopened.loadJobs()
        let job = try #require(reloaded.first)
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

        let jobs = try await repository.loadJobs()
        let job = try #require(jobs.first)
        // The manifest stores ISO-8601 to the SECOND, so a stamp taken between these two instants
        // reads back rounded DOWN — the window is widened by exactly that second rather than the
        // assertion being softened to "some time this century".
        #expect(job.capturedAt >= before.addingTimeInterval(-1))
        #expect(job.capturedAt <= after)
    }

    /// The Auto date is not a label on a screen: it is the number the create call sends. So it is
    /// followed the same way a chosen date is — computed by the rule from what the files said, put
    /// through `enqueue`, read back off the disk a relaunch would read, and finally found in the
    /// bytes of the request.
    @Test("the earliest capture instant is the date the create call sends")
    func theAutoDateReachesTheCreateCall() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let later = try #require(formatter.date(from: "2026-01-01T15:00:00Z"))
        // The earlier of the two carries no offset of its own: a civil reading, resolved here.
        let readings: [CaptureDecision] = [
            .settled(CaptureReading(instant: later, civil: nil, source: .exif)),
            .settled(CaptureReading(instant: nil, civil: "2026-01-01T13:00:00", source: .exif)),
        ]
        let auto = AutoMemoDate.autoMemoDate(readings, in: zone)
        #expect(auto.approximate, "the winner was the resolved one")

        let queued = await outbox(repository).enqueue(
            content: "the walk",
            visibility: nil,
            capturedAt: try #require(auto.instant),
            sources: []
        )
        #expect(queued)

        let reopened = try OutboxRepository(root: root.appending(path: "outbox"))
        let job = try #require(try await reopened.loadJobs().first)
        let request = try OutboxRequests.createMemo(
            baseURL: Fixture.server, token: "pat-token", job: job
        )
        let body = try #require(request.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // 13:00 in Berlin in January is 12:00Z — and whole seconds on the wire, as ever.
        #expect(sent["created_at"] as? String == "2026-01-01T12:00:00Z")
    }

    /// The order the composer shows is the order the manifest keeps, and the manifest is what the
    /// wire is built from. Nothing sorts anything again downstream: if the array handed to
    /// `enqueue` is in capture order, the memo is.
    @Test("the files reach the manifest in the order they were handed over")
    func theCaptureOrderReachesTheManifest() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        func staged(_ name: String) throws -> StagedSource {
            let url = root.appending(path: name)
            try Data(repeating: 0x41, count: 4).write(to: url)
            return StagedSource(url: url, filename: name, mime: "image/jpeg")
        }
        struct Item: CaptureCarrying {
            var source: StagedSource
            var capture: CaptureDecision
        }
        func item(_ name: String, _ stamp: String?) throws -> Item {
            let instant = stamp.flatMap { formatter.date(from: $0) }
            return Item(
                source: try staged(name),
                capture: .settled(
                    CaptureReading(
                        instant: instant, civil: nil, source: instant == nil ? nil : .exif)))
        }
        // Picked b, a, c (undated), d — the artefact's own ordering case.
        let picked = [
            try item("b.jpg", "2026-01-01T15:00:00Z"),
            try item("a.jpg", "2026-01-01T13:00:00Z"),
            try item("c.jpg", nil),
            try item("d.jpg", "2026-01-01T14:00:00Z"),
        ]

        let queued = await outbox(repository).enqueue(
            content: "the walk",
            visibility: nil,
            sources: AutoMemoDate.captureOrder(picked, in: zone).map(\.source)
        )
        #expect(queued)

        let reopened = try OutboxRepository(root: root.appending(path: "outbox"))
        let job = try #require(try await reopened.loadJobs().first)
        #expect(job.files.map(\.filename) == ["a.jpg", "d.jpg", "b.jpg", "c.jpg"])
    }
}
