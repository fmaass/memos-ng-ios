import Foundation

/// Why a capture is not moving, sorted by what brings it back.
///
/// Three classes and three answers, so that no single curve has to be right for every failure:
///
/// - `transient` — a socket drop, a 408, a 5xx, a 429. The server or the path between hiccuped and
///   will most likely take the same request seconds later. Spaced by `RetrySchedule`: the server's
///   own `Retry-After` when it named one, else 2, 4, 8, 32 and then every 60 s. Never longer than a
///   minute on the curve, and never dropped.
/// - `connectivity` — there is no path, or the policy says this path may not carry this capture.
///   No timer at all: nothing the clock does changes the network, and the path event resumes it.
/// - `hold` — the grant turned away, a 413, a capture made under another account. No timer either:
///   repeating cannot fix it, and the named fix (`HoldReason.fixAction`) resumes it.
public enum RetryClass: String, Sendable, Equatable, CaseIterable {
    case transient
    case connectivity
    case hold
}

/// How long a transient failure waits before it tries again.
///
/// Seconds, not hours: a transient failure is one the same request most likely survives a moment
/// later, and a capture that sat out fifteen minutes for a dropped socket is the delay this
/// replaced (MEMNG-955). The curve is capped at one minute and there is still no failure count at
/// which a job is dropped: the whole promise of the outbox is that a capture is not lost. What is
/// NOT transient does not come here at all — a missing network and a refusal wait on an event
/// (`RetryClass`), never on this clock.
public enum RetrySchedule {
    /// The spacing of the first five failures, in order; every later one waits `cap`.
    public static let steps: [TimeInterval] = [2, 4, 8, 32, 60]
    /// The longest the curve ever waits. A server's own `Retry-After` is taken as named instead.
    public static let cap: TimeInterval = 60

    /// The first failure's spacing.
    public static var base: TimeInterval { steps[0] }

    /// `attempt` is the number of attempts that have now failed, counting from 1.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        let index = Swift.min(Swift.max(attempt, 1), steps.count) - 1
        return Swift.min(steps[index], cap)
    }

    /// The transient class's next attempt: the server's `Retry-After` when it gave a usable one,
    /// raised to `UploadBudget.shortestRetryAfter`, otherwise the curve.
    public static func nextAttempt(
        afterFailure attempt: Int, from now: Date, retryAfter: TimeInterval? = nil
    ) -> Date {
        if let retryAfter, retryAfter >= 0, retryAfter <= UploadBudget.longestRetryAfter {
            return now.addingTimeInterval(Swift.max(retryAfter, UploadBudget.shortestRetryAfter))
        }
        return now.addingTimeInterval(delay(forAttempt: attempt))
    }

    /// The whole lane's per-file spacing: full jitter over the same curve, unless the server named
    /// its own delay.
    ///
    /// A separate entry point because the curve above also spaces the chunk lane and the memo
    /// create, which one job at a time never storms. Files of one capture fail together — the same
    /// rate limit, the same outage — and identical delays would bring them back together.
    ///
    /// - Parameters:
    ///   - retryAfter: seconds the server asked for, which REPLACE the curve un-jittered and are
    ///     taken as named down to `UploadBudget.shortestRetryAfter`: `cap` bounds the curve this
    ///     computes, not a delay the server chose.
    ///   - rng: a draw in `[0, 1]`; the live one is the system generator.
    public static func delay(
        forAttempt attempt: Int,
        retryAfter: TimeInterval?,
        rng: () -> Double
    ) -> TimeInterval {
        if let retryAfter, retryAfter >= 0 {
            return Swift.max(retryAfter, UploadBudget.shortestRetryAfter)
        }
        let draw = Swift.min(Swift.max(rng(), 0), 1)
        return delay(forAttempt: attempt) * draw
    }
}
