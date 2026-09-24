import Foundation
import MemosOutbox
import Testing

/// One capture on disk, one scripted server, one engine — the world a drain runs in.
///
/// Internal rather than file-private since MEMNG-289: the ordinary-write witnesses in
/// `OrdinaryWriteFenceTests` run in this same world, and a second copy of it there would be a
/// second set of defaults to keep in step with these.
struct Harness {
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
        holdingFirstSave: TestGate? = nil,
        // What the ENGINE writes through, built around the real repository. Passed as a factory
        // because the engine takes its persistence at construction and the repository does not
        // exist until this function has made one.
        persistence makePersistence: (@Sendable (OutboxRepository) -> any OutboxPersisting)? = nil,
        network: StubNetworkPath = StubNetworkPath(),
        allowsMobileData: Bool = false,
        // Where the engine's clock starts. Whole seconds unless a test says otherwise; the
        // round-trip witness starts it on a fraction, which is what a real clock hands out and
        // what the manifest cannot keep.
        clockStart: Date? = nil
    ) async throws -> Harness {
        let root = try Fixture.temporaryDirectory()
        // The provider is built BEFORE the repository, because the repository decides a refusal
        // under this provider's predicate: defaulted, every hold would be decided as if nothing
        // ever moved, and the three `SupersededRefusalTests` below would go red.
        let provider = SwitchableCredentials(credentials)
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
        let clock = MutableClock(clockStart ?? now)
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
        if let holdingFirstSave {
            persistence = GatedPersistence(repository, gate: holdingFirstSave)
        }
        if let makePersistence {
            persistence = makePersistence(repository)
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

    /// A drain pass outlives the account switch that happens during it: the credential was
    /// acquired under A and every request after the switch would be sent as A into B's session.
    /// The pass is ABANDONED rather than the job held — nothing is wrong with the capture, and the
    /// next pass acquires under whoever is signed in then.
    @Test("a pass whose session ended sends nothing and leaves the capture queued")
    func aSupersededPassSendsNothing() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        harness.credentials.supersedeAfterNextAcquisition()

        await harness.engine.drain()

        #expect(harness.http.requests.isEmpty, "not even the health probe is a request to send")
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.state == .waiting, "the capture waits for a pass that belongs to it")
    }

    /// The switch lands BETWEEN the probe and the first send — the window a check taken once at
    /// the start of the pass cannot see, because the probe is itself an await.
    @Test("a switch between the probe and the first send stops the pass there")
    func aSwitchAfterTheProbeStopsThePass() async throws {
        let switched = CredentialsBox()
        let http = ScriptedHTTP { request in
            // The switch lands INSIDE the probe, so the pass resumes into a session that is over.
            if request.httpMethod == "GET" {
                switched.value?.supersede()
                return OutboxHTTPResponse(statusCode: 200)
            }
            return ScriptedHTTP.session(uid: "u1", chunkSize: 400, received: 0)
        }
        let harness = try await Harness.make(bytes: 1000, http: http)
        defer { harness.cleanUp() }
        switched.value = harness.credentials

        await harness.engine.drain()

        #expect(harness.http.requests(method: "GET").count == 1, "the probe went out")
        #expect(harness.http.requests(method: "POST").isEmpty, "and nothing after it did")
        #expect(harness.scheduler.uploads.isEmpty)
        let saved = try #require(await harness.reload())
        #expect(saved.state == .waiting)
    }

    /// R-B4. The authority is withdrawn AFTER the engine's own check and before the executor that
    /// actually sends — the window an actor hop opens. The scheduler is the one send that cannot
    /// be taken back, so the check has to be inside it.
    @Test("a withdrawal between the engine's check and the scheduler sends no chunk")
    func aWithdrawalInsideTheHopSendsNoChunk() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        // The scheduler asks the authority as it is at the moment IT runs, so withdrawing after
        // the engine has decided to send is exactly the interleaving under test.
        harness.scheduler.beforeUpload = { harness.credentials.supersede() }

        await harness.engine.drain()

        #expect(
            harness.scheduler.authorityVerdicts == [false],
            "the authority the engine handed the executor still said yes after the withdrawal"
        )
        #expect(harness.scheduler.uploads.isEmpty, "so no chunk was handed over")
        let saved = try #require(await harness.reload())
        #expect(saved.state != .held, "and the capture is not held for it either")
    }

    /// And between two chunk sends: the first chunk is already with the background session, its
    /// answer comes back, and the pass that would send the SECOND one no longer has the authority
    /// the first was sent with.
    @Test("a switch between two chunks stops before the second one")
    func aSwitchBetweenChunksStopsTheNextSend() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        #expect(harness.scheduler.uploads.count == 1, "the premise: one chunk is on its way")

        // The switch lands after this pass re-acquires and before it sends the next chunk — the
        // window a check taken at acquisition time cannot see.
        harness.credentials.supersedeAfterNextAcquisition()
        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        #expect(harness.scheduler.uploads.count == 1, "the second chunk was never scheduled")
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

    /// A chunk answer re-enters `advance` with whoever is signed in when it lands, and a capture
    /// with its create resolved goes from there straight to its edit — which builds the request
    /// from those credentials. Another account's edit must not reach that account's server.
    @Test("a chunk answer after an account switch sends nothing of the other account's edit")
    func anEditCapturedUnderAnotherAccountIsHeldOnReentry() async throws {
        let harness = try await Harness.make(
            bytes: 400,
            http: .standard(),
            credentials: Fixture.credentials(server: Fixture.otherServer, owner: "someone-else")
        )
        defer { harness.cleanUp() }
        var job = harness.job
        job.files[0].uploadUID = "u1"
        job.files[0].chunkSize = 400
        job.files[0].stagedForEdit = true
        job.resolvedMemoUID = "m1"
        job.editKey = "k1"
        job.pendingEdit = PendingEdit(
            content: "on the beach, and then the ferry",
            visibility: "PRIVATE",
            capturedAt: harness.now,
            fileIDs: [job.files[0].id]
        )
        job.state = .uploading
        job.nextAttemptAt = harness.now
        try await harness.repository.save(job)

        await harness.engine.handle(
            ChunkResult(
                identity: OutboxTaskIdentity(jobID: job.id, fileID: job.files[0].id, offset: 0),
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )

        #expect(harness.http.requests.isEmpty, "a request went out under the wrong account")
        let saved = try #require(await harness.reload())
        #expect(saved.files[0].isComplete, "the premise: the answer completed the picture")
        #expect(saved.state == .held)
        #expect(saved.holdReason == .accountMismatch)
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
            [.refused("The memo was rejected (422).", nil)], repeating: .refused("again", nil)
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

    /// N2, reopened. The background session exists from the moment the app does and can deliver a
    /// finished chunk's answer in the same turn — before adoption has run, because adoption is a
    /// task the launch schedules. The delegate used to drop anything that arrived with no handler
    /// attached, and that answer carries the server's own `bytes_received`: dropped, those bytes
    /// are uploaded a second time.
    ///
    /// Driven through the delegate itself, because that is where the drop was. The previous version
    /// of this test called `engine.handle` directly, which is downstream of the delegate — it never
    /// touched the attachment ordering at all and stayed green with the fix taken out.
    @Test("a chunk result delivered before adoption is replayed, in order, not dropped")
    func aResultDeliveredBeforeAdoptionIsReplayed() async throws {
        let delegate = OutboxSessionDelegate()
        let handler = RecordingChunkHandler()
        let identity = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0)

        // Both arrive while nothing is attached — the window a launch opens.
        delegate.deliver(ChunkResult(identity: identity, statusCode: 200, body: Data("1".utf8)))
        delegate.deliver(ChunkResult(identity: identity, statusCode: 200, body: Data("2".utf8)))
        #expect(await handler.received.isEmpty, "the premise: nothing was attached yet")

        await delegate.attach(handler)

        let bodies = await handler.received.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(
            bodies == ["1", "2"],
            """
            an answer delivered before adoption was dropped, or replayed out of order — two \
            answers for one file are a cursor moving forwards
            """
        )
    }
}

/// Collects what the delegate hands on, in arrival order.
actor RecordingChunkHandler: OutboxChunkHandling {
    private(set) var received: [ChunkResult] = []

    func handle(_ result: ChunkResult) async { received.append(result) }
}

@Suite("Adoption before draining")
struct AdoptionOrderingTests {
    /// `cancel` writes its mark, then tears the task down; a relaunch between the two finds a
    /// capture back in the editor with its chunk still on the background session. Adopted, that
    /// chunk would go up and its answer be dropped.
    @Test("a task whose capture was taken back is cancelled at relaunch, not adopted")
    func aCancelledCapturesSurvivingTaskIsNotAdopted() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        var job = harness.job
        job.files[0].uploadUID = "u1"
        job.files[0].chunkSize = 400
        job.files[0].bytesConfirmed = 400
        job.state = .uploading
        let task = OutboxTaskIdentity(
            jobID: job.id, fileID: job.files[0].id, offset: 400,
            attempt: job.files[0].uploadAttempt)
        #expect(
            OutboxReconciliation.plan(jobs: [job], inFlight: [task]).adopted == [task],
            "control: the same task on a capture still queued is adopted")
        try await harness.repository.save(job.cancelled(at: harness.now))
        harness.scheduler.pretend(inFlight: [task])

        let plan = try await harness.engine.reconcile()

        #expect(plan.adopted.isEmpty, "a task the cancel had given up was adopted")
        #expect(harness.scheduler.cancellations == [task])
    }

    /// A chunk answer is the engine's own entry point, so it can land while `reconcile` waits for
    /// the session to list its tasks: the answer moves the row on and hands the successor task
    /// over, and the list then names that successor. Planned against a row read BEFORE the wait,
    /// the successor looks like a task at an offset or term the job never asked for, and a live
    /// transfer is torn down for a reason that stopped being true while the list was being read.
    @Test(
        "a successor handed over while the tasks are listed is adopted, not cancelled",
        arguments: ["the cursor advanced", "the attempt was bumped"]
    )
    func aSuccessorHandedOverMidEnumerationIsNotCancelled(handOff: String) async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        var job = harness.job
        job.files[0].uploadUID = "u1"
        job.files[0].chunkSize = 400
        job.files[0].bytesConfirmed = 400
        job.files[0].uploadAttempt = 1
        job.state = .uploading
        try await harness.repository.save(job)
        var moved = job
        if handOff == "the cursor advanced" {
            moved.files[0].bytesConfirmed = 800
        } else {
            moved.files[0].uploadAttempt = 2
        }
        let successor = OutboxTaskIdentity(
            jobID: job.id, fileID: job.files[0].id, offset: moved.files[0].bytesConfirmed,
            attempt: moved.files[0].uploadAttempt)
        #expect(
            OutboxReconciliation.plan(jobs: [job], inFlight: [successor]).cancelled == [successor],
            "control: against the row as it stood before the hand-off, the successor is a misfit")
        let handedOver = moved
        let repository = harness.repository
        let scheduler = harness.scheduler
        scheduler.beforeInFlight = {
            do {
                try await repository.save(handedOver)
            } catch {
                Issue.record("the hand-off could not write its row: \(error)")
            }
            scheduler.pretend(inFlight: [successor])
        }

        let plan = try await harness.engine.reconcile()

        #expect(harness.scheduler.cancellations.isEmpty, "a live successor was cancelled")
        #expect(plan.adopted == [successor])
        #expect(plan.drainable.isEmpty, "a job with its successor in flight was offered to a drain")
    }

    /// G3. The replay used to run in a Task nobody waited on, and a drain can start beside it. The
    /// two are not siblings, so `isDraining` does not exclude them from each other, and the
    /// interleaving is a lost cursor: the drain retains a job at offset 0 and awaits its probe, the
    /// replay banks the server's confirmed offset and advances, and the drain then resumes with the
    /// job it was holding — sending those bytes a second time and saving the older offset over the
    /// newer one.
    ///
    /// Serialised by adoption AWAITING the replay: `attach` does not return until every held answer
    /// has reached the engine, and `Outbox.start` does not drain until adoption has returned. That
    /// is what the first assertion below is: the cursor has already moved by the time `attach` is
    /// done, with no yielding of any kind in between.
    ///
    /// The handler is the REAL engine, not a recorder — the previous version of this test used one
    /// that only appended, so it could not have noticed a cursor at all.
    @Test("adoption does not return until a held answer has reached the cursor")
    func adoptionAwaitsTheReplayBeforeAnyDrain() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let first = try #require(harness.scheduler.uploads.first)
        #expect(first.identity.offset == 0, "control: the drain sent the chunk at offset 0")

        // The system answers that chunk while nothing is attached — a launch, before adoption ran.
        let delegate = OutboxSessionDelegate()
        delegate.deliver(
            ChunkResult(
                identity: first.identity,
                statusCode: 200,
                body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
            )
        )
        #expect(
            try #require(await harness.reload()).files[0].bytesConfirmed == 0,
            "the premise: nothing has banked it yet"
        )

        await delegate.attach(harness.engine)

        // Read with nothing awaited in between. Adoption returning while the replay is still in
        // flight is the whole of the bug: a drain starting HERE would be the one that races it.
        #expect(
            try #require(await harness.reload()).files[0].bytesConfirmed == 400,
            "adoption returned before the answer it was replaying had reached the cursor"
        )

        await harness.engine.drain()

        // Exactly once for the bytes the replay confirmed. A second send of offset 0 is what the
        // race produced: a drain resuming with the job it was holding, over a cursor that had
        // already moved. (Offset 400 may legitimately be sent again — nothing has confirmed it.)
        let offsets = harness.scheduler.uploads.map(\.identity.offset)
        #expect(
            offsets.filter { $0 == 0 }.count == 1,
            "the bytes the replay had already confirmed were uploaded a second time"
        )
        #expect(offsets.first == 0, "control: the first send is the one the replay answered")
        #expect(try #require(await harness.reload()).files[0].bytesConfirmed >= 400)
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

    /// The offset HEAD is a request like any other. `handle` reaches it without going through
    /// `advance` — a 409 or an unreadable answer asks the server where the upload stands — so it
    /// is the one network-producing step that could still leave the device on a refused network.
    @Test("asking the server where the upload stands waits for the network too")
    func theOffsetResyncIsGatedToo() async throws {
        let network = StubNetworkPath(.wifi)
        let harness = try await Harness.make(
            bytes: 1000,
            http: .standard(chunkSize: 400, headOffset: 250),
            network: network
        )
        defer { harness.cleanUp() }
        await harness.engine.drain()

        await network.move(to: .cellular)
        await harness.engine.handle(
            ChunkResult(
                identity: harness.scheduler.uploads[0].identity, statusCode: 409, body: Data()
            )
        )

        #expect(harness.http.requests(method: "HEAD").isEmpty, "no HEAD on a refused network")
        let saved = try #require(await harness.reload())
        #expect(saved.files[0].bytesConfirmed == 0, "and nothing is guessed in its place")
        #expect(saved.state == .waiting)
        #expect(saved.waitReason == .homeNetwork)
        #expect(saved.attemptCount == 0, "parked, not backed off: nothing was tried")
    }

    /// The event that releases a parked capture can arrive while a drain is already running, and
    /// the drain refuses to run twice at once. Dropping it would leave the capture parked until
    /// something unrelated happened to start another drain — the wifi came back and nothing moved.
    @Test("the wifi returning during a drain is not lost")
    func anEventArrivingDuringADrainIsNotLost() async throws {
        let gate = TestGate()
        let network = StubNetworkPath(.cellular)
        let harness = try await Harness.make(
            bytes: 400,
            http: .standard(chunkSize: 400),
            holdingFirstSave: gate,
            network: network
        )
        defer { harness.cleanUp() }
        let engine = harness.engine
        // The wiring `Outbox` makes in production, made by hand here: what this test is about is
        // what happens to the event, not who delivers it (`UploadTriggerTests` covers that).
        network.onPathChange { await engine.drain() }

        let draining = Task { await engine.drain() }
        // Parked mid-write: the refusal is being recorded, so the drain is inside itself — the
        // only moment an event can be lost in.
        await gate.waitUntilParked()
        await network.move(to: .wifi)
        await gate.open()
        await draining.value

        #expect(harness.scheduler.uploads.count == 1, "the event was not dropped")
        let saved = try #require(await harness.reload())
        #expect(saved.state == .uploading)
        #expect(saved.waitReason == nil)
    }
}

/// R-N2. A wake with no authority still has to ADOPT: the system woke this process because a
/// chunk finished, and its answer carries the server's own byte count. A wake that gated adoption
/// on authority attached no handler, discarded that answer and re-sent bytes the server holds.
@MainActor
@Suite("Adoption is not a send")
struct OutboxAdoptionTests {

    @Test("a wake with no credential still takes over the queue and sends nothing")
    func adoptionNeedsNoAuthority() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Nothing is signed in, so nothing can move — passed explicitly rather than defaulted, so
        // the intent is written down beside the repository that carries it.
        let signedOut = StaticCredentials(credentials: nil)
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { signedOut.stillCurrent(epoch: $0) }
        )
        let source = try Fixture.file(in: root, named: "one.heic", bytes: 400)
        _ = try await repository.enqueue(
            content: "on the beach",
            visibility: nil,
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(),
            sources: [StagedSource(url: source, filename: "one.heic", mime: "image/heic")]
        )
        let http = ScriptedHTTP.standard(chunkSize: 400)
        let preferences = Fixture.preferences(name: "memosng.outbox.tests.adoption")
        defer { Fixture.forgetting("memosng.outbox.tests.adoption") }
        let outbox = Outbox(
            repository: repository,
            // Nobody is signed in — the cold background wake this is about.
            credentials: signedOut,
            http: http,
            scheduler: ScriptedScheduler(),
            completion: ScriptedCompletion([.retry("not now")], repeating: .retry("not now")),
            network: StubNetworkPath(),
            preferences: preferences.store
        )

        await outbox.adopt()

        #expect(outbox.jobs.count == 1, "the queue is taken over whether or not it may be drained")
        #expect(http.requests.isEmpty, "and adoption itself sent nothing")
    }
}

/// Hands the scripted server the credentials it has to supersede, which do not exist yet when the
/// server is built.
final class CredentialsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SwitchableCredentials?

    var value: SwitchableCredentials? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// H1, the G3 residue, driven through the REAL facade — which is where the ordering lives. Going
/// at `delegate.attach` directly, as the round-5 test did, cannot see it: `adopt()` used to set a
/// flag BEFORE awaiting the attachment, so a second caller arriving inside that await saw the flag,
/// skipped adoption and drained. The two are not sibling drains, so the engine's own `isDraining`
/// cannot exclude them from each other, and the interleaving loses a cursor.
@MainActor
@Suite("Adoption is a barrier every drain passes")
struct AdoptionBarrierTests {
    @Test("no drain starts while adoption is still replaying, and nothing is sent twice")
    func adoptionIsABarrier() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        let preferences = Fixture.preferences(name: "memosng.outbox.tests.barrier")
        defer { Fixture.forgetting("memosng.outbox.tests.barrier") }
        // A chunk is already with the background session at offset 0 — the state a launch finds.
        await harness.engine.drain()
        let inFlight = try #require(harness.scheduler.uploads.first).identity
        #expect(inFlight.offset == 0, "control: the chunk at offset 0 went out")

        let gate = TestGate()
        let answered = ChunkResult(
            identity: inFlight,
            statusCode: 200,
            body: Data(#"{"upload_uid":"u1","chunk_size":400,"bytes_received":400}"#.utf8)
        )
        let outbox = Outbox(
            repository: harness.repository,
            credentials: harness.credentials,
            http: harness.http,
            scheduler: harness.scheduler,
            completion: harness.completion,
            network: harness.network,
            preferences: preferences.store,
            clock: { harness.clock.now },
            // Adoption held open, and then replaying the answer that was waiting — which is
            // exactly what a launch does, and exactly what a drain must not run beside.
            attachScheduler: { handler in
                await gate.pass()
                await handler.handle(answered)
            }
        )

        let launch = Task { await outbox.start() }
        await gate.waitUntilParked()

        // Every other way into a drain. None may reach the engine while adoption is held.
        let second = Task { await outbox.start() }
        let third = Task { await outbox.drain() }
        for _ in 0..<200 { await Task.yield() }
        #expect(
            harness.scheduler.uploads.count == 1,
            "a drain ran beside the replay: it retains an offset the replay is about to move"
        )

        await gate.open()
        await launch.value
        await second.value
        await third.value

        // Offset 0 exactly once — a drain that ran beside the replay would have sent it again,
        // because the cursor it was holding had not moved yet — and the cursor is where the
        // replay put it.
        let offsets = harness.scheduler.uploads.map(\.identity.offset)
        #expect(
            offsets.filter { $0 == 0 }.count == 1,
            "the bytes the replay was about to confirm were uploaded a second time"
        )
        #expect(
            try #require(await harness.reload()).files[0].bytesConfirmed == 400,
            "the replay's cursor was overwritten by a drain that started beside it"
        )
    }
}

/// H3. A 401 is only a refusal of the credential that EARNED it. Three sites persisted
/// `.held(.serverRefused)` on one whatever the grant had become, which strands a capture behind a
/// "sign in again" the person has already done.
@Suite("A refusal of a replaced grant is not a hold")
struct SupersededRefusalTests {
    /// H3a — the upload start.
    @Test("a 401 to an upload start whose grant was replaced backs off instead of holding")
    func upstartRefusalUnderAReplacedGrant() async throws {
        let switched = CredentialsBox()
        let http = ScriptedHTTP { request in
            guard request.httpMethod == "POST", request.url?.path.hasSuffix("/uploads") == true
            else { return ScriptedHTTP.json([:]) }
            // The renewal lands while this request is on the wire.
            switched.value?.supersede()
            return OutboxHTTPResponse(statusCode: 401, body: Data())
        }
        let harness = try await Harness.make(bytes: 1000, http: http)
        defer { harness.cleanUp() }
        switched.value = harness.credentials

        await harness.engine.drain()

        let job = try #require(await harness.reload())
        #expect(job.state != JobState.held, "a refusal of a replaced grant held the job")
        #expect(job.holdReason == nil)
    }

    /// H3b — the memo create.
    @Test("a 401 to a memo create whose grant was replaced is retried, not held")
    func createRefusalUnderAReplacedGrant() async throws {
        let switched = CredentialsBox()
        let http = ScriptedHTTP { request in
            guard request.httpMethod == "POST", request.url?.path.hasSuffix("/memos") == true
            else { return ScriptedHTTP.json([:]) }
            switched.value?.supersede()
            return OutboxHTTPResponse(statusCode: 401, body: Data())
        }
        // No files: the drain goes straight to the create.
        let harness = try await Harness.make(bytes: 0, http: http)
        defer { harness.cleanUp() }
        switched.value = harness.credentials

        await harness.engine.drain()

        let job = try #require(await harness.reload())
        #expect(
            job.state != JobState.held,
            "the create's stale 401 held a capture under a valid session"
        )
        #expect(job.holdReason == nil)
    }

    /// H3c — a chunk answer, which comes back in a LATER pass and so must carry the epoch it was
    /// sent under: by the time anything classifies it, nothing else knows which credential earned
    /// it.
    @Test("a 401 chunk answer carrying a replaced epoch backs off instead of holding")
    func chunkRefusalUnderAReplacedGrant() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard(chunkSize: 400))
        defer { harness.cleanUp() }
        await harness.engine.drain()
        let sent = try #require(harness.scheduler.uploads.first)
        let epoch = try #require(harness.scheduler.epoch(of: sent.identity))

        // The renewal happens between the chunk going out and its answer coming back.
        harness.credentials.supersede()
        await harness.engine.handle(
            ChunkResult(identity: sent.identity, statusCode: 401, epoch: epoch)
        )

        let job = try #require(await harness.reload())
        #expect(
            job.state != JobState.held,
            "a chunk refused under a credential this device has replaced held the capture"
        )
        #expect(job.holdReason == nil)
    }
}
