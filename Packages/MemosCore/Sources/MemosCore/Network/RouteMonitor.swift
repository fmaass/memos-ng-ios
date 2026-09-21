import Foundation
import Network

/// A route that has come back, and the outage it closes.
public struct RouteRegain: Sendable, Equatable {
    /// The ordinal of the LOSS this regain ends, taken at the monitor's own callback before any
    /// hop. It is what associates a regain with the recovery it belongs to: delivery order cannot,
    /// because a loss, a regain and a confirmation already in flight reach a store in any order.
    public let lossOrdinal: Int

    public init(lossOrdinal: Int) {
        self.lossOrdinal = lossOrdinal
    }
}

/// What the session asks about the route, and what it is told when one comes back.
///
/// Two halves on purpose. The count is read SYNCHRONOUSLY, in the instant before a check goes
/// out — the `issuedUnder:` idiom of a credential epoch, here for a route — and the regains
/// arrive as a stream, in the order the callback saw them. A double scripts the two separately,
/// which is the only way to stage a loss counted between a request and its answer.
public protocol RouteStatusMonitoring: Sendable {
    func lossesSeen() -> Int
    var regains: AsyncStream<RouteRegain> { get }
}

/// What a change of status MEANS, without the framework around it.
///
/// Separate from the monitor below because this is the whole of the rule and none of it can be
/// exercised through `NWPathMonitor`: a test drives the statuses and reads what came out.
struct RouteStatusLedger {
    private(set) var losses = 0
    private var routed: Bool

    init(routed: Bool) {
        self.routed = routed
    }

    /// Only a CHANGE is anything. `NWPathMonitor` repeats itself whenever any detail of a path
    /// moves, and a monitor that reported each one would turn a flapping interface into a request
    /// storm.
    ///
    /// A satisfied path with no counted loss behind it is the BASELINE — the path this process
    /// started on, or a detail change on a route that never went down — and nothing was lost for
    /// it to give back.
    mutating func adopt(satisfied: Bool) -> RouteRegain? {
        guard satisfied != routed else { return nil }
        routed = satisfied
        guard satisfied else {
            losses += 1
            return nil
        }
        guard losses > 0 else { return nil }
        return RouteRegain(lossOrdinal: losses)
    }
}

/// The system's own answer to "is there a route at all", counted and reported.
///
/// `@unchecked Sendable` with a lock rather than an actor, for the reason the outbox's own monitor
/// is one: `NWPathMonitor` calls back on its own queue, and the loss count has to be readable in
/// the instant before a request goes out. A read that had to await could not be the last thing that
/// happens before the question is asked.
///
/// It is a SECOND `NWPathMonitor`, beside the outbox's, and that is deliberate: the outbox's
/// `NetworkPath` keeps the three terms its spend policy is written in and no status at all, so "a
/// route came back" cannot be read out of it. One extra monitor buys that policy staying exactly as
/// it is.
public final class NetworkRouteMonitor: RouteStatusMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var ledger: RouteStatusLedger
    private let events: AsyncStream<RouteRegain>.Continuation
    public let regains: AsyncStream<RouteRegain>

    public init() {
        var events: AsyncStream<RouteRegain>.Continuation!
        regains = AsyncStream<RouteRegain> { events = $0 }
        self.events = events
        ledger = RouteStatusLedger(routed: monitor.currentPath.status == .satisfied)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.adopt(satisfied: path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: Self.queue))
    }

    deinit {
        monitor.cancel()
        events.finish()
    }

    public func lossesSeen() -> Int {
        lock.withLock { ledger.losses }
    }

    /// The ordinal is taken HERE, under the lock, before anything hops: which outage a regain
    /// closes is a fact about the callback, not about the order two deliveries happen to arrive in.
    private func adopt(satisfied: Bool) {
        let regain = lock.withLock { ledger.adopt(satisfied: satisfied) }
        guard let regain else { return }
        events.yield(regain)
    }

    private static let queue = "com.memos.ng.route"
}
