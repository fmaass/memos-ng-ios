import Foundation
import MemosOutbox
import Testing

/// Window 2, at the hop no engine-side comparison can close.
///
/// The engine computes a refusal's disposition on its own actor; the manifest is written on
/// `OutboxRepository`, a different one. A verdict decided before that hop is a decision about an
/// instant that has passed by the time the bytes go down — so both candidate outcomes travel and
/// the CHOICE is made where the write is. These three drive the real engine and supersede the grant
/// INSIDE the write, which is the only ordering that tells the fix apart from one that merely moved
/// the comparison later on the engine.
@Suite("A refusal decided at the disk, not at the answer")
struct OutboxRefusalEpochTests {

    /// One capture, one scripted server, and a persister that renews the grant as the write begins.
    private struct Harness {
        let root: URL
        let repository: OutboxRepository
        let persistence: SupersedingPersister
        let provider: SwitchableCredentials
        let scheduler: ScriptedScheduler
        let engine: OutboxEngine
        let job: UploadJob
        let preferencesName: String

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            Fixture.forgetting(preferencesName)
        }

        func reload() async -> UploadJob? { await repository.job(job.id) }
    }

    private func harness(
        bytes: Int,
        http: ScriptedHTTP,
        completion: (any MemoCompleting)? = nil
    ) async throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        let provider = SwitchableCredentials(Fixture.credentials())
        // The repository decides under the REAL provider's predicate. Defaulted, it would answer
        // "nothing ever moved" and every case below would pass without the fence existing.
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        var sources: [StagedSource] = []
        if bytes > 0 {
            let source = try Fixture.file(in: root, named: "one.heic", bytes: bytes)
            sources = [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let job = try await repository.enqueue(
            content: "on the beach",
            visibility: "PRIVATE",
            capturedAt: now,
            binding: Fixture.binding(),
            sources: sources
        )
        let persistence = SupersedingPersister(repository, superseding: provider)
        let scheduler = ScriptedScheduler()
        let preferences = Fixture.preferences()
        let engine = OutboxEngine(
            repository: persistence,
            credentials: provider,
            http: http,
            scheduler: scheduler,
            completion: completion ?? MemoCompletionEndpoint(http: http),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: { now }
        )
        return Harness(
            root: root,
            repository: repository,
            persistence: persistence,
            provider: provider,
            scheduler: scheduler,
            engine: engine,
            job: job,
            preferencesName: preferences.name
        )
    }

    /// 2a/2c — the chunk answer. It comes back in a LATER pass, so it carries the epoch it was sent
    /// under; the renewal then lands in the hop into the repository.
    @Test("a chunk refused under a grant replaced in the write hop is queued, not held")
    func aChunkRefusalSupersededAtTheDiskIsQueued() async throws {
        let harness = try await harness(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let sent = try #require(harness.scheduler.uploads.first)
        let epoch = try #require(harness.scheduler.epoch(of: sent.identity))
        // The premise: the chunk really was sent under the grant the engine still holds, so
        // nothing the ENGINE can see is stale when it classifies.
        #expect(harness.provider.stillCurrent(epoch: epoch), "the grant was already stale")

        await harness.engine.handle(
            ChunkResult(identity: sent.identity, statusCode: 401, epoch: epoch)
        )

        #expect(
            !harness.provider.stillCurrent(epoch: epoch),
            "the premise: the renewal landed in the write hop"
        )
        let saved = try #require(await harness.reload())
        #expect(saved.state != JobState.held, "a capture was stranded behind a stale refusal")
        #expect(saved.holdReason == nil)
        #expect(saved.lastError?.contains("was replaced") == true)
    }

    /// 2c — the upload start, whose verdict used to be computed at the classification and carried
    /// across the same hop.
    @Test("an upload start refused under a grant replaced in the write hop is queued, not held")
    func anUploadStartRefusalSupersededAtTheDiskIsQueued() async throws {
        let http = ScriptedHTTP { request in
            guard request.httpMethod == "POST", request.url?.path.hasSuffix("/uploads") == true
            else { return ScriptedHTTP.json([:]) }
            return OutboxHTTPResponse(statusCode: 401, body: Data())
        }
        let harness = try await harness(bytes: 1000, http: http)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(await harness.persistence.fencedSaves > 0, "the write hop was never exercised")
        let saved = try #require(await harness.reload())
        #expect(saved.state != JobState.held, "a capture was stranded behind a stale refusal")
        #expect(saved.holdReason == nil)
        #expect(saved.lastError?.contains("was replaced") == true)
    }

    /// 2b — the memo create, whose refusal crosses back into the engine as a return value and then
    /// crosses again into the repository.
    @Test("a create refused under a grant replaced in the write hop is queued, not held")
    func aCreateRefusalSupersededAtTheDiskIsQueued() async throws {
        let http = ScriptedHTTP { request in
            guard request.httpMethod == "POST", request.url?.path.hasSuffix("/memos") == true
            else { return ScriptedHTTP.json([:]) }
            return OutboxHTTPResponse(statusCode: 401, body: Data())
        }
        // No files: the drain goes straight to the create.
        let harness = try await harness(bytes: 0, http: http)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(await harness.persistence.fencedSaves > 0, "the write hop was never exercised")
        let saved = try #require(await harness.reload())
        #expect(saved.state != JobState.held, "a capture was stranded behind a stale refusal")
        #expect(saved.holdReason == nil)
        #expect(saved.lastError?.contains("was replaced") == true)
    }

    /// The control, and the reason the fence is a fence rather than a hole: with nothing moving in
    /// the write hop, the same refusal holds the capture exactly as it always did.
    @Test("a refusal whose grant still stands at the disk holds the capture")
    func aCurrentRefusalStillHolds() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = SwitchableCredentials(Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        let http = ScriptedHTTP { request in
            guard request.httpMethod == "POST", request.url?.path.hasSuffix("/memos") == true
            else { return ScriptedHTTP.json([:]) }
            return OutboxHTTPResponse(statusCode: 401, body: Data())
        }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let job = try await repository.enqueue(
            content: "on the beach",
            visibility: "PRIVATE",
            capturedAt: now,
            binding: Fixture.binding(),
            sources: []
        )
        let preferences = Fixture.preferences()
        defer { Fixture.forgetting(preferences.name) }
        let engine = OutboxEngine(
            repository: repository,
            credentials: provider,
            http: http,
            scheduler: ScriptedScheduler(),
            completion: MemoCompletionEndpoint(http: http),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: { now }
        )

        await engine.drain()

        let saved = try #require(await repository.job(job.id))
        #expect(saved.state == JobState.held, "a live refusal stopped holding the capture")
        #expect(saved.holdReason == .serverRefused)
    }
}
