import Foundation

/// The system's "I woke you to finish this" callbacks, held until each session says it is done AND
/// the wake has finished its own work.
///
/// It is a process-wide box rather than an injected dependency because the callback arrives at the
/// app delegate, which the system creates, while the session that must drain first is owned by the
/// outbox. Failing to call it eventually stops the system from waking the app at all, so it is
/// stored in exactly one place and fired exactly once.
///
/// Keyed by session identifier: the system hands over one callback per session it woke the app
/// for, and one session finishing says nothing about the other. The unkeyed calls are the chunk
/// session's, which is what they always were.
///
/// A handler fires when three things are true: it is stored, ITS session has said it finished
/// delivering (`sessionFinished`) since it was stored, and no wake is still working (`WakeWork`).
/// The session finishing is not enough on its own: a wake has to restore a session and send a
/// finished capture's memo create, possibly waiting on a drain another entry point owns, and a
/// process answered before that is a process the system may suspend mid-create. Nor may it wait
/// forever — so every stored handler fires after `fallbackDelay` whatever is still going.
@MainActor
public final class OutboxBackgroundCompletion {
    public static let shared = OutboxBackgroundCompletion()

    /// Under the roughly thirty seconds the system gives a woken app before it stops trusting it.
    public nonisolated static let fallbackDelay: Duration = .seconds(25)

    /// The identifiers of the sessions this outbox owns. A wake for any other is not ours.
    public static let sessionIdentifiers: Set<String> = [
        OutboxSession.identifier, OutboxUploadSession.identifier, OutboxSession.guestIdentifier,
    ]

    private struct Held {
        var run: () -> Void
        /// Which storing this is, so a fallback armed for an earlier handler under the same key
        /// can never fire a later one early.
        var ticket: Int
    }

    private var handlers: [String: Held] = [:]
    /// Sessions that said they finished delivering since their handler was stored.
    private var finished: Set<String> = []
    /// Wakes still working, whatever entry point began them.
    private var wakes = 0
    private var tickets = 0
    private let fallback: @Sendable () async -> Void

    /// - Parameter fallback: returns when a stored handler has waited long enough. Injected so a
    ///   test can reach the deadline without sleeping it.
    public init(
        fallback: @escaping @Sendable () async -> Void = {
            _ = try? await Task.sleep(for: OutboxBackgroundCompletion.fallbackDelay)
        }
    ) {
        self.fallback = fallback
    }

    public func store(_ handler: @escaping () -> Void) {
        store(handler, for: OutboxSession.identifier)
    }

    /// Holds a session's handler, and arms its fallback. What its session said before this is
    /// about an earlier batch of events, so it waits for this batch's own `sessionFinished`.
    public func store(_ handler: @escaping () -> Void, for identifier: String) {
        tickets += 1
        let ticket = tickets
        handlers[identifier] = Held(run: handler, ticket: ticket)
        finished.remove(identifier)
        let fallback = fallback
        Task { @MainActor [weak self] in
            await fallback()
            self?.fire(for: identifier, ticket: ticket)
        }
    }

    /// The system woke the app for one of this outbox's sessions: its handler is held, and the
    /// wake's own work is entered — synchronously, before any hop, so the session finishing in the
    /// very next callback cannot release the handler ahead of it.
    /// - Returns: the wake to leave once its work is over, or nil when the identifier is not one of
    ///   this outbox's sessions — the caller answers the system at once.
    public func beginWake(for identifier: String, handler: @escaping () -> Void) -> WakeWork? {
        guard Self.sessionIdentifiers.contains(identifier) else { return nil }
        store(handler, for: identifier)
        return enterWake()
    }

    /// Work a wake does that every held handler waits for — a background refresh's included.
    public func enterWake() -> WakeWork {
        wakes += 1
        return WakeWork(owner: self)
    }

    func wakeLeft() {
        wakes -= 1
        for identifier in finished.sorted() {
            fireIfReleased(identifier)
        }
    }

    /// The session has delivered its events and its delegate has applied them.
    public func sessionFinished(for identifier: String) {
        finished.insert(identifier)
        fireIfReleased(identifier)
    }

    /// Whether this session said it finished since its handler was stored and has not fired yet.
    public func hasFinished(_ identifier: String) -> Bool { finished.contains(identifier) }

    private func fireIfReleased(_ identifier: String) {
        guard wakes == 0, handlers[identifier] != nil, finished.contains(identifier) else {
            return
        }
        fire(for: identifier)
    }

    public var isPending: Bool { isPending(for: OutboxSession.identifier) }

    public func isPending(for identifier: String) -> Bool { handlers[identifier] != nil }

    public func fire() {
        fire(for: OutboxSession.identifier)
    }

    /// Fires the one callback stored for this session, and forgets it: a second call finds nothing.
    public func fire(for identifier: String) {
        finished.remove(identifier)
        let pending = handlers.removeValue(forKey: identifier)
        pending?.run()
    }

    private func fire(for identifier: String, ticket: Int) {
        guard handlers[identifier]?.ticket == ticket else { return }
        fire(for: identifier)
    }
}

/// One wake's own work, entered before it starts and left once it is over.
///
/// Left exactly once: a second `leave` does nothing, so one wake can never release a hold another
/// wake still has on the system's handlers.
@MainActor
public final class WakeWork {
    private let owner: OutboxBackgroundCompletion
    private var isLeft = false

    init(owner: OutboxBackgroundCompletion) {
        self.owner = owner
    }

    public func leave() {
        guard !isLeft else { return }
        isLeft = true
        owner.wakeLeft()
    }
}

/// The real background session.
///
/// One session, one identifier, one chunk in flight. Its delegate is the only thing that runs when
/// the app has been relaunched for a finished upload, so it does the least it can: collect the
/// answer, hand it to whoever is handling chunks, and call the system's completion handler when
/// the session has nothing left to say.
public actor BackgroundChunkScheduler: OutboxChunkScheduling {
    private let session: URLSession
    private let delegate: OutboxSessionDelegate

    /// - Parameter identifier: which background session this is. The member outbox's by default;
    ///   the guest outbox passes its own, so the two queues never share a session.
    public init(
        appGroup: String = OutboxDefaults.appGroup,
        identifier: String = OutboxSession.identifier
    ) {
        let delegate = OutboxSessionDelegate(identifier: identifier)
        self.delegate = delegate
        self.session = URLSession(
            configuration: OutboxSession.backgroundConfiguration(
                appGroup: appGroup, identifier: identifier),
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// The same scheduler over a session handed in.
    ///
    /// A background configuration belongs to the app's identifier and survives the process, so the
    /// enumeration below — the one thing here that reads what the system is holding rather than
    /// asking it for something — can otherwise only be exercised against whatever the app itself
    /// left behind. This takes the session instead, so the descriptions it reads are the ones the
    /// caller wrote.
    internal init(session: URLSession, delegate: OutboxSessionDelegate = OutboxSessionDelegate()) {
        self.delegate = delegate
        self.session = session
    }

    /// Wired after construction because the handler is the engine, and the engine needs the
    /// scheduler: one of the two references has to be attached rather than passed in.
    public func attach(_ handler: any OutboxChunkHandling) async {
        await delegate.attach(handler)
    }

    /// What the session holds, plus every answer the delegate has not finished handing over: a
    /// finished task has left `allTasks` while its answer is still on its way to the row, and a
    /// chunk listed nowhere in that window is rescheduled under the same identity.
    ///
    /// The session is read first, so a task it lists is counted whatever happens next. Read the
    /// other way round, a task still running at the delegate read and delivered before the session
    /// read would be missing from both.
    public func inFlight() async -> [OutboxTaskIdentity] {
        let listed = await session.allTasks.compactMap {
            OutboxTaskIdentity(taskDescription: $0.taskDescription)
        }
        var seen = Set(listed)
        return listed + delegate.listUndelivered().filter { seen.insert($0).inserted }
    }

    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        identity: OutboxTaskIdentity,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) {
        // A chunk handed to the background session is the one send that cannot be taken back: it
        // outlives this process. The engine checked before the hop that got here; this asks again
        // on THIS executor, because the hop itself is a suspension the switch fits into.
        guard authority.holds() else { return }
        // Recorded BEFORE the task starts: its answer can arrive in the very next callback, and a
        // refusal is only classifiable against the credential that earned it.
        delegate.record(epoch: epoch, for: identity)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = identity.taskDescription
        task.resume()
    }

    public func cancelEveryTask() async {
        for task in await session.allTasks {
            task.cancel()
        }
    }

    public func cancel(_ identities: [OutboxTaskIdentity]) async {
        let wanted = Set(identities.map(\.taskDescription))
        for task in await session.allTasks
        where task.taskDescription.map(wanted.contains) ?? false {
            task.cancel()
        }
    }
}

/// The session's delegate.
///
/// `@unchecked Sendable` with a lock is deliberate: URLSession calls a delegate on its own queue,
/// from a process that may have been launched for this callback alone, so the state it collects
/// cannot live in an actor it would have to await.
/// It is `public` for one reason: this class IS the seam between the URL loading system and the
/// engine, the drop it used to have happened here, and `MemosOutboxTests` exercises the package
/// through its public surface where it drives this class. `deliver` is what the callback below
/// calls, and what a test can call.
public final class OutboxSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var handler: (any OutboxChunkHandling)?
    /// Answers the session delivered before anything was attached, in arrival order.
    ///
    /// The session is created when the app is, and it can deliver a finished chunk's result in the
    /// same turn — before adoption has run, because adoption is a task the launch schedules. A
    /// result dropped there is the server's own `bytes_received` thrown away, and those bytes get
    /// sent a second time. So nothing is dropped: it waits here, and adoption replays it IN ORDER,
    /// which matters because two answers for one file are a cursor moving forwards.
    private var waiting: [ChunkResult] = []
    /// Which credential generation each in-flight chunk went out under, keyed the way the task is.
    /// Empty for anything this process did not schedule — a task adopted across a relaunch.
    private var epochs: [String: Int] = [:]
    /// Answers delivered whose handling has not returned, per identity.
    ///
    /// A count, not a set: two tasks can carry one identity — a 404 clears the upload without
    /// moving the attempt, and that answer's handler schedules the next chunk at the same offset
    /// and attempt — so the first answer to finish must not erase the second one's entry.
    private var undelivered: [OutboxTaskIdentity: Int] = [:]
    /// The counted identities an `inFlight()` read has listed. A pass that read one left its row to
    /// the answer, and an answer that then leaves the row with no task — parked for the network,
    /// say — moves it no further: only a new pass does, so the answer's settling asks for one.
    private var listedWhileUndelivered: Set<OutboxTaskIdentity> = []
    /// True while `attach` replays what was buffered. A pass asked for then would run beside the
    /// replay, so the request waits for the replay's end.
    private var replaying = false
    /// A listed answer settled while the replay ran: asked for once, when the replay is over.
    private var wakeOwedAfterReplay = false
    /// What is still being written to disk. The system's completion handler waits on this.
    private let pending = PendingHandlerWork()
    /// Where "finished" is reported; nil is the process-wide box the app delegate stores into.
    private let completion: OutboxBackgroundCompletion?
    /// The session this delegate reports for. The handler the system stored is keyed by it, so a
    /// guest session reporting under the member's name would leave its own handler to the fallback
    /// and release the member's early.
    let identifier: String

    public init(
        completion: OutboxBackgroundCompletion? = nil,
        identifier: String = OutboxSession.identifier
    ) {
        self.completion = completion
        self.identifier = identifier
        super.init()
    }

    func record(epoch: Int, for identity: OutboxTaskIdentity) {
        lock.withLock { epochs[identity.taskDescription] = epoch }
    }

    /// The identities whose answers are still being handed over, each marked as listed.
    func listUndelivered() -> [OutboxTaskIdentity] {
        lock.withLock {
            let counted = Array(undelivered.keys)
            listedWhileUndelivered.formUnion(counted)
            return counted
        }
    }

    /// One answer's handling has returned. True when it was the last for its identity, a read
    /// listed that identity meanwhile, and no replay is running: the caller then asks for a pass.
    /// Mid-replay the request is owed instead, and the replay's end makes it.
    private func settle(_ identity: OutboxTaskIdentity) -> Bool {
        lock.withLock {
            let left = (undelivered[identity] ?? 0) - 1
            guard left <= 0 else {
                undelivered[identity] = left
                return false
            }
            undelivered[identity] = nil
            guard listedWhileUndelivered.remove(identity) != nil else { return false }
            guard replaying else { return true }
            if !wakeOwedAfterReplay {
                wakeOwedAfterReplay = true
                pending.enter()
            }
            return false
        }
    }

    /// AWAITS the replay. Adoption is what calls this, and every drain `Outbox` starts waits for
    /// adoption to return (`Outbox.start`), so the replay and those drains are serialised by that
    /// alone. A pass the engine asks for itself — a deadline, a freed place — is not behind that
    /// barrier and may run during the replay: an answer being replayed is counted, so such a pass
    /// lists it and leaves its row alone, and a pass owed by a settled answer waits for the end.
    ///
    /// It used to hand the replay to an unawaited `Task`, which is not serialisation: a drain
    /// starting beside it retains a job at its own offset, awaits a probe, and resumes after the
    /// replay has banked a LATER offset — then re-sends those bytes and saves the older cursor over
    /// the newer one. `isDraining` cannot see that, because the replay is not a sibling drain.
    ///
    /// Each of these was counted into `pending` when it arrived, so the system's completion handler
    /// has been waiting on them since — and still is, until this loop has finished.
    public func attach(_ handler: any OutboxChunkHandling) async {
        let replay: [ChunkResult] = lock.withLock {
            self.handler = handler
            replaying = true
            let held = waiting
            waiting = []
            return held
        }
        for result in replay {
            await handler.handle(result)
            _ = settle(result.identity)
            pending.leave()
        }
        let owed: Bool = lock.withLock {
            replaying = false
            defer { wakeOwedAfterReplay = false }
            return wakeOwedAfterReplay
        }
        guard owed else { return }
        await handler.listedAnswerSettled()
        pending.leave()
    }

    /// An upload task's answer arrives as data, and the answer is the whole point: it carries the
    /// server's `bytes_received`, which is the only number the cursor advances from.
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let identity = OutboxTaskIdentity(taskDescription: task.taskDescription) else {
            return
        }
        let epoch = lock.withLock { epochs.removeValue(forKey: identity.taskDescription) }
        deliver(
            ChunkResult(
                identity: identity,
                statusCode: (task.response as? HTTPURLResponse)?.statusCode,
                body: body,
                errorDescription: error?.localizedDescription,
                epoch: epoch
            )
        )
    }

    /// One finished chunk's answer, from wherever it came from.
    ///
    /// Split out of the callback above so that what the callback DOES is reachable: building a
    /// `ChunkResult` from a `URLSessionTask` is an adapter no test can drive, and this is the part
    /// that used to lose it.
    public func deliver(_ result: ChunkResult) {
        // Counted BEFORE anything else, handler or no handler: the session can say "no more
        // events" in the very next callback, and the app must not answer that until this has
        // reached the disk — which, for a result that is still waiting for adoption, it has not.
        pending.enter()
        // In flight from here until its handling returns, on both branches: the task has already
        // left the session's listing, and the row does not know yet.
        let handler: (any OutboxChunkHandling)? = lock.withLock {
            undelivered[result.identity, default: 0] += 1
            guard let attached = self.handler else {
                waiting.append(result)
                return nil
            }
            return attached
        }
        guard let handler else { return }
        Task {
            await handler.handle(result)
            if settle(result.identity) { await handler.listedAnswerSettled() }
            pending.leave()
        }
    }

    /// The session has delivered everything it had. Only once the handling of it has finished is
    /// the system told — answering earlier is an invitation to be suspended mid-write, with the
    /// server's byte count banked nowhere.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = completion
        let identifier = identifier
        pending.onDrained {
            Task { @MainActor in
                (completion ?? .shared).sessionFinished(for: identifier)
            }
        }
    }
}
