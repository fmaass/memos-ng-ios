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

    // MARK: - the OTHER thing that can move inside the hop: the capture itself

    /// A refusal handler holds a snapshot of the manifest from BEFORE it suspended. While it is
    /// suspended in the acquisition, a sibling pass can advance the capture — and writing the
    /// handler's stale candidate then puts the cursor back to where the server has already moved
    /// past, so the next drain re-sends bytes the server holds.
    @Test("a refusal answered about a capture that has since advanced is not written")
    func aStaleRefusalDoesNotOverwriteProgress() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = LockedFlag()
        let box = RepositoryBox()
        let provider = InterferingCredentials(Fixture.credentials()) {
            await box.advanceOnce(moved)
        }
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        await box.attach(repository)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1000)
        let job = try await repository.enqueue(
            content: "on the beach",
            visibility: "PRIVATE",
            capturedAt: now,
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
        let preferences = Fixture.preferences()
        defer { Fixture.forgetting(preferences.name) }
        let engine = OutboxEngine(
            repository: repository,
            credentials: provider,
            http: ScriptedHTTP.standard(chunkSize: 400),
            scheduler: ScriptedScheduler(),
            completion: MemoCompletionEndpoint(http: ScriptedHTTP.standard()),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: { now }
        )
        let fileID = job.files[0].id

        await engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(jobID: job.id, fileID: fileID, offset: 0),
                statusCode: 401,
                epoch: 0
            )
        )

        #expect(moved.get(), "the premise: the sibling pass really did land in the hop")
        let saved = try #require(await repository.job(job.id))
        #expect(
            saved.files[0].bytesConfirmed == 400,
            "a refusal about a capture that had already advanced put the cursor back"
        )
        #expect(saved.state != JobState.held, "and it held the capture on the way past")
        #expect(saved.lastError == nil)
    }

    /// The same window, and the worse half of it: the sibling pass FINISHED the capture and deleted
    /// the manifest. A capture leaves the outbox whole — the manifest first, then the originals —
    /// so putting the row back writes a job whose files are gone, and the next drain reads a
    /// capture it can never send.
    @Test("a refusal answered about a capture that has since finished does not resurrect it")
    func aStaleRefusalDoesNotResurrectADeletedCapture() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = LockedFlag()
        let box = RepositoryBox()
        let provider = InterferingCredentials(Fixture.credentials()) {
            await box.deleteOnce(removed)
        }
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        await box.attach(repository)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1000)
        let job = try await repository.enqueue(
            content: "on the beach",
            visibility: "PRIVATE",
            capturedAt: now,
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
        let preferences = Fixture.preferences()
        defer { Fixture.forgetting(preferences.name) }
        let engine = OutboxEngine(
            repository: repository,
            credentials: provider,
            http: ScriptedHTTP.standard(chunkSize: 400),
            scheduler: ScriptedScheduler(),
            completion: MemoCompletionEndpoint(http: ScriptedHTTP.standard()),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: { now }
        )

        await engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(jobID: job.id, fileID: job.files[0].id, offset: 0),
                statusCode: 401,
                epoch: 0
            )
        )

        #expect(removed.get(), "the premise: the sibling pass really did land in the hop")
        #expect(
            await repository.job(job.id) == nil,
            "a refusal about a capture that had already left the outbox put it back"
        )
    }

    /// The same window one write later. A fenced write that THROWS runs a recovery — the job, held,
    /// saying the disk would not take it — and that recovery is one more write into a window still
    /// open. Unfenced, it puts back exactly what the fence had just refused to put back.
    @Test(
        "a storage-failure recovery does not write back a capture that has moved on",
        arguments: [Interference.advance, .delete]
    )
    func aRecoveryWriteDoesNotResurrectAMovedCapture(_ interference: Interference) async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = LockedFlag()
        let box = RepositoryBox()
        let provider = SwitchableCredentials(Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        await box.attach(repository)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 1000)
        let job = try await repository.enqueue(
            content: "on the beach",
            visibility: "PRIVATE",
            capturedAt: now,
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
        let persistence = FailingThenInterferingPersister(repository) {
            switch interference {
            case .advance: await box.advanceOnce(moved)
            case .delete: await box.deleteOnce(moved)
            }
        }
        let preferences = Fixture.preferences()
        defer { Fixture.forgetting(preferences.name) }
        let engine = OutboxEngine(
            repository: persistence,
            credentials: provider,
            http: ScriptedHTTP.standard(chunkSize: 400),
            scheduler: ScriptedScheduler(),
            completion: MemoCompletionEndpoint(http: ScriptedHTTP.standard()),
            network: StubNetworkPath(),
            preferences: preferences.store,
            clock: { now }
        )

        await engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(jobID: job.id, fileID: job.files[0].id, offset: 0),
                statusCode: 401,
                epoch: 0
            )
        )

        #expect(moved.get(), "the premise: the other pass landed inside the failed write")
        #expect(
            await persistence.recoveryWrites > 0,
            "the premise: the storage-failure recovery really ran"
        )
        switch interference {
        case .advance:
            let saved = try #require(await repository.job(job.id))
            #expect(
                saved.files[0].bytesConfirmed == 400,
                "the recovery wrote a stale snapshot back over confirmed progress"
            )
            #expect(saved.state != JobState.held, "and held a capture another pass owns")
            #expect(saved.holdReason == nil)
        case .delete:
            #expect(
                await repository.job(job.id) == nil,
                "the recovery resurrected a capture that had already left the outbox"
            )
        }
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
        #expect(saved.holdReason == .signInRequired, "a live 401 on the create names its fix")
    }
}

/// What the other pass does while the first write is failing.
enum Interference: Sendable {
    case advance
    case delete
}

/// A flag a test reads after the fact, so a premise can be asserted rather than assumed.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    func get() -> Bool { lock.withLock { value } }
}

/// The sibling pass, holding the repository the interference acts on.
///
/// A box because the provider is built BEFORE the repository — the repository takes the provider's
/// predicate — so the closure cannot capture something that does not exist yet.
actor RepositoryBox {
    private var repository: OutboxRepository?

    func attach(_ repository: OutboxRepository) { self.repository = repository }

    /// Advances the first file's confirmed count, exactly as a newer chunk answer would.
    func advanceOnce(_ flag: LockedFlag) async {
        guard let repository, !flag.get() else { return }
        let jobs = (try? await repository.loadJobs()) ?? []
        guard let job = jobs.first, let file = job.files.first else { return }
        try? await repository.save(job.advancing(fileID: file.id, bytesConfirmed: 400))
        flag.set()
    }

    /// Finishes the capture, exactly as a create that succeeded would.
    func deleteOnce(_ flag: LockedFlag) async {
        guard let repository, !flag.get() else { return }
        let jobs = (try? await repository.loadJobs()) ?? []
        guard let job = jobs.first else { return }
        await repository.delete(job)
        flag.set()
    }
}
