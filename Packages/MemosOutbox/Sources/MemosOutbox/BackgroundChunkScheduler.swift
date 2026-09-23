import Foundation

/// The system's "I woke you to finish this" callback, held until the session says it is done.
///
/// It is a process-wide box rather than an injected dependency because the callback arrives at the
/// app delegate, which the system creates, while the session that must drain first is owned by the
/// outbox. Failing to call it eventually stops the system from waking the app at all, so it is
/// stored in exactly one place and fired exactly once.
@MainActor
public final class OutboxBackgroundCompletion {
    public static let shared = OutboxBackgroundCompletion()

    private var handler: (() -> Void)?

    public init() {}

    public func store(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    public var isPending: Bool { handler != nil }

    public func fire() {
        let pending = handler
        handler = nil
        pending?()
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

    public init(appGroup: String = OutboxDefaults.appGroup) {
        let delegate = OutboxSessionDelegate()
        self.delegate = delegate
        self.session = URLSession(
            configuration: OutboxSession.backgroundConfiguration(appGroup: appGroup),
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

    public func inFlight() async -> [OutboxTaskIdentity] {
        await session.allTasks.compactMap {
            OutboxTaskIdentity(taskDescription: $0.taskDescription)
        }
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
    /// What is still being written to disk. The system's completion handler waits on this.
    private let pending = PendingHandlerWork()

    func record(epoch: Int, for identity: OutboxTaskIdentity) {
        lock.withLock { epochs[identity.taskDescription] = epoch }
    }

    /// AWAITS the replay. Adoption is what calls this, and a drain may only start after adoption
    /// has returned (`Outbox.start`), so the replay and the drain are serialised by that alone.
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
            let held = waiting
            waiting = []
            return held
        }
        for result in replay {
            await handler.handle(result)
            pending.leave()
        }
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
        let handler: (any OutboxChunkHandling)? = lock.withLock {
            guard let attached = self.handler else {
                waiting.append(result)
                return nil
            }
            return attached
        }
        guard let handler else { return }
        Task {
            await handler.handle(result)
            pending.leave()
        }
    }

    /// The session has delivered everything it had. Only once the handling of it has finished is
    /// the system told — answering earlier is an invitation to be suspended mid-write, with the
    /// server's byte count banked nowhere.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        pending.onDrained {
            Task { @MainActor in OutboxBackgroundCompletion.shared.fire() }
        }
    }
}
