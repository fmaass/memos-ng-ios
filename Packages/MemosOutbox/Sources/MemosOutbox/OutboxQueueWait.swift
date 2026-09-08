import Foundation

/// The one source of time a bounded wait reads: the instant its deadline is measured from, and the
/// sleep it spends getting there.
///
/// One protocol rather than two seams, because those two readings have to be the same clock. A fake
/// sleep measured against the real one never expires — the wait would spend its whole budget in an
/// instant and prove nothing about the bound — and a real sleep measured against a fake one waits
/// out the wall time nobody wants in a test. Here a sleep MOVES `now`, so the deadline is reached
/// by the very thing that waits for it.
public protocol OutboxWaitClock: Sendable {
    /// Monotonic. Only the difference between two readings is ever used, never the value.
    var now: ContinuousClock.Instant { get }
    func sleep(for duration: Duration) async throws
}

/// Time as the share extension actually spends it.
public struct OutboxSystemWaitClock: OutboxWaitClock {
    public init() {}

    public var now: ContinuousClock.Instant { ContinuousClock.now }

    /// A suspension, never a parked thread: an extension is a small process the system kills
    /// without asking, and a thread blocked in it is a share sheet that has stopped answering.
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, clock: ContinuousClock())
    }
}

/// Runs `capture`, and while the queue answers "busy" runs it again — every `interval`, until
/// `budget` is spent — then rethrows the refusal it was given last.
///
/// It exists because the queue's refusal is not a failure of the capture: the outbox root is held
/// for the length of one sweep or one other capture, and the share extension asking again a moment
/// later gets in. Surfacing that instant to the person as "this share could not be saved" would
/// make a lock they cannot see into a memo they have to write twice.
///
/// ONLY the typed refusal is retried, and both of its reasons are: `contended` says another holder
/// has the root, and `unavailable` says this process could not ask — which is no evidence about the
/// other one, may be a descriptor limit that clears, and is refused rather than published for
/// exactly that reason. Every other error is the capture itself failing and propagates at once; a
/// disk that is full does not empty in three seconds.
///
/// Deliberately NOT on `OutboxRepository`: the actor has no suspension point in it and is not going
/// to grow one for a wait — a queue that slept inside its own isolation would hold every other
/// caller of the queue behind the process it is waiting for.
///
/// - Parameter capture: the whole attempt, re-run from the top each time. Everything it reads —
///   the licence, the authority it commits under — is therefore read again on every attempt rather
///   than sampled once and replayed, which is what makes a wait safe to put in front of a write
///   that an account change may no longer be entitled to.
public func retryingWhileQueueBusy<T>(
    every interval: Duration = .milliseconds(100),
    within budget: Duration = .seconds(3),
    on clock: any OutboxWaitClock = OutboxSystemWaitClock(),
    _ capture: () async throws -> T
) async throws -> T {
    let deadline = clock.now.advanced(by: budget)
    while true {
        do {
            return try await capture()
        } catch let refusal as OutboxStorageError {
            guard case .queueBusy = refusal else { throw refusal }
            // Read from the same clock the sleep below moves, and read AFTER the attempt: the
            // budget bounds how long somebody is made to wait, so the last attempt is the one that
            // finds the deadline reached, not the one before it.
            guard clock.now < deadline else { throw refusal }
            try await clock.sleep(for: interval)
        }
    }
}
