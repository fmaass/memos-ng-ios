import Foundation
import MemosOutbox
import Testing

/// One capture on disk, one scripted server, one engine — the world a drain runs in.
private struct Harness {
    let root: URL
    let repository: OutboxRepository
    let http: ScriptedHTTP
    let scheduler: ScriptedScheduler
    let completion: ScriptedCompletion
    let engine: OutboxEngine
    let job: UploadJob
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    var file: OutboxFile { job.files[0] }

    static func make(
        bytes: Int = 1000,
        content: String = "on the beach",
        http: ScriptedHTTP,
        completion: ScriptedCompletion = ScriptedCompletion([.created(uid: "m1")]),
        scheduler: ScriptedScheduler = ScriptedScheduler(),
        credentials: OutboxCredentials? = Fixture.credentials(),
        binding: AccountBinding = Fixture.binding()
    ) async throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        var sources: [StagedSource] = []
        if bytes > 0 {
            let source = try Fixture.file(in: root, named: "one.heic", bytes: bytes)
            sources = [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let job = try await repository.enqueue(
            content: content,
            visibility: "PRIVATE",
            capturedAt: now,
            binding: binding,
            sources: sources
        )
        let engine = OutboxEngine(
            repository: repository,
            credentials: StaticCredentials(credentials: credentials),
            http: http,
            scheduler: scheduler,
            completion: completion,
            clock: { now }
        )
        return Harness(
            root: root,
            repository: repository,
            http: http,
            scheduler: scheduler,
            completion: completion,
            engine: engine,
            job: job
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func reload() async -> UploadJob? {
        await repository.job(job.id)
    }
}

@Suite("Draining")
struct EngineTests {
    @Test("a capture starts an upload session and puts its first chunk on the background session")
    func startsAndSchedules() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests(method: "GET").count == 1)
        #expect(harness.http.requests(method: "POST").count == 1)
        let uploads = harness.scheduler.uploads
        #expect(uploads.count == 1)
        #expect(uploads[0].identity.offset == 0)
        #expect(uploads[0].offsetHeader == "0")
        #expect(try Data(contentsOf: uploads[0].file) == Data(Fixture.content(1000).prefix(400)))

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].uploadUID == "u1")
        #expect(saved.files[0].chunkSize == 400)
        #expect(saved.state == .uploading)
    }

    @Test("an unreachable server costs one small request and never a chunk")
    func healthProbeGuardsTheDrain() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(health: 503))
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests.count == 1)
        #expect(harness.http.requests(method: "GET").count == 1)
        #expect(harness.scheduler.uploads.isEmpty)
        #expect(await harness.reload() != nil)
    }

    @Test("the cursor advances to the server's count and the next chunk follows")
    func advancesFromTheServersCount() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()

        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 400)
        let uploads = harness.scheduler.uploads
        #expect(uploads.count == 2)
        #expect(uploads[1].identity.offset == 400)
        #expect(try Data(contentsOf: uploads[1].file) == Data(Fixture.content(1000)[400..<800]))
    }

    @Test("a 409 re-syncs from the offset HEAD instead of guessing")
    func resyncsOnOffsetGap() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400, headOffset: 250)
        )
        defer { harness.cleanUp() }
        await harness.engine.drain()

        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity, statusCode: 409, body: Data()
            )
        )

        #expect(harness.http.requests(method: "HEAD").count == 1)
        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 250)
        #expect(harness.scheduler.uploads.count == 2)
        #expect(harness.scheduler.uploads[1].identity.offset == 250)
    }

    @Test("a lost upload session starts again from the original, which is never deleted")
    func startsOverWhenTheServerForgot() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let original = harness.repository.mediaURL(job: harness.job, file: harness.file)
        let before = try Data(contentsOf: original)

        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity, statusCode: 404, body: Data()
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 0)
        #expect(try Data(contentsOf: original) == before)
        // A fresh session was started and its first chunk queued again.
        #expect(harness.http.requests(method: "POST").count == 2)
        #expect(harness.scheduler.uploads.count == 2)
        #expect(harness.scheduler.uploads[1].identity.offset == 0)
    }

    @Test("a memo leaves the outbox only when the server has confirmed it")
    func completesAndClearsTheQueue() async throws {
        let harness = try await Harness.make(bytes: 0, http: .standard())
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil)
        #expect(await harness.repository.loadJobs().isEmpty)
    }

    @Test("a crash between the server's commit and the local delete cannot produce two memos")
    func replayWindowUsesTheSameKey() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1"), .created(uid: "m1")])
        let harness = try await Harness.make(bytes: 0, http: .standard(), completion: completion)
        defer { harness.cleanUp() }

        await harness.engine.drain()
        // The process died before the manifest was removed: on the next launch the job is back,
        // exactly as it was — same idempotency key and all.
        try await harness.repository.save(harness.job)
        await harness.engine.drain()

        #expect(completion.idempotencyKeys.count == 2)
        #expect(Set(completion.idempotencyKeys).count == 1)
        #expect(completion.idempotencyKeys[0] == harness.job.idempotencyKey)
        #expect(await harness.reload() == nil)
    }

    @Test("a relaunch adopts the surviving task instead of scheduling a second one")
    func relaunchDoesNotDoubleSchedule() async throws {
        let scheduler = ScriptedScheduler()
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), scheduler: scheduler
        )
        defer { harness.cleanUp() }
        // What the process would have persisted before it was killed: a started upload with a
        // chunk in flight at offset 400.
        var started = harness.job
        started.files[0].uploadUID = "u1"
        started.files[0].chunkSize = 400
        started.files[0].bytesConfirmed = 400
        started.state = .uploading
        try await harness.repository.save(started)
        scheduler.pretend(inFlight: [
            OutboxTaskIdentity(jobID: started.id, fileID: started.files[0].id, offset: 400)
        ])

        await harness.engine.drain()

        #expect(scheduler.uploads.isEmpty)
        #expect(scheduler.cancellations.isEmpty)
        #expect(harness.http.requests.isEmpty)
    }

    @Test("a task a relaunch cannot place is cancelled and the job is picked up again")
    func relaunchCancelsAStaleTask() async throws {
        let scheduler = ScriptedScheduler()
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), scheduler: scheduler
        )
        defer { harness.cleanUp() }
        var started = harness.job
        started.files[0].uploadUID = "u1"
        started.files[0].chunkSize = 400
        started.files[0].bytesConfirmed = 400
        try await harness.repository.save(started)
        let stale = OutboxTaskIdentity(
            jobID: started.id, fileID: started.files[0].id, offset: 0
        )
        scheduler.pretend(inFlight: [stale])

        await harness.engine.drain()

        #expect(scheduler.cancellations == [stale])
        #expect(scheduler.uploads.count == 1)
        #expect(scheduler.uploads[0].identity.offset == 400)
    }

    @Test("a capture made under another account is held and never sent")
    func heldUnderTheWrongAccount() async throws {
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(),
            binding: Fixture.binding(owner: "someone-else")
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests.isEmpty)
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.state == .held)
        #expect(saved.holdReason == .accountMismatch)
        #expect(saved.lastError != nil)
    }

    @Test("nothing drains while nobody is signed in")
    func signedOut() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(), credentials: nil)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests.isEmpty)
        #expect(await harness.reload() != nil)
    }

    @Test("a server that could not take the memo is retried later, with the job kept")
    func retriesTheCompletion() async throws {
        let completion = ScriptedCompletion([.retry("500")], repeating: .retry("500"))
        let harness = try await Harness.make(bytes: 0, http: .standard(), completion: completion)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        let saved = try #require(await harness.reload())
        #expect(saved.state == .waiting)
        #expect(saved.attemptCount == 1)
        #expect(saved.nextAttemptAt == harness.now.addingTimeInterval(15 * 60))
        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
    }

    @Test("a refusal that repeating cannot fix holds the job instead of looping")
    func holdsOnRefusal() async throws {
        let completion = ScriptedCompletion(
            [.refused("The memo was rejected (422).")], repeating: .refused("again")
        )
        let harness = try await Harness.make(bytes: 0, http: .standard(), completion: completion)
        defer { harness.cleanUp() }

        await harness.engine.drain()
        await harness.engine.drain()

        let saved = try #require(await harness.reload())
        #expect(saved.state == .held)
        #expect(saved.holdReason == .serverRefused)
        #expect(saved.lastError == "The memo was rejected (422).")
        // Held means held: the second drain did not try again.
        #expect(completion.idempotencyKeys.count == 1)
    }

    @Test("uploads_unlinkable restarts what the server lost and re-syncs what it has part of")
    func recoversFromAStrictRefusal() async throws {
        let failure = UploadsUnlinkableFailure(
            missingUploadUIDs: ["u1"], incompleteUploadUIDs: []
        )
        let completion = ScriptedCompletion(
            [.unlinkable(failure)], repeating: .created(uid: "m1")
        )
        let harness = try await Harness.make(
            bytes: 400, http: .standard(chunkSize: 400), completion: completion
        )
        defer { harness.cleanUp() }
        await harness.engine.drain()
        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        // The create was refused, the file's session was forgotten, and a new one was started —
        // from the original, which is still here.
        #expect(completion.idempotencyKeys.count >= 1)
        #expect(harness.http.requests(method: "POST").count == 2)
        let original = harness.repository.mediaURL(job: harness.job, file: harness.file)
        #expect(try Data(contentsOf: original) == Fixture.content(400))
    }

    @Test("a held job is released and tried again on request")
    func releasing() async throws {
        let harness = try await Harness.make(
            bytes: 0,
            http: .standard(),
            completion: ScriptedCompletion([.created(uid: "m1")]),
            binding: Fixture.binding(owner: "someone-else")
        )
        defer { harness.cleanUp() }
        await harness.engine.drain()
        #expect(try #require(await harness.reload()).state == .held)

        await harness.engine.release(jobID: harness.job.id)
        let released = try #require(await harness.reload())
        #expect(released.state == .waiting)
        #expect(released.holdReason == nil)
    }
}
