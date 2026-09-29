import Foundation

/// How long the channel waits before opening the stream again.
///
/// Not `RetrySchedule` from the outbox: that one is built for a capture that must survive a week
/// offline (15 minutes to 6 hours), and a live channel that waited 15 minutes to notice the server
/// came back would be no channel at all. The scales are different because the promises are.
///
/// Jittered. One device holds one connection, but an outage drops every device's connection at the
/// same instant, and a deterministic schedule then brings them all back at the same instants too —
/// the 2026-09-28 reconnect flood against a server whose connection pool was exhausted was exactly
/// that herd. `delay(forAttempt:serverHint:)` is the ceiling a test can state exactly; the wait
/// actually taken is drawn below it by `wait(forAttempt:serverHint:jitter:)`.
public struct SSEBackoff: Sendable, Equatable {
    /// The first wait, and the multiplicand every later one doubles from.
    public var base: TimeInterval
    /// The longest this client will impose on itself.
    public var cap: TimeInterval

    public init(base: TimeInterval = 1, cap: TimeInterval = 30) {
        self.base = base
        self.cap = cap
    }

    /// - Parameters:
    ///   - attempt: how many attempts have now failed, counting from 1.
    ///   - serverHint: the stream's own `retry:` in seconds, when it sent one. It REPLACES the
    ///     base rather than being clamped to it — a server that asks for a minute is stating a
    ///     fact about itself, and a client that halved it would be arguing with the answer. It
    ///     also raises the ceiling for the same reason, so the hint is never quietly shrunk.
    public func delay(forAttempt attempt: Int, serverHint: TimeInterval? = nil) -> TimeInterval {
        let start = max(serverHint ?? base, 0)
        guard attempt > 1 else { return start }
        // Bounded before use: `pow` on a large attempt count overflows to infinity, and a sleep of
        // infinity is a channel that never comes back.
        let exponent = Double(min(attempt - 1, 16))
        return min(start * pow(2, exponent), max(cap, start))
    }

    /// The wait actually taken: full jitter, drawn uniformly between the floor and
    /// `delay(forAttempt:serverHint:)`.
    ///
    /// The floor is zero, except under a stream `retry:` hint, where it is the hint itself: the
    /// jitter spreads the herd out AFTER the time the server asked for, never before it, for the
    /// reason the hint is never shrunk above.
    public func wait(
        forAttempt attempt: Int,
        serverHint: TimeInterval? = nil,
        jitter: any SSEJitter
    ) -> TimeInterval {
        let ceiling = delay(forAttempt: attempt, serverHint: serverHint)
        let floor = min(max(serverHint ?? 0, 0), ceiling)
        let draw = min(max(jitter.unit(), 0), 1)
        return floor + draw * (ceiling - floor)
    }
}

/// Where the jitter's randomness comes from, as a dependency — so a test can state the exact wait
/// a given draw produces instead of only its bounds.
public protocol SSEJitter: Sendable {
    /// A value in `0...1`. Anything outside it is clamped by the caller.
    func unit() -> Double
}

/// The real one: the system random number generator.
public struct SystemSSEJitter: SSEJitter {
    public init() {}

    public func unit() -> Double {
        Double.random(in: 0...1)
    }
}

/// Waiting, as a dependency — so the reconnect schedule can be asserted in a test without the
/// test taking as long as the schedule.
public protocol SSESleeper: Sendable {
    func sleep(for duration: TimeInterval) async throws
}

/// The real one. `ContinuousClock` keeps counting while the device is asleep, which is the right
/// clock for "how long since the connection dropped".
public struct ContinuousClockSleeper: SSESleeper {
    public init() {}

    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(duration))
    }
}
