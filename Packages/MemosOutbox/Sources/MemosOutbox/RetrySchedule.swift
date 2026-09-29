import Foundation

/// How long a failed job waits before it tries again.
///
/// Capped exponential spacing, and no failure count at which a job is dropped: the whole promise
/// of the outbox is that a capture is not lost, so the worst case is a job that retries every six
/// hours until someone looks at it — never one that disappears.
public enum RetrySchedule {
    public static let base: TimeInterval = 15 * 60
    public static let cap: TimeInterval = 6 * 60 * 60

    /// `attempt` is the number of attempts that have now failed, counting from 1.
    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return base }
        // The exponent is bounded before it is used: `pow` on a large attempt count overflows to
        // infinity, and `Date + .infinity` is not a date.
        let exponent = Double(Swift.min(attempt - 1, 16))
        return Swift.min(base * pow(2, exponent), cap)
    }

    public static func nextAttempt(afterFailure attempt: Int, from now: Date) -> Date {
        now.addingTimeInterval(delay(forAttempt: attempt))
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
    ///     taken as named: `cap` bounds the curve this computes, not a delay the server chose.
    ///   - rng: a draw in `[0, 1]`; the live one is the system generator.
    public static func delay(
        forAttempt attempt: Int,
        retryAfter: TimeInterval?,
        rng: () -> Double
    ) -> TimeInterval {
        if let retryAfter, retryAfter >= 0 { return retryAfter }
        let draw = Swift.min(Swift.max(rng(), 0), 1)
        return delay(forAttempt: attempt) * draw
    }
}
