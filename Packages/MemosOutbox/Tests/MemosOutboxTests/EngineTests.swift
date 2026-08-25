import Foundation
import MemosOutbox
import Testing

/// One capture on disk, one scripted server, one engine — the world a drain runs in.
private struct Harness {
    let root: URL
    let repository: OutboxRepository
    /// What the ENGINE writes through — the repository itself, unless a test asked for a disk that
    /// refuses. `repository` stays the real one either way, so a test can set the scene and read
    /// the outcome back through writes that always land.
    let persistence: any OutboxPersisting
    let http: ScriptedHTTP
    let scheduler: ScriptedScheduler
    /// The network the phone is on, which a test can move under a running drain.
    let network: StubNetworkPath
    let preferencesName: String
    let completion: any MemoCompleting
    let engine: OutboxEngine
    let job: UploadJob
    let clock: MutableClock
    let credentials: SwitchableCredentials
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    var file: OutboxFile { job.files[0] }

    static func make(
        bytes: Int = 1000,
        content: String = "on the beach",
        http: ScriptedHTTP,
        completion: (any MemoCompleting)? = nil,
        scheduler: ScriptedScheduler = ScriptedScheduler(),
        credentials: OutboxCredentials? = Fixture.credentials(),
        binding: AccountBinding = Fixture.binding(),
        refusedSaves: Int = 0,
        network: StubNetworkPath = StubNetworkPath(),
        allowsMobileData: Bool = false
    ) async throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        var sources: [StagedSource] = []
        if bytes > 0 {
            let source = try Fixture.file(in: root, named: "one.heic", bytes: bytes)
            sources = [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let clock = MutableClock(now)
        let provider = SwitchableCredentials(credentials)
        let preferences = Fixture.preferences(allowsMobileData: allowsMobileData)
        // Nil means the REAL completion path, driven by the same scripted server: the tests that
        // care about what a create actually sends and reads use that rather than a stand-in.
        let completion = completion ?? MemoCompletionEndpoint(http: http)
        let job = try await repository.enqueue(
            content: content,
            visibility: "PRIVATE",
            capturedAt: now,
            binding: binding,
            sources: sources
        )
        var persistence: any OutboxPersisting = repository
        if refusedSaves > 0 {
            persistence = FaultyPersistence(repository, refusals: refusedSaves)
        }
        let engine = OutboxEngine(
            repository: persistence,
            credentials: provider,
            http: http,
            scheduler: scheduler,
            completion: completion,
            network: network,
            preferences: preferences.store,
            clock: { clock.now }
        )
        return Harness(
            root: root,
            repository: repository,
            persistence: persistence,
            http: http,
            scheduler: scheduler,
            network: network,
            preferencesName: preferences.name,
            completion: completion,
            engine: engine,
            job: job,
            clock: clock,
            credentials: provider
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        Fixture.forgetting(preferencesName)
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
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(bytes: 0, http: .standard(), completion: completion)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil)
        #expect(try await harness.repository.loadJobs().isEmpty)
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

@Suite("Not letting go too early")
struct DurabilityTests {
    /// A create that answers 2xx with something this client cannot read is NOT proof a memo was
    /// stored — and the originals are deleted on that proof. The capture stays, the retry carries
    /// the same key, and the replay is the second chance to read the same answer.
    @Test("an unreadable success keeps the capture, and the replay finishes it")
    func unreadableSuccessDoesNotDelete() async throws {
        let attempts = Counter()
        let http = ScriptedHTTP { request in
            let path = request.url?.path() ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/memos"):
                attempts.increment()
                // The first answer is a 201 nobody can read; the replay is readable.
                let body =
                    attempts.count == 1
                    ? Data("<html>gateway</html>".utf8) : Data(#"{"uid":"m1"}"#.utf8)
                return OutboxHTTPResponse(statusCode: 201, body: body)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        // No `completion:` — the real completion path, so the decode is what is under test.
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }

        await harness.engine.drain()

        let kept = try #require(await harness.reload())
        #expect(kept.state == .waiting)
        #expect(kept.attemptCount == 1)
        #expect(kept.lastError?.contains("same key") == true)

        harness.clock.advance(20 * 60)
        await harness.engine.drain()

        #expect(await harness.reload() == nil)
        #expect(attempts.count == 2)
        let keys = harness.http.requests(method: "POST").compactMap { request -> String? in
            guard let body = request.httpBody,
                let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["idempotency_key"] as? String
        }
        #expect(
            keys == [harness.job.idempotencyKey.uuidString, harness.job.idempotencyKey.uuidString])
    }

    /// A cold background wake can arrive before anyone has restored the stored credential. The
    /// server's byte count must still reach the disk — throwing it away means re-uploading a
    /// chunk the server already has, every time.
    @Test("a chunk answer is banked even when nobody is signed in yet")
    func banksProgressWithoutCredentials() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let identity = harness.scheduler.uploads[0].identity

        // The process was relaunched for this callback alone: no session yet.
        harness.credentials.set(nil)
        await harness.engine.handle(
            ChunkResult(
                identity: identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 400)
        // Nothing was scheduled without a credential, and nothing was lost either.
        #expect(harness.scheduler.uploads.count == 1)

        harness.credentials.set(Fixture.credentials())
        await harness.engine.drain()
        #expect(harness.scheduler.uploads.count == 2)
        #expect(harness.scheduler.uploads[1].identity.offset == 400)
    }

    /// A task a reconcile cancelled can still report. Its answer describes an offset the job has
    /// moved past, and applying it would rewind the cursor and re-send bytes the server holds.
    @Test("an answer from a superseded attempt is ignored")
    func ignoresStaleChunkAnswers() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let first = harness.scheduler.uploads[0].identity

        await harness.engine.handle(
            ChunkResult(
                identity: first,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )
        #expect(try #require(await harness.reload()).files[0].bytesConfirmed == 400)

        // The same task reports again — a duplicate, or a cancelled one that landed late.
        await harness.engine.handle(
            ChunkResult(
                identity: first,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 400)
        // No third chunk was queued off the back of the stale answer.
        #expect(harness.scheduler.uploads.count == 2)
    }
}

@Suite("Background bookkeeping")
struct BackgroundWorkTests {
    @Test("the system is told a session finished only once its results are written")
    func completionWaitsForHandlerWork() async {
        let pending = PendingHandlerWork()
        let fired = Counter()

        pending.enter()
        pending.onDrained { fired.increment() }
        // The session says "no more events" while the last result is still being written.
        #expect(fired.count == 0)
        #expect(pending.outstandingCount == 1)

        pending.leave()
        #expect(fired.count == 1)
    }

    @Test("nothing outstanding answers immediately, and only once")
    func drainsImmediatelyWhenIdle() {
        let pending = PendingHandlerWork()
        let fired = Counter()
        pending.onDrained { fired.increment() }
        #expect(fired.count == 1)

        pending.enter()
        pending.leave()
        #expect(fired.count == 1)
    }

    @Test("several results in flight all have to land")
    func waitsForEveryOutstandingResult() {
        let pending = PendingHandlerWork()
        let fired = Counter()
        pending.enter()
        pending.enter()
        pending.onDrained { fired.increment() }
        pending.leave()
        #expect(fired.count == 0)
        pending.leave()
        #expect(fired.count == 1)
    }

    @Test("a background task's end is reported exactly once, whoever gets there first")
    func completionIsClaimedOnce() {
        let run = BackgroundRun()
        #expect(run.claimCompletion())
        #expect(!run.claimCompletion())
        #expect(run.isFinished)
    }

    @Test("work attached after the run ended is cancelled rather than left going")
    func attachAfterExpiry() async {
        let run = BackgroundRun()
        _ = run.claimCompletion()
        let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        run.attach(work)
        await work.value
        #expect(work.isCancelled)
    }

    @MainActor
    @Test("expiring stops the work in flight")
    func expireCancels() async {
        let run = BackgroundRun()
        let started = Counter()
        let work = Task<Void, Never> {
            started.increment()
            try? await Task.sleep(for: .seconds(30))
        }
        run.attach(work)
        run.expire()
        await work.value
        #expect(work.isCancelled)
    }

    @Test("a transition the disk would not take is not taken")
    func aRefusedWriteStopsTheDrain() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), refusedSaves: .max
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        // The server handed out an upload session and nothing on this device could write it down,
        // so no chunk goes out against a uid a relaunch would have no way to resume.
        #expect(harness.http.requests(method: "POST").count == 1)
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.files[0].uploadUID == nil)
        #expect(saved.state == .waiting)
        #expect(await harness.engine.lastPersistenceFailure != nil, "and it is said out loud")
    }

    @Test("a capture whose own manifest cannot be written is held, saying so")
    func aRefusedWriteHoldsTheCapture() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), refusedSaves: 1
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.scheduler.uploads.isEmpty, "nothing moves on from a state nobody wrote")
        let saved = try #require(await harness.reload())
        #expect(saved.state == .held)
        #expect(saved.holdReason == .storageFailed)
        #expect(saved.lastError?.contains("could not be saved on this device") == true)
    }

    @Test("a chunk answer that cannot be written down does not move the cursor on")
    func aRefusedWriteDoesNotMoveTheCursor() async throws {
        let scheduler = ScriptedScheduler()
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            scheduler: scheduler,
            refusedSaves: .max
        )
        defer { harness.cleanUp() }
        // A chunk is with the background session, written down while the disk still took writes.
        var started = harness.job
        started.files[0].uploadUID = "u1"
        started.files[0].chunkSize = 400
        started.state = .uploading
        try await harness.repository.save(started)

        await harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(
                    jobID: started.id, fileID: started.files[0].id, offset: 0
                ),
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 0, "the cursor is the server's count ON DISK")
        // Sending the next chunk from a count only this process holds is how the answer to it
        // becomes unusable: it would no longer match the offset the manifest still carries.
        #expect(scheduler.uploads.isEmpty)
    }
}

/// The network the phone is on, and what the drain is allowed to do on it.
///
/// Every one of these asserts on what did NOT leave the device, because that is the whole subject:
/// a capture held for the home network must cost nothing at all — not a chunk, not the health
/// probe, not the request that opens an upload session. The gate is asked again before EVERY
/// network-producing step rather than once per pass, so the path is moved under a running drain
/// here as well as between them.
@Suite("Draining over the network the phone is on")
struct NetworkPolicyDrainTests {
    @Test("mobile data with the toggle off costs nothing, and the row says what it waits for")
    func refusedBeforeTheProbe() async throws {
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            network: StubNetworkPath(.cellular),
            allowsMobileData: false
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests.isEmpty, "not even the health probe")
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.state == .waiting)
        #expect(saved.waitReason == .homeNetwork)
        #expect(saved.attemptCount == 0, "nothing was tried, so nothing is backing off")
    }

    @Test("the same phone with the toggle on probes and uploads")
    func permittedWithTheToggleOn() async throws {
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            network: StubNetworkPath(.cellular),
            allowsMobileData: true
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests(method: "GET").count == 1)
        #expect(harness.scheduler.uploads.count == 1)
        let saved = try #require(await harness.reload())
        #expect(saved.state == .uploading)
        #expect(saved.waitReason == nil)
    }

    @Test("the home wifi needs no toggle")
    func wifiNeedsNoPermission() async throws {
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            network: StubNetworkPath(.wifi),
            allowsMobileData: false
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.scheduler.uploads.count == 1)
        let saved = try #require(await harness.reload())
        #expect(saved.waitReason == nil)
    }

    /// Low Data Mode is a decision about the whole phone, and the toggle does not override it.
    @Test("Low Data Mode waits even with the toggle on")
    func lowDataModeAlwaysWaits() async throws {
        let constrained = NetworkPath(usesCellular: false, isExpensive: false, isConstrained: true)
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            network: StubNetworkPath(constrained),
            allowsMobileData: true
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests.isEmpty)
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.waitReason == .homeNetwork)
    }

    /// The path is read again for the ACTION, not once for the pass: the phone here is on the home
    /// wifi when the drain decides to run and on mobile data by the time the first request would
    /// go out. The probe went (it was permitted when it was made); the upload session did not.
    @Test("a network that changes mid-drain stops the very next request")
    func freshReadBeforeEachAction() async throws {
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400),
            network: StubNetworkPath(.wifi, thenAfterOneRead: .cellular),
            allowsMobileData: false
        )
        defer { harness.cleanUp() }

        await harness.engine.drain()

        #expect(harness.http.requests(method: "GET").count == 1, "the probe was permitted")
        #expect(harness.http.requests(method: "POST").isEmpty, "the upload session was not")
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.files[0].uploadUID == nil)
        #expect(saved.waitReason == .homeNetwork)
    }

    /// The continuation `handle` re-enters `advance` with. A chunk that finished on the wifi is
    /// banked — the server's count is never thrown away — but the NEXT one waits.
    @Test("a chunk finishing after the network changed does not schedule the next one")
    func theChunkContinuationIsGatedToo() async throws {
        let network = StubNetworkPath(.wifi)
        let harness = try await Harness.make(
            bytes: 1000, http: .standard(chunkSize: 400), network: network
        )
        defer { harness.cleanUp() }
        await harness.engine.drain()
        #expect(harness.scheduler.uploads.count == 1)

        await network.move(to: .cellular)
        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 400, "what the server said is still banked")
        #expect(harness.scheduler.uploads.count == 1, "and the next chunk is not sent")
        #expect(saved.state == .waiting)
        #expect(saved.waitReason == .homeNetwork)
    }

    /// The third network-producing action. A memo create is a request like any other, and a
    /// capture whose bytes are all on the server still waits for a network it may use.
    @Test("the memo create waits for the network too")
    func theCreateIsGatedToo() async throws {
        let network = StubNetworkPath(.wifi)
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(
            bytes: 400,
            http: .standard(chunkSize: 400),
            completion: completion,
            network: network
        )
        defer { harness.cleanUp() }
        await harness.engine.drain()

        await network.move(to: .cellular)
        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        #expect(completion.idempotencyKeys.isEmpty, "no memo was created on a refused network")
        let saved = try #require(await harness.reload())
        #expect(saved.files[0].isComplete)
        #expect(saved.state == .waiting)
        #expect(saved.waitReason == .homeNetwork)
    }
}
