import Foundation
import MemosOutbox
import Testing

/// Credentials that exist only once the session has been restored, and the restore is held on a
/// gate: the cold background wake, where nobody has signed in on this launch yet.
private final class RestoringCredentials: OutboxCredentialsProviding, @unchecked Sendable {
    let restored = TestGate()

    func currentCredentials() async -> OutboxCredentials? {
        await restored.pass()
        return Fixture.credentials()
    }

    func isCurrent(_ credentials: OutboxCredentials) -> Bool { true }

    func stillCurrent(epoch: Int) -> Bool { true }
}

/// A completion whose FIRST create parks on a gate until the test opens it. Every create is
/// recorded as it arrives, before it parks, because arriving is what a send is.
private final class ParkingCompletion: MemoCompleting, @unchecked Sendable {
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

private final class Raised: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// What happened, in the order it happened, across executors.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func note(_ event: String) { lock.withLock { recorded.append(event) } }
    var all: [String] { lock.withLock { recorded } }
}

/// The production upload scheduler, with its attachment held on a gate and recorded: how a test
/// can stand inside `adopt()` and ask whether a drain has started.
private actor ParkingAttachUploads: OutboxUploadScheduling {
    private let inner: BackgroundUploadScheduler
    private let gate: TestGate
    private let events: Events
    nonisolated let launch: UUID

    init(_ inner: BackgroundUploadScheduler, gate: TestGate, events: Events) {
        self.inner = inner
        self.gate = gate
        self.events = events
        self.launch = inner.launch
    }

    func attach(_ handler: any WholeAnswerHandling) async {
        await gate.pass()
        await inner.attach(handler)
        events.note("uploads attached")
    }

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
        await inner.upload(
            request, fromFile: file, for: ref, attempt: attempt, under: authority,
            issuedUnder: epoch
        )
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
        await inner.replace(task, under: authority, onSettled: onSettled, successor: successor)
    }

    func reexamineDeferred() async -> [WholeTask] { await inner.reexamineDeferred() }
}

private enum Wake {
    /// A capture with no files: the planner's next step for it is the memo create, which a wake
    /// may send.
    static func completeRow(in harness: Harness) async throws -> UploadJob {
        try await harness.repository.enqueue(
            content: "finished",
            visibility: "PRIVATE",
            capturedAt: harness.now.addingTimeInterval(-60),
            binding: Fixture.binding(),
            sources: []
        )
    }

    /// The facade as a background launch has it: the gate closed, because the app is not active.
    @MainActor
    static func outbox(
        _ harness: Harness,
        credentials: any OutboxCredentialsProviding,
        completion: any MemoCompleting
    ) -> Outbox {
        let clock = harness.clock
        return Outbox(
            repository: harness.repository,
            credentials: credentials,
            http: harness.http,
            scheduler: harness.scheduler,
            completion: completion,
            network: harness.network,
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: harness.preferencesName)!
            ),
            clock: { clock.now },
            schedulingGate: SchedulingGate(isOpen: false)
        )
    }

    /// Reachable, hands out upload sessions and creates memos.
    static func server() -> ScriptedHTTP {
        ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/uploads"):
                return ScriptedHTTP.session(uid: "u1", chunkSize: 5 * 1024 * 1024, received: 0)
            case ("POST", "/api/memos"):
                return ScriptedHTTP.json(["uid": "m1"], status: 201)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
    }

    /// Waits, bounded, for something another executor does. A mutation that never lets it happen
    /// turns the test red instead of parking the bundle.
    @MainActor
    static func eventually(_ condition: @MainActor () async -> Bool) async throws -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

@Suite("Wake barrier: the system's handler waits for the wake's own work")
@MainActor
struct WakeBarrierTests {
    @Test("a blocked restore holds the handler until the restore AND the create are through")
    func restorationBlocked() async throws {
        let completion = ParkingCompletion()
        let harness = try await Harness.make(bytes: 0, http: .standard())
        defer { harness.cleanUp() }
        let credentials = RestoringCredentials()
        let outbox = Wake.outbox(harness, credentials: credentials, completion: completion)
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        var fired = 0

        let work = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { fired += 1 }
        )
        box.sessionFinished(for: OutboxUploadSession.identifier)
        #expect(fired == 0, "the handler fired while the wake had not even started")
        let wake = Task { await outbox.wake(holding: work) { await outbox.start() } }

        await credentials.restored.waitUntilParked()
        #expect(fired == 0, "the handler fired while the restore was still running")
        await credentials.restored.open()
        await completion.gate.waitUntilParked()
        #expect(fired == 0, "the handler fired while the memo create was still out")
        await completion.gate.open()
        await wake.value

        #expect(fired == 1)
        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil, "the handler fired before the create was applied")
        // The fallback coming late finds nothing left to fire.
        await never.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(fired == 1)
    }

    @Test("a restore that never comes: the fallback fires the handler, exactly once")
    func restorationNeverComes() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(bytes: 0, http: .standard())
        defer { harness.cleanUp() }
        let credentials = RestoringCredentials()
        let outbox = Wake.outbox(harness, credentials: credentials, completion: completion)
        let deadline = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await deadline.pass() })
        var fired = 0

        let work = try #require(
            box.beginWake(for: OutboxSession.identifier) { fired += 1 }
        )
        box.sessionFinished(for: OutboxSession.identifier)
        let wake = Task { await outbox.wake(holding: work) { await outbox.start() } }
        await credentials.restored.waitUntilParked()
        await deadline.waitUntilParked()
        #expect(fired == 0)

        await deadline.open()
        #expect(try await Wake.eventually { fired == 1 }, "the fallback never fired the handler")
        #expect(!box.isPending(for: OutboxSession.identifier))

        // The restore landing after all: the wake ends, and the handler is not fired again.
        await credentials.restored.open()
        await wake.value
        #expect(fired == 1)
    }

    @Test("the owning drain: the wake's start returns, the handler waits for the owner's create")
    func owningDrain() async throws {
        let completion = ParkingCompletion()
        let harness = try await Harness.make(bytes: 0, http: .standard())
        defer { harness.cleanUp() }
        let outbox = Wake.outbox(harness, credentials: harness.credentials, completion: completion)
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        var fired = 0

        // A confirmation's drain, started before the system woke anyone, owns the create.
        let owning = Task { await outbox.start() }
        await completion.gate.waitUntilParked()

        let work = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { fired += 1 }
        )
        box.sessionFinished(for: OutboxUploadSession.identifier)
        let started = Raised()
        let wake = Task {
            await outbox.wake(holding: work) {
                await outbox.start()
                started.raise()
            }
        }
        #expect(try await Wake.eventually { started.isRaised }, "the wake's start never returned")
        #expect(fired == 0, "the handler fired while the owning drain's create was out")

        await completion.gate.open()
        await wake.value
        #expect(fired == 1)
        await owning.value
        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        box.sessionFinished(for: OutboxUploadSession.identifier)
        #expect(fired == 1, "one wake fired its handler twice")
    }

    @Test("each session's wake fires its own handler and never the other's")
    func routedByIdentifier() throws {
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        var chunk = 0
        var whole = 0

        #expect(box.beginWake(for: "live.discomarder.memosng.elsewhere") {} == nil)

        let wholeWake = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { whole += 1 }
        )
        box.sessionFinished(for: OutboxSession.identifier)
        wholeWake.leave()
        #expect(whole == 0, "the chunk session finishing released the upload session's handler")
        box.sessionFinished(for: OutboxUploadSession.identifier)
        #expect(whole == 1)
        #expect(chunk == 0)

        let chunkWake = try #require(
            box.beginWake(for: OutboxSession.identifier) { chunk += 1 }
        )
        box.sessionFinished(for: OutboxUploadSession.identifier)
        chunkWake.leave()
        #expect(chunk == 0, "the upload session finishing released the chunk session's handler")
        box.sessionFinished(for: OutboxSession.identifier)
        #expect(chunk == 1)
        #expect(whole == 1)
    }

    @Test("a wake from another entry point holds the handler until it, too, is over")
    func everyWakeHoldsTheHandler() throws {
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        var whole = 0

        let refresh = box.enterWake()
        let wake = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { whole += 1 }
        )
        box.sessionFinished(for: OutboxUploadSession.identifier)
        wake.leave()
        wake.leave()
        #expect(whole == 0, "a second leave of one wake released another wake's hold")
        refresh.leave()
        #expect(whole == 1)
    }

    @Test("the upload session's delegate finishing goes through the barrier, not around it")
    func uploadDelegateFinishesThroughTheBarrier() async throws {
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let delegate = UploadSessionDelegate(completion: box)
        var whole = 0
        let wake = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { whole += 1 }
        )

        delegate.urlSessionDidFinishEvents(
            forBackgroundURLSession: URLSession(configuration: .ephemeral)
        )
        #expect(
            try await Wake.eventually {
                box.hasFinished(OutboxUploadSession.identifier) || whole > 0
            }
        )
        #expect(whole == 0, "the delegate fired the handler while the wake still held it")
        wake.leave()
        #expect(whole == 1)
    }

    @Test("the chunk session's delegate finishing goes through the barrier, not around it")
    func chunkDelegateFinishesThroughTheBarrier() async throws {
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let delegate = OutboxSessionDelegate(completion: box)
        var chunk = 0
        let wake = try #require(box.beginWake(for: OutboxSession.identifier) { chunk += 1 })

        delegate.urlSessionDidFinishEvents(
            forBackgroundURLSession: URLSession(configuration: .ephemeral)
        )
        #expect(
            try await Wake.eventually { box.hasFinished(OutboxSession.identifier) || chunk > 0 }
        )
        #expect(chunk == 0, "the delegate fired the handler while the wake still held it")
        wake.leave()
        #expect(chunk == 1)
    }
}

@Suite("Composition: both sessions, the gate the app feeds")
@MainActor
struct OutboxCompositionTests {
    @Test("adopt attaches both sessions' delegates before any drain sends")
    func adoptAttachesBoth() async throws {
        let harness = try await Harness.make(bytes: 1000, http: .standard())
        defer { harness.cleanUp() }
        let events = Events()
        harness.http.beforeSend = { request in
            events.note("send \(request.httpMethod ?? "") \(request.url?.path() ?? "")")
        }
        let attaching = TestGate()
        let uploads = ParkingAttachUploads(
            BackgroundUploadScheduler(session: ScriptedUploadTaskSession()),
            gate: attaching, events: events
        )
        let clock = harness.clock
        let outbox = Outbox(
            repository: harness.repository,
            credentials: harness.credentials,
            http: harness.http,
            scheduler: harness.scheduler,
            completion: ScriptedCompletion([.created(uid: "m1")]),
            network: harness.network,
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: harness.preferencesName)!
            ),
            clock: { clock.now },
            attachScheduler: { _ in events.note("chunks attached") },
            uploads: uploads
        )

        let started = Task { await outbox.start() }
        await attaching.waitUntilParked()
        #expect(events.all == ["chunks attached"])
        // A second way in, arriving while the upload session is still being attached, joins it.
        let drained = Task { await outbox.drain() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.http.requests.isEmpty, "a drain sent before both delegates were attached")

        await attaching.open()
        await started.value
        await drained.value
        let all = events.all
        #expect(Array(all.prefix(2)) == ["chunks attached", "uploads attached"])
        #expect(all.dropFirst(2).allSatisfy { $0.hasPrefix("send ") })
        #expect(all.count > 2, "nothing was drained after adoption")
    }

    @Test("the composed outbox: closed until active, then a new capture goes on the whole lane")
    func composedGoesWholeWhenActive() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Wake.server())
        defer { harness.cleanUp() }
        let session = ScriptedUploadTaskSession()
        let outbox = Outbox.composed(
            repository: harness.repository,
            credentials: harness.credentials,
            http: harness.http,
            chunks: harness.scheduler,
            attachChunks: { _ in },
            uploads: BackgroundUploadScheduler(session: session),
            network: harness.network,
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: harness.preferencesName)!
            )
        )
        let uploadStarts = {
            harness.http.requests(method: "POST").filter { $0.url?.path() == "/api/uploads" }
        }

        // Launched, and not yet active: nothing new starts.
        await outbox.start()
        #expect(uploadStarts().isEmpty, "work started before the app was ever active")
        #expect(session.createdTasks.isEmpty)
        #expect(try #require(await harness.reload()).transport == nil)

        await outbox.appBecameActive().value
        let saved = try #require(await harness.reload())
        #expect(saved.transport == .whole)
        #expect(uploadStarts().count == 1)
        #expect(session.createdTasks.count == 1)
        #expect(harness.scheduler.uploads.isEmpty, "the capture took the chunk lane")

        // Backgrounded: the gate closes at once, so a drain starts nothing new.
        outbox.appEnteredBackground()
        let second = try await Wake.completeRow(in: harness)
        await outbox.drain()
        #expect(uploadStarts().count == 1)
        #expect(await harness.repository.job(second.id) == nil, "a closed gate held the create")
    }
}

@MainActor
@Suite("A withdrawal outlives the process that recorded it")
struct WithdrawalRecordTests {
    /// The outbox a launch composes over `session`, as the process `launch` names.
    private func outbox(
        _ harness: Harness, session: ScriptedUploadTaskSession, launch: UUID
    ) -> Outbox {
        Outbox.composed(
            repository: harness.repository,
            credentials: harness.credentials,
            http: harness.http,
            chunks: harness.scheduler,
            attachChunks: { _ in },
            uploads: BackgroundUploadScheduler(session: session, launch: launch),
            network: harness.network,
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: harness.preferencesName)!
            )
        )
    }

    private func listing(
        _ id: Int, _ job: UploadJob, launch: UUID, epoch: Int
    ) -> WholeTaskListing {
        WholeTaskListing(
            taskIdentifier: id,
            taskDescription: WholeTaskIdentity(
                jobID: job.id, fileID: job.files[0].id, attempt: 0, launch: launch, epoch: epoch
            ).taskDescription
        )
    }

    @Test("a cancel the dying process never issued is issued by the next launch, signed out")
    func aSignedOutLaunchFinishesTheWithdrawal() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: Wake.server(), credentials: nil
        )
        defer { harness.cleanUp() }
        let dead = UUID()
        // The sign-out moved the epoch to 3 and recorded it; the process ended before any cancel.
        outbox(harness, session: ScriptedUploadTaskSession(), launch: dead)
            .recordWithdrawal(at: 3)
        #expect(
            harness.repository.withdrawals.pending() == OutboxWithdrawal(launch: dead, epoch: 3),
            "the premise: the withdrawal is on disk"
        )

        // A fresh process over the same queue, nobody signed in, and the system still carrying
        // the withdrawn account's uploads.
        let session = ScriptedUploadTaskSession(listing: [
            listing(7, harness.job, launch: dead, epoch: 2),
            listing(8, harness.job, launch: UUID(), epoch: 9),
            WholeTaskListing(taskIdentifier: 9, taskDescription: "not|a|whole|task"),
            // Minted by the dying process after the withdrawal: the next account's.
            listing(10, harness.job, launch: dead, epoch: 3),
        ])
        await outbox(harness, session: session, launch: UUID()).adopt()

        #expect(Set(session.cancelledIdentifiers) == [7, 8, 9])
        #expect(harness.scheduler.everyTaskCancellations == 1, "the chunk lane's too")
        #expect(harness.repository.withdrawals.pending() == nil, "a cancel issued is not owed")
    }

    @Test("the record stays until the cancel is issued, and a later one outlives an earlier cancel")
    func theRecordOutlivesItsCancel() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Wake.server())
        defer { harness.cleanUp() }
        let launch = UUID()
        let session = ScriptedUploadTaskSession(listing: [
            listing(7, harness.job, launch: launch, epoch: 2)
        ])
        let facade = outbox(harness, session: session, launch: launch)
        facade.recordWithdrawal(at: 3)
        let listed = TestGate()
        session.holdNextListing(on: listed)

        let finishing = Task { @MainActor in await facade.finishWithdrawal() }
        // Bounded, so a withdrawal that never lists turns this red instead of parking the bundle.
        let parked = try await Wake.eventually { session.listingCount > 0 }
        if !parked { await listed.open() }
        try #require(parked, "the withdrawal never asked the session what it carries")
        #expect(session.cancelledIdentifiers.isEmpty, "the premise: no cancel is issued yet")
        #expect(
            harness.repository.withdrawals.pending() == OutboxWithdrawal(launch: launch, epoch: 3),
            "the record went before its cancel was issued"
        )
        // Another withdrawal lands while the first one's cancel is in flight.
        facade.recordWithdrawal(at: 5)
        await listed.open()
        await finishing.value

        #expect(session.cancelledIdentifiers == [7])
        #expect(
            harness.repository.withdrawals.pending() == OutboxWithdrawal(launch: launch, epoch: 5),
            "the earlier cancel cleared a later withdrawal"
        )
        await facade.finishWithdrawal()
        #expect(harness.repository.withdrawals.pending() == nil)
    }
}
