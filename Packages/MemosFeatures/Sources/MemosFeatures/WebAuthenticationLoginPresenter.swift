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
public final class WebAuthenticationLoginPresenter: NSObject, NativeLoginPresenter {
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
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }
                continuation.resume(throwing: Self.loginError(from: error))
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            // `start() == false` means the sheet never appeared and the completion will not run,
            // so this resume is the only one on that path.
            if !session.start() {
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
            return ASPresentationAnchor()
        }
    }
}
