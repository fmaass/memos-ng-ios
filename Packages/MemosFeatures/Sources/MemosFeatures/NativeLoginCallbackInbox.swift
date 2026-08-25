import Foundation
import MemosCore

/// Where a URL the app was opened with meets the sign-in that is waiting for one.
///
/// The two are far apart: the URL arrives on the scene — `onOpenURL`, or a browsing user activity
/// for a universal link — and the sign-in waiting for it is a presenter created by a button three
/// layers down. This is the one seam between them, and it is deliberately dumb: it holds at most
/// one waiter, hands it each URL, and keeps the ones nobody claims out of the flow entirely.
///
/// The entry is bound to the ATTEMPT that registered it. A sign-in that ends takes its entry with
/// it by name, so an entry belonging to a cancelled attempt cannot still be sitting here when the
/// next one starts — and `stopWaiting(for:)` from a dead attempt cannot unregister the live one's.
///
/// The claim, not the inbox, decides what belongs to the sign-in. Every URL the app opens for any
/// reason passes through here, and a shared-memo link must not resolve a sign-in.
@MainActor
public final class NativeLoginCallbackInbox {
    /// The one the app's scene delivers into. A presenter may be given its own instead, which is
    /// what makes the delivery path a test rather than a device.
    public static let shared = NativeLoginCallbackInbox()

    private struct Entry {
        let attempt: NativeLoginFlow.Attempt
        /// `true` when the waiter recognised the URL as its own.
        let claim: (URL) -> Bool
    }

    private var entry: Entry?

    init() {}

    /// The attempt currently waiting for a callback, if any. Readable so a test can assert that a
    /// finished sign-in left nothing of itself behind.
    var waitingFor: NativeLoginFlow.Attempt? { entry?.attempt }

    /// Wait for a callback on behalf of one attempt. At most one waits at a time; a later attempt
    /// replaces an earlier one, which is what a supersede would need and what a retry does.
    func waitForCallback(
        for attempt: NativeLoginFlow.Attempt,
        _ claim: @escaping (URL) -> Bool
    ) {
        entry = Entry(attempt: attempt, claim: claim)
    }

    /// Stop waiting, but only if the entry still belongs to this attempt.
    ///
    /// The fence matters on the teardown as much as on the delivery: an attempt that ends after
    /// the next one has already registered would otherwise silently unregister ITS entry, and the
    /// sign-in the person is looking at would stop being able to receive its own callback.
    func stopWaiting(for attempt: NativeLoginFlow.Attempt) {
        guard entry?.attempt == attempt else { return }
        entry = nil
    }

    /// Offer a URL to whatever is waiting.
    ///
    /// - Returns: `true` if a waiting sign-in took it.
    @discardableResult
    public func deliver(_ url: URL) -> Bool {
        // Copied out first: claiming the URL is what ends the wait, and the claim closure clears
        // this property while it runs.
        guard let entry else {
            MemosLog.session.debug("native sign-in: a URL arrived with no sign-in waiting for one")
            return false
        }
        let taken = entry.claim(url)
        if !taken {
            // Deliberately without the URL: the callback's query carries the one-shot handoff
            // code, and nothing about a URL is worth putting a credential into a log for.
            MemosLog.session.debug(
                "native sign-in: a URL arrived that is not the callback being waited for"
            )
        }
        return taken
    }
}
