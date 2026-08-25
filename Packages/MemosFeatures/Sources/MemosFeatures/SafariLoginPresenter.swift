import Foundation
import MemosCore
import SafariServices
import SwiftUI
import UIKit

/// The UI half of the native login: puts the household sign-on in an `SFSafariViewController` the
/// app presents ITSELF, and hands the callback URL back to the session store.
///
/// It used to be an `ASWebAuthenticationSession`, and that is the whole reason this exists. On one
/// household iPhone that session presented nothing at all: no sheet, no error, no request reaching
/// the server, `start()` returning true, and every piece of instrumentation put around it agreeing
/// that a sign-in had begun. The same build presented fine on another phone, and the "Advanced"
/// sheet presented fine on the failing one — so ordinary view-controller presentation worked and
/// only the system's own opaque presentation did not. There is nothing left to instrument inside
/// it, so it is gone: the browser view is presented by this code, through the same mechanism the
/// sheet that works uses, and every step of it can be seen.
///
/// The password is still never visible to the app. `SFSafariViewController` runs out of process:
/// its content, its cookies and its form fields belong to Safari, and the app can neither read the
/// page nor inject into it. That is also what keeps the standing household sign-on usable — the
/// session is shared with Safari, so a person who is already signed in is not asked again.
@MainActor
public final class SafariLoginPresenter: NSObject, NativeLoginPresenter {
    /// One attempt's objects, which exist only while it is on screen.
    ///
    /// The browser view is held STRONGLY, for the reason the authentication session had to be:
    /// as a local it belongs to a scope that ends the moment the continuation is handed over. It
    /// is also what a callback has to be able to take down, and the watchdog's evidence that the
    /// presentation happened at all.
    private struct Attempt {
        let continuation: CheckedContinuation<URL, any Error>
        let browser: SFSafariViewController
        /// Carried per attempt because they name the server that was typed into this one.
        let callbackHost: String
        let callbackPath: String
    }

    /// The view controller the browser view is presented from. Injectable so "there is nowhere to
    /// present" is a test rather than a device.
    private let resolveHost: @MainActor () -> UIViewController?
    private let inbox: NativeLoginCallbackInbox
    /// How long after presenting the view has to be on screen before the app stops believing it.
    private let watchdog: Duration
    private var flow = NativeLoginFlow()
    private var attempt: Attempt?

    public override init() {
        self.resolveHost = SafariLoginPresenter.currentHost
        self.inbox = .shared
        self.watchdog = .seconds(3)
        super.init()
    }

    init(
        host resolve: @escaping @MainActor () -> UIViewController?,
        inbox: NativeLoginCallbackInbox,
        watchdog: Duration = .seconds(3)
    ) {
        self.resolveHost = resolve
        self.inbox = inbox
        self.watchdog = watchdog
        super.init()
    }

    public func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        // Resolved BEFORE anything is built, so "there is nowhere to present" is a sentence the
        // sign-in screen shows rather than a presentation into a window attached to nothing —
        // which puts no view on screen and looks exactly like a button that did nothing.
        guard let host = resolveHost() else {
            MemosLog.session.error(
                "native sign-in: no foreground window scene to present the sign-in view on"
            )
            throw NativeLoginError.presentationFailed("no window is on screen to open it on")
        }
        // `SFSafariViewController` traps on a URL it cannot browse. It cannot happen —
        // `ServerConfiguration` only makes https base URLs — but a trap is a worse way to find out.
        guard let scheme = authorizeURL.scheme?.lowercased(), scheme == "https" else {
            MemosLog.session.error("native sign-in: the authorize URL is not an https URL")
            throw NativeLoginError.presentationFailed("the sign-in address cannot be opened")
        }
        guard attempt == nil else {
            MemosLog.session.error("native sign-in: a sign-in view is already open")
            throw NativeLoginError.presentationFailed("a sign-in is already open")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let browser = SFSafariViewController(url: authorizeURL)
            browser.delegate = self
            browser.dismissButtonStyle = .cancel
            attempt = Attempt(
                continuation: continuation,
                browser: browser,
                callbackHost: callbackHost,
                callbackPath: callbackPath
            )
            // Registered BEFORE the view is on screen: a return trip cannot be faster than the
            // presentation animation, but a wait that starts after it is a race for no reason.
            inbox.waitForCallback { [weak self] url in
                guard let self, let attempt = self.attempt,
                    let lane = NativeLoginReturn.lane(
                        of: url,
                        callbackHost: attempt.callbackHost,
                        callbackPath: attempt.callbackPath
                    )
                else { return false }
                self.apply(self.flow.receive(.callback(url, lane)))
                return true
            }
            _ = flow.receive(.presented)
            MemosLog.session.info("native sign-in: presenting the sign-in view")
            host.present(browser, animated: true)
            watchPresentation()
        }
    }

    /// The exchange that follows a delivered callback is the session store's, and its outcome is
    /// reported back here so the attempt has an end rather than just stopping. It is also the last
    /// line in the log of a sign-in, which on a device nobody can attach to is the difference
    /// between "it failed" and "it never got that far".
    public func exchangeFinished(succeeded: Bool) {
        apply(flow.receive(.exchangeFinished(succeeded: succeeded)))
    }

    /// Did the view actually come up?
    ///
    /// The failure being designed around presented nothing while reporting success, so success is
    /// not taken on anyone's word: a moment after presenting, the browser view either has a window
    /// or the attempt is over with a sentence saying so.
    ///
    /// It is emphatically NOT a limit on how long a sign-in may take. Once the view is on screen
    /// this never fires again, whatever happens in it — and it must not, because the return trip
    /// ends with a person reading a page and tapping "Return to memosng" on it. A timer that gave
    /// up while somebody was looking at that button would be this bug with a new face.
    private func watchPresentation() {
        let delay = watchdog
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let attempt = self.attempt, self.flow.state == .presenting else {
                return
            }
            if attempt.browser.viewIfLoaded?.window == nil {
                MemosLog.session.error(
                    "native sign-in: the sign-in view is not on screen after presenting it"
                )
                self.apply(self.flow.receive(.timedOut))
            } else {
                MemosLog.session.info("native sign-in: the sign-in view is on screen")
            }
        }
    }

    /// Does what the machine decided, and nothing the machine did not.
    private func apply(_ effect: NativeLoginFlow.Effect) {
        switch effect {
        case .nothing:
            break
        case .deliver(let url, let lane):
            MemosLog.session.info(
                "native sign-in: the callback arrived on the \(lane.description, privacy: .public)"
            )
            endPresentation()?.continuation.resume(returning: url)
        case .abandon(let error):
            let detail = error.message ?? "no reason given"
            MemosLog.session.error(
                "native sign-in ended without a callback: \(detail, privacy: .public)"
            )
            endPresentation()?.continuation.resume(throwing: error)
        case .settle:
            let outcome = String(describing: flow.state)
            MemosLog.session.info(
                "native sign-in: the attempt ended \(outcome, privacy: .public)"
            )
        }
    }

    /// Takes the attempt down and hands it back to be resumed.
    ///
    /// The attempt is cleared BEFORE the caller resumes anything: that, and not the machine's
    /// state, is what makes it impossible to resume one continuation twice when both return lanes
    /// deliver the same callback. Returns `nil` when there is nothing left to end.
    private func endPresentation() -> Attempt? {
        guard let attempt else { return nil }
        self.attempt = nil
        inbox.stopWaiting()
        // Dismissed by the app, so the delegate's "the person closed it" does not fire — and if a
        // future iOS decides it should, the machine has already left `presenting` and ignores it.
        attempt.browser.presentingViewController?.dismiss(animated: true)
        return attempt
    }

    /// The view controller the browser view is put on top of.
    ///
    /// Which SCENE is on screen is decided by `LoginAnchor`, on a description rather than on UIKit
    /// itself, because `connectedScenes` is a set with no order and getting it wrong is invisible
    /// on a single-scene simulator. From that scene's window this walks up whatever is already
    /// presented — the "Advanced" sheet, most obviously — because UIKit refuses to present from a
    /// controller that is already presenting something, and a refused presentation is silent.
    private static func currentHost() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let described = scenes.map {
            LoginAnchor.SceneState(
                activation: LoginAnchor.Activation($0.activationState),
                windowIsKey: $0.windows.map(\.isKeyWindow)
            )
        }
        guard case .window(let scene, let window) = LoginAnchor.choice(among: described),
            let root = scenes[scene].windows[window].rootViewController
        else { return nil }
        var top = root
        while let above = top.presentedViewController, !above.isBeingDismissed {
            top = above
        }
        return top
    }
}

extension SafariLoginPresenter: SFSafariViewControllerDelegate {
    /// The person closed the browser view. It is the only cancel signal there is, and it cannot
    /// tell a deliberate close apart from a finished login whose callback never came back — so it
    /// is reported either way, and never silently.
    public nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated {
            apply(flow.receive(.dismissed))
        }
    }

    /// Instrumentation only. A first load that failed is a sign-in that could never have worked,
    /// and it is otherwise indistinguishable from a person who did not try.
    public nonisolated func safariViewController(
        _ controller: SFSafariViewController,
        didCompleteInitialLoad didLoadSuccessfully: Bool
    ) {
        MainActor.assumeIsolated {
            MemosLog.session.info(
                "native sign-in: the sign-on page loaded: \(didLoadSuccessfully, privacy: .public)"
            )
        }
    }

    /// The browser followed a redirect. Two things at once.
    ///
    /// It is the log line that says how far a sign-in got, which is what was missing when the old
    /// session failed — and only the scheme, host and path of it, never the query, because the
    /// callback's query carries the one-shot handoff code.
    ///
    /// It is also a third way for the callback to be noticed. A universal link opens the app when
    /// somebody TAPS it; a server redirect to the same address inside a browser view often just
    /// loads it. Seeing it here needs neither an association Apple has published nor a link
    /// anybody tapped, and it hands the URL to the same machine, in the same lane, as the other
    /// two.
    public nonisolated func safariViewController(
        _ controller: SFSafariViewController,
        initialLoadDidRedirectTo url: URL
    ) {
        MainActor.assumeIsolated {
            // Only the scheme, host and path of it: a callback's query carries the one-shot
            // handoff code, and no log line is worth putting a credential in one for.
            let destination = "\(url.scheme ?? "?")://\(url.host() ?? "?")\(url.path())"
            MemosLog.session.info(
                "native sign-in: the browser went to \(destination, privacy: .public)"
            )
            guard let attempt,
                let lane = NativeLoginReturn.lane(
                    of: url,
                    callbackHost: attempt.callbackHost,
                    callbackPath: attempt.callbackPath
                )
            else { return }
            apply(flow.receive(.callback(url, lane)))
        }
    }
}

extension LoginAnchor.Activation {
    init(_ state: UIScene.ActivationState) {
        switch state {
        case .foregroundActive: self = .foregroundActive
        case .foregroundInactive: self = .foregroundInactive
        case .background: self = .background
        case .unattached: self = .unattached
        // A state this build has no name for is one it cannot claim is on screen.
        @unknown default: self = .unattached
        }
    }
}
