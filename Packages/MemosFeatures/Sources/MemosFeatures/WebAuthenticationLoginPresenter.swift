import AuthenticationServices
import MemosCore
import SwiftUI

/// The UI half of the native login: puts the household sign-on in an
/// `ASWebAuthenticationSession` and hands the callback URL back to the session store.
///
/// The HTTPS callback form is the point — only an app holding the associated-domains entitlement
/// for the host can receive it, which is what makes an intercepted authorize URL useless to
/// another app. A custom URL scheme was rejected for exactly that hole.
///
/// `prefersEphemeralWebBrowserSession` stays false on purpose: the whole flow exists to REUSE the
/// person's standing sign-on, and an ephemeral session would ask for a password every time.
/// Main-actor isolated, which is what lets it HOLD the presenting session: a `Sendable` class
/// with no isolation may own no mutable state, and this one has to own exactly one thing.
@MainActor
public final class WebAuthenticationLoginPresenter: NSObject, NativeLoginPresenter {
    /// The session while it is presenting, and only while it is presenting.
    ///
    /// `ASWebAuthenticationSession` does not keep itself alive. As a local it is owned by the call
    /// scope, and the scope ends the moment the continuation is handed over — so the session can
    /// be deallocated before anybody taps anything, the sheet goes away, and the completion
    /// handler never runs at all. That failure is silent and intermittent: the sign-in simply
    /// produces nothing. Held here from `start()` and dropped in the completion, so the presenter
    /// owns exactly one at a time and none between attempts.
    private var presenting: ASWebAuthenticationSession?

    /// The context provider, for the same reason the session is held: `presentationContextProvider`
    /// is a WEAK reference, so nothing else keeps it alive between `start()` and the first time
    /// AuthenticationServices asks it for an anchor.
    private var context: AnchorProvider?

    /// Where the sheet is put. Injectable so the no-window path is a test rather than a device.
    private let resolveAnchor: @MainActor () -> ASPresentationAnchor?

    public override init() {
        self.resolveAnchor = WebAuthenticationLoginPresenter.currentAnchor
        super.init()
    }

    init(anchor resolve: @escaping @MainActor () -> ASPresentationAnchor?) {
        self.resolveAnchor = resolve
        super.init()
    }

    public func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        // Resolved BEFORE the session exists, so "there is nowhere to present" is an error the
        // sign-in screen shows rather than a session started against a window that is attached to
        // nothing — which presents no sheet and looks exactly like a button that did nothing.
        guard let anchor = resolveAnchor() else {
            MemosLog.session.error(
                "native sign-in: no foreground window scene to present the sign-in sheet on"
            )
            throw NativeLoginError.presentationFailed("no window is on screen to open it on")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callback: .https(host: callbackHost, path: callbackPath)
            ) { [weak self] callbackURL, error in
                // Weak, so the presenter owning the session that owns this closure is not a cycle.
                // The callback arrives on the main thread — it is a UI API — and the hop is
                // explicit for the same reason it is in `presentationAnchor`.
                MainActor.assumeIsolated { self?.release() }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                let failure = Self.loginError(from: error)
                if failure == .cancelled {
                    MemosLog.session.debug("native sign-in: the person closed the sign-in sheet")
                } else {
                    let detail = failure.message ?? "no reason given"
                    MemosLog.session.error(
                        "native sign-in ended without a callback: \(detail, privacy: .public)"
                    )
                }
                continuation.resume(throwing: failure)
            }
            session.prefersEphemeralWebBrowserSession = false
            let provider = AnchorProvider(anchor: anchor)
            session.presentationContextProvider = provider
            context = provider
            presenting = session
            // `start() == false` means the sheet never appeared and the completion will not run,
            // so this resume is the only one on that path — and the only place the session has to
            // be let go of by hand. It is logged as well as thrown: the screen says one sentence,
            // and the log is what says which sentence it was on a device nobody can attach to.
            if !session.start() {
                release()
                MemosLog.session.error(
                    "native sign-in: ASWebAuthenticationSession.start() returned false"
                )
                continuation.resume(
                    throwing: NativeLoginError.presentationFailed("the system refused to open it")
                )
            }
        }
    }

    /// One attempt's objects, dropped together: the session and the provider that only exists for
    /// it. Leaving the provider behind would keep a window alive for no reason.
    private func release() {
        presenting = nil
        context = nil
    }

    /// A cancel is a decision, not a failure — it maps to the one case the UI stays quiet about.
    private static func loginError(from error: (any Error)?) -> NativeLoginError {
        guard let error else { return .presentationFailed("it ended without a result") }
        if let sessionError = error as? ASWebAuthenticationSessionError,
            sessionError.code == .canceledLogin
        {
            return .cancelled
        }
        return .presentationFailed(error.localizedDescription)
    }

    /// The window the person is looking at, or nothing.
    ///
    /// The ordering is not decided here: `connectedScenes` is a set, and which of its members owns
    /// the screen is the part that is easy to get wrong and impossible to see wrong on a
    /// single-scene simulator. This maps UIKit into the description `LoginAnchor` decides on and
    /// maps the answer back — `scenes` keeps its order across both, so the indices agree.
    private static func currentAnchor() -> ASPresentationAnchor? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let described = scenes.map {
            LoginAnchor.SceneState(
                activation: LoginAnchor.Activation($0.activationState),
                windowIsKey: $0.windows.map(\.isKeyWindow)
            )
        }
        guard case .window(let scene, let window) = LoginAnchor.choice(among: described) else {
            return nil
        }
        return scenes[scene].windows[window]
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

/// Hands back the one window the sign-in was resolved onto.
///
/// It is a separate object rather than a method on the presenter so the anchor can be a `let`:
/// `presentationAnchor(for:)` may not return nothing, and the alternative to a non-optional stored
/// anchor is a branch that has to invent one — which is how a deprecated, scene-less `UIWindow()`
/// gets built and a sheet gets presented on a window that is attached to nothing.
@MainActor
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
        super.init()
    }

    /// The protocol is not main-actor-bound but anchors are UI objects, so the hop is explicit.
    nonisolated func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }
}
