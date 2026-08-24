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
}
