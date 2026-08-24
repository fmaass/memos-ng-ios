import Foundation
import MemosAPI

/// Ending the wait without anybody tapping anything.
///
/// A memo is created before its pictures are derived: the server accepts the upload, links it, and
/// its worker produces the thumbnail and the preview afterwards. Until then the attachment is
/// `pending`/`processing` and there is nothing to fetch — the card shows a WAITING treatment (see
/// `AttachmentReadiness`). Nothing on the phone can end that state; only asking the server again
/// can, and a person should not have to know that pulling the timeline down is how you find out
/// whether your own photo has arrived.
///
/// So while a memo on screen is still waiting, it is re-read on a capped backoff: 3s, 6s, 12s,
/// 24s, then every 30s. The backoff is the whole reason this is a schedule rather than a timer —
/// the common case resolves within a few seconds, and a slow one must not turn into a request per
/// second per card for as long as somebody leaves the app open.
///
/// SEAM (phase 5c — SSE): `GET /api/events` already pushes media-ready events to the web app. When
/// the client subscribes to that stream, this poll is what it REPLACES: the loop goes, and
/// `TimelineStore.refreshMemo` becomes the handler for one `media` event. Nothing else here
/// outlives that change.
public enum TierReadinessPoll {
    /// Substituted in tests, so the schedule is asserted rather than waited out.
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// The first wait. Short, because the common case is a few seconds of worker time.
    public static let firstDelay: Duration = .seconds(3)
    /// The longest it ever waits. A memo whose worker job is stuck must cost about two requests a
    /// minute, not one a second.
    public static let maximumDelay: Duration = .seconds(30)

    /// 3s, 6s, 12s, 24s, 30s, 30s… — doubling until the cap, then flat.
    ///
    /// Pure, so the schedule can be stated as numbers in a test instead of measured with a
    /// stopwatch against a running server.
    public static func delay(afterAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return firstDelay }
        var delay = firstDelay
        for _ in 0..<attempt {
            delay += delay
            if delay >= maximumDelay { return maximumDelay }
        }
        return delay
    }

    /// Re-reads one memo until nothing on it is waiting any more.
    ///
    /// It is a plain `async` function rather than a timer object because that is what makes the
    /// lifetime somebody else's problem in the right way: the view starts it in a `.task`, and
    /// SwiftUI cancels that task when the row goes away. Every step checks cancellation, so a
    /// screen that has been left stops asking about a memo nobody is looking at.
    ///
    /// It also stops on its own when the answer arrives (nothing waiting), when the memo is no
    /// longer loaded at all (deleted, or scrolled out of the loaded window), and when a re-read
    /// fails — a poll is a background convenience, and one that keeps retrying against an error is
    /// how a background convenience turns into a request storm.
    @MainActor
    public static func run(
        uid: String,
        in store: TimelineStore,
        using client: any APIProtocol,
        baseURL: URL,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            guard let memo = store.memos.first(where: { $0.uid == uid }), memo.isAwaitingTiers
            else { return }
            // Waiting FIRST: the memo was read from the server moments ago, so asking again
            // immediately would only re-fetch what is already on screen.
            do {
                try await sleep(delay(afterAttempt: attempt))
            } catch {
                return  // cancelled mid-wait
            }
            attempt += 1
            guard !Task.isCancelled else { return }
            guard await store.refreshMemo(uid: uid, using: client, baseURL: baseURL) else {
                return
            }
        }
    }
}
