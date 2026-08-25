import Foundation
import MemosAPI

/// Everything that can go wrong between "sign in" and a token in the keychain.
///
/// One typed enum rather than whatever each layer happened to throw: the flow spans a browser
/// view, a redirect and an HTTP call, and every one of its outcomes has to arrive on the sign-in
/// screen as a sentence somebody can act on.
public enum NativeLoginError: Error, Sendable, Equatable {
    /// The browser view went away without a callback. It is usually a deliberate close, and it
    /// used to be silent for exactly that reason — but the app cannot tell a deliberate close
    /// apart from a finished login whose callback never arrived, and those two look identical
    /// from the outside: a button that did nothing. So it says one sentence now.
    case cancelled
    /// The authentication session could not be put on screen at all.
    case presentationFailed(String)
    /// The identity provider refused, carrying the reason it redirected back with.
    case refused(reason: String)
    /// The callback arrived with neither a code nor a reason.
    case malformedCallback
    /// The server refused to trade the handoff code for a token. Terminal, all four of them.
    case exchangeRejected(NativeExchangeFailure)
    /// The address typed into the sign-in field cannot become an https base URL.
    case invalidServer
    /// The login could not even be started: a device name or challenge the server would reject.
    case unusableRequest
    /// Anything the API layer classified.
    case api(APIError)

    /// What to show. Every case has something to say, `cancelled` included: silence is what the
    /// failure this flow was rebuilt around looked like from the phone.
    public var message: String? {
        switch self {
        case .cancelled:
            "The sign-in was closed before it came back. Nothing was signed in - tap Sign in to "
                + "try again."
        case .presentationFailed(let detail): "The sign-in window could not open: \(detail)"
        case .refused(let reason): "The sign-in was refused (\(reason))."
        case .malformedCallback: "The sign-in came back incomplete. Please try again."
        case .exchangeRejected(let failure): failure.message
        case .invalidServer: "That does not look like an https server address."
        case .unusableRequest: "This device's name could not be used to sign in."
        case .api(let error): error.errorDescription
        }
    }
}

/// Puts the web login on screen and hands back the URL it finished on.
///
/// The protocol lives here and its implementation lives in the UI layer: `MemosCore` also builds
/// for macOS (that is how the gate proves it compiles warning-free) and a browser view is a UI
/// object. Splitting it this way also makes every branch of the flow testable — a stub presenter
/// can cancel, fail to present, or hand back any callback URL at all.
public protocol NativeLoginPresenter: Sendable {
    /// - Returns: the callback URL the login came back on.
    /// - Throws: `NativeLoginError.cancelled` or `.presentationFailed`.
    @MainActor
    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL
}

/// Which return trip a finished login came back on, and how to tell one of ours from any other
/// URL the system hands the app.
///
/// The app used to be told this by `ASWebAuthenticationSession`: it was given a host and a path,
/// it watched for them itself, and it handed back a URL that could only be the callback. That
/// session is gone — it refused to present at all on one household phone, silently, past every
/// piece of instrumentation put around it — so the browser view is presented by the app now, and
/// recognising the return trip is the app's job.
///
/// There are two forms of it, and in THIS deployment only one of them can ever fire.
///
/// The custom-scheme form is the lane. It is not a fallback: the server this app talks to is on
/// internal-only DNS, so Apple's CDN cannot fetch the domain association at all — not late, not
/// eventually — and a universal link that is never associated never opens an app. What comes back
/// on this lane is a link on the callback page the person taps.
///
/// Any app on the phone could claim `memosng://`, so this lane carries no proof of who is
/// listening. It does not have to: what crosses it is a one-shot handoff code that is worthless
/// without the PKCE verifier, and the verifier never leaves this process. An intercepted code buys
/// an eavesdropper nothing — which is the whole point of PKCE and the reason the weaker lane is
/// safe to depend on.
///
/// The HTTPS form is kept for the estates and the futures where the association IS publicly
/// fetchable: there it is the better lane, because only an app entitled to the server's host can
/// be opened by it. It costs a handful of lines here and it would start working with nothing to
/// change if a public AASA is ever served for this domain.
public enum NativeLoginReturn {
    /// Which of the two forms a callback URL took.
    public enum Lane: String, Sendable, Equatable, CaseIterable {
        case universalLink
        case customScheme

        /// For the log line that says how a sign-in came back, which on a device nobody can
        /// attach to is the difference between a diagnosis and a guess.
        public var description: String {
            switch self {
            case .universalLink: "https universal link"
            case .customScheme: "memosng:// scheme"
            }
        }
    }

    /// The scheme the callback page's tap-to-return link uses. Registered in `CFBundleURLTypes`.
    public static let customScheme = "memosng"

    /// The single host under that scheme this app answers to. A host rather than a bare path so
    /// the app can grow a second custom-scheme entry point without either of them widening.
    public static let customHost = "auth-callback"

    /// Which lane this URL arrived on, or `nil` when it is not this sign-in's callback at all.
    ///
    /// Every URL the app is opened with reaches this — a shared memo link, anything a person
    /// taps — so a URL that is not the callback has to come back as "not mine" rather than as a
    /// malformed one: the sign-in still waiting must not be resolved by an unrelated tap.
    ///
    /// Schemes and hosts are compared case-insensitively because the system does not promise a
    /// case: iOS lowercases a scheme it opens, and a host is case-insensitive by RFC 3986.
    public static func lane(of url: URL, callbackHost: String, callbackPath: String) -> Lane? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else { return nil }
        let host = components.host?.lowercased()
        if scheme == "https" {
            guard host == callbackHost.lowercased() else { return nil }
            // The associated-domain file declares `/ios/auth/callback*`, so a deeper path is
            // still ours. `callbackPath` itself, or a path SEGMENT below it — never a sibling
            // that merely starts with the same letters.
            let path = components.percentEncodedPath
            guard path == callbackPath || path.hasPrefix(callbackPath + "/") else { return nil }
            return .universalLink
        }
        if scheme == customScheme {
            // `memosng:auth-callback?...` (no slashes) parses with a nil host and the name in the
            // path, which is a shape a hand-written link in an HTML page can easily take.
            let named =
                host
                ?? components.percentEncodedPath.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                )
            guard named.lowercased() == customHost else { return nil }
            return .customScheme
        }
        return nil
    }
}
