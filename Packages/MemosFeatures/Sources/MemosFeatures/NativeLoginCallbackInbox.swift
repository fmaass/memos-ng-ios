import Foundation
import MemosCore

/// Where a URL the app was opened with meets the sign-in that is waiting for one.
///
/// The two are far apart: the URL arrives on the scene — `onOpenURL`, or a browsing user activity
/// for a universal link — and the sign-in waiting for it is a presenter created by a button three
/// layers down. This is the one seam between them, and it is deliberately dumb: it holds at most
/// one waiter, hands it each URL, and keeps the ones nobody claims out of the flow entirely.
///
/// The claim, not the inbox, decides what belongs to the sign-in. Every URL the app opens for any
/// reason passes through here, and a shared-memo link must not resolve a sign-in.
@MainActor
public final class NativeLoginCallbackInbox {
    /// The one the app's scene delivers into. A presenter may be given its own instead, which is
    /// what makes the delivery path a test rather than a device.
    public static let shared = NativeLoginCallbackInbox()

    /// `true` when the waiter recognised the URL as its own.
    private var claim: ((URL) -> Bool)?

    init() {}

    /// Wait for a callback. At most one sign-in waits at a time — a second replaces the first,
    /// which cannot happen through the presenter but is defined rather than left to chance.
    func waitForCallback(_ claim: @escaping (URL) -> Bool) {
        self.claim = claim
    }

    func stopWaiting() {
        claim = nil
    }

    /// Offer a URL to whatever is waiting.
    ///
    /// - Returns: `true` if a waiting sign-in took it.
    @discardableResult
    public func deliver(_ url: URL) -> Bool {
        // Copied out first: claiming the URL is what ends the wait, and the claim closure clears
        // this property while it runs.
        guard let claim else {
            MemosLog.session.debug("native sign-in: a URL arrived with no sign-in waiting for one")
            return false
        }
        let taken = claim(url)
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
