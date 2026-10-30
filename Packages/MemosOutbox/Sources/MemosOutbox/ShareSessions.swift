import Foundation
import Synchronization

/// What one wake decided about one registered share session.
public enum ShareSessionVerdict: Sendable, Equatable {
    /// It still carries a file its capture needs: left registered, and the app's lane leaves the
    /// capture alone.
    case kept
    /// Nothing it holds is needed any more — the capture landed, was withdrawn, or its tasks
    /// ended — so it is no longer registered, and the capture is the app's lane's again.
    case retired
}

/// The app's side of the share sessions: one attached `URLSession` per registered identifier, and
/// the reconciliation that decides which of them are still needed.
///
/// The attach is CLAIMED synchronously, per identifier: the check and the insert are one critical
/// section with nothing awaited inside it, so two wakes that overlap — a launch and a
/// `handleEventsForBackgroundURLSession`, or two of those — get the same session, and the process
/// never creates a second session under an identifier it already holds.
///
/// A session stays attached for the life of the process, retired or not: the system may still
/// deliver a finished task's events under that identifier, and a second session created for it
/// later would be exactly the duplicate the claim exists to prevent.
public final class ShareSessions: Sendable {
    public let registry: SessionRegistry
    private let make: @Sendable (String) -> any UploadTaskSession
    private let attached = Mutex<[String: any UploadTaskSession]>([:])

    /// - Parameter make: builds the session for one identifier; called at most once per identifier.
    public init(
        registry: SessionRegistry,
        make: @escaping @Sendable (String) -> any UploadTaskSession
    ) {
        self.registry = registry
        self.make = make
    }

    @discardableResult
    public func attach(_ identifier: String) -> any UploadTaskSession {
        attached.withLock { sessions in
            if let session = sessions[identifier] { return session }
            let session = make(identifier)
            sessions[identifier] = session
            return session
        }
    }

    /// Whether this process answers for `identifier`: one it attached, or one the registry names.
    public func owns(_ identifier: String) -> Bool {
        attached.withLock { $0[identifier] != nil } || registry.contains(identifier: identifier)
    }

    /// Attaches to every registered identifier, reconciles its tasks against the capture's
    /// manifest and retires the identifiers nothing needs. Sends nothing: a cancel is local, and a
    /// capture handed back here is resumed by the app's lane from the server's own offset.
    @discardableResult
    public func wake(repository: OutboxRepository) async -> [String: ShareSessionVerdict] {
        var verdicts: [String: ShareSessionVerdict] = [:]
        var finished: Set<String> = []
        for entry in registry.entries() {
            let session = attach(entry.identifier)
            switch await repository.presence(entry.jobID) {
            case .unreadable:
                // A failure to look is not an answer: the capture may still need these tasks.
                verdicts[entry.identifier] = .kept
            case .absent:
                // Landed or withdrawn — either way no file of it is wanted. Whatever is still
                // sending is cancelled locally and nothing is asked of the server.
                for task in await session.allTasks() where task.state.isLive {
                    await session.cancel(taskIdentifier: task.taskIdentifier)
                }
                finished.insert(entry.identifier)
            case .present(let job):
                let live = await session.allTasks().filter(\.state.isLive)
                let plan = WholeReconciliation.plan(jobs: [job], tasks: live)
                for identifier in plan.cancelled {
                    await session.cancel(taskIdentifier: identifier)
                }
                if plan.adopted.isEmpty {
                    finished.insert(entry.identifier)
                } else {
                    verdicts[entry.identifier] = .kept
                }
            }
        }
        do {
            try registry.retire(finished)
            for identifier in finished { verdicts[identifier] = .retired }
        } catch {
            // The lease was busy: they stay registered, and the next wake retires them.
            for identifier in finished { verdicts[identifier] = .kept }
        }
        return verdicts
    }
}

extension WholeTaskState {
    /// Still able to send bytes.
    var isLive: Bool { self == .running || self == .suspended }
}

/// The delegate every attached share session is created with: it says when the system has
/// delivered all of a session's events, which is when the app may answer the wake it was handed.
public final class ShareSessionEvents: NSObject, URLSessionDelegate, Sendable {
    private let finished: @Sendable (String) -> Void

    public init(finished: @escaping @Sendable (String) -> Void) {
        self.finished = finished
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        finished(identifier)
    }
}

/// The share sessions' wakes, one ticket each, and the one-shot claim on answering each.
///
/// The system hands the app one completion handler per wake, and two things can answer it: the
/// session saying its events are over, and the fallback deadline. Each answer CLAIMS here,
/// synchronously, at the callback site and before any hop — whichever claims first wins, and the
/// other finds nothing. A fallback is bound to its own ticket and never to the identifier, so a
/// late fallback from an earlier wake cannot answer a later wake under the same identifier before
/// that wake's events are over.
public final class ShareWakeTickets: Sendable {
    private struct State {
        var next = 0
        var pending: [Int: String] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// A new wake for `identifier`; the ticket its handler is held under.
    public func arm(_ identifier: String) -> Int {
        state.withLock { state in
            state.next += 1
            state.pending[state.next] = identifier
            return state.next
        }
    }

    /// The session's events are over: every wake armed for it so far is answered, exactly once.
    public func claimFinished(_ identifier: String) -> [Int] {
        state.withLock { state in
            let won = state.pending.filter { $0.value == identifier }.map(\.key).sorted()
            for ticket in won { state.pending[ticket] = nil }
            return won
        }
    }

    /// The fallback for one wake: true only when that wake had not been answered yet.
    public func claim(_ ticket: Int) -> Bool {
        state.withLock { $0.pending.removeValue(forKey: ticket) != nil }
    }
}
