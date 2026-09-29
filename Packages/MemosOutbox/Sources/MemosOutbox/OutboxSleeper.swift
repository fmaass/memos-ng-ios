import Foundation

/// How the engine waits for a file's deadline.
///
/// A protocol because a deadline is a duration, and a test that slept it would be a test of the
/// clock rather than of the engine: the tests hand in a sleeper they advance themselves.
public protocol OutboxSleeping: Sendable {
    /// Returns once `deadline` has passed, or throws `CancellationError` once the calling task is
    /// cancelled — whichever comes first.
    func sleep(until deadline: Date) async throws
}

/// The system's sleep, measured against the wall clock the engine's own clock defaults to.
public struct SystemSleeper: OutboxSleeping {
    public init() {}

    public func sleep(until deadline: Date) async throws {
        let interval = Swift.max(deadline.timeIntervalSinceNow, 0)
        try await Task.sleep(for: .seconds(interval))
    }
}
