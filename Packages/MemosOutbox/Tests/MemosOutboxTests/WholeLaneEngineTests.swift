import Foundation
@testable import MemosOutbox
import Testing

/// A value a `@Sendable` script reads and a test changes between two steps.
private final class WholeBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// The real repository behind a gate that, once armed, stops the next write an ANSWER makes —
/// whether that write is the per-file rebase or a fenced save — so a race test holds one answer
/// open however the engine chooses to write it.
private actor AnswerWriteGate: OutboxPersisting {
    private let inner: OutboxRepository
    private let gate: TestGate
    private var armed = 0
    private var skipping = 0

    init(_ inner: OutboxRepository, gate: TestGate) {
        self.inner = inner
        self.gate = gate
    }

    /// Holds `count` writes, after letting the first `skipping` through.
    func arm(_ count: Int, skipping: Int = 0) {
        armed = count
        self.skipping = skipping
    }

    private func passIfArmed() async {
        guard armed > 0 else { return }
        guard skipping == 0 else {
            skipping -= 1
            return
        }
        armed -= 1
        await gate.pass()
    }

    func loadJobs() async throws -> [UploadJob] { try await inner.loadJobs() }

    func job(_ id: UUID) async -> UploadJob? { await inner.job(id) }

    func save(_ job: UploadJob) async throws {
        await passIfArmed()
        try await inner.save(job)
    }

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        await passIfArmed()
        return try await inner.save(
            job, ifStillCurrent: epoch, matching: snapshot, else: fallback
        )
    }

    func delete(_ job: UploadJob) async { await inner.delete(job) }

    func delete(_ job: UploadJob, ifStillCurrent snapshot: UploadJob) async -> Bool {
        await inner.delete(job, ifStillCurrent: snapshot)
    }

    func sweepOrphans() async throws -> SweepOutcome { try await inner.sweepOrphans() }

    func sliceChunk(
        job: UploadJob, file: OutboxFile, offset: Int64, length: Int, attempt: Int?
    ) async throws -> URL {
        try await inner.sliceChunk(
            job: job, file: file, offset: offset, length: length, attempt: attempt
        )
    }

    func removeChunk(at url: URL) async { await inner.removeChunk(at: url) }

    nonisolated func chunkURL(jobID: UUID, fileID: UUID, offset: Int64, attempt: Int?) -> URL {
        inner.chunkURL(jobID: jobID, fileID: fileID, offset: offset, attempt: attempt)
    }

    nonisolated func mediaURL(job: UploadJob, file: OutboxFile) -> URL {
        inner.mediaURL(job: job, file: file)
    }

    func applyFileAnswer(
        jobID: UUID,
        fileID: UUID,
        attempt: Int,
        outcome: WholeFileChange,
        presented: WholeTaskProvenance,
        at instant: Date
    ) async throws -> UploadJob? {
        await passIfArmed()
        return try await inner.applyFileAnswer(
            jobID: jobID, fileID: fileID, attempt: attempt, outcome: outcome,
            presented: presented, at: instant
        )
    }
}

/// The production scheduler with one hand-off to it — the `holding`-th — stopped at a gate until
/// the test opens it, so the engine sits inside its hand-off loop between one file's task and the
/// next file's. Or, with `holdingFirstSuccessor`, the first replacement stopped just after its
/// successor closure has returned — the row written at the new term — and before the scheduler
/// creates the task. Or, with `holdingMismatched`, the first mismatch list naming any task held
/// once it has been taken. Or, once `churn` is called, each of the next listings preceded by an
/// answer for a row nobody has, which claims and releases a file in the engine: a queue that keeps
/// moving.
private actor PausingUploads: OutboxUploadScheduling {
    nonisolated let launch: UUID
    private let inner: BackgroundUploadScheduler
    private let gate: TestGate
    private var untilHeld: Int
    private var successorHold: TestGate?
    private var mismatchedHold: TestGate?
    private var churning = 0
    private var churnAnswer: WholeAnswer?
    private var churnInto: (any WholeAnswerHandling)?

    init(
        _ inner: BackgroundUploadScheduler, gate: TestGate = TestGate(), holding index: Int = 0,
        holdingFirstSuccessor successorHold: TestGate? = nil,
        holdingMismatched mismatchedHold: TestGate? = nil
    ) {
        self.inner = inner
        self.launch = inner.launch
        self.gate = gate
        self.untilHeld = index
        self.successorHold = successorHold
        self.mismatchedHold = mismatchedHold
    }

    func churn(_ count: Int, like answer: WholeAnswer, into handler: any WholeAnswerHandling) {
        churning = count
        churnAnswer = answer
        churnInto = handler
    }

    var churnLeft: Int { churning }

    func attach(_ handler: any WholeAnswerHandling) async { await inner.attach(handler) }

    func tasks() async -> [WholeTaskListing] {
        if churning > 0, var answer = churnAnswer, let handler = churnInto {
            churning -= 1
            answer.identity.jobID = UUID()
            answer.taskIdentifier = 9_000 + churning
            await handler.handle(answer)
        }
        return await inner.tasks()
    }

    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        for ref: WholeFileRef,
        attempt: Int,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) async -> WholeTask? {
        untilHeld -= 1
        if untilHeld == 0 { await gate.pass() }
        return await inner.upload(
            request, fromFile: file, for: ref, attempt: attempt, under: authority,
            issuedUnder: epoch
        )
    }

    func cancel(_ taskIdentifiers: [Int]) async { await inner.cancel(taskIdentifiers) }

    func cancelUnreadable() async -> [Int] { await inner.cancelUnreadable() }

    func mismatched(allowsMobileData: Bool) async -> [WholeTask] {
        let listed = await inner.mismatched(allowsMobileData: allowsMobileData)
        guard !listed.isEmpty, let hold = mismatchedHold else { return listed }
        mismatchedHold = nil
        await hold.pass()
        return listed
    }

    func replace(
        _ task: WholeTask,
        under authority: SendAuthority,
        onSettled: @escaping @concurrent @Sendable (WholeTask?) async -> Void,
        successor: @escaping @concurrent @Sendable () async -> WholeSuccessor?
    ) async -> WholeReplacement {
        let hold = successorHold
        successorHold = nil
        return await inner.replace(task, under: authority, onSettled: onSettled) {
            let built = await successor()
            await hold?.pass()
            return built
        }
    }

    func reexamineDeferred() async -> [WholeTask] { await inner.reexamineDeferred() }
}

/// The real engine, the real repository and the PRODUCTION `BackgroundUploadScheduler`, over a
/// scripted task session and a scripted server. A capture of one picture and one video.
private struct WholeRig {
    let root: URL
    let repository: OutboxRepository
    let http: ScriptedHTTP
    let postStatus: WholeBox<Int>
    let attempted: WholeBox<[String]>
    let chunks: ScriptedScheduler
    let session: ScriptedUploadTaskSession
    let delegate: UploadSessionDelegate
    let launch: UUID
    let gate: SchedulingGate
    let credentials: SwitchableCredentials
    let network: StubNetworkPath
    let preferences: UploadPreferences
    let preferencesName: String
    let clock: MutableClock
    let completion: ScriptedCompletion
    let engine: OutboxEngine
    let job: UploadJob

    var picture: OutboxFile { job.files[0] }
    var video: OutboxFile { job.files[1] }

    static func make(
        withUploads: Bool = true,
        listing: @Sendable (UploadJob) -> [WholeTaskListing] = { _ in [] },
        onCancel: ScriptedUploadTaskSession.OnCancel = .staysListed,
        persistence makePersistence: (@Sendable (OutboxRepository) -> any OutboxPersisting)? =
            nil,
        completion: [MemoCompletionOutcome] = [.created(uid: "m1")],
        prepare: @Sendable (UploadJob) -> UploadJob? = { _ in nil },
        wrapUploads: (@Sendable (BackgroundUploadScheduler) -> any OutboxUploadScheduling)? = nil,
        network: StubNetworkPath = StubNetworkPath(),
        chunksInFlight: [OutboxTaskIdentity] = []
    ) async throws -> WholeRig {
        let root = try Fixture.temporaryDirectory()
        let provider = SwitchableCredentials(Fixture.credentials())
        let repository = try OutboxRepository(
            root: root.appending(path: "outbox"),
            stillCurrent: { provider.stillCurrent(epoch: $0) }
        )
        let sources = [
            StagedSource(
                url: try Fixture.file(in: root, named: "picture.heic", bytes: 1000),
                filename: "picture.heic", mime: "image/heic"
            ),
            StagedSource(
                url: try Fixture.file(in: root, named: "video.mov", bytes: 3000),
                filename: "video.mov", mime: "video/quicktime"
            ),
        ]
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var job = try await repository.enqueue(
            content: "a picture and a video", visibility: "PRIVATE", capturedAt: now,
            binding: Fixture.binding(), sources: sources
        )
        if let prepared = prepare(job) {
            try await repository.save(prepared)
            job = try #require(await repository.job(job.id))
        }
        let postStatus = WholeBox(201)
        let posts = Counter()
        let http = ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/uploads"):
                guard postStatus.value == 201 else {
                    return OutboxHTTPResponse(statusCode: postStatus.value)
                }
                posts.increment()
                return ScriptedHTTP.session(
                    uid: "u\(posts.count)", chunkSize: 5 * 1024 * 1024, received: 0
                )
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
        let attempted = WholeBox<[String]>([])
        http.beforeSend = { request in
            attempted.mutate {
                $0.append("\(request.httpMethod ?? "") \(request.url?.path() ?? "")")
            }
        }
        let session = ScriptedUploadTaskSession(listing: listing(job), onCancel: onCancel)
        let delegate = UploadSessionDelegate()
        let launch = UUID()
        // The replace barrier's bound is spent on this clock, one pause at a time, never slept.
        let barrier = MutableClock(now)
        let uploads = BackgroundUploadScheduler(
            session: session, delegate: delegate, launch: launch,
            now: { barrier.now }, pause: { barrier.advance(11) }
        )
        let clock = MutableClock(now)
        let preferences = Fixture.preferences(allowsMobileData: false)
        let chunks = ScriptedScheduler(inFlight: chunksInFlight)
        let completion = ScriptedCompletion(completion)
        let gate = SchedulingGate()
        let engine = OutboxEngine(
            repository: makePersistence?(repository) ?? repository,
            credentials: provider,
            http: http,
            scheduler: chunks,
            completion: completion,
            network: network,
            preferences: preferences.store,
            clock: { clock.now },
            schedulingGate: gate,
            uploads: withUploads ? (wrapUploads?(uploads) ?? uploads) : nil
        )
        await uploads.attach(engine)
        return WholeRig(
            root: root, repository: repository, http: http, postStatus: postStatus,
            attempted: attempted, chunks: chunks, session: session, delegate: delegate,
            launch: launch, gate: gate, credentials: provider, network: network,
            preferences: preferences.store,
            preferencesName: preferences.name, clock: clock, completion: completion,
            engine: engine, job: job
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        Fixture.forgetting(preferencesName)
    }

    func reload() async throws -> UploadJob { try #require(await repository.job(job.id)) }

    var uploadPosts: Int {
        http.requests(method: "POST").filter { $0.url?.path() == "/api/uploads" }.count
    }

    var attemptedUploadPosts: Int { attempted.value.filter { $0 == "POST /api/uploads" }.count }

    /// The task created for this file under this term.
    func task(for fileID: UUID, attempt: Int = 0) throws -> ScriptedUploadTaskSession.Created {
        try #require(
            session.createdTasks.first {
                let identity = WholeTaskIdentity(taskDescription: $0.description)
                return identity?.fileID == fileID && identity?.attempt == attempt
            }
        )
    }

    /// The term of every task created for this file, in creation order.
    func attempts(of fileID: UUID) -> [Int] {
        session.createdTasks.compactMap { created in
            WholeTaskIdentity(taskDescription: created.description)
                .flatMap { $0.fileID == fileID ? $0.attempt : nil }
        }
    }

    /// What the session would hand the delegate for this task.
    func answer(
        _ task: ScriptedUploadTaskSession.Created,
        status: Int?,
        received: Int? = nil,
        launch: UUID? = nil
    ) throws -> WholeAnswer {
        var identity = try #require(WholeTaskIdentity(taskDescription: task.description))
        if let launch { identity.launch = launch }
        let body = received.map { ScriptedHTTP.session(uid: "x", chunkSize: 1, received: $0).body }
        return WholeAnswer(
            taskIdentifier: task.taskIdentifier, identity: identity, statusCode: status,
            body: body ?? Data()
        )
    }

    /// Waits, bounded, for something another executor does after a callback.
    func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await condition()
    }
}

@Suite("Whole lane: the engine drives whole rows")
struct WholeLaneEngineTests {
    @Test("a two-file capture opens both sessions, writes once, then hands off both files")
    func twoFilesInOnePass() async throws {
        let parked = TestGate()
        let rig = try await WholeRig.make(persistence: {
            GatedPersistence($0, gate: parked, holding: 1)
        })
        defer { rig.cleanUp() }
        let drain = Task { await rig.engine.drain() }
        await parked.waitUntilParked()
        // Held inside the pass's first write: both sessions are already open and nothing has been
        // handed to the session on a state nobody wrote.
        #expect(rig.uploadPosts == 2)
        #expect(rig.session.createdTasks.isEmpty)
        await parked.open()
        await drain.value

        let created = rig.session.createdTasks
        #expect(created.count == 2)
        let saved = try await rig.reload()
        #expect(saved.transport == .whole)
        #expect(saved.state == .uploading)
        #expect(saved.files.map(\.uploadUID) == ["u1", "u2"])
        #expect(created.map(\.request.httpMethod) == ["PATCH", "PATCH"])
        let offsets = created.map { $0.request.value(forHTTPHeaderField: "Upload-Offset") }
        #expect(offsets == ["0", "0"])
        #expect(created.allSatisfy { !$0.request.allowsCellularAccess })
        #expect(rig.chunks.uploads.isEmpty)
    }

    @Test("two answers racing both land on disk, and the memo is created once")
    func twoAnswersRace() async throws {
        let parked = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: parked)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")]
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let pictureAnswer = try rig.answer(
            rig.task(for: rig.picture.id), status: 200, received: 1000
        )
        let videoAnswer = try rig.answer(
            rig.task(for: rig.video.id), status: 200, received: 3000
        )
        await gated.value?.arm(1)

        let first = Task { await rig.engine.handle(pictureAnswer) }
        await parked.waitUntilParked()
        await rig.engine.handle(videoAnswer)
        await parked.open()
        await first.value

        let saved = try await rig.reload()
        #expect(saved.files.allSatisfy { $0.isComplete })
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    @Test("a sibling's answer does not resend a file whose finished task left the list mid-write")
    func twoAnswersRaceTaskGone() async throws {
        let parked = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: parked)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")]
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let pictureTask = try rig.task(for: rig.picture.id)
        let pictureAnswer = try rig.answer(pictureTask, status: 200, received: 1000)
        let videoAnswer = try rig.answer(
            rig.task(for: rig.video.id), status: 200, received: 3000
        )
        let postsBefore = rig.attemptedUploadPosts
        await gated.value?.arm(1)

        let first = Task { await rig.engine.handle(pictureAnswer) }
        await parked.waitUntilParked()
        // The picture's task has finished and left the list; its success is still being written.
        rig.session.forget(pictureTask.taskIdentifier)
        await rig.engine.handle(videoAnswer)
        #expect(rig.attemptedUploadPosts == postsBefore)
        await parked.open()
        await first.value

        let saved = try await rig.reload()
        #expect(saved.files.allSatisfy { $0.isComplete })
        #expect((saved.file(rig.picture.id)?.uploadAttempt ?? 0) == 0)
        #expect(rig.attemptedUploadPosts == postsBefore)
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    @Test("an answer landing mid-hand-off does not send the file the loop has not reached yet")
    func answerMidHandOff() async throws {
        let parked = TestGate()
        // The create is answered "later" so the row stays on disk to be read back.
        let rig = try await WholeRig.make(
            completion: [.retry("later")],
            wrapUploads: { PausingUploads($0, gate: parked, holding: 2) }
        )
        defer { rig.cleanUp() }
        let drain = Task { await rig.engine.drain() }
        await parked.waitUntilParked()
        // Both files are written with their sessions; only the picture has its task so far.
        #expect(rig.session.createdTasks.count == 1)
        let pictureTask = try rig.task(for: rig.picture.id)
        await rig.engine.handle(try rig.answer(pictureTask, status: 200, received: 1000))
        #expect(rig.attemptedUploadPosts == 2)
        #expect(rig.session.createdTasks.count == 1)
        await parked.open()
        await drain.value

        let videoTask = try rig.task(for: rig.video.id)
        await rig.engine.handle(try rig.answer(videoTask, status: 200, received: 3000))
        let saved = try await rig.reload()
        #expect(saved.files.allSatisfy { $0.isComplete })
        #expect(saved.files.map { $0.uploadAttempt ?? 0 } == [0, 0])
        #expect(rig.attemptedUploadPosts == 2)
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    @Test("an answer against a row whose memo create has begun writes nothing")
    func creatingRowTakesNoAnswer() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        var creating = try await rig.reload()
        creating.state = .creating
        try await rig.repository.save(creating)
        let before = try await rig.reload()

        let written = try await rig.repository.applyFileAnswer(
            jobID: rig.job.id, fileID: rig.picture.id, attempt: 0, outcome: .confirmed(1000),
            presented: .unknown, at: rig.clock.now
        )
        #expect(written == nil)
        await rig.engine.handle(
            try rig.answer(rig.task(for: rig.picture.id), status: 200, received: 1000)
        )
        let after = try await rig.reload()
        #expect(after == before)
        #expect(rig.completion.idempotencyKeys.isEmpty)
    }

    @Test("a picture's failure retries only the picture, and the video's later answer still lands")
    func siblingSurvivesRetry() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let oldPicture = try rig.task(for: rig.picture.id)
        let videoTask = try rig.task(for: rig.video.id)

        await rig.engine.handle(try rig.answer(oldPicture, status: 503))
        rig.session.forget(oldPicture.taskIdentifier)
        #expect(try await rig.reload().state == .waiting)
        rig.clock.advance(7 * 3600)
        await rig.engine.drain()

        let newPicture = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(rig.uploadPosts == 3)
        #expect(rig.session.createdTasks.count == 3)
        #expect(!rig.session.cancelledIdentifiers.contains(videoTask.taskIdentifier))
        var saved = try await rig.reload()
        #expect(saved.file(rig.video.id)?.uploadAttempt == nil)
        #expect(saved.file(rig.picture.id)?.uploadAttempt == 1)

        await rig.engine.handle(try rig.answer(videoTask, status: 200, received: 3000))
        saved = try await rig.reload()
        #expect(saved.file(rig.video.id)?.isComplete == true)
        #expect(saved.file(rig.picture.id)?.isComplete == false)
        #expect(rig.completion.idempotencyKeys.isEmpty)

        await rig.engine.handle(try rig.answer(newPicture, status: 200, received: 1000))
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    @Test("matrix: a listed task matching its file is adopted and its file is not sent again")
    func adoptsMatchingTasks() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        await rig.engine.drain()
        #expect(rig.uploadPosts == 2)
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.session.cancelledIdentifiers.isEmpty)
    }

    @Test("matrix: a task for no row, and one for a row off the whole lane, are cancelled")
    func cancelsTasksNoRowNeeds() async throws {
        let stale = WholeBox<String?>(nil)
        let rig = try await WholeRig.make(
            withUploads: true,
            listing: { job in
                let description = WholeTaskIdentity(
                    jobID: job.id, fileID: job.files[0].id, attempt: 5, launch: UUID(), epoch: 0
                ).taskDescription
                stale.value = description
                return [
                    WholeTaskListing(
                        taskIdentifier: 7,
                        taskDescription: WholeTaskIdentity(
                            jobID: UUID(), fileID: UUID(), attempt: 0, launch: UUID(), epoch: 0
                        ).taskDescription
                    ),
                    WholeTaskListing(taskIdentifier: 8, taskDescription: description),
                ]
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(Set(rig.session.cancelledIdentifiers) == [7, 8])
        // The stale task carries its file until it has ended: only the other file goes out.
        #expect(rig.attempts(of: rig.video.id) == [0])
        #expect(rig.attempts(of: rig.picture.id).isEmpty)

        rig.delegate.complete(
            taskIdentifier: 8, taskDescription: stale.value, statusCode: nil,
            errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id).count == 1 })
        await rig.engine.untilQuiescent()
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("matrix: an unreadable task is cancelled, its answer applies nowhere, the row completes")
    func unreadableTaskEndToEnd() async throws {
        let rig = try await WholeRig.make(listing: { _ in
            [WholeTaskListing(taskIdentifier: 7, taskDescription: "not|a|whole|task")]
        })
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(rig.session.cancelledIdentifiers == [7])
        // Its cancellation still ends it, through the one claim every terminal callback takes.
        #expect(
            rig.delegate.complete(
                taskIdentifier: 7, taskDescription: "not|a|whole|task", statusCode: nil,
                errorDescription: "cancelled"
            )
        )
        // Ended, it leaves the session's list, and only then are the files sent.
        rig.session.forget(7)
        await rig.engine.drain()
        await rig.engine.handle(
            try rig.answer(rig.task(for: rig.picture.id), status: 200, received: 1000)
        )
        await rig.engine.handle(
            try rig.answer(rig.task(for: rig.video.id), status: 200, received: 3000)
        )
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    @Test("matrix: a record with no task is sent again whole only while scheduling is open")
    func recordOnlyWaitsForTheGate() async throws {
        let rig = try await WholeRig.make(prepare: { job in
            var started = job
            started.transport = .whole
            started.state = .uploading
            started.files[0].uploadUID = "old-a"
            started.files[1].uploadUID = "old-b"
            return started
        })
        defer { rig.cleanUp() }
        let before = try await rig.reload()
        rig.gate.close()
        await rig.engine.drain()
        #expect(try await rig.reload() == before)
        #expect(rig.attemptedUploadPosts == 0)
        #expect(rig.session.createdTasks.isEmpty)

        rig.gate.open()
        await rig.engine.drain()
        let saved = try await rig.reload()
        #expect(saved.files.map(\.uploadAttempt) == [1, 1])
        #expect(saved.files.map(\.uploadUID) == ["u1", "u2"])
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("matrix: no row and no task — nothing is sent and nothing cancelled")
    func neitherDoesNothing() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.repository.delete(rig.job)
        await rig.engine.drain()
        #expect(rig.attempted.value.isEmpty)
        #expect(rig.session.createdTasks.isEmpty)
        #expect(rig.session.cancelledIdentifiers.isEmpty)
    }

    @Test("a refusal this launch earned holds under the current credential")
    func thisLaunchRefusalHolds() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        await rig.engine.handle(try rig.answer(rig.task(for: rig.picture.id), status: 401))
        let saved = try await rig.reload()
        #expect(saved.state == .held)
        #expect(saved.holdReason == .serverRefused)
    }

    @Test("a refusal this launch earned under a replaced credential backs off")
    func supersededRefusalBacksOff() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        rig.credentials.supersede()
        await rig.engine.handle(try rig.answer(rig.task(for: rig.picture.id), status: 401))
        let saved = try await rig.reload()
        #expect(saved.state == .waiting)
        #expect(saved.attemptCount == 1)
    }

    @Test("a refusal another launch earned backs off; the retry's own refusal then holds")
    func foreignRefusalBacksOffThenPostHolds() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        await rig.engine.handle(try rig.answer(picture, status: 401, launch: UUID()))
        var saved = try await rig.reload()
        #expect(saved.state == .waiting)
        #expect(saved.holdReason == nil)

        rig.session.forget(picture.taskIdentifier)
        rig.postStatus.value = 401
        rig.clock.advance(7 * 3600)
        await rig.engine.drain()
        saved = try await rig.reload()
        #expect(saved.state == .held)
        #expect(saved.holdReason == .serverRefused)
    }

    @Test("a toggle flip replaces each task: cancelled first, successor under the new choice")
    func toggleFlipReplaces() async throws {
        let rig = try await WholeRig.make(onCancel: .leavesListing(after: 1))
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let old = rig.session.createdTasks.map(\.taskIdentifier)
        await rig.preferences.set(true)
        await rig.engine.drain()

        #expect(Set(rig.session.cancelledIdentifiers) == Set(old))
        let successors = rig.session.createdTasks.dropFirst(2)
        #expect(successors.count == 2)
        #expect(successors.allSatisfy { $0.request.allowsCellularAccess })
        #expect(try await rig.reload().files.map(\.uploadAttempt) == [1, 1])
    }

    @Test("mobile data turned off on cellular cancels each task though the pass may send nothing")
    func toggleOffOnCellularCancels() async throws {
        let rig = try await WholeRig.make(onCancel: .leavesListing(after: 1))
        defer { rig.cleanUp() }
        await rig.preferences.set(true)
        await rig.network.move(to: .cellular)
        await rig.engine.drain()
        let old = rig.session.createdTasks.map(\.taskIdentifier)
        #expect(old.count == 2)
        let postsBefore = rig.attemptedUploadPosts

        await rig.preferences.set(false)
        await rig.engine.drain()

        // The tasks the old choice let onto cellular are gone, and nothing replaces them until
        // the phone is on a network the new choice allows.
        #expect(Set(rig.session.cancelledIdentifiers) == Set(old))
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.attemptedUploadPosts == postsBefore)
    }

    @Test("a deferred successor goes out under the choice standing when it is sent")
    func deferredSuccessorTakesCurrentChoice() async throws {
        let rig = try await WholeRig.make(onCancel: .staysListed)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        await rig.preferences.set(true)
        await rig.engine.drain()
        #expect(rig.session.createdTasks.count == 2)
        // Changed again while the replacement waits for the old task to end.
        await rig.preferences.set(false)

        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.session.createdTasks.count == 3 })
        await rig.engine.untilQuiescent()

        let successor = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(!successor.request.allowsCellularAccess)
        #expect(!successor.request.allowsExpensiveNetworkAccess)
    }

    @Test("a listed task nobody can read holds back every file until it has left the list")
    func unreadableTaskIsABarrier() async throws {
        let rig = try await WholeRig.make(
            listing: { _ in
                [WholeTaskListing(taskIdentifier: 7, taskDescription: "not|a|whole|task")]
            },
            onCancel: .staysListed
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        // Cancelled, and still listed: it may be carrying either file, so neither goes out.
        #expect(rig.session.cancelledIdentifiers == [7])
        #expect(rig.session.createdTasks.isEmpty)
        #expect(rig.attemptedUploadPosts == 0)

        rig.session.forget(7)
        await rig.engine.drain()
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("a sign-out cancels every task of both sessions, and their late answers send nothing")
    func signOutAbandonsEveryTask() async throws {
        let chunk = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0, attempt: 0)
        let rig = try await WholeRig.make(
            listing: { job in
                [
                    WholeTaskListing(
                        taskIdentifier: 7,
                        taskDescription: WholeTaskIdentity(
                            jobID: job.id, fileID: job.files[0].id, attempt: 0, launch: UUID(),
                            epoch: 0
                        ).taskDescription
                    ),
                    WholeTaskListing(taskIdentifier: 8, taskDescription: "not|a|whole|task"),
                ]
            },
            chunksInFlight: [chunk]
        )
        defer { rig.cleanUp() }
        // The session's credential is withdrawn first; the outbox is told after.
        rig.credentials.set(nil)
        await rig.engine.abandonAllTasks()

        #expect(rig.chunks.cancellations == [chunk])
        #expect(Set(rig.session.cancelledIdentifiers) == [7, 8])

        // The cancelled task still answers. Nobody is signed in, so nothing is sent again.
        await rig.engine.handle(
            WholeAnswer(
                taskIdentifier: 7,
                identity: WholeTaskIdentity(
                    jobID: rig.job.id, fileID: rig.picture.id, attempt: 0, launch: UUID(),
                    epoch: 0
                ),
                statusCode: nil,
                body: Data()
            )
        )
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(rig.session.createdTasks.isEmpty)
        #expect(rig.attemptedUploadPosts == 0)
        #expect(rig.completion.idempotencyKeys.isEmpty)
        #expect(await rig.repository.job(rig.job.id) != nil)
    }

    @Test("a deferred replacement's cancelled task answers without a status, and changes nothing")
    func deferredReplacementLateAnswer() async throws {
        let rig = try await WholeRig.make(onCancel: .staysListed)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        await rig.preferences.set(true)
        await rig.engine.drain()
        // Both old tasks are still listed: no successor may go out beside them.
        #expect(rig.session.createdTasks.count == 2)

        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.session.createdTasks.count == 3 })
        await rig.engine.untilQuiescent()

        let saved = try await rig.reload()
        let file = try #require(saved.file(rig.picture.id))
        #expect(file.uploadAttempt == 1)
        #expect(file.uploadUID == "u3")
        #expect(saved.attemptCount == 0)
        #expect(saved.lastError == nil)
        #expect(saved.state == .uploading)
    }

    @Test("a replacement owns its file past the successor's write, until its task exists")
    func replacementOwnsUntilTaskCreated() async throws {
        let parked = TestGate()
        let rig = try await WholeRig.make(
            onCancel: .leavesListing(after: 1),
            completion: [.retry("later")],
            wrapUploads: { PausingUploads($0, holdingFirstSuccessor: parked) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        await rig.preferences.set(true)
        let drain = Task { await rig.engine.drain() }
        await parked.waitUntilParked()
        // One file's successor is written at attempt 1, its old task has left the list and the
        // scheduler has not created the new one yet. The sibling answers now.
        let written = try await rig.reload()
        let replaced = try #require(written.files.first { $0.uploadAttempt == 1 })
        let sibling = try #require(written.files.first { $0.id != replaced.id })
        let postsBefore = rig.attemptedUploadPosts
        await rig.engine.handle(
            try rig.answer(
                rig.task(for: sibling.id), status: 200, received: Int(sibling.byteSize)
            )
        )
        #expect(rig.attemptedUploadPosts == postsBefore)
        await parked.open()
        await drain.value

        let saved = try await rig.reload()
        #expect(saved.file(replaced.id)?.uploadAttempt == 1)
        let attempts = rig.session.createdTasks.compactMap { created in
            WholeTaskIdentity(taskDescription: created.description)
                .flatMap { $0.fileID == replaced.id ? $0.attempt : nil }
        }
        #expect(attempts == [0, 1])
        #expect(rig.attemptedUploadPosts == postsBefore)
    }

    @Test("a replacement settling while a sibling's pass reads the task list sends nothing again")
    func replacementSettlesDuringSiblingListing() async throws {
        let parked = TestGate()
        let listing = TestGate()
        let rig = try await WholeRig.make(
            onCancel: .leavesListing(after: 1),
            completion: [.retry("later")],
            wrapUploads: { PausingUploads($0, holdingFirstSuccessor: parked) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        await rig.preferences.set(true)
        let drain = Task { await rig.engine.drain() }
        await parked.waitUntilParked()
        let written = try await rig.reload()
        let replaced = try #require(written.files.first { $0.uploadAttempt == 1 })
        let sibling = try #require(written.files.first { $0.id != replaced.id })
        let postsBefore = rig.attemptedUploadPosts
        let answer = try rig.answer(
            rig.task(for: sibling.id), status: 200, received: Int(sibling.byteSize)
        )

        // The sibling's continuation takes its listing while the successor has no task yet, and
        // is held there with that listing in hand.
        rig.session.holdNextListing(on: listing)
        let continuation = Task { await rig.engine.handle(answer) }
        await listing.waitUntilParked()
        // Meanwhile the successor's task is created and the replacement settles.
        await parked.open()
        await drain.value
        #expect(rig.session.createdTasks.count == 3)
        await listing.open()
        await continuation.value

        let saved = try await rig.reload()
        #expect(saved.file(replaced.id)?.uploadAttempt == 1)
        #expect(saved.file(sibling.id)?.isComplete == true)
        let attempts = rig.session.createdTasks.compactMap { created in
            WholeTaskIdentity(taskDescription: created.description)
                .flatMap { $0.fileID == replaced.id ? $0.attempt : nil }
        }
        #expect(attempts == [0, 1])
        #expect(rig.attemptedUploadPosts == postsBefore)
    }

    @Test("a deferred replacement owns its file once the old task has left the list")
    func deferredReplacementOwnsFile() async throws {
        let rig = try await WholeRig.make(onCancel: .staysListed, completion: [.retry("later")])
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        await rig.preferences.set(true)
        await rig.engine.drain()
        #expect(rig.session.createdTasks.count == 2)
        // The picture's old task ends, so its successor goes out.
        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        let pictureSent = try await rig.eventually { rig.session.createdTasks.count == 3 }
        #expect(pictureSent)
        await rig.engine.untilQuiescent()
        // The video's old task leaves the list with no callback: only a later look finds it gone.
        rig.session.forget(video.taskIdentifier)
        let postsBefore = rig.attemptedUploadPosts

        let successor = try rig.task(for: rig.picture.id, attempt: 1)
        await rig.engine.handle(try rig.answer(successor, status: 200, received: 1000))
        #expect(rig.attemptedUploadPosts == postsBefore)
        #expect(rig.session.createdTasks.count == 3)

        await rig.engine.drain()
        await rig.engine.drain()
        let attempts = rig.session.createdTasks.compactMap { created in
            WholeTaskIdentity(taskDescription: created.description)
                .flatMap { $0.fileID == rig.video.id ? $0.attempt : nil }
        }
        #expect(attempts == [0, 1])
        #expect(rig.attemptedUploadPosts == postsBefore + 1)
        let saved = try await rig.reload()
        #expect(saved.file(rig.picture.id)?.isComplete == true)
        #expect(saved.file(rig.video.id)?.uploadAttempt == 1)
    }

    @Test("send hop: the gate closing during the whole row's write stops every hand-off")
    func wholeSendHop() async throws {
        let parked = TestGate()
        let rig = try await WholeRig.make(persistence: {
            GatedPersistence($0, gate: parked, holding: 1)
        })
        defer { rig.cleanUp() }
        let drain = Task { await rig.engine.drain() }
        await parked.waitUntilParked()
        rig.gate.close()
        await parked.open()
        await drain.value
        #expect(rig.session.createdTasks.isEmpty)
        #expect(try await rig.reload().attemptCount == 0)

        rig.gate.open()
        await rig.engine.drain()
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("an engine without an upload scheduler never puts a row on the whole lane")
    func noSchedulerNoWhole() async throws {
        let rig = try await WholeRig.make(withUploads: false)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(try await rig.reload().transport == nil)
        #expect(rig.chunks.uploads.count == 1)
        #expect(rig.session.createdTasks.isEmpty)
    }

    @Test("a row begun on the chunk lane still completes there beside an upload scheduler")
    func chunkRowCompletes() async throws {
        let rig = try await WholeRig.make(prepare: { job in
            var started = job
            started.files[0].uploadUID = "c1"
            return started
        })
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let first = try #require(rig.chunks.uploads.first)
        await rig.engine.handle(
            ChunkResult(
                identity: first.identity, statusCode: 200,
                body: ScriptedHTTP.session(uid: "c1", chunkSize: 1, received: 1000).body
            )
        )
        let second = try #require(rig.chunks.uploads.last)
        #expect(second.identity.fileID == rig.video.id)
        await rig.engine.handle(
            ChunkResult(
                identity: second.identity, statusCode: 200,
                body: ScriptedHTTP.session(uid: "u1", chunkSize: 1, received: 3000).body
            )
        )
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.repository.job(rig.job.id) == nil)
        #expect(rig.session.createdTasks.isEmpty)
    }

    @Test("a wake schedules nothing new: it only finishes a completed transfer's memo create")
    func wakeOnlyCreates() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        // The picture's task is gone from the list: its file is a record with no task.
        rig.session.forget(picture.taskIdentifier)
        rig.gate.close()
        let postsBefore = rig.attemptedUploadPosts

        await rig.engine.handle(try rig.answer(video, status: 200, received: 3000))
        #expect(try await rig.reload().file(rig.video.id)?.isComplete == true)
        #expect(rig.attemptedUploadPosts == postsBefore)
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.completion.idempotencyKeys.isEmpty)

        await rig.engine.handle(try rig.answer(picture, status: 200, received: 1000))
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(rig.attemptedUploadPosts == postsBefore)
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("Try again beside a cancelling task sends nothing until it ends, then exactly once")
    func tryAgainWaitsForOldTask() async throws {
        let rig = try await WholeRig.make(onCancel: .staysListed, completion: [.retry("later")])
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        await rig.engine.release(jobID: rig.job.id)
        let cancelled = Set(rig.session.cancelledIdentifiers)
        #expect(cancelled.isSuperset(of: [picture.taskIdentifier, video.taskIdentifier]))
        // Both old tasks are still listed, cancelling: no new term may go out beside either.
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(rig.attemptedUploadPosts == 2)

        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attemptedUploadPosts == 3 })
        await rig.engine.untilQuiescent()
        await rig.engine.drain()
        #expect(rig.attemptedUploadPosts == 3)
        #expect(rig.attempts(of: rig.picture.id).count == 2)
        #expect(rig.attempts(of: rig.video.id) == [0])

        rig.delegate.complete(
            taskIdentifier: video.taskIdentifier, taskDescription: video.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attemptedUploadPosts == 4 })
        await rig.engine.untilQuiescent()
        await rig.engine.drain()
        #expect(rig.attemptedUploadPosts == 4)
        #expect(rig.attempts(of: rig.video.id).count == 2)
    }

    @Test("a mismatch list taken before a sibling's answer replaces no file that answer is sending")
    func mismatchAdmissionRefusesOwnedFile() async throws {
        let listed = TestGate()
        let written = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: written)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")],
            wrapUploads: { PausingUploads($0, holdingMismatched: listed) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        let videoAnswer = try rig.answer(video, status: 200, received: 3000)
        await rig.preferences.set(true)
        // The drain takes the mismatch list — both old tasks — and is held with it in hand.
        let drain = Task { await rig.engine.drain() }
        await listed.waitUntilParked()
        // The picture's task leaves the list with no callback. The video's success lands, and its
        // continuation sends the picture again whole: posted, then held at its write.
        rig.session.forget(picture.taskIdentifier)
        await gated.value?.arm(1, skipping: 1)
        let continuation = Task { await rig.engine.handle(videoAnswer) }
        await written.waitUntilParked()
        #expect(rig.attemptedUploadPosts == 3)
        // The held mismatch list is acted on while that hand-off still owns the picture.
        await listed.open()
        await drain.value
        #expect(rig.attemptedUploadPosts == 3)
        await written.open()
        await continuation.value
        await rig.engine.untilQuiescent()

        #expect(rig.attemptedUploadPosts == 3)
        #expect(rig.attempts(of: rig.picture.id).count == 2)
        #expect(rig.attempts(of: rig.video.id) == [0])
        let saved = try await rig.reload()
        #expect(saved.file(rig.video.id)?.isComplete == true)
        #expect(saved.file(rig.picture.id)?.uploadUID == "u3")
    }

    @Test("a deferred successor whose write is refused leaves its row to a drain that sends it")
    func deferredSuccessorLosesItsWrite() async throws {
        let written = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            onCancel: .staysListed,
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: written)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")]
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        await rig.preferences.set(true)
        await rig.engine.drain()
        #expect(rig.session.createdTasks.count == 2)
        // The video's old task ends, and its successor goes out.
        rig.session.forget(video.taskIdentifier)
        rig.delegate.complete(
            taskIdentifier: video.taskIdentifier, taskDescription: video.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.session.createdTasks.count == 3 })
        await rig.engine.untilQuiescent()
        // The picture's old task ends; its successor opens a session and is held at its write.
        await gated.value?.arm(1)
        rig.session.forget(picture.taskIdentifier)
        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        await written.waitUntilParked()
        // The video's successor succeeds meanwhile: the row moves under that write, and the
        // video's continuation leaves the picture to the replacement that owns it.
        let videoSuccessor = try rig.task(for: rig.video.id, attempt: 1)
        await rig.engine.handle(try rig.answer(videoSuccessor, status: 200, received: 3000))
        #expect(rig.attempts(of: rig.picture.id) == [0])
        await written.open()

        // The refused write sends nothing; the drain its settlement asks for sends the picture.
        let resent = try await rig.eventually { rig.attempts(of: rig.picture.id).count == 2 }
        #expect(resent)
        await rig.engine.untilQuiescent()
        #expect(rig.attempts(of: rig.picture.id).count == 2)
        #expect(rig.attemptedUploadPosts == 5)
        let file = try #require(try await rig.reload().file(rig.picture.id))
        let retried = try rig.task(for: rig.picture.id, attempt: file.uploadAttempt ?? 0)
        await rig.engine.handle(try rig.answer(retried, status: 200, received: 1000))
        #expect(try await rig.reload().files.allSatisfy { $0.isComplete })
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    @Test("an answer whose every plan meets a moving queue asks for a drain; the row completes")
    func restartExhaustionRequestsDrain() async throws {
        let wrapped = WholeBox<PausingUploads?>(nil)
        let rig = try await WholeRig.make(
            completion: [.retry("later")],
            wrapUploads: { inner in
                let uploads = PausingUploads(inner)
                wrapped.value = uploads
                return uploads
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        // The picture's task is gone from the list: its file is a record with no task.
        rig.session.forget(picture.taskIdentifier)
        let uploads = try #require(wrapped.value)
        let answer = try rig.answer(video, status: 200, received: 3000)
        // One more moving listing than the engine plans again for: every plan restarts.
        await uploads.churn(5, like: answer, into: rig.engine)

        await rig.engine.handle(answer)
        #expect(await uploads.churnLeft == 0)
        await rig.engine.untilQuiescent()
        #expect(rig.attempts(of: rig.picture.id).count == 2)
        #expect(rig.attemptedUploadPosts == 3)
        let file = try #require(try await rig.reload().file(rig.picture.id))
        let retried = try rig.task(for: rig.picture.id, attempt: file.uploadAttempt ?? 0)
        await rig.engine.handle(try rig.answer(retried, status: 200, received: 1000))
        #expect(try await rig.reload().files.allSatisfy { $0.isComplete })
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    @Test("a start whose failure write a sibling's answer overtook leaves its row to another drain")
    func refusedFailureWriteRequestsDrain() async throws {
        let written = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: written)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")]
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        // The picture's task is gone from the list: a drain sends it again whole, owning it.
        rig.session.forget(picture.taskIdentifier)
        rig.postStatus.value = 500
        await gated.value?.arm(1)
        let drain = Task { await rig.engine.drain() }
        // Its start was answered 500, and the write of that failure is held.
        await written.waitUntilParked()
        #expect(rig.attemptedUploadPosts == 3)
        // The video's success lands meanwhile; its continuation leaves the owned picture alone.
        await rig.engine.handle(try rig.answer(video, status: 200, received: 3000))
        #expect(rig.attemptedUploadPosts == 3)
        rig.postStatus.value = 201
        await written.open()
        await drain.value
        await rig.engine.untilQuiescent()

        // The failure's write was refused: no task, no backoff — the drain it asked for sends it.
        #expect(rig.attempts(of: rig.picture.id).count == 2)
        #expect(rig.attemptedUploadPosts == 4)
        let file = try #require(try await rig.reload().file(rig.picture.id))
        let retried = try rig.task(for: rig.picture.id, attempt: file.uploadAttempt ?? 0)
        await rig.engine.handle(try rig.answer(retried, status: 200, received: 1000))
        #expect(try await rig.reload().files.allSatisfy { $0.isComplete })
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    @Test("an ended task is forgotten once the list no longer names it, or its row is gone")
    func endedTasksArePruned() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        await rig.engine.handle(try rig.answer(picture, status: 200, received: 1000))
        // Still listed: kept, so it cannot count as carrying its file.
        #expect(await rig.engine.ended[picture.taskIdentifier] == rig.job.id)

        rig.session.forget(picture.taskIdentifier)
        await rig.engine.drain()
        #expect(await rig.engine.ended[picture.taskIdentifier] == nil)

        // The last answer completes the row and the memo is created: the row is gone.
        await rig.engine.handle(try rig.answer(video, status: 200, received: 3000))
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.engine.ended[video.taskIdentifier] == rig.job.id)
        await rig.engine.drain()
        #expect(await rig.engine.ended.isEmpty)
    }
}

@Suite("Whole lane: the per-file rebase")
struct WholeFileAnswerTests {
    @Test("a legacy manifest rebased by one answer changes that file's count and nothing else")
    func legacyManifestFieldByField() async throws {
        let root = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try OutboxRepository(root: root.appending(path: "outbox"))
        let id = UUID()
        let fileA = UUID()
        func file(_ id: UUID, _ name: String, _ uid: String) -> [String: Any] {
            [
                "id": id.uuidString, "relativePath": name, "filename": name, "mime": "image/heic",
                "byteSize": 1000, "uploadUID": uid, "bytesConfirmed": 0, "chunkSize": 5_242_880,
            ]
        }
        // Written as an older build wrote it: none of the late optional keys at all.
        let legacy: [String: Any] = [
            "id": id.uuidString, "idempotencyKey": UUID().uuidString, "content": "legacy",
            "visibility": "PRIVATE", "capturedAt": "2025-06-15T15:06:40Z",
            "files": [file(fileA, "a.heic", "u-a"), file(UUID(), "b.heic", "u-b")],
            "binding": ["serverBaseURL": Fixture.server.absoluteString, "ownerSubject": "fabian"],
            "state": "uploading", "attemptCount": 0, "nextAttemptAt": "2025-06-15T15:00:00Z",
            "transport": "whole",
        ]
        let url = root.appending(path: "outbox/jobs/\(id.uuidString).json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)

        let written = try await repository.applyFileAnswer(
            jobID: id, fileID: fileA, attempt: 0, outcome: .confirmed(1000),
            presented: .unknown, at: Date(timeIntervalSince1970: 1_750_000_000)
        )
        #expect(written?.file(fileA)?.isComplete == true)

        let raw = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        // `advancing` clears the backoff, so the one job-level field that moves is its date.
        #expect(Set(raw.keys) == Set(legacy.keys))
        for key in legacy.keys where key != "files" && key != "nextAttemptAt" {
            #expect((raw[key] as AnyObject).isEqual(legacy[key]), "\(key)")
        }
        let before = try #require(legacy["files"] as? [[String: Any]])
        let after = try #require(raw["files"] as? [[String: Any]])
        #expect(after.count == 2)
        for (index, original) in before.enumerated() {
            #expect(Set(after[index].keys) == Set(original.keys))
            for (key, value) in original where !(index == 0 && key == "bytesConfirmed") {
                #expect((after[index][key] as AnyObject).isEqual(value), "\(index).\(key)")
            }
        }
        #expect(after[0]["bytesConfirmed"] as? Int == 1000)
    }
}
