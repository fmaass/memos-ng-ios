import Foundation
import MemosOutbox
import Testing

/// A protocol that answers nothing, so a task that was started stays started and no byte leaves
/// the machine. These tasks exist only to be read back through the real adapter.
private final class SilentUploadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {}

    override func stopLoading() {}
}

/// Collects what the delegate hands on, in arrival order.
private actor RecordingWholeHandler: WholeAnswerHandling {
    private(set) var received: [WholeAnswer] = []

    func handle(_ answer: WholeAnswer) async { received.append(answer) }
}

private enum Upload {
    static let base = URL(string: "https://memos.example.invalid")!

    static func identity(attempt: Int = 0, launch: UUID = UUID()) -> WholeTaskIdentity {
        WholeTaskIdentity(
            jobID: UUID(), fileID: UUID(), attempt: attempt, launch: launch, epoch: 3
        )
    }

    static func request(allowsMobileData: Bool = false) -> URLRequest {
        OutboxRequests.wholeUpload(
            baseURL: base, token: "t", uploadUID: "u1", allowsMobileData: allowsMobileData
        )
    }

    static func silentSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentUploadProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A clock the barrier's pause moves by one second, so the bound is reached by listing, never
    /// by sleeping.
    static func scheduler(
        on session: ScriptedUploadTaskSession,
        delegate: UploadSessionDelegate = UploadSessionDelegate(),
        launch: UUID = UUID(),
        clock: MutableClock = MutableClock(Date(timeIntervalSince1970: 1_760_000_000))
    ) -> BackgroundUploadScheduler {
        BackgroundUploadScheduler(
            session: session,
            delegate: delegate,
            launch: launch,
            now: { clock.now },
            pause: {
                clock.advance(1)
                await Task.yield()
            }
        )
    }

    /// Counts each build — where a caller would write the bumped term — and, when handed a gate,
    /// parks on it mid-build.
    static func successor(
        counter: Counter, parkingOn gate: TestGate? = nil
    ) -> @Sendable () async -> WholeSuccessor? {
        {
            counter.increment()
            await gate?.pass()
            return WholeSuccessor(
                request: request(allowsMobileData: true),
                file: URL(fileURLWithPath: "/dev/null"),
                ref: WholeFileRef(jobID: UUID(), fileID: UUID()),
                attempt: 1,
                epoch: 4
            )
        }
    }

    /// Waits, bounded, for the scripted session to have created `count` tasks.
    static func waitForCreated(_ count: Int, on session: ScriptedUploadTaskSession) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while session.createdTasks.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return session.createdTasks.count >= count
    }
}

@Suite("Whole lane: the upload session's identity and requests")
struct UploadSessionIdentityTests {
    /// Two sessions in one process are allowed only under two identifiers: the system hands a
    /// task's answer to whichever session carries its identifier.
    @Test("the upload session is a second session: its own identifier, launch events on")
    func configuration() {
        let configuration = OutboxUploadSession.backgroundConfiguration(
            appGroup: "group.test.invalid"
        )
        #expect(configuration.identifier == "live.discomarder.memosng.uploads")
        #expect(configuration.identifier != OutboxSession.identifier)
        #expect(OutboxUploadSession.identifier != OutboxSession.identifier)
        #expect(OutboxSession.identifier == "live.discomarder.memosng.outbox")
        #expect(configuration.sharedContainerIdentifier == "group.test.invalid")
        #expect(configuration.sessionSendsLaunchEvents == true)
        #expect(configuration.isDiscretionary == false)
        #expect(configuration.allowsConstrainedNetworkAccess == false)
        // The session stays permissive: the person's choice rides on each request.
        #expect(configuration.allowsCellularAccess == true)
        #expect(configuration.allowsExpensiveNetworkAccess == true)
    }

    @Test("a whole upload carries the person's choice on the request", arguments: [true, false])
    func perRequestFlags(allowsMobileData: Bool) {
        let request = OutboxRequests.wholeUpload(
            baseURL: Upload.base, token: "tok", uploadUID: "u9", allowsMobileData: allowsMobileData
        )
        #expect(request.allowsCellularAccess == allowsMobileData)
        #expect(request.allowsExpensiveNetworkAccess == allowsMobileData)
        #expect(request.allowsConstrainedNetworkAccess == false, "Low Data Mode is never allowed")
        #expect(
            WholeTaskNetworkAccess(request: request)
                == .policy(allowsMobileData: allowsMobileData)
        )
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.path() == "/api/uploads/u9")
        #expect(request.value(forHTTPHeaderField: "Upload-Offset") == "0")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.httpBody == nil, "the body is the file handed to the session")
    }

    @Test("every task state the session reports is named")
    func taskStates() {
        #expect(WholeTaskState(URLSessionTask.State.running) == .running)
        #expect(WholeTaskState(URLSessionTask.State.suspended) == .suspended)
        #expect(WholeTaskState(URLSessionTask.State.canceling) == .canceling)
        #expect(WholeTaskState(URLSessionTask.State.completed) == .completed)
    }
}

@Suite("Whole lane: the real task adapter")
struct UploadTaskAdapterTests {
    @Test("the adapter lists raw tasks: description, the original request's flags, state")
    func listsRawTasks() async throws {
        let session = Upload.silentSession()
        defer { session.invalidateAndCancel() }
        let whole = Upload.identity()
        let wifiOnly = session.dataTask(with: Upload.request(allowsMobileData: false))
        wifiOnly.taskDescription = whole.taskDescription
        let cellular = session.dataTask(with: Upload.request(allowsMobileData: true))
        cellular.taskDescription = "not one of ours"
        wifiOnly.resume()
        cellular.resume()

        let listed = await URLSessionUploadTaskSession(session: session).allTasks()

        let first = try #require(listed.first { $0.taskIdentifier == wifiOnly.taskIdentifier })
        #expect(first.taskDescription == whole.taskDescription)
        #expect(first.access == .policy(allowsMobileData: false))
        #expect(first.state == .running)
        let second = try #require(listed.first { $0.taskIdentifier == cellular.taskIdentifier })
        #expect(second.taskDescription == "not one of ours", "an unreadable task is listed raw")
        #expect(second.access == .policy(allowsMobileData: true))
    }

    @Test("the adapter starts a described upload from a file, and a cancel ends it")
    func startsAndCancels() async throws {
        let session = Upload.silentSession()
        defer { session.invalidateAndCancel() }
        let directory = try Fixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Fixture.file(in: directory, named: "original.bin", bytes: 64)
        let adapter = URLSessionUploadTaskSession(session: session)
        let identity = Upload.identity()

        let id = adapter.uploadTask(
            with: Upload.request(), fromFile: file, description: identity.taskDescription
        )

        let started = try #require(await adapter.allTasks().first { $0.taskIdentifier == id })
        #expect(started.taskDescription == identity.taskDescription)
        #expect(started.state == .running, "the adapter did not start the task")

        await adapter.cancel(taskIdentifier: id)
        let deadline = Date().addingTimeInterval(2)
        var stillSending = true
        while stillSending, Date() < deadline {
            stillSending = await adapter.allTasks().contains {
                $0.taskIdentifier == id && $0.state == .running
            }
            if stillSending { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(!stillSending, "the cancel never reached the task")
    }
}

@Suite("Whole lane: the session delegate")
struct UploadSessionDelegateTests {
    @Test("answers delivered before adoption are replayed, in order, not dropped")
    func replayBeforeAttach() async {
        let delegate = UploadSessionDelegate()
        let handler = RecordingWholeHandler()
        let identity = Upload.identity()
        delegate.deliver(WholeAnswer(taskIdentifier: 1, identity: identity, statusCode: 500))
        delegate.deliver(WholeAnswer(taskIdentifier: 2, identity: identity, statusCode: 200))
        #expect(await handler.received.isEmpty, "the premise: nothing was attached yet")

        await delegate.attach(handler)

        #expect(await handler.received.map(\.taskIdentifier) == [1, 2])
    }

    /// A success and a terminal failure for one task: exactly one delivery wins, and it is decided
    /// where the callback lands, before any hop.
    @Test("a duplicate terminal answer for one task is delivered once")
    func duplicateTerminalAnswerIsDeliveredOnce() async {
        let delegate = UploadSessionDelegate()
        let handler = RecordingWholeHandler()
        let identity = Upload.identity()

        let first = delegate.complete(
            taskIdentifier: 41, taskDescription: identity.taskDescription,
            statusCode: 200, errorDescription: nil
        )
        let second = delegate.complete(
            taskIdentifier: 41, taskDescription: identity.taskDescription,
            statusCode: nil, errorDescription: "the connection was lost"
        )
        await delegate.attach(handler)

        #expect(first)
        #expect(!second, "the second answer for one task was taken as well")
        let received = await handler.received
        #expect(received.count == 1, "one task's answer was delivered \(received.count) times")
        #expect(received.first?.statusCode == 200, "the first answer is the one that wins")
        #expect(received.first?.identity == identity)
    }

    /// The same, through the callback URLSession itself calls, with a real task and a body.
    @Test("the session's own terminal callback, called twice for one task, delivers once")
    func realCallbackTwiceDeliversOnce() async throws {
        let session = Upload.silentSession()
        defer { session.invalidateAndCancel() }
        let delegate = UploadSessionDelegate()
        let handler = RecordingWholeHandler()
        let identity = Upload.identity()
        let task = session.dataTask(with: Upload.request())
        task.taskDescription = identity.taskDescription

        delegate.urlSession(session, dataTask: task, didReceive: Data("{\"bytes".utf8))
        delegate.urlSession(session, dataTask: task, didReceive: Data("_received\":9}".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        await delegate.attach(handler)

        let received = await handler.received
        #expect(received.count == 1, "one task's answer was delivered \(received.count) times")
        let answer = try #require(received.first)
        #expect(String(decoding: answer.body, as: UTF8.self) == "{\"bytes_received\":9}")
        #expect(answer.errorDescription == nil)
        #expect(answer.taskIdentifier == task.taskIdentifier)
    }

    @Test("a task whose description cannot be read ends, and nothing is delivered for it")
    func unreadableAnswerIsNotDelivered() async {
        let delegate = UploadSessionDelegate()
        let handler = RecordingWholeHandler()
        #expect(
            delegate.complete(
                taskIdentifier: 7, taskDescription: "garbage",
                statusCode: 200, errorDescription: nil
            )
        )
        await delegate.attach(handler)
        #expect(await handler.received.isEmpty)
    }

    @MainActor
    @Test("a session's completion handler fires only its own, exactly once")
    func keyedCompletion() {
        let completion = OutboxBackgroundCompletion()
        var chunk = 0
        var whole = 0
        completion.store({ chunk += 1 }, for: OutboxSession.identifier)
        completion.store({ whole += 1 }, for: OutboxUploadSession.identifier)

        completion.fire(for: OutboxUploadSession.identifier)
        completion.fire(for: OutboxUploadSession.identifier)
        #expect(whole == 1)
        #expect(chunk == 0, "the upload session finishing fired the chunk session's handler")
        #expect(!completion.isPending(for: OutboxUploadSession.identifier))
        #expect(completion.isPending(for: OutboxSession.identifier))

        // The unkeyed calls are the chunk session's, as they always were.
        #expect(completion.isPending)
        completion.fire()
        #expect(chunk == 1)
        #expect(whole == 1)
        #expect(!completion.isPending)
    }
}

@Suite("Whole lane: the upload scheduler")
struct BackgroundUploadSchedulerTests {
    @Test("a task's description carries this launch and the epoch the request presented")
    func descriptionCarriesLaunchAndEpoch() async throws {
        let session = ScriptedUploadTaskSession()
        let launch = UUID()
        let ref = WholeFileRef(jobID: UUID(), fileID: UUID())
        let request = Upload.request(allowsMobileData: false)
        let file = URL(fileURLWithPath: "/dev/null")

        let task = try #require(
            await Upload.scheduler(on: session, launch: launch).upload(
                request, fromFile: file, for: ref, attempt: 2, under: .unfenced, issuedUnder: 7
            )
        )

        let created = try #require(session.createdTasks.first)
        #expect(session.createdTasks.count == 1)
        #expect(created.taskIdentifier == task.taskIdentifier)
        #expect(created.request == request, "the request went out as it was handed in")
        #expect(created.file == file)
        let read = try #require(WholeTaskIdentity(taskDescription: created.description))
        #expect(read == task.identity)
        #expect(read.launch == launch)
        #expect(read.epoch == 7)
        #expect(read.attempt == 2)
        #expect(read.jobID == ref.jobID && read.fileID == ref.fileID)
        #expect(read.provenance(currentLaunch: launch) == .thisLaunch(epoch: 7))
    }

    @Test("an authority withdrawn at the scheduler's own check creates no task")
    func withdrawnAuthorityCreatesNothing() async {
        let session = ScriptedUploadTaskSession()
        let asked = Counter()
        let withdrawn = SendAuthority {
            asked.increment()
            return false
        }
        let scheduler = Upload.scheduler(on: session)

        let task = await scheduler.upload(
            Upload.request(), fromFile: URL(fileURLWithPath: "/dev/null"),
            for: WholeFileRef(jobID: UUID(), fileID: UUID()), attempt: 0,
            under: withdrawn, issuedUnder: 1
        )

        #expect(task == nil)
        #expect(asked.count == 1, "the scheduler did not ask the authority itself")
        #expect(session.createdTasks.isEmpty)

        // A successor is held to the same check, and asked BEFORE it is built: a withdrawn
        // authority never has the caller write a term for a send that will not happen.
        let listed = WholeTask(taskIdentifier: 5, identity: Upload.identity())
        let built = Counter()
        let replacement = await scheduler.replace(
            listed, under: withdrawn, successor: Upload.successor(counter: built)
        )
        #expect(replacement == .replaced(nil))
        #expect(built.count == 0, "the successor was built under a withdrawn authority")
        #expect(session.createdTasks.isEmpty)
    }

    /// The build may suspend, so the authority is asked again at the send. What the build wrote
    /// stands with no task — the state reconciliation reads as a file nothing carries.
    @Test("an authority withdrawn while the successor is built sends nothing")
    func authorityWithdrawnDuringBuild() async {
        let session = ScriptedUploadTaskSession()
        let holds = Counter()
        let authority = SendAuthority {
            holds.increment()
            return holds.count == 1
        }
        let built = Counter()
        let listed = WholeTask(taskIdentifier: 5, identity: Upload.identity())

        let replacement = await Upload.scheduler(on: session).replace(
            listed, under: authority, successor: Upload.successor(counter: built)
        )

        #expect(replacement == .replaced(nil))
        #expect(built.count == 1)
        #expect(holds.count == 2, "the send did not ask the authority again after the build")
        #expect(session.createdTasks.isEmpty)
    }

    @Test("a task whose description cannot be read is cancelled, not dropped")
    func unreadableTasksAreCancelled() async {
        let readable = Upload.identity()
        let chunkDescription = OutboxTaskIdentity(jobID: UUID(), fileID: UUID(), offset: 0)
            .taskDescription
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 1, taskDescription: nil),
            WholeTaskListing(taskIdentifier: 2, taskDescription: readable.taskDescription),
            WholeTaskListing(taskIdentifier: 3, taskDescription: "garbage"),
            WholeTaskListing(taskIdentifier: 4, taskDescription: chunkDescription),
        ])

        let cancelled = await Upload.scheduler(on: session).cancelUnreadable()

        #expect(cancelled == [1, 3, 4])
        #expect(session.cancelledIdentifiers == [1, 3, 4])
    }

    /// The flags are read from the tasks the session holds, so a task a previous launch created is
    /// judged by what it actually carries.
    @Test("tasks created before a relaunch are judged by the flags they carry")
    func mismatchedReadsFlagsAcrossRelaunch() async throws {
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(
                taskIdentifier: 1, taskDescription: "garbage",
                access: .policy(allowsMobileData: true)
            )
        ])
        let before = Upload.scheduler(on: session)
        let ref = WholeFileRef(jobID: UUID(), fileID: UUID())
        let file = URL(fileURLWithPath: "/dev/null")
        let cellular = try #require(
            await before.upload(
                Upload.request(allowsMobileData: true), fromFile: file, for: ref, attempt: 0,
                under: .unfenced, issuedUnder: 1
            )
        )
        let wifiOnly = try #require(
            await before.upload(
                Upload.request(allowsMobileData: false), fromFile: file, for: ref, attempt: 0,
                under: .unfenced, issuedUnder: 1
            )
        )

        // A new process, with nothing in memory: the session is all it has.
        let after = Upload.scheduler(on: session)
        #expect(await after.mismatched(allowsMobileData: false) == [cellular])
        #expect(await after.mismatched(allowsMobileData: true) == [wifiOnly])
    }

    @Test("a task with no listed request, or no longer able to send, is judged accordingly")
    func mismatchedEdges() async {
        let unknown = Upload.identity()
        let stopping = Upload.identity()
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 1, taskDescription: unknown.taskDescription),
            WholeTaskListing(
                taskIdentifier: 2, taskDescription: stopping.taskDescription,
                access: .policy(allowsMobileData: true), state: .canceling
            ),
        ])
        let scheduler = Upload.scheduler(on: session)
        let unknownTask = WholeTask(taskIdentifier: 1, identity: unknown)
        #expect(await scheduler.mismatched(allowsMobileData: false) == [unknownTask])
        #expect(await scheduler.mismatched(allowsMobileData: true) == [unknownTask])
    }

    /// A cancel is a request, not a barrier. The successor waits for proof the old task is over.
    @Test("replace sends no successor while the old task is listed, and one once it has ended")
    func replaceWaitsForTheTerminalCallback() async throws {
        let old = WholeTask(taskIdentifier: 9, identity: Upload.identity())
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(
                taskIdentifier: 9, taskDescription: old.identity.taskDescription,
                access: .policy(allowsMobileData: false)
            )
        ])
        let delegate = UploadSessionDelegate()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_760_000_000))
        let start = clock.now
        let scheduler = Upload.scheduler(on: session, delegate: delegate, clock: clock)
        let built = Counter()

        let outcome = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: built)
        )

        #expect(outcome == .deferred)
        #expect(session.cancelledIdentifiers == [9])
        #expect(clock.now.timeIntervalSince(start) >= BackgroundUploadScheduler.replaceBound)
        #expect(session.createdTasks.isEmpty, "a successor went out beside a listed predecessor")
        #expect(built.count == 0, "the successor was built while its predecessor could answer")

        // Time alone proves nothing: an hour later, still listed, still nothing.
        clock.advance(3600)
        #expect(await scheduler.reexamineDeferred().isEmpty)
        #expect(session.createdTasks.isEmpty)

        // The terminal callback — a cancelled task's, with no status — is the proof.
        delegate.complete(
            taskIdentifier: 9, taskDescription: old.identity.taskDescription,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(await Upload.waitForCreated(1, on: session), "no successor after termination")
        #expect(await scheduler.reexamineDeferred().isEmpty)
        #expect(session.createdTasks.count == 1)
        #expect(built.count == 1)
    }

    @Test("a deferred successor goes once its predecessor leaves the session's list")
    func replaceSendsOnceTheTaskLeavesTheListing() async {
        let old = WholeTask(taskIdentifier: 9, identity: Upload.identity())
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 9, taskDescription: old.identity.taskDescription)
        ])
        let scheduler = Upload.scheduler(on: session)
        let built = Counter()

        let outcome = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: built)
        )
        #expect(outcome == .deferred)
        #expect(session.createdTasks.isEmpty)

        session.forget(9)
        let sent = await scheduler.reexamineDeferred()
        #expect(sent.count == 1)
        #expect(session.createdTasks.count == 1)
        #expect(await scheduler.reexamineDeferred().isEmpty, "one successor was sent twice")
        #expect(session.createdTasks.count == 1)
        #expect(built.count == 1)
    }

    @Test("a task that ends within the bound is replaced at once, by exactly one successor")
    func replaceWithinTheBound() async throws {
        let old = WholeTask(taskIdentifier: 9, identity: Upload.identity())
        let session = ScriptedUploadTaskSession(
            listing: [
                WholeTaskListing(taskIdentifier: 9, taskDescription: old.identity.taskDescription)
            ],
            onCancel: .leavesListing(after: 3)
        )
        let clock = MutableClock(Date(timeIntervalSince1970: 1_760_000_000))
        let start = clock.now
        let scheduler = Upload.scheduler(on: session, clock: clock)

        let outcome = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: Counter())
        )

        guard case .replaced(let successor?) = outcome else {
            Issue.record("expected one successor, got \(outcome)")
            return
        }
        #expect(session.createdTasks.map(\.taskIdentifier) == [successor.taskIdentifier])
        #expect(clock.now.timeIntervalSince(start) < BackgroundUploadScheduler.replaceBound)
    }

    @Test("a second replace of the same task is refused, and one successor goes")
    func secondReplaceIsRefused() async {
        let old = WholeTask(taskIdentifier: 9, identity: Upload.identity())
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 9, taskDescription: old.identity.taskDescription)
        ])
        let scheduler = Upload.scheduler(on: session)
        let built = Counter()

        let first = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: built)
        )
        let second = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: built)
        )
        #expect(first == .deferred)
        #expect(second == .refused)
        #expect(session.cancelledIdentifiers == [9], "the refused call cancelled again")

        session.forget(9)
        #expect(await scheduler.reexamineDeferred().count == 1)
        #expect(session.createdTasks.count == 1)
        #expect(built.count == 1)
    }
}

/// Handles answers in arrival order, parking inside the one it is told to until the gate opens.
private actor ParkingWholeHandler: WholeAnswerHandling {
    private let gate: TestGate
    private let parkingOn: Int
    private(set) var received: [WholeAnswer] = []

    init(gate: TestGate, parkingOn taskIdentifier: Int) {
        self.gate = gate
        self.parkingOn = taskIdentifier
    }

    func handle(_ answer: WholeAnswer) async {
        if answer.taskIdentifier == parkingOn { await gate.pass() }
        received.append(answer)
    }

    /// Whether an answer for this task has been handled within the bound.
    func handled(_ taskIdentifier: Int, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        func seen() -> Bool { received.contains { $0.taskIdentifier == taskIdentifier } }
        while !seen(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return seen()
    }
}

@Suite("Whole lane: the delegate and the barrier under interleaving")
struct UploadInterleavingTests {
    /// Two answers for one file are a cursor moving forwards; one that overtakes the replay moves
    /// it backwards.
    @Test("an answer arriving while adoption replays is handled once, after the ones before it")
    func answerDuringReplayKeepsItsPlace() async {
        let delegate = UploadSessionDelegate()
        let gate = TestGate()
        let handler = ParkingWholeHandler(gate: gate, parkingOn: 1)
        let identity = Upload.identity()
        delegate.deliver(WholeAnswer(taskIdentifier: 1, identity: identity, statusCode: 200))
        delegate.deliver(WholeAnswer(taskIdentifier: 2, identity: identity, statusCode: 200))

        let attaching = Task { await delegate.attach(handler) }
        await gate.waitUntilParked()
        delegate.deliver(WholeAnswer(taskIdentifier: 3, identity: identity, statusCode: 200))

        let overtook = await handler.handled(3, within: 0.3)
        #expect(!overtook, "an answer arriving mid-replay overtook the replay")
        await gate.open()
        await attaching.value

        #expect(await handler.received.map(\.taskIdentifier) == [1, 2, 3])
    }

    /// A listing is evidence only about the tasks that existed when it was taken.
    @Test("a task deferred while a reexamination awaits its listing is not judged by that listing")
    func staleListingDoesNotReleaseANewlyDeferredTask() async throws {
        let first = WholeTask(taskIdentifier: 9, identity: Upload.identity())
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 9, taskDescription: first.identity.taskDescription)
        ])
        let scheduler = Upload.scheduler(on: session)
        let firstBuilt = Counter()
        let secondBuilt = Counter()
        let firstOutcome = await scheduler.replace(
            first, under: .unfenced, successor: Upload.successor(counter: firstBuilt)
        )
        #expect(firstOutcome == .deferred)
        session.forget(9)

        // The reexamination takes its listing — the first task gone, the second not yet
        // created — and is still awaiting it while the second is created, cancelled and deferred,
        // with every listing its own replace took still holding it.
        let gate = TestGate()
        session.holdNextListing(on: gate)
        let reexamination = Task { await scheduler.reexamineDeferred() }
        await gate.waitUntilParked()
        let second = try #require(
            await scheduler.upload(
                Upload.request(), fromFile: URL(fileURLWithPath: "/dev/null"),
                for: WholeFileRef(jobID: UUID(), fileID: UUID()), attempt: 0,
                under: .unfenced, issuedUnder: 1
            )
        )
        let secondOutcome = await scheduler.replace(
            second, under: .unfenced, successor: Upload.successor(counter: secondBuilt)
        )
        #expect(secondOutcome == .deferred)

        await gate.open()
        let sent = await reexamination.value

        #expect(sent.count == 1, "the reexamination sent \(sent.count) successors")
        #expect(firstBuilt.count == 1, "the first task left the listing, and its successor goes")
        #expect(secondBuilt.count == 0, "a successor went out while its predecessor was listed")
        #expect(session.createdTasks.count == 2, "the second task and the first one's successor")
        #expect(await scheduler.reexamineDeferred().isEmpty, "the second task is still listed")
        #expect(secondBuilt.count == 0)
    }

    @Test("a terminal callback, a reexamination and a second replace racing: one successor")
    func concurrentPathsSendOneSuccessor() async {
        let old = WholeTask(taskIdentifier: 9, identity: Upload.identity())
        let session = ScriptedUploadTaskSession(listing: [
            WholeTaskListing(taskIdentifier: 9, taskDescription: old.identity.taskDescription)
        ])
        let delegate = UploadSessionDelegate()
        let scheduler = Upload.scheduler(on: session, delegate: delegate)
        let built = Counter()
        let gate = TestGate()
        let outcome = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: built, parkingOn: gate)
        )
        #expect(outcome == .deferred)

        // The task leaves the listing; a reexamination takes the successor and parks in its build.
        session.forget(9)
        let reexamination = Task { await scheduler.reexamineDeferred() }
        await gate.waitUntilParked()

        // Every other path arrives while that build is under way.
        delegate.complete(
            taskIdentifier: 9, taskDescription: old.identity.taskDescription,
            statusCode: nil, errorDescription: "cancelled"
        )
        #expect(await scheduler.reexamineDeferred().isEmpty)
        let again = await scheduler.replace(
            old, under: .unfenced, successor: Upload.successor(counter: built)
        )
        #expect(again == .refused)

        await gate.open()
        let sent = await reexamination.value
        // The terminal callback's path runs on a task of its own; give it every chance to act.
        try? await Task.sleep(for: .milliseconds(100))

        #expect(sent.count == 1)
        #expect(built.count == 1, "the successor was built \(built.count) times")
        #expect(session.createdTasks.count == 1)
    }
}
