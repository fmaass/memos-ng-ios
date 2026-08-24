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

    public override init() { super.init() }

    public func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callback: .https(host: callbackHost, path: callbackPath)
            ) { [weak self] callbackURL, error in
                // Weak, so the presenter owning the session that owns this closure is not a cycle.
                // The callback arrives on the main thread — it is a UI API — and the hop is
                // explicit for the same reason it is in `presentationAnchor`.
                MainActor.assumeIsolated { self?.presenting = nil }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                continuation.resume(throwing: Self.loginError(from: error))
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            presenting = session
            // `start() == false` means the sheet never appeared and the completion will not run,
            // so this resume is the only one on that path — and the only place the session has to
            // be let go of by hand.
            if !session.start() {
                presenting = nil
                continuation.resume(
                    throwing: NativeLoginError.presentationFailed(
                        "The sign-in sheet could not be presented."
                    )
                )
            }
        }
    }

    /// A cancel is a decision, not a failure — it maps to the one case the UI stays quiet about.
    private static func loginError(from error: (any Error)?) -> NativeLoginError {
        guard let error else { return .presentationFailed("The sign-in ended without a result.") }
        if let sessionError = error as? ASWebAuthenticationSessionError,
            sessionError.code == .canceledLogin
        {
            return .cancelled
        }
        return .presentationFailed(error.localizedDescription)
    }
}

extension WebAuthenticationLoginPresenter: ASWebAuthenticationPresentationContextProviding {
    /// The protocol is not main-actor-bound but anchors are UI objects, so the hop is explicit.
    nonisolated public func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            // A freshly constructed window is attached to nothing and AuthenticationServices
            // refuses to present from it — the anchor must be the window someone is looking at.
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
                ?? scenes.first?.windows.first
            {
                return window
            }
            // No window in any connected scene yet. A window built ON a scene is at least
            // attached to something, and it is the only way left to build one: UIWindow's
            // scene-less initialisers are deprecated as of iOS 26 in favour of this one.
            if let scene = scenes.first(where: { $0.activationState == .foregroundActive })
                ?? scenes.first
            {
                return ASPresentationAnchor(windowScene: scene)
            }
            return Self.detachedAnchor()
        }
    }

    /// The last resort, and unchanged: with no window scene at all there is nothing to attach a
    /// window to. AuthenticationServices refuses to present from a detached window, which is the
    /// existing behaviour on this path — `start()` returns false and the caller reports a
    /// presentation failure. It sits in a deprecated declaration of its own because that is the
    /// one place a call to a deprecated initialiser belongs.
    @available(iOS, deprecated: 26.0, message: "There is no window scene to build a window on.")
    @MainActor
    private static func detachedAnchor() -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}
