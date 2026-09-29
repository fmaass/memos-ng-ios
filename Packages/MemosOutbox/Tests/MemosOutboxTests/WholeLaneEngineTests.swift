import CryptoKit
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

/// The engine behind a door: every answer waits on `gate` before the engine sees it.
private actor DelayedEntry: WholeAnswerHandling {
    private let engine: OutboxEngine
    private let gate: TestGate

    init(_ engine: OutboxEngine, gate: TestGate) {
        self.engine = engine
        self.gate = gate
    }

    func handle(_ answer: WholeAnswer) async {
        await gate.pass()
        await engine.handle(answer)
    }

    func unreadableTaskEnded() async { await engine.unreadableTaskEnded() }
    func adoptionReplayed() async { await engine.adoptionReplayed() }
}

/// The real repository behind a gate that, once armed, stops the next write an ANSWER makes —
/// whether that write is the per-file rebase or a fenced save — so a race test holds one answer
/// open however the engine chooses to write it.
private actor AnswerWriteGate: OutboxPersisting {
    private let inner: OutboxRepository
    private let gate: TestGate
    private var armed = 0
    private var skipping = 0
    private var beforeHold: (@Sendable (OutboxRepository) async -> Void)?

    init(_ inner: OutboxRepository, gate: TestGate) {
        self.inner = inner
        self.gate = gate
    }

    /// Runs `body` once, against the real repository, just before the next write that holds a row,
    /// so that write meets a row something else has moved.
    func interfereBeforeHold(_ body: @escaping @Sendable (OutboxRepository) async -> Void) {
        beforeHold = body
    }

    private func interfereIfHolding(_ job: UploadJob) async {
        guard job.state == .held, let body = beforeHold else { return }
        beforeHold = nil
        await body(inner)
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
        await interfereIfHolding(job)
        await passIfArmed()
        try await inner.save(job)
    }

    func save(
        _ job: UploadJob,
        ifStillCurrent epoch: Int?,
        matching snapshot: UploadJob,
        else fallback: UploadJob
    ) async throws -> UploadJob? {
        await interfereIfHolding(job)
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

    nonisolated var tails: WholeTailStaging { inner.tails }

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

    func holdsUnappliedAnswers() async -> Bool { await inner.holdsUnappliedAnswers() }
    func unappliedAnswers() async -> [WholeFileRef: Int] { await inner.unappliedAnswers() }

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

/// The production scheduler, with every task it creates first handed to `ending` — which may
/// deliver that task's whole terminal answer to the engine — before its creator hears of it: after
/// `upload` has the task and before it returns, and for a replacement's successor before
/// `onSettled`. A task is resumed as it is created, so a fast failure or a small file can end in
/// exactly that order; here the order is fixed, not raced.
private actor EarlyEndingUploads: OutboxUploadScheduling {
    nonisolated let launch: UUID
    private let inner: BackgroundUploadScheduler
    private let ending: @Sendable (WholeTask) async -> Void

    init(
        _ inner: BackgroundUploadScheduler,
        ending: @escaping @Sendable (WholeTask) async -> Void
    ) {
        self.inner = inner
        self.launch = inner.launch
        self.ending = ending
    }

    func attach(_ handler: any WholeAnswerHandling) async { await inner.attach(handler) }
    func tasks() async -> [WholeTaskListing] { await inner.tasks() }
    func holdsUnappliedAnswers() async -> Bool { await inner.holdsUnappliedAnswers() }
    func unappliedAnswers() async -> [WholeFileRef: Int] { await inner.unappliedAnswers() }

    func upload(
        _ request: URLRequest,
        fromFile file: URL,
        for ref: WholeFileRef,
        attempt: Int,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) async -> WholeTask? {
        let task = await inner.upload(
            request, fromFile: file, for: ref, attempt: attempt, under: authority,
            issuedUnder: epoch
        )
        if let task { await ending(task) }
        return task
    }

    func cancel(_ taskIdentifiers: [Int]) async { await inner.cancel(taskIdentifiers) }
    func cancelUnreadable() async -> [Int] { await inner.cancelUnreadable() }

    func mismatched(allowsMobileData: Bool) async -> [WholeTask] {
        await inner.mismatched(allowsMobileData: allowsMobileData)
    }

    func replace(
        _ task: WholeTask,
        under authority: SendAuthority,
        onSettled: @escaping @concurrent @Sendable (WholeTask?) async -> Void,
        successor: @escaping @concurrent @Sendable () async -> WholeSuccessor?
    ) async -> WholeReplacement {
        let ending = self.ending
        return await inner.replace(
            task, under: authority,
            onSettled: { sent in
                if let sent { await ending(sent) }
                await onSettled(sent)
            },
            successor: successor
        )
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
        chunksInFlight: [OutboxTaskIdentity] = [],
        launch: UUID = UUID(),
        attached: Bool = true,
        headStatus: Int = 404,
        answerHead: (@Sendable (URLRequest) -> OutboxHTTPResponse?)? = nil,
        sleeper: any OutboxSleeping = ControlledSleeper(),
        rng: @escaping @Sendable () -> Double = { 1 },
        answerPost: (@Sendable (URLRequest) -> OutboxHTTPResponse?)? = nil,
        wrapHTTP: (@Sendable (ScriptedHTTP) -> any OutboxHTTPPerforming)? = nil
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
                if let scripted = answerPost?(request) { return scripted }
                guard postStatus.value == 201 else {
                    return OutboxHTTPResponse(statusCode: postStatus.value)
                }
                posts.increment()
                return ScriptedHTTP.session(
                    uid: "u\(posts.count)", chunkSize: 5 * 1024 * 1024, received: 0
                )
            case ("HEAD", _):
                if let scripted = answerHead?(request) { return scripted }
                return OutboxHTTPResponse(statusCode: headStatus)
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
            http: wrapHTTP?(http) ?? http,
            scheduler: chunks,
            completion: completion,
            network: network,
            preferences: preferences.store,
            clock: { clock.now },
            schedulingGate: gate,
            uploads: withUploads ? (wrapUploads?(uploads) ?? uploads) : nil,
            sleeper: sleeper,
            rng: rng
        )
        if attached { await uploads.attach(engine) }
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
        // The answer's place, given back, asked for a drain of its own that may still be running.
        await rig.engine.untilQuiescent()

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
        let orphan = WholeBox<String?>(nil)
        let rig = try await WholeRig.make(
            withUploads: true,
            listing: { job in
                let description = WholeTaskIdentity(
                    jobID: job.id, fileID: job.files[0].id, attempt: 5, launch: UUID(), epoch: 0
                ).taskDescription
                stale.value = description
                let other = WholeTaskIdentity(
                    jobID: UUID(), fileID: UUID(), attempt: 0, launch: UUID(), epoch: 0
                )
                orphan.value = other.taskDescription
                return [
                    WholeTaskListing(taskIdentifier: 7, taskDescription: orphan.value),
                    WholeTaskListing(taskIdentifier: 8, taskDescription: description),
                ]
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(Set(rig.session.cancelledIdentifiers) == [7, 8])
        // A cancelled task keeps its place until it has ended, so the two stale tasks hold both
        // places and nothing goes out yet; the stale one also carries its file.
        #expect(rig.session.createdTasks.isEmpty)

        rig.delegate.complete(
            taskIdentifier: 8, taskDescription: stale.value, statusCode: nil,
            errorDescription: "cancelled"
        )
        // One place came free, and it goes to the first file in capture order.
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id).count == 1 })
        await rig.engine.untilQuiescent()
        #expect(rig.attempts(of: rig.video.id).isEmpty)

        // A task whose row is gone leaves the list with its end: nothing keeps its record.
        rig.session.forget(7)
        rig.delegate.complete(
            taskIdentifier: 7, taskDescription: orphan.value, statusCode: nil,
            errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id) == [0] })
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

    @Test("matrix: a record with no task is resumed only while scheduling is open")
    func recordOnlyWaitsForTheGate() async throws {
        let rig = try await WholeRig.make(
            prepare: { job in
                var started = job
                started.transport = .whole
                started.state = .uploading
                started.files[0].uploadUID = "old-a"
                started.files[1].uploadUID = "old-b"
                return started
            },
            answerHead: { _ in
                OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": "0"])
            }
        )
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
        // Each session is kept and asked where it stands; nothing arrived, so each original goes.
        #expect(saved.files.map(\.uploadAttempt) == [1, 1])
        #expect(saved.files.map(\.uploadUID) == ["old-a", "old-b"])
        #expect(rig.http.requests(method: "HEAD").count == 2)
        #expect(rig.attemptedUploadPosts == 0)
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
        await rig.engine.untilQuiescent()
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

    @Test("a task nobody can read ending is itself what sends the files it held back")
    func unreadableEndReleasesTheBarrier() async throws {
        let rig = try await WholeRig.make(
            listing: { _ in
                [WholeTaskListing(taskIdentifier: 7, taskDescription: "not|a|whole|task")]
            },
            onCancel: .staysListed
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(rig.session.createdTasks.isEmpty, "the premise: the barrier held")

        // It ends and leaves the list. Nobody drains: no network change, no foreground, no tap.
        rig.session.forget(7)
        rig.delegate.complete(
            taskIdentifier: 7, taskDescription: "not|a|whole|task", statusCode: nil,
            errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.session.createdTasks.count == 2 })
        await rig.engine.untilQuiescent()
    }

    @Test("mobile data turned off, then the app backgrounded before the drain: the task stops")
    func toggleOffCancelsUnderAClosedGate() async throws {
        let rig = try await WholeRig.make(onCancel: .leavesListing(after: 1))
        defer { rig.cleanUp() }
        await rig.preferences.set(true)
        await rig.engine.drain()
        let old = rig.session.createdTasks.map(\.taskIdentifier)
        #expect(old.count == 2)

        await rig.preferences.set(false)
        rig.gate.close()
        await rig.engine.drain()

        // Cancelling is not new work; the successor is, and it waits for the foreground.
        #expect(Set(rig.session.cancelledIdentifiers) == Set(old))
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("the chunk session's sign-out cancel reaches a task nobody can read")
    func chunkCancelEveryTaskReachesUnreadable() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // A task never resumed is not listed; one resumed and suspended is, and cannot finish.
        // Resumed, it may fail before the suspend lands — the host does not resolve — so the
        // premise is set up again until a task is caught live.
        var live: URLSessionUploadTask?
        for _ in 0..<50 {
            let candidate = session.uploadTask(
                with: URLRequest(url: URL(string: "https://memos.example.invalid/api/uploads/x")!),
                from: Data()
            )
            candidate.taskDescription = "not|a|chunk"
            candidate.resume()
            candidate.suspend()
            for _ in 0..<20 where candidate.state == .running {
                try await Task.sleep(for: .milliseconds(5))
            }
            if candidate.state == .suspended {
                live = candidate
                break
            }
        }
        let task = try #require(live, "the premise: a task is still live")
        let listed = await session.allTasks.map(\.taskIdentifier)
        try #require(listed.contains(task.taskIdentifier), "the premise: the session lists it")
        let scheduler = BackgroundChunkScheduler(session: session)
        #expect(await scheduler.inFlight().isEmpty, "the premise: the lane cannot read it")

        await scheduler.cancelEveryTask()

        #expect(task.state == .canceling || task.state == .completed)
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
        let launch = UUID()
        let rig = try await WholeRig.make(
            listing: { job in
                let file = job.files[0].id
                let described = { (id: Int, launch: UUID, epoch: Int) in
                    WholeTaskListing(
                        taskIdentifier: id,
                        taskDescription: WholeTaskIdentity(
                            jobID: job.id, fileID: file, attempt: 0, launch: launch, epoch: epoch
                        ).taskDescription
                    )
                }
                return [
                    // Another launch's: nothing says it was not sent for the account whose grant
                    // just ended.
                    described(7, UUID(), 9),
                    WholeTaskListing(taskIdentifier: 8, taskDescription: "not|a|whole|task"),
                    // This launch's, under a grant newer than the withdrawal: the next account's
                    // work, which a late sweep must not interrupt.
                    described(9, launch, 5),
                    described(10, launch, 2),
                ]
            },
            chunksInFlight: [chunk],
            launch: launch
        )
        defer { rig.cleanUp() }
        // The session's credential is withdrawn first; the outbox is told after.
        rig.credentials.set(nil)
        await rig.engine.abandonAllTasks(withdrawnAt: 3)

        #expect(rig.chunks.everyTaskCancellations == 1)
        #expect(rig.chunks.cancellations == [chunk])
        #expect(Set(rig.session.cancelledIdentifiers) == [7, 8, 10])

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
        await rig.engine.untilQuiescent()
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
        // continuation asks where the picture stands: the HEAD finds no session, the fresh term is
        // written, and the picture goes again whole — posted, then held at its hand-off's write.
        rig.session.forget(picture.taskIdentifier)
        await gated.value?.arm(1, skipping: 2)
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

    /// The failure of a session request is written onto the row as it stands at the write, so a
    /// sibling's success landing first no longer throws it away: the file keeps its own deadline,
    /// nothing is sent for it before that, and the deadline timer sends it — no test-side drain.
    @Test(
        "a start whose failure a sibling's answer overtook keeps its own deadline, and the timer sends it",
        arguments: [(500, nil as String?, 900.0), (429, "2" as String?, 2.0)]
    )
    func refusedFailureWriteRequestsDrain(status: Int, retryAfter: String?, delay: Double)
        async throws
    {
        let written = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let sleeper = ControlledSleeper()
        let failing = WholeBox(false)
        let rig = try await WholeRig.make(
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: written)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")],
            sleeper: sleeper,
            answerPost: { _ in
                guard failing.value else { return nil }
                return OutboxHTTPResponse(
                    statusCode: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:]
                )
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        // The picture's task is gone from the list: a drain asks the server, finds no session,
        // writes the fresh term and sends it again whole, owning it; the failure's write is held.
        rig.session.forget(picture.taskIdentifier)
        failing.value = true
        await gated.value?.arm(1, skipping: 1)
        let drain = Task { await rig.engine.drain() }
        await written.waitUntilParked()
        #expect(rig.attemptedUploadPosts == 3)
        // The video's success lands meanwhile, and moves the row the failure was decided on.
        rig.session.forget(video.taskIdentifier)
        await rig.engine.handle(try rig.answer(video, status: 200, received: 3000))
        #expect(rig.attemptedUploadPosts == 3)
        failing.value = false
        await written.open()
        await drain.value
        await rig.engine.untilQuiescent()

        // The failure landed on the row as the video left it: its deadline stands, and the video's
        // confirmation with it. Nothing else went out for the picture.
        let row = try await rig.reload()
        let deadline = rig.clock.now.addingTimeInterval(delay)
        #expect(row.file(rig.picture.id)?.nextAttemptAt == deadline)
        #expect(row.file(rig.video.id)?.isComplete == true)
        #expect(rig.attemptedUploadPosts == 3)
        #expect(rig.attempts(of: rig.picture.id).count == 1)
        #expect(sleeper.armed == [deadline])

        rig.clock.advance(delay)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id).count == 2 })
        await rig.engine.untilQuiescent()
        #expect(rig.attemptedUploadPosts == 4)
        let file = try #require(try await rig.reload().file(rig.picture.id))
        let retried = try rig.task(for: rig.picture.id, attempt: file.uploadAttempt ?? 0)
        await rig.engine.handle(try rig.answer(retried, status: 200, received: 1000))
        #expect(try await rig.reload().files.allSatisfy { $0.isComplete })
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    /// A launch's adoption replays what the session buffered, one answer at a time, and the
    /// first answer's own write advances its row. A file whose task has finished and whose answer
    /// is still buffered is carried by nothing the row can see; re-planned then, it goes again.
    @Test("adoption applies every buffered answer of a row before the row is planned again")
    func adoptionReplaysBeforeReplanning() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        // Both finished while nothing was attached: the session lists neither any more, and
        // their answers wait for adoption.
        rig.session.forget(picture.taskIdentifier)
        rig.session.forget(video.taskIdentifier)
        rig.delegate.deliver(try rig.answer(picture, status: 200, received: 1000))
        rig.delegate.deliver(try rig.answer(video, status: 200, received: 3000))

        await rig.delegate.attach(rig.engine)
        await rig.engine.untilQuiescent()

        #expect(rig.attempts(of: rig.video.id) == [0])
        #expect(rig.attempts(of: rig.picture.id) == [0])
        #expect(rig.uploadPosts == 2)
        #expect(rig.completion.idempotencyKeys.count == 1)
    }

    /// The other half: what the replay passed over is planned once it has landed, with nothing
    /// else asked to happen — no network change, no foreground, no tap.
    @Test("a retry an answer asked for during adoption goes once the replay has landed")
    func adoptionEndPlansWhatItHeld() async throws {
        // A draw of zero makes the file's schedule due at once, so the retry is the replay's.
        let rig = try await WholeRig.make(attached: false, rng: { 0 })
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        rig.session.forget(picture.taskIdentifier)
        rig.session.forget(video.taskIdentifier)
        rig.delegate.deliver(try rig.answer(picture, status: 200, received: 1000))
        // The server lost the video's session: it is sent again whole, once.
        rig.delegate.deliver(try rig.answer(video, status: 409))

        await rig.delegate.attach(rig.engine)
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id) == [0, 1] })
        await rig.engine.untilQuiescent()

        #expect(rig.attempts(of: rig.video.id) == [0, 1])
        #expect(rig.attempts(of: rig.picture.id) == [0])
        #expect(rig.uploadPosts == 3)
    }

    /// A live answer is in flight between the session's callback and the engine: its task
    /// already shows as finished, and nothing in the engine owns its file yet.
    @Test("a finished task whose live answer has not been applied still carries its file")
    func liveAnswerCarriesItsFile() async throws {
        let rig = try await WholeRig.make(attached: false)
        defer { rig.cleanUp() }
        let entry = TestGate()
        await rig.delegate.attach(DelayedEntry(rig.engine, gate: entry))
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        rig.session.markCompleted(picture.taskIdentifier)
        rig.delegate.deliver(try rig.answer(picture, status: 200, received: 1000))
        await entry.waitUntilParked()

        // Another pass, while the success waits at the engine's door.
        await rig.engine.drain()

        #expect(rig.attempts(of: rig.picture.id) == [0])
        #expect(rig.uploadPosts == 2)
        #expect(rig.session.createdTasks.count == 2)
        await entry.open()
        let applied = try await rig.eventually {
            try await rig.reload().file(rig.picture.id)?.isComplete == true
        }
        #expect(applied, "the original success lands")
        await rig.engine.untilQuiescent()
        #expect(rig.attempts(of: rig.picture.id) == [0])
    }

    /// The account-mismatch hold is a write, and a sibling's answer can move the row under it. The
    /// row's account is asked again where every whole-file send begins, so a replacement cannot
    /// carry one account's file to another.
    @Test("a replacement never opens a session for another account's row, hold or no hold")
    func replacementKeepsTheRowsAccount() async throws {
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            onCancel: .leavesListing(after: 1),
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: TestGate())
                gated.value = persistence
                return persistence
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(rig.session.createdTasks.count == 2, "the premise: A's two files are out")
        let posted = rig.uploadPosts

        // B signs in with a capture of its own queued, and A's tasks still outstanding.
        let brenda = Fixture.credentials(owner: "brenda", token: "pat-b")
        rig.credentials.set(brenda)
        _ = try await rig.repository.enqueue(
            content: "brenda's", visibility: "PRIVATE",
            capturedAt: Date(timeIntervalSince1970: 1_750_000_000),
            binding: Fixture.binding(owner: "brenda"),
            sources: [
                StagedSource(
                    url: try Fixture.file(in: rig.root, named: "b.heic", bytes: 500),
                    filename: "b.heic", mime: "image/heic"
                )
            ]
        )
        let pictureID = rig.picture.id
        let jobID = rig.job.id
        // A's picture lands between the hold's read and its write, so the hold loses.
        await gated.value?.interfereBeforeHold { repository in
            guard let row = await repository.job(jobID) else { return }
            try? await repository.save(
                row.updating(pictureID) { $0.bytesConfirmed = $0.byteSize }
            )
        }
        await rig.preferences.set(true)

        await rig.engine.drain()
        await rig.engine.untilQuiescent()

        let aPosts = rig.http.requests(method: "POST").dropFirst(posted).filter { request in
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return body.contains("picture.heic") || body.contains("video.mov")
        }
        #expect(aPosts.isEmpty, "A's file metadata went to a session under B's credential")
        let aTasks = rig.session.createdTasks.filter {
            WholeTaskIdentity(taskDescription: $0.description)?.jobID == jobID
        }
        #expect(aTasks.count == 2, "A's bytes went out under B's credential")
        let row = try await rig.reload()
        #expect(row.state == .held, "the drain that follows holds A's row")
    }

    /// A success that says nothing readable asks the server where the upload stands. Asked under
    /// another account, that server knows nothing of the upload, and its 404 would forget a file
    /// the row's own server may already hold.
    @Test("an unreadable success after an account switch asks no server and keeps its upload")
    func unreadableSuccessKeepsTheRowsAccount() async throws {
        let rig = try await WholeRig.make(headStatus: 404)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let uploadUID = try #require(try await rig.reload().file(rig.picture.id)?.uploadUID)
        rig.credentials.set(Fixture.credentials(owner: "brenda", token: "pat-b"))

        await rig.engine.handle(try rig.answer(picture, status: 200))
        await rig.engine.untilQuiescent()

        #expect(
            rig.http.requests(method: "HEAD").isEmpty,
            "A's upload was asked about under B's credential"
        )
        let row = try await rig.reload()
        #expect(row.file(rig.picture.id)?.uploadUID == uploadUID, "A's upload was forgotten")
        #expect(
            (row.file(rig.picture.id)?.uploadAttempt ?? 0) == 0,
            "A's file was put up to be sent again whole"
        )
        #expect(row.state == .held, "the drain that follows holds A's row")
        #expect(row.holdReason == .accountMismatch)
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
        await rig.engine.untilQuiescent()
        #expect(await rig.engine.ended[picture.taskIdentifier] == nil)

        // The last answer completes the row and the memo is created: the row is gone.
        await rig.engine.handle(try rig.answer(video, status: 200, received: 3000))
        #expect(rig.completion.idempotencyKeys.count == 1)
        #expect(await rig.engine.ended[video.taskIdentifier] == rig.job.id)
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
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

/// Holds the first request whose body names `marker` until the gate opens — a session request
/// suspended mid-flight.
private final class ParkingHTTP: OutboxHTTPPerforming, @unchecked Sendable {
    private let inner: ScriptedHTTP
    private let gate: TestGate
    private let marker: String
    private let lock = NSLock()
    private var parked = false

    init(_ inner: ScriptedHTTP, gate: TestGate, marker: String) {
        self.inner = inner
        self.gate = gate
        self.marker = marker
    }

    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let first = lock.withLock { () -> Bool in
            guard !parked, body.contains(marker) else { return false }
            parked = true
            return true
        }
        if first { await gate.pass() }
        return try await inner.perform(request, under: authority)
    }
}

extension WholeRig {
    /// A second capture, of one or more files, queued behind the rig's own.
    func enqueueSecond(named names: [String] = ["second.heic"]) async throws -> UploadJob {
        let sources = try names.map { name in
            StagedSource(
                url: try Fixture.file(in: root, named: name, bytes: 500),
                filename: name, mime: "image/heic"
            )
        }
        return try await repository.enqueue(
            content: "a second capture", visibility: "PRIVATE",
            capturedAt: clock.now.addingTimeInterval(1), binding: Fixture.binding(),
            sources: sources
        )
    }

    func postsNaming(_ filename: String) -> Int {
        http.requests(method: "POST").filter { request in
            request.url?.path() == "/api/uploads"
                && (request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                    .contains(filename)
        }.count
    }

    var healthProbes: Int { http.requests(method: "GET").count }

    /// Two tasks in flight, then the video answered 429 with `Retry-After`, the picture's success
    /// landing before that deadline. Answers are delivered as the session would leave things: the
    /// task gone from the list.
    func storm(retryAfter: String = "2", offset: TimeInterval = 0) async throws {
        await engine.drain()
        let picture = try task(for: self.picture.id)
        let video = try task(for: self.video.id)
        clock.advance(offset)
        session.forget(video.taskIdentifier)
        var busy = try answer(video, status: 429)
        busy.retryAfter = retryAfter
        await engine.handle(busy)
        session.forget(picture.taskIdentifier)
        await engine.handle(try answer(picture, status: 200, received: 1000))
        await engine.untilQuiescent()
    }
}

@Suite("Whole lane: the upload budget, per-file deadlines and the deadline timer")
struct WholeBudgetEngineTests {
    @Test("a 429 with Retry-After on one file, then a sibling's success before it: nothing more")
    func stormSendsNothing() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        let start = rig.clock.now
        try await rig.storm()

        let row = try await rig.reload()
        #expect(row.file(rig.video.id)?.nextAttemptAt == start.addingTimeInterval(2))
        #expect(row.file(rig.picture.id)?.isComplete == true)
        #expect(row.state != .held)
        #expect(rig.uploadPosts == 2)
        #expect(rig.session.createdTasks.count == 2)
        #expect(sleeper.armed == [start.addingTimeInterval(2)])
    }

    @Test("past the deadline the timer sends the retry, with no drain from the test")
    func timerSendsRetry() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        try await rig.storm()
        rig.clock.advance(2)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id) == [0, 1] })
        #expect(rig.uploadPosts == 3)
        #expect(sleeper.mostArmedAtOnce == 1)
    }

    @Test("closing the gate first leaves no armed timer, and nothing is sent at the deadline")
    func closedGateSendsNothing() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        try await rig.storm()
        rig.gate.close()
        #expect(try await rig.eventually { sleeper.armed.isEmpty })
        rig.clock.advance(5)
        sleeper.advance(to: rig.clock.now)
        await rig.engine.untilQuiescent()
        #expect(rig.uploadPosts == 2)
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("a reopen before the deadline re-arms once: exactly one retry, from exactly one drain")
    func reopenRearmsOnce() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        try await rig.storm()
        let deadline = try #require(sleeper.armed.first)
        rig.gate.close()
        #expect(try await rig.eventually { sleeper.armed.isEmpty })
        rig.gate.open()
        #expect(try await rig.eventually { sleeper.armed == [deadline] })
        let probes = rig.healthProbes
        rig.clock.advance(3)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id).count == 2 })
        await rig.engine.untilQuiescent()
        #expect(rig.uploadPosts == 3)
        #expect(rig.healthProbes == probes + 1)
        #expect(sleeper.mostArmedAtOnce == 1)
    }

    @Test("a timer another arm replaced causes no drain when its callback arrives after all")
    func supersededTimerIsSilent() async throws {
        let sleeper = ControlledSleeper(honoursCancellation: false)
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        try await rig.storm()
        rig.gate.close()
        #expect(try await rig.eventually { sleeper.cancellations == 1 })
        rig.gate.open()
        #expect(try await rig.eventually { sleeper.history.count == 2 })
        let probes = rig.healthProbes
        rig.clock.advance(3)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id).count == 2 })
        await rig.engine.untilQuiescent()
        #expect(rig.healthProbes == probes + 1)
        #expect(rig.uploadPosts == 3)
    }

    @Test("a fractional instant's deadline is persisted rounded up, and the timer waits for it")
    func fractionalDeadlineRoundsUp() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        let start = rig.clock.now
        try await rig.storm(offset: 0.75)
        let reloaded = try #require(try await rig.reload().file(rig.video.id)?.nextAttemptAt)
        #expect(reloaded == start.addingTimeInterval(3))
        #expect(sleeper.armed == [start.addingTimeInterval(3)])
        rig.clock.advance(2.1)
        sleeper.advance(to: rig.clock.now)
        await rig.engine.untilQuiescent()
        #expect(rig.uploadPosts == 2)
        rig.clock.advance(0.25)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.uploadPosts == 3 })
    }

    @Test("a fresh engine that adopts two tasks refuses another capture a place until one ends")
    func adoptedTasksHoldTheBudget() async throws {
        let rig = try await WholeRig.make(
            listing: { job in
                job.files.enumerated().map { index, file in
                    WholeTaskListing(
                        taskIdentifier: 70 + index,
                        taskDescription: WholeTaskIdentity(
                            jobID: job.id, fileID: file.id, attempt: 0, launch: UUID(), epoch: 0
                        ).taskDescription,
                        access: WholeTaskNetworkAccess(
                            request: OutboxRequests.wholeUpload(
                                baseURL: Fixture.server, token: "t", uploadUID: "u\(index)",
                                allowsMobileData: false
                            )
                        ),
                        state: .running
                    )
                }
            },
            prepare: { job in
                var sent = job
                sent.transport = .whole
                sent.state = .uploading
                for index in sent.files.indices { sent.files[index].uploadUID = "u\(index)" }
                return sent
            }
        )
        defer { rig.cleanUp() }
        let second = try await rig.enqueueSecond()
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(rig.uploadPosts == 0)
        #expect(rig.session.createdTasks.isEmpty)

        rig.session.forget(70)
        let identity = WholeTaskIdentity(
            jobID: rig.job.id, fileID: rig.picture.id, attempt: 0, launch: UUID(), epoch: 0
        )
        await rig.engine.handle(
            WholeAnswer(
                taskIdentifier: 70, identity: identity, statusCode: 200,
                body: ScriptedHTTP.session(uid: "x", chunkSize: 1, received: 1000).body
            )
        )
        #expect(
            try await rig.eventually {
                rig.session.createdTasks.contains {
                    WholeTaskIdentity(taskDescription: $0.description)?.jobID == second.id
                }
            }
        )
        #expect(rig.postsNaming("second.heic") == 1)
    }

    @Test("A holds both places, B opens no session, and A's completion starts B with no drain")
    func releaseStartsTheWaitingCapture() async throws {
        let rig = try await WholeRig.make()
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let second = try await rig.enqueueSecond()
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.postsNaming("second.heic") == 0)

        let picture = try rig.task(for: rig.picture.id)
        rig.session.forget(picture.taskIdentifier)
        await rig.engine.handle(try rig.answer(picture, status: 200, received: 1000))
        #expect(
            try await rig.eventually {
                rig.session.createdTasks.contains {
                    WholeTaskIdentity(taskDescription: $0.description)?.jobID == second.id
                }
            }
        )
        #expect(rig.postsNaming("second.heic") == 1)
        #expect(rig.session.createdTasks.count == 3)
    }

    @Test("a hand-off suspended in its session request already holds its places")
    func suspendedHandOffHoldsPlaces() async throws {
        let parked = TestGate()
        let rig = try await WholeRig.make(
            wrapHTTP: { ParkingHTTP($0, gate: parked, marker: "picture.heic") }
        )
        defer { rig.cleanUp() }
        let drain = Task { await rig.engine.drain() }
        await parked.waitUntilParked()
        var second = try await rig.enqueueSecond(named: ["b1.heic", "b2.heic"])
        second.transport = .whole
        second.state = .uploading
        second.files[0].uploadUID = "ub1"
        try await rig.repository.save(second)
        // An answer for the second capture's first file: its continuation plans that capture
        // while the first capture's hand-off is still waiting for its first session.
        await rig.engine.handle(
            WholeAnswer(
                taskIdentifier: 9_999,
                identity: WholeTaskIdentity(
                    jobID: second.id, fileID: second.files[0].id, attempt: 0,
                    launch: rig.launch, epoch: 0
                ),
                statusCode: 500
            )
        )
        #expect(rig.postsNaming("b2.heic") == 0)
        await parked.open()
        await drain.value
        await rig.engine.untilQuiescent()
        #expect(rig.postsNaming("b2.heic") == 0)
        #expect(rig.session.createdTasks.count == 2)
    }

    @Test("a replaced task's place passes to its successor; a failed successor frees it for B")
    func replacementKeepsItsPlace() async throws {
        let videoFails = WholeBox(false)
        let rig = try await WholeRig.make(
            onCancel: .staysListed,
            answerPost: { request in
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard videoFails.value, body.contains("video.mov") else { return nil }
                return OutboxHTTPResponse(statusCode: 500)
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        _ = try await rig.enqueueSecond()
        await rig.preferences.set(true)
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        // Both old tasks are cancelled and still listed: their successors wait, holding the places.
        let cancelled = Set(rig.session.cancelledIdentifiers)
        #expect(cancelled == [picture.taskIdentifier, video.taskIdentifier])
        #expect(rig.session.createdTasks.count == 2)
        #expect(rig.postsNaming("second.heic") == 0)

        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id) == [0, 1] })
        await rig.engine.untilQuiescent()
        // The picture's successor took the picture's place: the second capture is still refused.
        #expect(rig.postsNaming("second.heic") == 0)
        #expect(rig.session.createdTasks.count == 3)

        videoFails.value = true
        rig.delegate.complete(
            taskIdentifier: video.taskIdentifier, taskDescription: video.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        // The video's successor could not open a session, so its place goes to the second capture.
        #expect(try await rig.eventually { rig.postsNaming("second.heic") == 1 })
        await rig.engine.untilQuiescent()
        #expect(rig.attempts(of: rig.video.id) == [0])
        #expect(rig.session.createdTasks.count == 4)
    }

    @Test("a session request answered 429 spaces its file; a sibling's success clears nothing")
    func sessionBackpressureIsPerFile() async throws {
        let sleeper = ControlledSleeper()
        let busy = WholeBox(true)
        let rig = try await WholeRig.make(
            sleeper: sleeper,
            answerPost: { request in
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard busy.value, body.contains("video.mov") else { return nil }
                return OutboxHTTPResponse(statusCode: 429, headers: ["Retry-After": "2"])
            }
        )
        defer { rig.cleanUp() }
        let start = rig.clock.now
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        let row = try await rig.reload()
        #expect(row.file(rig.video.id)?.nextAttemptAt == start.addingTimeInterval(2))
        #expect(row.state != .held)
        let picture = try rig.task(for: rig.picture.id)
        #expect(rig.postsNaming("video.mov") == 1)

        busy.value = false
        rig.session.forget(picture.taskIdentifier)
        await rig.engine.handle(try rig.answer(picture, status: 200, received: 1000))
        await rig.engine.untilQuiescent()
        #expect(rig.postsNaming("video.mov") == 1)

        rig.clock.advance(2)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.postsNaming("video.mov") == 2 })
        #expect(try await rig.eventually { (try? rig.task(for: rig.video.id)) != nil })
    }

    @Test("a later deadline is armed while an earlier file's retry is in flight")
    func laterSiblingDeadlineWakes() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        let start = rig.clock.now
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        for (task, wait) in [(video, "2"), (picture, "5")] {
            rig.session.forget(task.taskIdentifier)
            var busy = try rig.answer(task, status: 429)
            busy.retryAfter = wait
            await rig.engine.handle(busy)
        }
        await rig.engine.untilQuiescent()
        #expect(sleeper.armed == [start.addingTimeInterval(2)])

        rig.clock.advance(2)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id) == [0, 1] })
        await rig.engine.untilQuiescent()
        // The video's retry is in flight, its deadline past; the picture's is still ahead.
        #expect(sleeper.armed == [start.addingTimeInterval(5)])

        rig.clock.advance(3)
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id) == [0, 1] })
        #expect(sleeper.mostArmedAtOnce == 1)
    }

    @Test("a seven-day deadline survives the manifest round trip, at or after the asked instant")
    func weekDeadlineRoundTrips() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let video = try rig.task(for: rig.video.id)
        rig.clock.advance(0.75)
        let asked = rig.clock.now.addingTimeInterval(604_800)
        rig.session.forget(video.taskIdentifier)
        var busy = try rig.answer(video, status: 429)
        busy.retryAfter = "604800"
        await rig.engine.handle(busy)
        await rig.engine.untilQuiescent()
        // Read back from the manifest on disk, decoded afresh.
        let due = try #require(try await rig.reload().file(rig.video.id)?.nextAttemptAt)
        #expect(due >= asked)
        #expect(due < asked.addingTimeInterval(1))
        #expect(sleeper.armed == [due])
    }

    @Test("a short success waits for its jittered deadline, then the timer sends")
    func shortSuccessWaitsThenSends() async throws {
        let sleeper = ControlledSleeper()
        let rig = try await WholeRig.make(sleeper: sleeper, rng: { 0.5 })
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let answeredAt = rig.clock.now
        rig.session.forget(picture.taskIdentifier)
        await rig.engine.handle(try rig.answer(picture, status: 200, received: 400))
        await rig.engine.untilQuiescent()

        // Attempt 1 draws half of its 900 s, rounded up to the second a manifest keeps.
        let due = Date(
            timeIntervalSince1970: (answeredAt.timeIntervalSince1970 + 450).rounded(.up)
        )
        let row = try await rig.reload()
        #expect(row.file(rig.picture.id)?.nextAttemptAt == due)
        #expect(row.file(rig.picture.id)?.attemptCount == 1)
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(rig.postsNaming("picture.heic") == 1)
        #expect(sleeper.armed == [due])

        rig.clock.advance(due.timeIntervalSince(rig.clock.now))
        sleeper.advance(to: rig.clock.now)
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id) == [0, 1] })
        #expect(rig.postsNaming("picture.heic") == 2)
    }

    @Test("a task that ended before its hand-off counted it gives its place back at once")
    func endedBeforeCountedFreesItsPlace() async throws {
        let ending = WholeBox<(@Sendable (WholeTask) async -> Void)?>(nil)
        let rig = try await WholeRig.make(
            wrapUploads: { inner in
                EarlyEndingUploads(inner) { task in await ending.value?(task) }
            }
        )
        defer { rig.cleanUp() }
        _ = try await rig.enqueueSecond()
        let session = rig.session
        let engine = rig.engine
        let pictureID = rig.picture.id
        ending.value = { task in
            guard task.identity.fileID == pictureID, task.identity.attempt == 0 else { return }
            session.forget(task.taskIdentifier)
            await engine.handle(
                WholeAnswer(
                    taskIdentifier: task.taskIdentifier, identity: task.identity, statusCode: 200,
                    body: ScriptedHTTP.session(uid: "x", chunkSize: 1, received: 1000).body
                )
            )
        }
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(try await rig.reload().file(pictureID)?.isComplete == true)
        // The picture's place went back when its hand-off learned of the task, so the second
        // capture has it; the video still holds the other.
        #expect(try await rig.eventually { rig.postsNaming("second.heic") == 1 })
    }

    @Test("the LAST reservation's task ending before it is counted still gives its place back")
    func lastEndedBeforeCountedFreesItsPlace() async throws {
        let ending = WholeBox<(@Sendable (WholeTask) async -> Void)?>(nil)
        let rig = try await WholeRig.make(
            wrapUploads: { inner in
                EarlyEndingUploads(inner) { task in await ending.value?(task) }
            }
        )
        defer { rig.cleanUp() }
        _ = try await rig.enqueueSecond()
        let session = rig.session
        let engine = rig.engine
        let videoID = rig.video.id
        // The video is the hand-off's second and last conversion: nothing is reserved after it.
        ending.value = { task in
            guard task.identity.fileID == videoID, task.identity.attempt == 0 else { return }
            session.forget(task.taskIdentifier)
            await engine.handle(
                WholeAnswer(
                    taskIdentifier: task.taskIdentifier, identity: task.identity, statusCode: 200,
                    body: ScriptedHTTP.session(uid: "x", chunkSize: 1, received: 3000).body
                )
            )
        }
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(try await rig.reload().file(videoID)?.isComplete == true)
        #expect(try await rig.eventually { rig.postsNaming("second.heic") == 1 })
    }

    @Test("the LAST successor ending before its replacement settled still gives its place back")
    func lastSuccessorEndedBeforeSettledFreesItsPlace() async throws {
        let ending = WholeBox<(@Sendable (WholeTask) async -> Void)?>(nil)
        let rig = try await WholeRig.make(
            onCancel: .staysListed,
            wrapUploads: { inner in
                EarlyEndingUploads(inner) { task in await ending.value?(task) }
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        _ = try await rig.enqueueSecond()
        await rig.preferences.set(true)
        await rig.engine.drain()
        await rig.engine.untilQuiescent()

        // The picture's successor settles as a live task: one reservation converted, one left.
        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id) == [0, 1] })
        await rig.engine.untilQuiescent()
        #expect(rig.postsNaming("second.heic") == 0)

        let session = rig.session
        let engine = rig.engine
        let videoID = rig.video.id
        ending.value = { task in
            guard task.identity.fileID == videoID, task.identity.attempt == 1 else { return }
            session.forget(task.taskIdentifier)
            await engine.handle(
                WholeAnswer(
                    taskIdentifier: task.taskIdentifier, identity: task.identity, statusCode: 200,
                    body: ScriptedHTTP.session(uid: "x", chunkSize: 1, received: 3000).body
                )
            )
        }
        rig.delegate.complete(
            taskIdentifier: video.taskIdentifier, taskDescription: video.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attempts(of: rig.video.id) == [0, 1] })
        await rig.engine.untilQuiescent()
        #expect(try await rig.reload().file(videoID)?.isComplete == true)
        // The picture's successor holds one place; the video's, already ended, gave its back.
        #expect(try await rig.eventually { rig.postsNaming("second.heic") == 1 })
    }

    @Test("a successor that ended before its replacement settled gives its place back at once")
    func successorEndedBeforeSettledFreesItsPlace() async throws {
        let ending = WholeBox<(@Sendable (WholeTask) async -> Void)?>(nil)
        let rig = try await WholeRig.make(
            onCancel: .staysListed,
            wrapUploads: { inner in
                EarlyEndingUploads(inner) { task in await ending.value?(task) }
            }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        _ = try await rig.enqueueSecond()
        await rig.preferences.set(true)
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(rig.postsNaming("second.heic") == 0)

        let session = rig.session
        let engine = rig.engine
        let pictureID = rig.picture.id
        ending.value = { task in
            guard task.identity.fileID == pictureID, task.identity.attempt == 1 else { return }
            session.forget(task.taskIdentifier)
            await engine.handle(
                WholeAnswer(
                    taskIdentifier: task.taskIdentifier, identity: task.identity, statusCode: 200,
                    body: ScriptedHTTP.session(uid: "x", chunkSize: 1, received: 1000).body
                )
            )
        }
        rig.delegate.complete(
            taskIdentifier: picture.taskIdentifier, taskDescription: picture.description,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(try await rig.eventually { rig.attempts(of: rig.picture.id) == [0, 1] })
        await rig.engine.untilQuiescent()
        #expect(try await rig.reload().file(pictureID)?.isComplete == true)
        // The video's cancelled task still holds one place; the picture's successor gave its back.
        #expect(try await rig.eventually { rig.postsNaming("second.heic") == 1 })
    }
}

/// Bytes that differ from block to block and within a block, so a tail cut at the wrong offset
/// cannot hash the same as the right one.
private enum Pattern {
    static func block(_ index: Int, size: Int) -> Data {
        var data = Data(repeating: UInt8(truncatingIfNeeded: index &* 31 &+ 7), count: size)
        withUnsafeBytes(of: UInt64(index).bigEndian) { data.replaceSubrange(0..<8, with: $0) }
        data[size / 2] = UInt8(truncatingIfNeeded: index &+ 1)
        return data
    }

    /// Writes `blocks` blocks of `size` bytes to `url`, one block in memory at a time.
    static func write(to url: URL, blocks: Int, size: Int) throws {
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for index in 0..<blocks { try handle.write(contentsOf: block(index, size: size)) }
    }

    /// The SHA-256 of bytes `from...` of what `write` produced, computed from the generator and
    /// never from the file.
    static func digest(blocks: Int, size: Int, from offset: Int) -> String {
        var hasher = SHA256()
        for index in 0..<blocks {
            let start = index * size
            guard start + size > offset else { continue }
            let data = block(index, size: size)
            hasher.update(data: data.subdata(in: Swift.max(offset - start, 0)..<size))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The original's reads, recorded: how large each ask was and how much came back.
private struct CountingReader: TailReading {
    let handle: FileHandle
    var largestAsk = 0
    var largestRead = 0
    var reads = 0

    mutating func read(upToCount count: Int) throws -> Data? {
        largestAsk = Swift.max(largestAsk, count)
        let data = try handle.read(upToCount: count)
        largestRead = Swift.max(largestRead, data?.count ?? 0)
        reads += 1
        return data
    }
}

@Suite("Whole lane: an interrupted upload resumes from the server's offset")
struct WholeResumeTests {
    static let mebibyte = 1 << 20
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// The picture has a session nothing is carrying; the video is already on the server.
    static func resumable(
        uid: String = "s1", attempt: Int? = nil, freshSessions: Int? = nil,
        bytesConfirmed: Int64 = 0
    ) -> @Sendable (UploadJob) -> UploadJob? {
        { job in
            var started = job
            started.transport = .whole
            started.state = .waiting
            started.files[0].uploadUID = uid
            started.files[0].uploadAttempt = attempt
            started.files[0].freshSessions = freshSessions
            started.files[0].bytesConfirmed = bytesConfirmed
            started.files[1].uploadUID = "v1"
            started.files[1].bytesConfirmed = started.files[1].byteSize
            return started
        }
    }

    static func offset(_ value: Int64) -> OutboxHTTPResponse {
        OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": String(value)])
    }

    private func heads(_ rig: WholeRig) -> Int { rig.http.requests(method: "HEAD").count }

    private func stagedTails(_ rig: WholeRig) -> [WholeStagedTail] {
        rig.repository.tails.staged()
    }

    @Test("planner: a session with missing bytes is resumed while open and waits while closed")
    func plannerResumes() throws {
        let file = OutboxFile(
            relativePath: "a", filename: "a.mov", mime: "video/quicktime", byteSize: 100,
            uploadUID: "s1", bytesConfirmed: 40
        )
        var job = Fixture.job(files: [file])
        job.transport = .whole
        let open = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: Self.now, schedulingOpen: true
        )
        #expect(open == .resume(file.id))
        let closed = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: Self.now, schedulingOpen: false
        )
        #expect(closed == .wait(until: .distantFuture))
        let carried = OutboxPlanner.nextWholeAction(
            for: job, credentials: Fixture.credentials(), now: Self.now, schedulingOpen: true,
            carried: [file.id]
        )
        #expect(carried == .upload(starting: []))
    }

    @Test("HEAD 200 at 30 MiB of 50 → one PATCH of the staged 20 MiB tail at that offset")
    func resumesFromTheOffset() async throws {
        let size = 50 * Self.mebibyte
        let offset = Int64(30 * Self.mebibyte)
        let rig = try await WholeRig.make(
            prepare: Self.resumable(),
            answerHead: { _ in Self.offset(offset) }
        )
        defer { rig.cleanUp() }
        var job = try await rig.reload()
        let original = rig.repository.mediaURL(job: job, file: job.files[0])
        try Pattern.write(to: original, blocks: 50, size: Self.mebibyte)
        job.files[0].byteSize = Int64(size)
        try await rig.repository.save(job)

        await rig.engine.drain()

        #expect(heads(rig) == 1)
        #expect(rig.attemptedUploadPosts == 0)
        #expect(rig.session.createdTasks.count == 1)
        let task = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(task.request.httpMethod == "PATCH")
        #expect(task.request.value(forHTTPHeaderField: "Upload-Offset") == "31457280")
        #expect(task.request.url?.path() == "/api/uploads/s1")
        let expected = OutboxRequests.wholeUpload(
            baseURL: Fixture.credentials().serverBaseURL, token: "t", uploadUID: "s1",
            allowsMobileData: false
        )
        #expect(task.request.allowsCellularAccess == expected.allowsCellularAccess)
        #expect(
            task.request.allowsExpensiveNetworkAccess == expected.allowsExpensiveNetworkAccess)
        #expect(
            task.request.allowsConstrainedNetworkAccess
                == expected.allowsConstrainedNetworkAccess)
        let ref = WholeFileRef(jobID: job.id, fileID: job.files[0].id)
        #expect(task.file == rig.repository.tails.url(for: ref, attempt: 1))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: task.file.path(percentEncoded: false))
        #expect((attributes[.size] as? NSNumber)?.int64Value == Int64(20 * Self.mebibyte))
        #expect(
            try Pattern.digest(of: task.file)
                == Pattern.digest(blocks: 50, size: Self.mebibyte, from: Int(offset)))
        // The original is untouched, and the count is the server's.
        #expect(
            try Pattern.digest(of: original)
                == Pattern.digest(blocks: 50, size: Self.mebibyte, from: 0))
        let saved = try await rig.reload()
        #expect(saved.files[0].bytesConfirmed == offset)
        #expect(saved.files[0].uploadUID == "s1")
        #expect(saved.files[0].uploadAttempt == 1)
    }

    @Test("HEAD 200 at offset 0 → the original itself is sent at offset 0, nothing staged")
    func offsetZeroSendsTheOriginal() async throws {
        let rig = try await WholeRig.make(
            prepare: Self.resumable(), answerHead: { _ in Self.offset(0) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let task = try rig.task(for: rig.picture.id, attempt: 1)
        let job = try await rig.reload()
        #expect(task.file == rig.repository.mediaURL(job: job, file: job.files[0]))
        #expect(task.request.value(forHTTPHeaderField: "Upload-Offset") == "0")
        #expect(stagedTails(rig).isEmpty)
    }

    @Test("the copy reads the original a MiB at a time and writes exactly its tail (200 MB)")
    func boundedCopy() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "original.mov")
        try Pattern.write(to: source, blocks: 200, size: Self.mebibyte)
        let offset = 123_456_789
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var reader = CountingReader(handle: handle)
        let destination = directory.appending(path: "tail")

        let copied = try WholeTailStaging.copy(from: &reader, to: destination)

        #expect(copied == Int64(200 * Self.mebibyte - offset))
        #expect(reader.largestAsk <= Self.mebibyte)
        #expect(reader.largestRead <= Self.mebibyte)
        #expect(reader.reads >= (200 * Self.mebibyte - offset) / Self.mebibyte)
        #expect(
            try Pattern.digest(of: destination)
                == Pattern.digest(blocks: 200, size: Self.mebibyte, from: offset))
    }

    @Test("HEAD 200 with the whole file → confirmed with no request, and the memo is created")
    func wholeOnTheServerIsConfirmed() async throws {
        let rig = try await WholeRig.make(
            prepare: Self.resumable(), answerHead: { _ in Self.offset(1000) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(heads(rig) == 1)
        #expect(rig.session.createdTasks.isEmpty)
        #expect(rig.attemptedUploadPosts == 0)
        #expect(!rig.attempted.value.contains { $0.contains("finalize") })
        #expect(!rig.attempted.value.contains { $0.hasPrefix("PATCH") })
        #expect(await rig.repository.job(rig.job.id) == nil)
    }

    @Test("HEAD 404 → one fresh POST /api/uploads, and the original sent from byte 0")
    func lostSessionStartsFresh() async throws {
        let rig = try await WholeRig.make(prepare: Self.resumable(), headStatus: 404)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        #expect(heads(rig) == 1)
        #expect(rig.uploadPosts == 1)
        let task = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(task.request.value(forHTTPHeaderField: "Upload-Offset") == "0")
        #expect(task.request.url?.path() == "/api/uploads/u1")
        let saved = try await rig.reload()
        #expect(saved.files[0].uploadUID == "u1")
        #expect(saved.files[0].freshSessions == 1)
    }

    @Test("the fourth HEAD 404 in a row holds the capture with its reason and sends nothing")
    func fourthLossHolds() async throws {
        let rig = try await WholeRig.make(prepare: Self.resumable(), headStatus: 404)
        defer { rig.cleanUp() }
        for round in 1...3 {
            await rig.engine.drain()
            // An answer's place, given back, asks for a drain of its own that may still be running.
            await rig.engine.untilQuiescent()
            #expect(rig.uploadPosts == round)
            let task = try #require(rig.session.createdTasks.last)
            // The transfer drops: the session is kept, and the next attempt asks the server.
            await rig.engine.handle(try rig.answer(task, status: nil))
            rig.session.forget(task.taskIdentifier)
            rig.clock.advance(86_400)
            #expect(try await rig.reload().files[0].freshSessions == round)
        }
        let tasksBefore = rig.session.createdTasks.count
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(heads(rig) == 4)
        #expect(rig.uploadPosts == 3)
        #expect(rig.session.createdTasks.count == tasksBefore)
        let saved = try await rig.reload()
        #expect(saved.state == .held)
        #expect(saved.holdReason == .uploadSessionLost)
        #expect(saved.lastError == OutboxEngine.message(for: .uploadSessionLost))
    }

    @Test("a confirmed file's lost sessions are forgotten, so a later loss starts again at one")
    func confirmResetsTheAllowance() {
        let file = OutboxFile(
            relativePath: "a", filename: "a", mime: "a", byteSize: 10, uploadUID: "s1",
            freshSessions: 3, conflictResync: true
        )
        let job = Fixture.job(files: [file])
        let confirmed = job.advancing(fileID: file.id, bytesConfirmed: 10)
        #expect(confirmed.files[0].freshSessions == nil)
        #expect(confirmed.files[0].conflictResync == nil)
        let partial = job.advancing(fileID: file.id, bytesConfirmed: 5)
        #expect(partial.files[0].freshSessions == 3)
    }

    @Test("409 on the tail → exactly one HEAD re-sync and the same rule; a second 409 starts fresh")
    func conflictResyncsOnce() async throws {
        let reported = WholeBox<Int64>(400)
        let rig = try await WholeRig.make(
            prepare: Self.resumable(), answerHead: { _ in Self.offset(reported.value) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let first = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(heads(rig) == 1)

        reported.value = 600
        await rig.engine.handle(try rig.answer(first, status: 409))
        #expect(heads(rig) == 2)
        let second = try rig.task(for: rig.picture.id, attempt: 2)
        #expect(second.request.value(forHTTPHeaderField: "Upload-Offset") == "600")
        #expect(try await rig.reload().files[0].conflictResync == true)
        #expect(rig.uploadPosts == 0)

        await rig.engine.handle(try rig.answer(second, status: 409))
        #expect(heads(rig) == 2)
        let saved = try await rig.reload()
        #expect(saved.files[0].uploadUID == nil)
        #expect(saved.files[0].freshSessions == 1)
        #expect(saved.files[0].conflictResync == nil)
    }

    @Test("HEAD refused for the credential it presented holds; under a replaced one it backs off")
    func headRefusalCarriesItsEpoch() async throws {
        let current = try await WholeRig.make(prepare: Self.resumable(), headStatus: 401)
        defer { current.cleanUp() }
        await current.engine.drain()
        let held = try await current.reload()
        #expect(held.state == .held)
        #expect(held.holdReason == .serverRefused)
        #expect(current.session.createdTasks.isEmpty)

        let renew = WholeBox<(@Sendable () -> Void)?>(nil)
        let stale = try await WholeRig.make(
            prepare: Self.resumable(),
            answerHead: { _ in
                renew.value?()
                return OutboxHTTPResponse(statusCode: 401)
            }
        )
        defer { stale.cleanUp() }
        let credentials = stale.credentials
        renew.value = { credentials.supersede() }
        await stale.engine.drain()
        let waiting = try await stale.reload()
        #expect(waiting.state == .waiting)
        #expect(waiting.holdReason == nil)
        let superseded = OutboxRefusal(statusCode: 0, issuedUnder: nil, what: "upload")
        #expect(waiting.lastError == superseded.supersededMessage)
        #expect(stale.session.createdTasks.isEmpty)
    }

    @Test("a background wake with a resumable file sends no HEAD, stages nothing, starts no task")
    func wakeNeverResumes() async throws {
        let rig = try await WholeRig.make(
            prepare: Self.resumable(bytesConfirmed: 400), answerHead: { _ in Self.offset(400) }
        )
        defer { rig.cleanUp() }
        rig.gate.close()
        await rig.engine.drain()
        #expect(heads(rig) == 0)
        #expect(rig.session.createdTasks.isEmpty)
        #expect(stagedTails(rig).isEmpty)
        #expect(try await rig.reload().files[0].uploadUID == "s1")
    }

    @Test("relaunch: the tail's task listed with its record → adopted, no second task, tail kept")
    func relaunchAdoptsTheTailTask() async throws {
        let other = UUID()
        let rig = try await WholeRig.make(
            listing: { job in
                [
                    WholeTaskListing(
                        taskIdentifier: 77,
                        taskDescription: WholeTaskIdentity(
                            jobID: job.id, fileID: job.files[0].id, attempt: 1, launch: other,
                            epoch: 0
                        ).taskDescription,
                        access: WholeTaskNetworkAccess(
                            request: OutboxRequests.wholeUpload(
                                baseURL: Fixture.server, token: "t", uploadUID: "s1",
                                allowsMobileData: false, offset: 400
                            )
                        ),
                        state: .running
                    )
                ]
            },
            prepare: Self.resumable(attempt: 1, bytesConfirmed: 400),
            answerHead: { _ in Self.offset(400) }
        )
        defer { rig.cleanUp() }
        let ref = WholeFileRef(jobID: rig.job.id, fileID: rig.picture.id)
        let tail = rig.repository.tails.url(for: ref, attempt: 1)
        try Data(repeating: 1, count: 600).write(to: tail)

        await rig.engine.drain()

        #expect(heads(rig) == 0)
        #expect(rig.session.createdTasks.isEmpty)
        #expect(rig.session.cancelledIdentifiers.isEmpty)
        #expect(FileManager.default.fileExists(atPath: tail.path(percentEncoded: false)))
    }

    @Test("relaunch: a record with no task → its tail is deleted and a foreground HEAD resumes it")
    func relaunchWithoutTaskResumesInTheForeground() async throws {
        let rig = try await WholeRig.make(
            prepare: Self.resumable(attempt: 1, bytesConfirmed: 400),
            answerHead: { _ in Self.offset(700) }
        )
        defer { rig.cleanUp() }
        let ref = WholeFileRef(jobID: rig.job.id, fileID: rig.picture.id)
        let tail = rig.repository.tails.url(for: ref, attempt: 1)
        try Data(repeating: 1, count: 600).write(to: tail)

        rig.gate.close()
        await rig.engine.drain()
        #expect(!FileManager.default.fileExists(atPath: tail.path(percentEncoded: false)))
        #expect(heads(rig) == 0)
        #expect(rig.session.createdTasks.isEmpty)

        rig.gate.open()
        await rig.engine.drain()
        #expect(heads(rig) == 1)
        let task = try rig.task(for: rig.picture.id, attempt: 2)
        #expect(task.request.value(forHTTPHeaderField: "Upload-Offset") == "700")
        #expect(task.file == rig.repository.tails.url(for: ref, attempt: 2))
    }

    @Test("a tail task's confirmed answer deletes its tail")
    func tailsGoWithTheirTask() async throws {
        let rig = try await WholeRig.make(
            prepare: Self.resumable(), answerHead: { _ in Self.offset(400) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let task = try rig.task(for: rig.picture.id, attempt: 1)
        #expect(FileManager.default.fileExists(atPath: task.file.path(percentEncoded: false)))
        await rig.engine.handle(try rig.answer(task, status: 204, received: 1000))
        #expect(!FileManager.default.fileExists(atPath: task.file.path(percentEncoded: false)))
        #expect(stagedTails(rig).isEmpty)
    }

    @Test("a hold one tail task's refusal lands deletes every tail of the capture, a sibling's too")
    func holdViaCallbackTakesEveryTail() async throws {
        let rig = try await WholeRig.make(
            prepare: { job in
                var started = job
                started.transport = .whole
                started.state = .waiting
                started.files[0].uploadUID = "s1"
                started.files[1].uploadUID = "v1"
                return started
            },
            answerHead: { _ in Self.offset(400) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        let picture = try rig.task(for: rig.picture.id, attempt: 1)
        let video = try rig.task(for: rig.video.id, attempt: 1)
        #expect(stagedTails(rig).count == 2)
        // The app leaves the foreground: the video's task is suspended, the picture's answers.
        rig.gate.close()

        await rig.engine.handle(try rig.answer(picture, status: 401))

        let saved = try await rig.reload()
        #expect(saved.state == .held)
        #expect(saved.holdReason == .serverRefused)
        #expect(stagedTails(rig).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: video.file.path(percentEncoded: false)))
    }

    @Test("an unreadable success's HEAD refused for its credential holds; a replaced one backs off")
    func unreadableSuccessHeadRefusal() async throws {
        let current = try await WholeRig.make(headStatus: 401)
        defer { current.cleanUp() }
        await current.engine.drain()
        let picture = try current.task(for: current.picture.id)
        await current.engine.handle(try current.answer(picture, status: 200))
        #expect(heads(current) == 1)
        let held = try await current.reload()
        #expect(held.state == .held)
        #expect(held.holdReason == .serverRefused)

        let renew = WholeBox<(@Sendable () -> Void)?>(nil)
        let stale = try await WholeRig.make(
            answerHead: { _ in
                renew.value?()
                return OutboxHTTPResponse(statusCode: 401)
            }
        )
        defer { stale.cleanUp() }
        await stale.engine.drain()
        let task = try stale.task(for: stale.picture.id)
        let credentials = stale.credentials
        renew.value = { credentials.supersede() }
        await stale.engine.handle(try stale.answer(task, status: 200))
        #expect(heads(stale) == 1)
        let waiting = try await stale.reload()
        #expect(waiting.state == .waiting)
        #expect(waiting.holdReason == nil)
        let superseded = OutboxRefusal(statusCode: 0, issuedUnder: nil, what: "upload")
        #expect(waiting.lastError == superseded.supersededMessage)
    }

    @Test("an unreadable success's HEAD is judged by the credential it presented, not the task's")
    func unreadableSuccessHeadJudgedByItsOwnEpoch() async throws {
        let rig = try await WholeRig.make(headStatus: 401)
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        // Renewed after the task went out: the HEAD presents the credential that stands now.
        rig.credentials.supersede()

        await rig.engine.handle(try rig.answer(picture, status: 200))

        #expect(heads(rig) == 1)
        let held = try await rig.reload()
        #expect(held.state == .held)
        #expect(held.holdReason == .serverRefused)
    }

    static func busyHead(_ status: Int = 429) -> OutboxHTTPResponse {
        OutboxHTTPResponse(statusCode: status, headers: ["Retry-After": "3600"])
    }

    @Test("a resume's HEAD answered 429 with Retry-After waits as long as the server asked")
    func resumeHeadHonoursRetryAfter() async throws {
        let rig = try await WholeRig.make(
            prepare: Self.resumable(), answerHead: { _ in Self.busyHead() }
        )
        defer { rig.cleanUp() }
        let start = rig.clock.now
        await rig.engine.drain()
        await rig.engine.untilQuiescent()
        #expect(heads(rig) == 1)
        #expect(rig.session.createdTasks.isEmpty)
        let row = try await rig.reload()
        #expect(row.state != .held)
        #expect(row.file(rig.picture.id)?.nextAttemptAt == start.addingTimeInterval(3600))
    }

    @Test("an unreadable success's HEAD answered 503 with Retry-After waits as long as asked")
    func unreadableSuccessHeadHonoursRetryAfter() async throws {
        let rig = try await WholeRig.make(answerHead: { _ in Self.busyHead(503) })
        defer { rig.cleanUp() }
        let start = rig.clock.now
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        await rig.engine.handle(try rig.answer(picture, status: 200))
        await rig.engine.untilQuiescent()
        #expect(heads(rig) == 1)
        let row = try await rig.reload()
        #expect(row.state != .held)
        #expect(row.file(rig.picture.id)?.nextAttemptAt == start.addingTimeInterval(3600))
    }

    @Test("a manifest written before the resume counters existed decodes with none")
    func olderManifestDecodes() throws {
        let id = UUID()
        let json = """
            {"id":"\(id.uuidString)","relativePath":"a","filename":"a.mov","mime":"video/quicktime",
            "byteSize":100,"uploadUID":"s1","bytesConfirmed":40,"chunkSize":5242880}
            """
        let file = try JSONDecoder().decode(OutboxFile.self, from: Data(json.utf8))
        #expect(file.freshSessions == nil)
        #expect(file.conflictResync == nil)
        #expect(file.uploadUID == "s1")
        let counted = """
            {"id":"\(id.uuidString)","relativePath":"a","filename":"a.mov","mime":"video/quicktime",
            "byteSize":100,"bytesConfirmed":0,"chunkSize":1,"freshSessions":2,"conflictResync":true}
            """
        let later = try JSONDecoder().decode(OutboxFile.self, from: Data(counted.utf8))
        #expect(later.freshSessions == 2)
        #expect(later.conflictResync == true)
    }

    @Test("reconciliation keeps a tail only for a live task naming its file and term")
    func planDiscardsUnclaimedTails() {
        let file = OutboxFile(
            relativePath: "a", filename: "a", mime: "a", byteSize: 10, uploadUID: "s1",
            bytesConfirmed: 4, uploadAttempt: 2
        )
        var job = Fixture.job(files: [file])
        job.transport = .whole
        let ref = WholeFileRef(jobID: job.id, fileID: file.id)
        let root = URL(filePath: "/tails")
        let staging = WholeTailStaging(directory: root)
        let claimed = WholeStagedTail(ref: ref, attempt: 2, url: staging.url(for: ref, attempt: 2))
        let older = WholeStagedTail(ref: ref, attempt: 1, url: staging.url(for: ref, attempt: 1))
        let task = WholeTaskListing(
            taskIdentifier: 5,
            taskDescription: WholeTaskIdentity(
                jobID: job.id, fileID: file.id, attempt: 2, launch: UUID(), epoch: 0
            ).taskDescription
        )
        let live = WholeReconciliation.plan(jobs: [job], tasks: [task], tails: [claimed, older])
        #expect(live.discardedTails == [older.url])
        let none = WholeReconciliation.plan(jobs: [job], tasks: [], tails: [claimed, older])
        #expect(Set(none.discardedTails) == [claimed.url, older.url])
        #expect(none.retryWhole == [ref])
    }

    @Test("a name that only contains a tail's marks is no tail; a half-written copy still is one")
    func stagedNamesOnlyTails() throws {
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = WholeTailStaging(directory: directory)
        let ref = WholeFileRef(jobID: UUID(), fileID: UUID())
        let tail = staging.url(for: ref, attempt: 3)
        let partial = staging.url(for: ref, attempt: 4).appendingPathExtension("partial")
        let prefix = "\(ref.jobID.uuidString)-\(ref.fileID.uuidString)"
        var decoys = ["\(prefix)-a3.tail.bak", "\(prefix)-a.tail", "\(prefix)-a-1.tail"]
        decoys += ["\(prefix).tail", "\(prefix)-a3.chunk", "-a3.tail"]
        decoys.append("\(ref.jobID.uuidString)-0")
        let files = [tail, partial] + decoys.map { directory.appending(path: $0) }
        for url in files {
            try Data([1]).write(to: url)
        }

        let staged = staging.staged()

        let names = Set(staged.map(\.url.lastPathComponent))
        #expect(names == [tail.lastPathComponent, partial.lastPathComponent])
        #expect(staged.allSatisfy { $0.ref == ref })
        #expect(Set(staged.map(\.attempt)) == [3, 4])
    }

    @Test("a resume held at its write owns its file: a sibling's answer sends it nothing more")
    func resumeOwnsItsFile() async throws {
        let written = TestGate()
        let gated = WholeBox<AnswerWriteGate?>(nil)
        let rig = try await WholeRig.make(
            persistence: { repository in
                let persistence = AnswerWriteGate(repository, gate: written)
                gated.value = persistence
                return persistence
            },
            completion: [.retry("later")],
            answerHead: { _ in Self.offset(400) }
        )
        defer { rig.cleanUp() }
        await rig.engine.drain()
        let picture = try rig.task(for: rig.picture.id)
        let video = try rig.task(for: rig.video.id)
        await rig.engine.handle(try rig.answer(picture, status: nil))
        rig.session.forget(picture.taskIdentifier)
        await rig.engine.untilQuiescent()
        rig.clock.advance(86_400)
        // The picture's resume is held at its write, after its HEAD and its staging.
        await gated.value?.arm(1)
        let drain = Task { await rig.engine.drain() }
        await written.waitUntilParked()
        #expect(heads(rig) == 1)

        // The video's success lands and its continuation plans the row while the resume owns the
        // picture.
        await rig.engine.handle(try rig.answer(video, status: 200, received: 3000))
        #expect(heads(rig) == 1)
        await written.open()
        await drain.value
        await rig.engine.untilQuiescent()
        #expect(heads(rig) == 1)
        #expect(rig.attempts(of: rig.picture.id) == [0, 1])
    }
}
