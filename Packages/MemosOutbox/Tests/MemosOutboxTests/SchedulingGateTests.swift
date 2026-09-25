import Foundation
import MemosOutbox
import Testing

/// The same world as `Harness`, with an engine that asks a scheduling gate.
///
/// Built from the harness's own parts — its persistence, its scripted server and session, its
/// credentials and preference suite — so the engine under test writes to the same disk the test
/// reads back, and no second repository is constructed for it.
extension Harness {
    func engine(
        gate: SchedulingGate,
        completion: (any MemoCompleting)? = nil,
        credentials: (any OutboxCredentialsProviding)? = nil
    ) -> OutboxEngine {
        let clock = self.clock
        return OutboxEngine(
            repository: persistence,
            credentials: credentials ?? self.credentials,
            http: http,
            scheduler: scheduler,
            completion: completion ?? self.completion,
            network: network,
            preferences: UploadPreferences(defaults: UserDefaults(suiteName: preferencesName)!),
            clock: { clock.now },
            schedulingGate: gate
        )
    }
}

private struct Missing: Error {}

private enum Gated {
    /// A capture with no files: the planner's next step for it is the memo create.
    static func completeRow(
        in harness: Harness, content: String = "finished", capturedOffset: TimeInterval = -60
    ) async throws -> UploadJob {
        try await harness.repository.enqueue(
            content: content,
            visibility: "PRIVATE",
            capturedAt: harness.now.addingTimeInterval(capturedOffset),
            binding: Fixture.binding(),
            sources: []
        )
    }

    /// The harness's capture with its upload session open and `confirmed` bytes on the server.
    static func started(
        _ harness: Harness, confirmed: Int64, chunkSize: Int = 1000
    ) async throws -> UploadJob {
        var job = harness.job
        job.files[0].uploadUID = "u1"
        job.files[0].chunkSize = chunkSize
        job.files[0].bytesConfirmed = confirmed
        try await harness.repository.save(job)
        guard let saved = await harness.reload() else { throw Missing() }
        return saved
    }

    /// A capture whose memo exists and which still owes that memo an edit.
    static func editRow(in harness: Harness) async throws -> UploadJob {
        var job = try await completeRow(in: harness, content: "edited", capturedOffset: -30)
        job.resolvedMemoUID = "m9"
        job.editKey = "edit-key"
        job.pendingEdit = PendingEdit(
            content: "edited again", visibility: "PRIVATE", capturedAt: job.capturedAt,
            fileIDs: []
        )
        try await harness.repository.save(job)
        guard let saved = await harness.repository.job(job.id) else { throw Missing() }
        return saved
    }

    static func answer(_ job: UploadJob, offset: Int64, received: Int) -> ChunkResult {
        ChunkResult(
            identity: OutboxTaskIdentity(jobID: job.id, fileID: job.files[0].id, offset: offset),
            statusCode: 200,
            body: ScriptedHTTP.session(uid: "u1", chunkSize: 1000, received: received).body
        )
    }

    /// Reachable, hands out upload sessions, creates memos and applies edits.
    static func server(
        patchStatus: Int = 200, onPatch: @escaping @Sendable () -> Void = {}
    ) -> ScriptedHTTP {
        ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/uploads"):
                return ScriptedHTTP.session(uid: "u1", chunkSize: 1000, received: 0)
            case ("POST", "/api/memos"):
                return ScriptedHTTP.json(["uid": "m1"], status: 201)
            case ("PATCH", _):
                onPatch()
                return ScriptedHTTP.json(["uid": "m9"], status: patchStatus)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
    }

    static func uploadStarts(_ http: ScriptedHTTP) -> Int {
        http.requests(method: "POST").filter { $0.url?.path() == "/api/uploads" }.count
    }

    static func creates(_ http: ScriptedHTTP) -> Int {
        http.requests(method: "POST").filter { $0.url?.path() == "/api/memos" }.count
    }
}

/// A completion whose FIRST create parks on a gate until the test opens it. Every create is
/// recorded as it arrives, before it parks, because arriving is what a send is.
private final class BlockingCompletion: MemoCompleting, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var keys: [UUID] = []

    func create(
        job: UploadJob,
        credentials: OutboxCredentials,
        under authority: SendAuthority
    ) async -> MemoCompletionOutcome {
        guard authority.holds() else { return .retry("no authority") }
        let first = lock.withLock {
            keys.append(job.idempotencyKey)
            return keys.count == 1
        }
        if first { await gate.pass() }
        return .created(uid: "m1")
    }

    var idempotencyKeys: [UUID] { lock.withLock { keys } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

private final class Late<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite("Scheduling gate: the authority's second clause")
struct SchedulingClauseTests {
    @Test("an authority built without the clause is exactly what it was: the gate is inert")
    func theClauseDefaultsOpen() {
        #expect(SchedulingGate().isOpen, "a gate nobody feeds must start open")
        let plain = SendAuthority { true }
        #expect(plain.holds())
        #expect(plain.withdrawal() == nil)
        let fed = SchedulingGate()
        let gated = SendAuthority({ true }, scheduling: { fed.isOpen })
        #expect(gated.holds(), "an open gate withdraws nothing")
    }

    @Test("a closed gate withdraws the send, and says so apart from a credential withdrawal")
    func aClosedGateIsItsOwnWithdrawal() {
        let gate = SchedulingGate(isOpen: false)
        let credentialStands = Flag()
        credentialStands.raise()
        let authority = SendAuthority({ credentialStands.isRaised }, scheduling: { gate.isOpen })

        #expect(!authority.holds())
        #expect(authority.withdrawal() == .scheduling)
        #expect(authority.credentialHolds(), "the credential clause alone still stands")

        let copy = authority
        gate.open()
        #expect(copy.holds())
        #expect(authority.withdrawal() == nil, "the verdict is shared by every copy")

        let replaced = SendAuthority({ false }, scheduling: { false })
        #expect(!replaced.holds())
        #expect(replaced.withdrawal() == .credential, "a moved account is named first")
        #expect(!replaced.credentialHolds())
    }

    @Test("the whole lane's scheduler asks the clause itself and creates no task while closed")
    func wholeSchedulerHonoursTheGate() async {
        let session = ScriptedUploadTaskSession()
        let scheduler = BackgroundUploadScheduler(session: session)
        let gate = SchedulingGate(isOpen: false)
        let authority = SendAuthority({ true }, scheduling: { gate.isOpen })
        let request = OutboxRequests.wholeUpload(
            baseURL: Fixture.server, token: "t", uploadUID: "u1", allowsMobileData: false
        )
        let ref = WholeFileRef(jobID: UUID(), fileID: UUID())
        let file = URL(fileURLWithPath: "/dev/null")

        let withheld = await scheduler.upload(
            request, fromFile: file, for: ref, attempt: 0, under: authority, issuedUnder: 1
        )
        #expect(withheld == nil)
        #expect(session.createdTasks.isEmpty)
        #expect(authority.withdrawal() == .scheduling)

        gate.open()
        let sent = await scheduler.upload(
            request, fromFile: file, for: ref, attempt: 0, under: authority, issuedUnder: 1
        )
        #expect(sent != nil)
        #expect(session.createdTasks.count == 1)
    }
}

@Suite("Scheduling gate: what a closed gate lets out")
struct SchedulingGateEngineTests {
    @Test("a closed gate: the drain starts no upload, and a complete row still sends one create")
    func closedDrainSendsOnlyTheCreate() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(
            bytes: 1000, http: Gated.server(), completion: completion
        )
        defer { harness.cleanUp() }
        let finished = try await Gated.completeRow(in: harness)
        let before = await harness.reload()
        let engine = harness.engine(gate: SchedulingGate(isOpen: false))

        await engine.drain()

        #expect(Gated.uploadStarts(harness.http) == 0)
        #expect(harness.scheduler.uploads.isEmpty)
        #expect(harness.scheduler.authorityVerdicts.isEmpty, "the early skip reached no sender")
        #expect(completion.idempotencyKeys == [finished.idempotencyKey])
        #expect(await harness.repository.job(finished.id) == nil)
        #expect(await harness.reload() == before, "the waiting capture was written to")
    }

    @Test("a closed gate: an answer's continuation banks the bytes and hands off nothing")
    func closedContinuationBanksAndStops() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        let gate = SchedulingGate()
        let engine = harness.engine(gate: gate)
        let started = try await Gated.started(harness, confirmed: 0, chunkSize: 400)
        await engine.drain()
        #expect(harness.scheduler.uploads.count == 1, "the premise: one chunk went out")

        gate.close()
        await engine.handle(Gated.answer(started, offset: 0, received: 400))

        let banked = try #require(await harness.reload())
        #expect(banked.files[0].bytesConfirmed == 400)
        #expect(harness.scheduler.uploads.count == 1, "a wake handed off the next chunk")
        #expect(harness.scheduler.authorityVerdicts.count == 1, "the continuation reached a sender")

        gate.open()
        await engine.drain()
        #expect(harness.scheduler.uploads.count == 2)
        #expect(harness.scheduler.uploads.last?.identity.offset == 400)
    }

    @Test("a closed gate: an answer that completes the capture sends its create, and nothing else")
    func closedContinuationStillCreates() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(
            bytes: 1000, http: Gated.server(), completion: completion
        )
        defer { harness.cleanUp() }
        let started = try await Gated.started(harness, confirmed: 0)
        let engine = harness.engine(gate: SchedulingGate(isOpen: false))

        await engine.handle(Gated.answer(started, offset: 0, received: 1000))

        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil)
        #expect(Gated.uploadStarts(harness.http) == 0)
    }

    @Test("a closed gate: a network change and a toggle change drain nothing but the create")
    @MainActor
    func closedPathAndToggleSendOnlyTheCreate() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(
            bytes: 1000, http: Gated.server(), completion: completion,
            network: StubNetworkPath(.cellular)
        )
        defer { harness.cleanUp() }
        let finished = try await Gated.completeRow(in: harness)
        let preferences = UploadPreferences(
            defaults: UserDefaults(suiteName: harness.preferencesName)!
        )
        let clock = harness.clock
        let outbox = Outbox(
            repository: harness.repository,
            credentials: harness.credentials,
            http: harness.http,
            scheduler: harness.scheduler,
            completion: completion,
            network: harness.network,
            preferences: preferences,
            clock: { clock.now },
            schedulingGate: SchedulingGate(isOpen: false)
        )

        await harness.network.move(to: .wifi)
        await preferences.set(true)
        await outbox.drain()

        #expect(completion.idempotencyKeys == [finished.idempotencyKey])
        #expect(Gated.uploadStarts(harness.http) == 0)
        #expect(harness.scheduler.uploads.isEmpty)
    }

    @Test("the gate opening mid-pass takes effect at the next step; the held write lands whole")
    func openingMidPassTakesEffectAtTheNextStep() async throws {
        let held = TestGate()
        let harness = try await Harness.make(
            bytes: 1000, http: Gated.server(), holdingFirstSave: held
        )
        defer { harness.cleanUp() }
        // Captured first, so the pass reaches it first: its create's bookkeeping write is the
        // first save, and the one held open.
        let finished = try await Gated.completeRow(in: harness)
        let gate = SchedulingGate(isOpen: false)
        let engine = harness.engine(gate: gate)

        let pass = Task { await engine.drain() }
        await held.waitUntilParked()
        gate.open()
        await held.open()
        await pass.value

        #expect(Gated.creates(harness.http) == 1)
        #expect(await harness.repository.job(finished.id) == nil, "the held write was cut short")
        #expect(Gated.uploadStarts(harness.http) == 1, "the next step did not see the gate open")
        #expect(harness.scheduler.uploads.count == 1)
    }

    @Test("a release asked while the gate is closed writes nothing")
    func releaseWaitsForTheGate() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        var parked = harness.job
        parked.state = .held
        parked.holdReason = .serverRefused
        try await harness.repository.save(parked)
        let before = await harness.reload()
        let gate = SchedulingGate(isOpen: false)
        let engine = harness.engine(gate: gate)

        await engine.release(jobID: harness.job.id)
        #expect(await harness.reload() == before)

        gate.open()
        await engine.release(jobID: harness.job.id)
        #expect(await harness.reload()?.state != .held)
    }
}

@Suite("Scheduling gate: the sender is the fence")
struct SchedulingSendHopTests {
    @Test("chunk lane: the gate closing while the hand-off's save is held sends nothing")
    func chunkHandOffWithheldAtTheSender() async throws {
        let held = TestGate()
        let harness = try await Harness.make(
            bytes: 1000, http: Gated.server(), holdingFirstSave: held
        )
        defer { harness.cleanUp() }
        let started = try await Gated.started(harness, confirmed: 0)
        let gate = SchedulingGate()
        let engine = harness.engine(gate: gate)

        let pass = Task { await engine.drain() }
        await held.waitUntilParked()
        gate.close()
        await held.open()
        await pass.value

        #expect(harness.scheduler.authorityVerdicts == [false])
        #expect(harness.scheduler.uploads.isEmpty)
        let after = try #require(await harness.reload())
        #expect(after.state == .uploading, "the save the hand-off waited on still landed")
        #expect(after.files[0].bytesConfirmed == 0)
        #expect(after.attemptCount == started.attemptCount, "a withheld hand-off wrote a backoff")
        #expect(after.nextAttemptAt == started.nextAttemptAt)

        gate.open()
        await engine.drain()
        #expect(harness.scheduler.authorityVerdicts == [false, true])
        #expect(harness.scheduler.uploads.count == 1)
    }

    @Test("chunk lane: the gate closing inside the hop to the scheduler sends nothing")
    func chunkHandOffWithheldInsideTheHop() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        _ = try await Gated.started(harness, confirmed: 0)
        let gate = SchedulingGate()
        let engine = harness.engine(gate: gate)
        harness.scheduler.beforeUpload = { gate.close() }

        await engine.drain()

        #expect(harness.scheduler.authorityVerdicts == [false])
        #expect(harness.scheduler.uploads.isEmpty)
    }

    @Test("HTTP: the gate closing after the engine's read sends no upload start, writes nothing")
    func uploadStartWithheldAtTheSender() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        let gate = SchedulingGate()
        let engine = harness.engine(gate: gate)
        let before = await harness.reload()
        harness.http.beforeSend = { request in
            if request.url?.path() == "/api/uploads" { gate.close() }
        }

        await engine.drain()

        #expect(Gated.uploadStarts(harness.http) == 0)
        #expect(await harness.reload() == before, "a withheld start wrote to the capture")
        #expect(harness.scheduler.uploads.isEmpty)

        harness.http.beforeSend = nil
        gate.open()
        await engine.drain()
        #expect(Gated.uploadStarts(harness.http) == 1)
    }

    @Test("memo edit: a closed gate sends no PATCH and writes nothing, and the create still goes")
    func closedGateHoldsTheEditBack() async throws {
        let harness = try await Harness.make(bytes: 0, http: Gated.server())
        defer { harness.cleanUp() }
        let edit = try await Gated.editRow(in: harness)
        let engine = harness.engine(gate: SchedulingGate(isOpen: false))

        await engine.drain()

        #expect(harness.http.requests(method: "PATCH").isEmpty)
        #expect(await harness.repository.job(edit.id) == edit, "the edit's row was written to")
        #expect(Gated.creates(harness.http) == 1)
        #expect(await harness.reload() == nil)
    }

    @Test("memo edit: withheld at the sender, the claim goes back with no backoff; the key replays")
    func editWithheldAtTheSender() async throws {
        let harness = try await Harness.make(bytes: 0, http: Gated.server())
        defer { harness.cleanUp() }
        let edit = try await Gated.editRow(in: harness)
        let gate = SchedulingGate()
        let engine = harness.engine(gate: gate)
        harness.http.beforeSend = { request in
            if request.httpMethod == "PATCH" { gate.close() }
        }

        await engine.drain()

        #expect(harness.http.requests(method: "PATCH").isEmpty)
        let after = try #require(await harness.repository.job(edit.id))
        #expect(after.patchAttempt == 1, "the claim's own write")
        #expect(after.editUnansweredSince != nil, "the claim's own write")
        #expect(after.attemptCount == edit.attemptCount, "a withheld edit counted an attempt")
        #expect(after.nextAttemptAt == edit.nextAttemptAt, "a withheld edit wrote a backoff")
        #expect(after.state != .held)

        harness.http.beforeSend = nil
        gate.open()
        await engine.drain()
        let patches = harness.http.requests(method: "PATCH")
        #expect(patches.count == 1)
        #expect(await harness.repository.job(edit.id) == nil, "the replayed edit was not applied")
    }

    /// A create answered "these uploads are incomplete" asks the server where each stands. With the
    /// gate closed that HEAD is withheld, and the recovery must not be written without its answer:
    /// written, the file still reads as complete and the same pass sends the create again, until
    /// the step ceiling writes a backoff.
    @Test("create recovery: a HEAD withheld by the gate writes nothing and sends no second create")
    func withheldRecoveryWritesNothing() async throws {
        let unlinkable = MemoCompletionOutcome.unlinkable(
            UploadsUnlinkableFailure(missingUploadUIDs: [], incompleteUploadUIDs: ["u1"])
        )
        let completion = ScriptedCompletion([unlinkable], repeating: unlinkable)
        let harness = try await Harness.make(
            bytes: 1000, http: Gated.server(), completion: completion
        )
        defer { harness.cleanUp() }
        let complete = try await Gated.started(harness, confirmed: 1000)
        let engine = harness.engine(gate: SchedulingGate(isOpen: false))

        await engine.drain()

        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(harness.http.requests(method: "HEAD").isEmpty)
        let after = try #require(await harness.reload())
        #expect(after.files == complete.files, "a recovery was written without the server's answer")
        #expect(after.attemptCount == complete.attemptCount, "a withheld recovery counted a try")
        #expect(after.nextAttemptAt == complete.nextAttemptAt, "a withheld recovery backed off")
        #expect(after.state == .creating, "more than the create's own write landed")
    }

    /// The answer is judged by the credential clause alone. Read through `holds()`, a gate that
    /// closed while the PATCH was out would call this refusal one a replaced credential earned.
    @Test("memo edit: a refusal answered after the gate closed is still judged as a refusal")
    func refusalAfterTheGateClosedIsARefusal() async throws {
        let gate = SchedulingGate()
        let harness = try await Harness.make(
            bytes: 0, http: Gated.server(patchStatus: 401, onPatch: { gate.close() })
        )
        defer { harness.cleanUp() }
        let edit = try await Gated.editRow(in: harness)
        let engine = harness.engine(gate: gate)

        await engine.drain()

        #expect(harness.http.requests(method: "PATCH").count == 1)
        #expect(await harness.repository.job(edit.id)?.state == .held)
    }
}

@Suite("Scheduling gate: the create claim and quiescence")
struct CreateClaimTests {
    @Test("a drain and an answer continuation racing on one complete capture send one create")
    func oneCreateWhenADrainAndAContinuationRace() async throws {
        let completion = BlockingCompletion()
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        let complete = try await Gated.started(harness, confirmed: 1000)
        let engine = harness.engine(gate: SchedulingGate(), completion: completion)

        let pass = Task { await engine.drain() }
        await completion.gate.waitUntilParked()
        // A late duplicate answer for the file the create is already about.
        await engine.handle(Gated.answer(complete, offset: 1000, received: 1000))
        await completion.gate.open()
        await pass.value

        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
    }

    @Test("the owning drain: a second drain returns at once; quiescence waits for the create")
    func quiescenceWaitsForTheOwningDrain() async throws {
        let completion = BlockingCompletion()
        let harness = try await Harness.make(bytes: 0, http: Gated.server())
        defer { harness.cleanUp() }
        let engine = harness.engine(gate: SchedulingGate(), completion: completion)

        let owning = Task { await engine.drain() }
        await completion.gate.waitUntilParked()
        await engine.drain()
        #expect(await harness.reload() != nil, "the second drain waited for the first")

        let quiet = Flag()
        let parked = Latch()
        let waiting = Task {
            await engine.untilQuiescent(parked: { Task { await parked.open() } })
            quiet.raise()
        }
        // The waiter is registered and suspended before anything is released: no sleep decides it.
        #expect(await parked.wait(within: 2), "untilQuiescent never parked")
        #expect(!quiet.isRaised, "quiescence was reported while the owning create was out")

        await completion.gate.open()
        await waiting.value
        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil, "quiescence came before the create finished")
        await owning.value
    }

    @Test("quiescence waits for an answer continuation's create, sent while the gate is closed")
    func quiescenceWaitsForAContinuation() async throws {
        let completion = BlockingCompletion()
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        let started = try await Gated.started(harness, confirmed: 0)
        let engine = harness.engine(gate: SchedulingGate(isOpen: false), completion: completion)

        let answering = Task {
            await engine.handle(Gated.answer(started, offset: 0, received: 1000))
        }
        await completion.gate.waitUntilParked()
        let quiet = Flag()
        let parked = Latch()
        let waiting = Task {
            await engine.untilQuiescent(parked: { Task { await parked.open() } })
            quiet.raise()
        }
        // The waiter is registered and suspended before anything is released: no sleep decides it.
        #expect(await parked.wait(within: 2), "untilQuiescent never parked")
        #expect(!quiet.isRaised, "quiescence was reported while a continuation was creating")

        await completion.gate.open()
        await waiting.value
        await answering.value
        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil)
    }

    @Test("a continuation holding a pre-delete snapshot sends no create once the claim is free")
    func preDeleteSnapshotSendsNoCreate() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")], repeating: .created(uid: "m1"))
        let harness = try await Harness.make(bytes: 1000, http: Gated.server())
        defer { harness.cleanUp() }
        let complete = try await Gated.started(harness, confirmed: 1000)
        let late = Late<OutboxEngine>()
        // The drain runs INSIDE the continuation's credential wait: it claims, creates, deletes
        // and releases while the continuation holds the manifest it read before any of that.
        let interfering = InterferingCredentials(Fixture.credentials()) {
            await late.value?.drain()
        }
        let engine = harness.engine(
            gate: SchedulingGate(), completion: completion, credentials: interfering
        )
        late.value = engine

        await engine.handle(Gated.answer(complete, offset: 1000, received: 1000))

        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil)
    }
}
