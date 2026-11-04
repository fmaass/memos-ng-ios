import Foundation

/// The member outbox's old chunk session, kept only to retire it (MEMNG-546).
///
/// Every member capture goes on the whole lane now, and a row an older build began in chunks is
/// moved onto it where it is first read (the repository's `retiresChunkLane`). What that older
/// build handed to the chunk session may still be in the system's hands, though, and a task the
/// system finishes is delivered to whichever session in the process carries its identifier. So a
/// session under the member chunk identifier is still created at launch — to receive those answers
/// and drop every one of them, and to cancel each leftover task ONCE, at adoption, before any drain
/// (`Outbox.composed`). A chunk answer for a row that moved would carry the old session's byte
/// count into a file the whole lane is sending from its first byte.
///
/// It takes the engine's chunk seat. `inFlight` is always empty: a chunk task is no row's business
/// any more, and listing one would have the engine adopt it. `upload` is never asked, because the
/// member engine sends every row on the whole lane, and does nothing if it is. `cancelEveryTask`
/// still cancels: a withdrawn credential is in those tasks' headers.
///
/// `@unchecked Sendable` with a lock, like the live chunk delegate: URLSession calls a delegate on
/// its own queue, from a process that may have been launched for this callback alone.
public final class RetiredChunkSession: NSObject, OutboxChunkScheduling, URLSessionDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var session: URLSession?
    private var retired = false

    /// The session under the member chunk identifier. Created synchronously while the app
    /// launches, for the reason the live sessions are: an answer finds only a session that already
    /// exists.
    public init(appGroup: String = OutboxDefaults.appGroup) {
        super.init()
        let session = URLSession(
            configuration: OutboxSession.backgroundConfiguration(
                appGroup: appGroup, identifier: OutboxSession.identifier),
            delegate: self,
            delegateQueue: nil
        )
        lock.withLock { self.session = session }
    }

    /// Over a session handed in, or none: a composition with nothing left behind to retire.
    internal init(session: URLSession?) {
        self.session = session
        super.init()
    }

    /// Nothing behind it: nothing to cancel, nothing to receive.
    public static var none: RetiredChunkSession { RetiredChunkSession(session: nil) }

    /// Cancels every task the retired session holds, once per process: the first call claims the
    /// work synchronously, under the lock, so a second caller — a wake racing the launch — finds
    /// it taken and cancels nothing twice.
    public func retire() async {
        let claimed: URLSession? = lock.withLock {
            guard !retired else { return nil }
            retired = true
            return session
        }
        guard let claimed else { return }
        for task in await claimed.allTasks {
            task.cancel()
        }
    }

    public func inFlight() async -> [OutboxTaskIdentity] { [] }

    public func upload(
        _ request: URLRequest,
        fromFile file: URL,
        identity: OutboxTaskIdentity,
        under authority: SendAuthority,
        issuedUnder epoch: Int
    ) async {}

    public func cancel(_ identities: [OutboxTaskIdentity]) async {}

    public func cancelEveryTask() async {
        guard let session = lock.withLock({ session }) else { return }
        for task in await session.allTasks {
            task.cancel()
        }
    }

    /// The session has said all it had to say: the system's completion handler is released, so a
    /// wake for this identifier is not held for the fallback delay. No answer is read on the way —
    /// none is anyone's to apply.
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            OutboxBackgroundCompletion.shared.sessionFinished(for: OutboxSession.identifier)
        }
    }
}
