import Foundation
import MemosCore
import SwiftUI
import UIKit

/// The UI half of the native login: puts the household sign-on in a browser view the app presents
/// ITSELF, and hands the callback URL back to the session store.
///
/// It used to be an `ASWebAuthenticationSession`, and that is the whole reason this exists. On one
/// household iPhone that session presented nothing at all: no sheet, no error, no request reaching
/// the server, `start()` returning true, and every piece of instrumentation put around it agreeing
/// that a sign-in had begun. A device capture found the cause — that phone holds no domain
/// association for the server's host, and the session reports that refusal with the same code it
/// uses for a person closing the sheet. There is nothing left to instrument inside it.
///
/// The password is still never visible to the app: the browser view runs out of process, and its
/// content, cookies and form fields belong to Safari.
///
/// Every signal this class receives is fenced to the ATTEMPT it was created for. A browser view
/// closing, a watchdog firing and a URL arriving from outside the process can all reach here after
/// the attempt that produced them has ended and another has begun; without the fence each of them
/// cancels or fails a sign-in it has nothing to do with. The fence is `NativeLoginFlow.Attempt`,
/// checked by the machine, and it is the same generation fence the rest of the app uses.
@MainActor
public final class SafariLoginPresenter: NSObject, NativeLoginPresenter {
    /// One attempt's objects, which exist only while it is on screen.
    private struct Live {
        let attempt: NativeLoginFlow.Attempt
        let continuation: CheckedContinuation<URL, any Error>
        let browser: any LoginBrowser
        /// Carried per attempt because they name the server that was typed into this one.
        let callbackHost: String
        let callbackPath: String
    }

    /// The view controller the browser view is presented from. Injectable so "there is nowhere to
    /// present" is a test rather than a device.
    private let resolveHost: @MainActor () -> UIViewController?
    /// How a browser view is made. Injectable for the same reason: the interleavings that broke
    /// this flow cannot be produced through a real one.
    private let makeBrowser: @MainActor (URL) -> any LoginBrowser
    private let inbox: NativeLoginCallbackInbox
    /// How long after presenting the view has to be on screen before the app stops believing it.
    private let watchdog: Duration
    private var flow = NativeLoginFlow()
    private var live: Live?

    public override init() {
        self.resolveHost = SafariLoginPresenter.currentHost
        self.makeBrowser = { SafariLoginBrowser(url: $0) }
        self.inbox = .shared
        self.watchdog = .seconds(3)
        super.init()
    }

    init(
        host resolve: @escaping @MainActor () -> UIViewController?,
        inbox: NativeLoginCallbackInbox,
        watchdog: Duration = .seconds(3),
        makeBrowser: @escaping @MainActor (URL) -> any LoginBrowser = {
            SafariLoginBrowser(url: $0)
        }
    ) {
        self.resolveHost = resolve
        self.makeBrowser = makeBrowser
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
        // The browser view cannot open anything but http(s) and TRAPS on a URL it cannot browse.
        // It cannot happen — `ServerConfiguration` only makes https base URLs — but a trap is a
        // worse way to find that out than a sentence on the screen.
        guard let scheme = authorizeURL.scheme?.lowercased(), scheme == "https" else {
            MemosLog.session.error("native sign-in: the authorize URL is not an https URL")
            throw NativeLoginError.presentationFailed("the sign-in address cannot be opened")
        }
        // The machine decides whether this tap opens anything. A tap arriving while a sign-in is
        // already on screen is ignored there, and this is the shape that refusal takes out here:
        // it is not an error to report, because nothing went wrong and the sign-in the person is
        // looking at is still running. Reporting it would paint a failure over a working sign-in
        // AND end the live attempt's `signingIn` state, which is what used to happen.
        guard case .present(let attempt) = flow.receive(.presented) else {
            MemosLog.session.debug("native sign-in: a tap arrived while one is already on screen")
            throw NativeLoginError.alreadySigningIn
        }
        return try await withCheckedThrowingContinuation { continuation in
            let browser = makeBrowser(authorizeURL)
            live = Live(
                attempt: attempt,
                continuation: continuation,
                browser: browser,
                callbackHost: callbackHost,
                callbackPath: callbackPath
            )
            // Each of these captures the attempt it belongs to rather than reading whatever is
            // live when it fires. That is the fence: a browser view that closes after its attempt
            // ended names THAT attempt, and the machine drops it.
            browser.onClose = { [weak self] in
                self?.receive(.dismissed(attempt))
            }
            browser.onRedirect = { [weak self] url in
                self?.browserRedirected(to: url)
            }
            browser.onInitialLoad = { loaded in
                MemosLog.session.info(
                    "native sign-in: the sign-on page loaded: \(loaded, privacy: .public)"
                )
            }
            // Registered BEFORE the view is on screen: a return trip cannot be faster than the
            // presentation animation, but a wait that starts after it is a race for no reason.
            inbox.waitForCallback(for: attempt) { [weak self] url in
                guard let self, let live = self.live, live.attempt == attempt,
                    let lane = NativeLoginReturn.lane(
                        of: url,
                        callbackHost: live.callbackHost,
                        callbackPath: live.callbackPath
                    )
                else { return false }
                guard Self.carriesAnAnswer(url) else {
                    MemosLog.session.debug(
                        "native sign-in: a stripped echo of the callback arrived; still waiting"
                    )
                    return false
                }
                self.receive(.callback(url, lane, attempt))
                return true
            }
            MemosLog.session.info(
                "native sign-in: presenting the sign-in view for attempt \(attempt.generation)"
            )
            browser.present(from: host)
            watchPresentation(of: attempt)
        }
    }

    /// Whether a URL that IS on one of the callback's lanes carries a sign-in's answer at all.
    ///
    /// A real callback always has something on it — `code` when it worked, `error` when it was
    /// refused — and the query is what carries it. So a lane-matched URL with no query is an ECHO
    /// of the callback's address rather than the callback itself: iOS reports one that way on the
    /// browser view's redirect delegate, with the parameters withheld, and an address can be
    /// re-opened by hand just as emptily. Claiming one resolves the attempt with nothing in it,
    /// which reaches the person as "the sign-in came back incomplete" over a sign-in whose real
    /// callback is still coming. Refusing it leaves the attempt WAITING, which is the only state
    /// the real one can still arrive into.
    ///
    /// It is the CLAIM — is this URL mine — and it deliberately does not read the parameters:
    /// which lane a URL is on is still `NativeLoginReturn.lane`'s question and what is written on
    /// it is still the callback parser's, and a URL that has a query but nothing usable in it is
    /// claimed here and reported as a malformed callback, which is what it is.
    private static func carriesAnAnswer(_ url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        return !items.isEmpty
    }

    /// The exchange that follows a delivered callback is the session store's, and its outcome is
    /// reported back here so the attempt has an end rather than just stopping. It is also the last
    /// line in the log of a sign-in, which on a device nobody can attach to is the difference
    /// between "it failed" and "it never got that far".
    public func exchangeFinished(succeeded: Bool) {
        guard case .exchanging(let attempt) = flow.state else { return }
        receive(.exchangeFinished(succeeded: succeeded, attempt))
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
    ///
    /// It is fenced to its own attempt, because a timer is the signal most likely to outlive one:
    /// cancel a sign-in and start another inside three seconds and the first one's watchdog is
    /// still coming.
    private func watchPresentation(of attempt: NativeLoginFlow.Attempt) {
        let delay = watchdog
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, let live = self.live, live.attempt == attempt else { return }
            if live.browser.isOnScreen {
                MemosLog.session.info("native sign-in: the sign-in view is on screen")
            } else {
                MemosLog.session.error(
                    "native sign-in: the sign-in view is not on screen after presenting it"
                )
                self.receive(.timedOut(attempt))
            }
        }
    }

    /// The browser followed a redirect while loading. A log line, and deliberately nothing else.
    ///
    /// It says how far a sign-in got, which is what was missing when the old session failed — and
    /// only the scheme, host and path of it, never the query, because the callback's query
    /// carries the one-shot handoff code.
    ///
    /// It was also meant to be a third way for the callback to be NOTICED: a universal link opens
    /// the app when somebody taps it, while a server redirect to the same address inside a browser
    /// view often just loads it. That idea cannot be built on this delegate, and the field settled
    /// it. iOS withholds the QUERY from `initialLoadDidRedirectTo:` — the address arrives with its
    /// parameters removed — and a callback's entire answer is in that query. On a RETRY, where the
    /// household sign-on cookie is still in the browser view's own storage, nothing is typed and
    /// nothing is tapped: every hop through to the callback page is a redirect of the first load,
    /// so this is the delegate the callback comes back on, stripped. Delivered, it ended the
    /// attempt with a callback that had no code in it — the person read "the sign-in came back
    /// incomplete" while the real page, already rendered with a handoff code on it, was still on
    /// its way. So nothing here is ever delivered. The lanes that deliver are the callback page's
    /// tap-to-return link and `onOpenURL`, and both of them carry the query.
    private func browserRedirected(to url: URL) {
        let destination = "\(url.scheme ?? "?")://\(url.host() ?? "?")\(url.path())"
        MemosLog.session.info(
            "native sign-in: the browser went to \(destination, privacy: .public)"
        )
    }

    /// Every signal goes through the machine, and only the machine's answer is acted on.
    private func receive(_ event: NativeLoginFlow.Event) {
        apply(flow.receive(event))
    }

    /// Does what the machine decided, and nothing the machine did not.
    private func apply(_ effect: NativeLoginFlow.Effect) {
        switch effect {
        case .nothing, .present:
            // `.present` is carried out by `authenticate`, which is the only place that has a
            // continuation to hold; there is nothing left for it here.
            break
        case .deliver(let url, let lane, let attempt):
            MemosLog.session.info(
                "native sign-in: the callback arrived on the \(lane.description, privacy: .public)"
            )
            end(attempt)?.continuation.resume(returning: url)
        case .abandon(let error, let attempt):
            let detail = error.message ?? "no reason given"
            MemosLog.session.error(
                "native sign-in ended without a callback: \(detail, privacy: .public)"
            )
            end(attempt)?.continuation.resume(throwing: error)
        case .settle(let attempt):
            let outcome = String(describing: flow.state)
            MemosLog.session.info(
                "native sign-in: the attempt ended \(outcome, privacy: .public)"
            )
            // Belt and braces: the browser view came down when the callback was delivered, and
            // this is what makes "no attempt ever ends with its view up" true of every terminal
            // effect rather than of most of them.
            _ = end(attempt)
        }
    }

    /// Takes one attempt down and hands it back to be resumed — but only if it is still the live
    /// one, so a late signal can never end a sign-in that is not its own.
    ///
    /// The attempt is cleared BEFORE the caller resumes anything: that, and not the machine's
    /// state, is what makes it impossible to resume one continuation twice when both return lanes
    /// deliver the same callback.
    private func end(_ attempt: NativeLoginFlow.Attempt) -> Live? {
        guard let live, live.attempt == attempt else { return nil }
        self.live = nil
        inbox.stopWaiting(for: attempt)
        // Dismissed by the app, so the browser's "the person closed it" does not fire — and if a
        // future iOS decides it should, the machine has already left this attempt and drops it.
        live.browser.onClose = nil
        live.browser.onRedirect = nil
        live.browser.dismiss()
        return live
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
