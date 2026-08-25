import Foundation
import Network

/// The system's own answer to "what network is this", kept current and reported when it changes.
///
/// `@unchecked Sendable` with a lock rather than an actor, for the same reason the session
/// delegate is one: `NWPathMonitor` calls back on its own queue, and the drain reads the path
/// synchronously at the moment before it would send bytes. A read that had to await could not be
/// the last thing that happens before a request goes out.
public final class NetworkPathMonitor: NetworkPathProviding, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// Cellular until the monitor says otherwise: the value is replaced in the initialiser below,
    /// and if that ever failed to happen the safe reading of an unknown network is the one that
    /// waits rather than the one that spends a phone plan.
    private var path = NetworkPath.cellular
    private var handler: OutboxTrigger?

    public init() {
        path = NetworkPath(monitor.currentPath)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.adopt(NetworkPath(path))
        }
        monitor.start(queue: DispatchQueue(label: "\(OutboxSession.identifier).path"))
    }

    deinit {
        monitor.cancel()
    }

    public func currentPath() -> NetworkPath {
        lock.withLock { path }
    }

    public func onPathChange(_ handler: @escaping OutboxTrigger) {
        lock.withLock { self.handler = handler }
    }

    /// Only a CHANGE is reported. The monitor repeats itself whenever any detail of a path moves,
    /// and a drain started for a detail the outbox does not read is a request for nothing.
    private func adopt(_ next: NetworkPath) {
        let handler: OutboxTrigger? = lock.withLock {
            guard next != path else { return nil }
            path = next
            return self.handler
        }
        guard let handler else { return }
        Task { await handler() }
    }
}

extension NetworkPath {
    /// What the system says, in the three terms the policy is written in.
    public init(_ path: NWPath) {
        self.init(
            usesCellular: path.usesInterfaceType(.cellular),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
