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

    /// Wired after construction because the handler is the engine, and the engine needs the
    /// scheduler: one of the two references has to be attached rather than passed in.
    public func attach(_ handler: any OutboxChunkHandling) {
        delegate.attach(handler)
    }

    public func inFlight() async -> [OutboxTaskIdentity] {
        await session.allTasks.compactMap {
            OutboxTaskIdentity(taskDescription: $0.taskDescription)
        }
    }

    public func upload(_ request: URLRequest, fromFile file: URL, identity: OutboxTaskIdentity) {
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
final class OutboxSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var handler: (any OutboxChunkHandling)?
    /// What is still being written to disk. The system's completion handler waits on this.
    private let pending = PendingHandlerWork()

    func attach(_ handler: any OutboxChunkHandling) {
        lock.withLock { self.handler = handler }
    }

    /// An upload task's answer arrives as data, and the answer is the whole point: it carries the
    /// server's `bytes_received`, which is the only number the cursor advances from.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let identity = OutboxTaskIdentity(taskDescription: task.taskDescription) else {
            return
        }
        let result = ChunkResult(
            identity: identity,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            body: body,
            errorDescription: error?.localizedDescription
        )
        guard let handler = lock.withLock({ self.handler }) else { return }
        // Counted BEFORE the work is spawned: the session can say "no more events" in the very
        // next callback, and the app must not answer that until this has reached the disk.
        pending.enter()
        Task {
            await handler.handle(result)
            pending.leave()
        }
    }

    /// The session has delivered everything it had. Only once the handling of it has finished is
    /// the system told — answering earlier is an invitation to be suspended mid-write, with the
    /// server's byte count banked nowhere.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        pending.onDrained {
            Task { @MainActor in OutboxBackgroundCompletion.shared.fire() }
        }
    }
}
