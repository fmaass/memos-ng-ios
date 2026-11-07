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
            uploads: BackgroundUploadScheduler(session: session),
            network: harness.network,
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: harness.preferencesName)!
            )
        )
        let uploadStarts = {
            harness.http.sessionAsks
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

    /// Where the repository keeps its record, taken by a directory: the real store's atomic write
    /// has nowhere to land, and it says so.
    private func refuseRecords(_ harness: Harness) throws {
        try FileManager.default.createDirectory(
            at: harness.root.appending(path: "outbox/withdrawal.json"),
            withIntermediateDirectories: false
        )
    }

    private func setPermissions(_ harness: Harness, root: Int, record: Int) throws {
        let outbox = harness.root.appending(path: "outbox")
        let file = outbox.appending(path: "withdrawal.json")
        try FileManager.default.setAttributes([.posixPermissions: record], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: root], ofItemAtPath: outbox.path)
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

    @Test("a record the disk refused still has its cancel issued, over both sessions, once")
    func aRefusedRecordIsStillCancelled() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Wake.server())
        defer { harness.cleanUp() }
        try refuseRecords(harness)
        let launch = UUID()
        let session = ScriptedUploadTaskSession(listing: [
            listing(7, harness.job, launch: launch, epoch: 2),
            // Minted at the epoch the sign-out moved to: the next account's.
            listing(8, harness.job, launch: launch, epoch: 3),
        ])
        let facade = outbox(harness, session: session, launch: launch)
        facade.recordWithdrawal(at: 3)
        try #require(
            harness.repository.withdrawals.pending() == nil, "the premise: the record never landed"
        )

        await facade.finishWithdrawal()

        #expect(session.cancelledIdentifiers == [7], "the withdrawn account's upload still sends")
        await facade.finishWithdrawal()
        #expect(session.cancelledIdentifiers == [7], "a cancel issued is not owed")
    }

    @Test("an older launch's record and a refused one are both cancelled, and the old one goes")
    func anOlderRecordAndARefusedOneAreBothCancelled() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Wake.server())
        defer { harness.cleanUp() }
        let dead = UUID()
        let launch = UUID()
        // A process that withdrew at its own epoch 3 ended before the cancel.
        try #require(
            harness.repository.withdrawals.record(OutboxWithdrawal(launch: dead, epoch: 3))
        )
        let session = ScriptedUploadTaskSession(listing: [
            listing(7, harness.job, launch: dead, epoch: 2),
            // This launch's, minted before its own withdrawal: the older record cannot reach it,
            // because epochs start again in every launch.
            listing(8, harness.job, launch: launch, epoch: 4),
            // Minted at the epoch this launch's sign-out moved to: the next account's.
            listing(9, harness.job, launch: launch, epoch: 5),
        ])
        let facade = outbox(harness, session: session, launch: launch)
        // A root the write can neither land in nor replace the old record through.
        try setPermissions(harness, root: 0o555, record: 0o444)
        defer { try? setPermissions(harness, root: 0o755, record: 0o644) }
        facade.recordWithdrawal(at: 5)
        try setPermissions(harness, root: 0o755, record: 0o644)
        try #require(
            harness.repository.withdrawals.pending() == OutboxWithdrawal(launch: dead, epoch: 3),
            "the premise: the new record never replaced the old one"
        )

        await facade.finishWithdrawal()

        #expect(Set(session.cancelledIdentifiers) == [7, 8])
        #expect(
            harness.repository.withdrawals.pending() == nil,
            "the older record would cancel this launch's valid uploads at the next launch"
        )
    }

    @Test("a refused record made while an earlier cancel is in flight outlives that cancel")
    func aRefusedRecordOutlivesAnEarlierCancel() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Wake.server())
        defer { harness.cleanUp() }
        try refuseRecords(harness)
        let launch = UUID()
        let session = ScriptedUploadTaskSession(listing: [
            listing(7, harness.job, launch: launch, epoch: 2),
            listing(8, harness.job, launch: launch, epoch: 4),
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
        facade.recordWithdrawal(at: 5)
        await listed.open()
        await finishing.value
        #expect(session.cancelledIdentifiers == [7])

        await facade.finishWithdrawal()
        #expect(
            Set(session.cancelledIdentifiers) == [7, 8],
            "the earlier cancel dropped a later withdrawal"
        )
    }
}

/// The app came to the foreground and the drain that started is over, within the deadline.
@MainActor
func becameActive(_ outbox: Outbox) async throws {
    let drain = outbox.appBecameActive()
    try await bounded("the foreground drain") { await drain.value }
}

/// Returns once the outbox's engine is quiescent, within the deadline: `wake` leaves only then.
@MainActor
func outboxQuiet(_ outbox: Outbox) async throws {
    try await bounded("the outbox going quiet") { @MainActor in
        await outbox.wake(holding: OutboxBackgroundCompletion().enterWake()) {}
    }
}

/// Runs `deliver` inside one wake of the upload session, and returns once the system's handler is
/// called — every answer the session delivered applied, the wake left — and the engine is quiet
/// after them. Each step is a handshake the code under test makes, and each is bounded.
@MainActor
func answersSettled(
    _ outbox: Outbox,
    box: OutboxBackgroundCompletion,
    delegate: UploadSessionDelegate,
    _ deliver: () throws -> Void
) async throws {
    let (called, call) = AsyncStream.makeStream(of: Void.self)
    let work = try #require(box.beginWake(for: OutboxUploadSession.identifier) { call.yield() })
    try deliver()
    delegate.urlSessionDidFinishEvents(
        forBackgroundURLSession: URLSession(configuration: .ephemeral)
    )
    try await bounded("the wake leaving") { @MainActor in await outbox.wake(holding: work) {} }
    try await bounded("the system's handler") { for await _ in called { return } }
    try await outboxQuiet(outbox)
}

/// The facade-level half of the whole-file pilot checklist (page 4065): each test names the line
/// it holds. The outbox is composed over a scripted upload session whose delegate the test keeps.
@MainActor
@Suite("Wake and withdrawal: the pilot checklist")
struct WakePilotChecklistTests {
    private struct Composed {
        let outbox: Outbox
        let session: ScriptedUploadTaskSession
        let delegate: UploadSessionDelegate
    }

    /// Reachable, hands out upload sessions, says where one stands, and creates memos.
    private static func server() -> ScriptedHTTP {
        ScriptedHTTP { request in
            switch (request.httpMethod ?? "", request.url?.path() ?? "") {
            case ("GET", "/health"):
                return OutboxHTTPResponse(statusCode: 200)
            case ("POST", "/api/uploads"):
                return ScriptedHTTP.session(uid: "u1", chunkSize: 5 * 1024 * 1024, received: 0)
            case ("HEAD", _):
                return OutboxHTTPResponse(statusCode: 200, headers: ["Upload-Offset": "0"])
            case ("POST", "/api/memos"):
                return ScriptedHTTP.json(["uid": "m1"], status: 201)
            default:
                return OutboxHTTPResponse(statusCode: 500)
            }
        }
    }

    /// The outbox `live` composes, as the process `launch`, with the real memo create.
    private func compose(
        _ harness: Harness,
        listing: [WholeTaskListing] = [],
        launch: UUID = UUID(),
        box: OutboxBackgroundCompletion = OutboxBackgroundCompletion(),
        onCancel: ScriptedUploadTaskSession.OnCancel = .leavesListing(after: 1)
    ) -> Composed {
        let session = ScriptedUploadTaskSession(listing: listing, onCancel: onCancel)
        let delegate = UploadSessionDelegate(completion: box)
        // The replace barrier's bound is spent on this clock, one pause at a time, never slept.
        let barrier = MutableClock(harness.now)
        let outbox = Outbox.composed(
            repository: harness.repository,
            credentials: harness.credentials,
            http: harness.http,
            uploads: BackgroundUploadScheduler(
                session: session, delegate: delegate, launch: launch,
                now: { barrier.now }, pause: { barrier.advance(11) }
            ),
            network: harness.network,
            preferences: UploadPreferences(
                defaults: UserDefaults(suiteName: harness.preferencesName)!
            )
        )
        return Composed(outbox: outbox, session: session, delegate: delegate)
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

    /// What the system hands the delegate when this task's whole file has arrived.
    private func success(_ created: ScriptedUploadTaskSession.Created, of job: UploadJob) throws
        -> WholeAnswer
    {
        let identity = try #require(WholeTaskIdentity(taskDescription: created.description))
        let file = try #require(job.files.first { $0.id == identity.fileID })
        return WholeAnswer(
            taskIdentifier: created.taskIdentifier, identity: identity, statusCode: 200,
            body: ScriptedHTTP.session(uid: "x", chunkSize: 1, received: Int(file.byteSize)).body
        )
    }

    private func memoCreates(_ harness: Harness) -> Int {
        harness.http.requests(method: "POST").filter { $0.url?.path() == "/api/memos" }.count
    }

    /// Line 1: a picture and a video handed off, the phone locked, both transfers finished in
    /// one wake of the upload session: one memo, the row gone, and the handler called once.
    @Test("line 1: a backgrounded picture and video end in one memo, no row, and one handler")
    func backgroundedPairEndsInOneMemo() async throws {
        let harness = try await Harness.make(bytes: 0, http: Self.server())
        defer { harness.cleanUp() }
        await harness.repository.delete(harness.job)
        let job = try await harness.repository.enqueue(
            content: "a picture and a video", visibility: "PRIVATE", capturedAt: harness.now,
            binding: Fixture.binding(),
            sources: [
                StagedSource(
                    url: try Fixture.file(in: harness.root, named: "picture.heic", bytes: 1000),
                    filename: "picture.heic", mime: "image/heic"
                ),
                StagedSource(
                    url: try Fixture.file(in: harness.root, named: "video.mov", bytes: 3000),
                    filename: "video.mov", mime: "video/quicktime"
                ),
            ]
        )
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let composed = compose(harness, box: box)
        try await becameActive(composed.outbox)
        #expect(composed.session.createdTasks.count == 2, "the premise: both files are handed off")
        composed.outbox.appEnteredBackground()

        var fired = 0
        let work = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { fired += 1 }
        )
        for created in composed.session.createdTasks {
            composed.delegate.deliver(try success(created, of: job))
        }
        composed.delegate.urlSessionDidFinishEvents(
            forBackgroundURLSession: URLSession(configuration: .ephemeral)
        )
        let outbox = composed.outbox
        try await bounded("the wake") { @MainActor in
            await outbox.wake(holding: work) { await outbox.start() }
        }

        #expect(memoCreates(harness) == 1)
        #expect(await harness.repository.job(job.id) == nil, "the row outlived its memo")
        #expect(fired == 1)
        box.sessionFinished(for: OutboxUploadSession.identifier)
        #expect(fired == 1, "one wake called its handler twice")
    }

    /// Line 9: the restore takes longer than the fallback. The handler is called once, by the
    /// fallback; the restore then lands and the memo is created under the capture's own key.
    @Test("line 9: a restore past the fallback: one handler, then the memo under the same key")
    func lateRestoreRecoversUnderTheSameKey() async throws {
        let completion = ScriptedCompletion([.created(uid: "m1")])
        let harness = try await Harness.make(bytes: 0, http: .standard())
        defer { harness.cleanUp() }
        let credentials = RestoringCredentials()
        let outbox = Wake.outbox(harness, credentials: credentials, completion: completion)
        let deadline = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await deadline.pass() })
        var fired = 0
        let (handled, handler) = AsyncStream.makeStream(of: Void.self)
        let work = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) {
                fired += 1
                handler.yield()
            }
        )
        box.sessionFinished(for: OutboxUploadSession.identifier)
        let wake = Task { await outbox.wake(holding: work) { await outbox.start() } }
        let restore = credentials.restored
        try await bounded("the restore parking") { await restore.waitUntilParked() }
        try await bounded("the fallback parking") { await deadline.waitUntilParked() }
        await deadline.open()
        try await bounded("the fallback calling the handler") { for await _ in handled { return } }
        #expect(fired == 1, "the fallback never fired the handler")
        #expect(completion.idempotencyKeys.isEmpty, "the premise: nothing was created yet")

        await credentials.restored.open()
        try await bounded("the wake") { await wake.value }
        #expect(completion.idempotencyKeys == [harness.job.idempotencyKey])
        #expect(await harness.reload() == nil, "the capture was not recovered")
        #expect(fired == 1)
    }

    /// Line 13: A signs out, and before the cancel it owes is issued B signs in and captures. The
    /// cancel, issued late, reaches A's uploads only; B's capture goes and becomes a memo.
    ///
    /// A's job has two tasks by then, both of this launch: task 7, listed at the start, and the
    /// one the first drain minted under epoch 0, before the sign-out moved the epoch to 3. Both
    /// predate the withdrawal and both are cancelled, so the cancellation is judged by whose job
    /// each cancelled task names, never by a count of one (MEMNG-673): every cancelled task is A's,
    /// and B's, minted under the epoch the withdrawal moved to, is not among them.
    @Test("line 13: a capture made while the last account's cancel is delayed still goes")
    func captureDuringDelayedCancelRecovers() async throws {
        let harness = try await Harness.make(http: Self.server())
        defer { harness.cleanUp() }
        let launch = UUID()
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let parked = listing(7, harness.job, launch: launch, epoch: 2)
        let composed = compose(harness, listing: [parked], launch: launch, box: box)
        try await becameActive(composed.outbox)
        // A's sign-out: recorded at the epoch it moved to, its cancel not yet issued.
        composed.outbox.recordWithdrawal(at: 3)
        harness.credentials.set(Fixture.credentials(owner: "brenda", token: "pat-b"))
        for _ in 0..<3 { harness.credentials.supersede() }
        let capture = try await harness.repository.enqueue(
            content: "brenda's", visibility: "PRIVATE", capturedAt: harness.now,
            binding: Fixture.binding(owner: "brenda"),
            sources: [
                StagedSource(
                    url: try Fixture.file(in: harness.root, named: "b.heic", bytes: 500),
                    filename: "b.heic", mime: "image/heic"
                )
            ]
        )
        await composed.outbox.drain()
        let sent = try #require(
            composed.session.createdTasks.first {
                WholeTaskIdentity(taskDescription: $0.description)?.jobID == capture.id
            },
            "B's capture was never handed off"
        )

        // The delayed cancel is issued now, with B's upload already listed beside A's.
        await composed.outbox.finishWithdrawal()

        let cancelled = composed.session.cancelledIdentifiers
        #expect(!cancelled.contains(sent.taskIdentifier), "B's upload was cancelled with A's")
        #expect(cancelled.contains(7), "A's listed upload was left to send")
        var descriptions: [Int: String?] = [parked.taskIdentifier: parked.taskDescription]
        for created in composed.session.createdTasks {
            descriptions[created.taskIdentifier] = created.description
        }
        for identifier in cancelled {
            let identity = try #require(
                WholeTaskIdentity(taskDescription: descriptions[identifier] ?? nil),
                "cancelled task \(identifier) names no whole-task identity"
            )
            #expect(identity.jobID == harness.job.id, "task \(identifier), not A's, was cancelled")
        }
        let minted = composed.session.createdTasks.filter {
            WholeTaskIdentity(taskDescription: $0.description)?.jobID == harness.job.id
        }
        #expect(!minted.isEmpty, "the premise: A's drain minted a task before the sign-out")
        for task in minted {
            #expect(cancelled.contains(task.taskIdentifier), "A's minted upload was left to send")
        }
        try await answersSettled(composed.outbox, box: box, delegate: composed.delegate) {
            composed.delegate.deliver(try success(sent, of: capture))
        }
        #expect(
            await harness.repository.job(capture.id) == nil, "B's capture never became a memo"
        )
    }

    /// Line 19: three tasks under a choice that no longer stands, each slow to cancel, while the
    /// gate is closed and another capture only needs its memo. The wake calls its handler once,
    /// after that memo; the three files go again once the app is active and the tasks have ended
    /// — two first, within the upload budget, the third once one of them is done — and make the
    /// memo.
    @Test("line 19: three slow cancels under a closed gate: one handler, then the files recover")
    func slowCancelsUnderAClosedGate() async throws {
        let harness = try await Harness.make(
            bytes: 0, http: Self.server(), allowsMobileData: true
        )
        defer { harness.cleanUp() }
        await harness.repository.delete(harness.job)
        let sources = try (0..<3).map { index in
            StagedSource(
                url: try Fixture.file(in: harness.root, named: "p\(index).heic", bytes: 400),
                filename: "p\(index).heic", mime: "image/heic"
            )
        }
        var row = try await harness.repository.enqueue(
            content: "three", visibility: "PRIVATE", capturedAt: harness.now,
            binding: Fixture.binding(), sources: sources
        )
        row.transport = .whole
        row.state = .uploading
        for index in row.files.indices { row.files[index].uploadUID = "u\(index)" }
        try await harness.repository.save(row)
        let finished = try await Wake.completeRow(in: harness)
        let launch = UUID()
        // Each handed off before mobile data was allowed.
        let listed = row.files.enumerated().map { index, file in
            WholeTaskListing(
                taskIdentifier: 70 + index,
                taskDescription: WholeTaskIdentity(
                    jobID: row.id, fileID: file.id, attempt: 0, launch: launch, epoch: 0
                ).taskDescription,
                access: WholeTaskNetworkAccess.policy(allowsMobileData: false),
                state: .running
            )
        }
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let composed = compose(
            harness, listing: listed, launch: launch, box: box, onCancel: .staysListed
        )
        var fired = 0
        let work = try #require(
            box.beginWake(for: OutboxUploadSession.identifier) { fired += 1 }
        )
        box.sessionFinished(for: OutboxUploadSession.identifier)

        let outbox = composed.outbox
        try await bounded("the wake") { @MainActor in
            await outbox.wake(holding: work) { await outbox.start() }
        }

        #expect(fired == 1, "the wake never called its handler")
        #expect(await harness.repository.job(finished.id) == nil, "the ready memo was not made")
        #expect(Set(composed.session.cancelledIdentifiers) == [70, 71, 72])
        #expect(composed.session.createdTasks.isEmpty, "a closed gate handed a file off")

        try await becameActive(composed.outbox)
        try await answersSettled(composed.outbox, box: box, delegate: composed.delegate) {
            for index in 0..<3 {
                composed.session.forget(70 + index)
                composed.delegate.complete(
                    taskIdentifier: 70 + index, taskDescription: listed[index].taskDescription,
                    statusCode: nil, errorDescription: "cancelled"
                )
            }
        }
        // Recovered within the upload budget: two places, so two of the three go first. Each
        // successor is sent once its old task has ended, on the scheduler's own time.
        let session = composed.session
        try await bounded("two files going again") { await session.untilCreated(2) }
        let first = composed.session.createdTasks
        #expect(first.count == 2, "more files went than the budget has places")

        try await answersSettled(composed.outbox, box: box, delegate: composed.delegate) {
            for created in first {
                composed.session.forget(created.taskIdentifier)
                composed.delegate.deliver(try success(created, of: row))
            }
        }
        try await bounded("the third file going") { await session.untilCreated(3) }
        let all = composed.session.createdTasks
        #expect(all.count == 3, "a file went more than once")
        let carried = all.compactMap { WholeTaskIdentity(taskDescription: $0.description)?.fileID }
        #expect(Set(carried) == Set(row.files.map(\.id)), "a file went twice, or one never went")
        let third = try #require(all.dropFirst(2).first)
        try await answersSettled(composed.outbox, box: box, delegate: composed.delegate) {
            composed.session.forget(third.taskIdentifier)
            composed.delegate.deliver(try success(third, of: row))
        }
        #expect(await harness.repository.job(row.id) == nil, "the three files never made a memo")
        #expect(fired == 1)
    }

    /// Line 25: A's upload parked on a network it may not use, a sign-out whose cancel the dying
    /// process never issued, a relaunch signed out, then the network A may use comes back.
    @Test("line 25: a signed-out relaunch cancels A's parked upload; reconnecting sends nothing")
    func signedOutRelaunchSendsNothingOnReconnect() async throws {
        let harness = try await Harness.make(
            bytes: 1000, http: Self.server(), credentials: nil,
            network: StubNetworkPath(.cellular)
        )
        defer { harness.cleanUp() }
        let dead = UUID()
        compose(harness, launch: dead).outbox.recordWithdrawal(at: 3)
        let relaunched = compose(
            harness, listing: [listing(7, harness.job, launch: dead, epoch: 2)]
        )
        await relaunched.outbox.adopt()
        try await becameActive(relaunched.outbox)
        await harness.network.move(to: .wifi)
        await relaunched.outbox.drain()

        #expect(relaunched.session.cancelledIdentifiers == [7], "A's upload was left to send")
        #expect(harness.http.requests.isEmpty, "something went out with nobody signed in")
        #expect(relaunched.session.createdTasks.isEmpty)
        #expect(await harness.reload() != nil, "A's capture was lost")
    }

    /// Line 28: a withdrawal record outlives a launch that put B's capture on the whole lane. The
    /// next launch's cancel reaches B's upload as well; B's file goes again and makes one memo.
    @Test("line 28: an older record's extra cancel of B's upload recovers into one memo")
    func extraCancellationRecovers() async throws {
        let harness = try await Harness.make(bytes: 1000, http: Self.server())
        defer { harness.cleanUp() }
        try #require(
            harness.repository.withdrawals.record(OutboxWithdrawal(launch: UUID(), epoch: 3))
        )
        var row = try #require(await harness.reload())
        row.transport = .whole
        row.state = .uploading
        row.files[0].uploadUID = "u1"
        try await harness.repository.save(row)
        let never = TestGate()
        let box = OutboxBackgroundCompletion(fallback: { await never.pass() })
        let relaunched = compose(
            harness, listing: [listing(8, harness.job, launch: UUID(), epoch: 1)], box: box
        )

        await relaunched.outbox.adopt()
        #expect(
            relaunched.session.cancelledIdentifiers == [8], "the premise: B's upload was cancelled"
        )
        #expect(harness.repository.withdrawals.pending() == nil)
        try await becameActive(relaunched.outbox)
        let sent = try #require(relaunched.session.createdTasks.first, "B's file never went again")
        try await answersSettled(relaunched.outbox, box: box, delegate: relaunched.delegate) {
            relaunched.delegate.deliver(try success(sent, of: row))
        }

        #expect(await harness.reload() == nil, "no memo")
        #expect(memoCreates(harness) == 1)
    }
}
