import Foundation

/// Counts the delegate work a background session has handed over, so that "the session has no more
/// events" can be answered honestly.
///
/// A background URL session delivers its results and then tells the app it is finished; the app
/// answers the system's completion handler, and the system is then free to SUSPEND the process.
/// The handling of a finished chunk — banking the server's byte count, writing the manifest,
/// slicing the next chunk — happens asynchronously, so calling that handler the moment the session
/// says "done" invites a suspension in the middle of it. This exists to make the answer wait.
///
/// It is lock-backed rather than an actor on purpose: `enter()` has to be SYNCHRONOUS, called on
/// the delegate's own thread before the work is spawned. An `await` there would let the "nothing
/// outstanding" answer overtake the work it is meant to be counting.
public final class PendingHandlerWork: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding = 0
    private var whenDrained: (@Sendable () -> Void)?

    public init() {}

    public var outstandingCount: Int { lock.withLock { outstanding } }

    /// Register work that is about to start. Must be called before it is spawned.
    public func enter() {
        lock.withLock { outstanding += 1 }
    }

    public func leave() {
        let drained: (@Sendable () -> Void)? = lock.withLock {
            outstanding -= 1
            guard outstanding <= 0, let pending = whenDrained else { return nil }
            whenDrained = nil
            return pending
        }
        drained?()
    }

    /// Runs `body` once everything outstanding has finished — immediately when nothing is.
    ///
    /// Only the most recent registration is kept: there is one system completion handler per
    /// session event batch, and calling an older one late is not better than not calling it.
    public func onDrained(_ body: @escaping @Sendable () -> Void) {
        let immediately: Bool = lock.withLock {
            guard outstanding > 0 else { return true }
            whenDrained = body
            return false
        }
        if immediately { body() }
    }
}

/// One piece of background work whose end must be reported to the system EXACTLY once.
///
/// The system gives a background task a deadline and kills the app if it is not told the work
/// finished; telling it twice is equally wrong. Expiry and completion race by nature — the
/// expiration handler runs on the system's thread while the work is still going — so the decision
/// of who reports is made once, under a lock, and the loser does nothing.
public final class BackgroundRun: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var work: Task<Void, Never>?

    public init() {}

    public var isFinished: Bool { lock.withLock { finished } }

    /// Claims the right to report the end. True for exactly one caller, ever.
    public func claimCompletion() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    /// Hands over the running work so an expiry can stop it. Work attached after the run has
    /// already ended is cancelled immediately rather than left going.
    public func attach(_ task: Task<Void, Never>) {
        let alreadyFinished: Bool = lock.withLock {
            guard !finished else { return true }
            work = task
            return false
        }
        if alreadyFinished { task.cancel() }
    }

    /// The system wants the process back. Stops the work; the caller reports the end.
    public func expire() {
        let running: Task<Void, Never>? = lock.withLock { work }
        running?.cancel()
    }
}
