import Foundation

/// The whole lane's background session: its identity and its configuration, in one place so the
/// properties that matter can be asserted.
///
/// A second session beside `OutboxSession`, never a second use of it. The system keeps one
/// background session per identifier and hands every task's answer to whichever session in the
/// process carries that identifier, so the two lanes can only stay apart by never sharing one.
public enum OutboxUploadSession {
    /// Stable across launches by definition: a background session is found again by this string,
    /// and changing it would strand every task in flight.
    public static let identifier = "live.discomarder.memosng.uploads"

    /// Minted once per process, the first time anything asks for it.
    ///
    /// A whole task's description carries it, so an answer can tell whether the process holding it
    /// is the one that sent the request — the only process that knows which credential that was.
    public static let processLaunch = UUID()

    public static func backgroundConfiguration(
        appGroup: String = OutboxDefaults.appGroup
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // The container the app group shares, so an original and the session that uploads it are
        // reachable from every process that may be launched to finish the capture.
        configuration.sharedContainerIdentifier = appGroup
        // Permissive here on purpose. A session's configuration is fixed for the life of the
        // process, so a session that refused cellular could not be told the person turned mobile
        // data on this afternoon. Each REQUEST carries the person's choice instead
        // (`OutboxRequests.wholeUpload`), and a task created under the other choice is replaced.
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        // Low Data Mode is a decision about the whole phone; no choice made in this app overrides
        // it, so it is refused here as well as on every request.
        configuration.allowsConstrainedNetworkAccess = false
        // Not discretionary: when the app is open and the network is right, the capture goes now.
        configuration.isDiscretionary = false
        // The system relaunches the app for a task that finished while it was gone. Without this,
        // a capture completed in the background is heard about only at the next foreground.
        configuration.sessionSendsLaunchEvents = true
        // The transport's own fence under the engine's budget: however many tasks exist, no more
        // than the budget's connections reach the server at once.
        configuration.httpMaximumConnectionsPerHost = UploadBudget.maxInFlightUploads
        return configuration
    }
}

/// Which networks one task's request may use, as the request itself says.
///
/// Read off the request a task was CREATED with, which the system keeps with the task across a
/// relaunch. That is what makes a toggle flipped while the app was gone detectable at all: the
/// process that chose the flags is gone, and the task is the only thing still holding them.
public struct WholeTaskNetworkAccess: Sendable, Equatable, Hashable {
    public var allowsCellular: Bool
    public var allowsExpensive: Bool
    public var allowsConstrained: Bool

    public init(allowsCellular: Bool, allowsExpensive: Bool, allowsConstrained: Bool) {
        self.allowsCellular = allowsCellular
        self.allowsExpensive = allowsExpensive
        self.allowsConstrained = allowsConstrained
    }

    public init(request: URLRequest) {
        self.init(
            allowsCellular: request.allowsCellularAccess,
            allowsExpensive: request.allowsExpensiveNetworkAccess,
            allowsConstrained: request.allowsConstrainedNetworkAccess
        )
    }

    /// What a whole task must carry under the person's choice. Mobile data decides cellular and
    /// expensive networks together — a personal hotspot is the phone's cellular by another road —
    /// and Low Data Mode is refused either way.
    public static func policy(allowsMobileData: Bool) -> WholeTaskNetworkAccess {
        WholeTaskNetworkAccess(
            allowsCellular: allowsMobileData,
            allowsExpensive: allowsMobileData,
            allowsConstrained: false
        )
    }
}

/// Where a listed task is in its life, as the session reports it.
public enum WholeTaskState: Sendable, Equatable {
    /// Sending, or waiting for a network its request allows.
    case running
    /// Created and not started.
    case suspended
    /// Asked to stop, and not yet ended: its terminal callback is still to come.
    case canceling
    /// Ended. Its answer has been, or is being, delivered.
    case completed

    public init(_ state: URLSessionTask.State) {
        switch state {
        case .running:
            self = .running
        case .suspended:
            self = .suspended
        case .canceling:
            self = .canceling
        case .completed:
            self = .completed
        @unknown default:
            // A state this build cannot name is read as one that sends nothing more, so nothing is
            // replaced on the strength of it.
            self = .completed
        }
    }
}

/// The upload session, as the scheduler needs to see it: list what it holds, start one task, cancel
/// one.
///
/// A protocol because a real background session cannot be driven from a unit test, and what the
/// scheduler decides from a listing — which tasks to cancel, which carry the wrong networks, when a
/// cancelled task has really gone — has to be asserted against listings a test writes.
public protocol UploadTaskSession: Sendable {
    /// Every task the session holds, whatever process created it, with the description, the
    /// network flags of its original request and its state, exactly as the session reports them.
    func allTasks() async -> [WholeTaskListing]
    /// Creates, describes and starts one upload task, SYNCHRONOUSLY: the caller has just been told
    /// it may send, and a suspension here is the window that answer goes stale in.
    /// - Returns: the new task's identifier.
    func uploadTask(with request: URLRequest, fromFile file: URL, description: String) -> Int
    /// Asks the session to cancel one task, and returns before the task has ended. A cancel is a
    /// request: only the task's terminal callback, or its absence from a later listing, says it is
    /// over.
    func cancel(taskIdentifier: Int) async
}

/// The adapter over a real `URLSession`.
///
/// `@unchecked Sendable` because its one stored property is a `URLSession`, which is thread-safe;
/// it holds no state of its own.
public final class URLSessionUploadTaskSession: UploadTaskSession, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func allTasks() async -> [WholeTaskListing] {
        await session.allTasks.map { task in
            WholeTaskListing(
                taskIdentifier: task.taskIdentifier,
                taskDescription: task.taskDescription,
                access: task.originalRequest.map(WholeTaskNetworkAccess.init(request:)),
                state: WholeTaskState(task.state)
            )
        }
    }

    public func uploadTask(
        with request: URLRequest, fromFile file: URL, description: String
    ) -> Int {
        let task = session.uploadTask(with: request, fromFile: file)
        // Described BEFORE it starts: its answer can arrive in the very next callback, and an
        // answer with no description is one nothing can apply.
        task.taskDescription = description
        task.resume()
        return task.taskIdentifier
    }

    public func cancel(taskIdentifier: Int) async {
        for task in await session.allTasks where task.taskIdentifier == taskIdentifier {
            task.cancel()
        }
    }
}
