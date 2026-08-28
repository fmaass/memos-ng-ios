import Foundation

/// The browser-brokered device login, as far as the wire is concerned.
///
/// Everything here is pure — the URL that starts a login, and the reading of the callback the
/// authentication session lands on. Both are places where a mistake is invisible until it is
/// expensive: a malformed `code_challenge` becomes a 422 the person in front of the app cannot
/// act on, and a callback misread as "no code" turns a completed login into a silent failure. So
/// both are unit-tested here rather than only exercised through a live session.
public enum NativeLogin {
    /// The `client` value that switches the BFF's `/api/auth/login` into device-handoff mode.
    public static let client = "ios"

    /// Path of the HTTPS return lane. It belongs to the app, not to a browser: only an app
    /// holding the associated-domains entitlement for the server's host can be opened by it.
    ///
    /// On THIS estate that lane can never fire. The server is on internal-only DNS, so Apple's
    /// CDN cannot fetch the domain association at all and a universal link that is never
    /// associated never opens an app. The custom scheme (`memosng://auth-callback`) is the
    /// permanent primary lane here; this path is kept as a self-activating enhancement, for the
    /// estates that already have a public AASA and for the day a split-horizon stub is served.
    public static let callbackPath = "/ios/auth/callback"

    /// `native_auth.DEVICE_NAME_MAX` on the server, which answers 422 to anything longer.
    public static let deviceNameMaxLength = 64

    /// Which credential a trip round the login lane is being made for.
    ///
    /// The two trips are byte-identical as far as Authelia is concerned — same client, same
    /// redirect URI, same scopes — and differ only in what the BFF hands back at the end of them.
    /// That is the whole reason the step-up needs no identity-provider change and no household SSO
    /// restart: the purpose is the server's own state, carried in its encrypted transaction cookie
    /// and never forwarded to the IdP.
    ///
    /// The server refuses a purpose it does not offer rather than degrading to a login, so this
    /// enum has exactly the values it publishes — a value invented here would be a 422 the person
    /// holding the phone cannot act on.
    public enum Purpose: String, Sendable, Equatable, CaseIterable {
        /// Trade the handoff code for a device token. The default, and named nowhere on the wire.
        case login
        /// Trade it for a short-lived management grant instead (MEMNG-138 option 2).
        case manage
    }

    /// What came back on the callback URL.
    public enum Callback: Sendable, Equatable {
        /// The one-shot handoff code, to be exchanged together with the PKCE verifier.
        case code(String)
        /// The login was refused upstream. An app cannot read an HTTP status out of an
        /// authentication session — it only ever sees the callback URL — so a refusal has to
        /// arrive as a parameter on that URL.
        case failed(reason: String)
        /// Neither: a truncated redirect, or a URL that was never ours.
        case malformed
    }

    /// The URL that starts a device login, or `nil` when these arguments could only produce a 422.
    ///
    /// The validation mirrors the server's (`valid_code_challenge`, `valid_device_name`) on
    /// purpose: a request that cannot succeed should fail on the device, where the flow can say
    /// why, rather than inside a browser sheet that can only show an error page.
    ///
    /// The device name is required for BOTH purposes, because the server validates it for both:
    /// `client=ios` is what turns on the device-handoff mode, and the name is part of that mode
    /// whatever the trip is buying.
    public static func authorizeURL(
        configuration: ServerConfiguration,
        codeChallenge: String,
        device: String,
        purpose: Purpose = .login
    ) -> URL? {
        guard isValidCodeChallenge(codeChallenge) else { return nil }
        guard let device = normalizedDeviceName(device) else { return nil }
        guard
            var components = URLComponents(
                url: configuration.baseURL, resolvingAgainstBaseURL: false
            )
        else { return nil }
        // `ServerConfiguration` guarantees an empty path, so this is an assignment rather than an
        // append: appending would double the separator for a base URL that ended in one.
        components.path = "/api/auth/login"
        components.queryItems = [
            URLQueryItem(name: "client", value: client),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "device", value: device),
        ]
        // An absent `purpose` IS a login on the server, so the sign-in's URL stays exactly the one
        // it has always sent. Only the step-up names itself.
        if purpose != .login {
            components.queryItems?.append(URLQueryItem(name: "purpose", value: purpose.rawValue))
        }
        return components.url
    }

    /// The host the authentication session must be told to wait for — the server's own, because
    /// the BFF redirects the login back to a path on itself.
    public static func callbackHost(for configuration: ServerConfiguration) -> String? {
        URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)?.host
    }

    /// Reads the callback the authentication session handed back.
    public static func callback(from url: URL) -> Callback {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return .malformed }
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return .code(code)
        }
        if let reason = items.first(where: { $0.name == "error" })?.value, !reason.isEmpty {
            return .failed(reason: reason)
        }
        return .malformed
    }

    /// RFC 7636 §4.1 in the server's own bounds: 43–128 characters of un-padded base64url.
    public static func isValidCodeChallenge(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz"))
            .union(CharacterSet(charactersIn: "0123456789-_"))
        guard (43...128).contains(value.unicodeScalars.count) else { return false }
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A device display name the server will accept: it becomes the PAT's name, and a PAT with no
    /// name is unattributable in the token list.
    ///
    /// The length is counted in unicode scalars because the server counts Python `len()`, which is
    /// code points — a `String.count` of grapheme clusters would let a name through that the
    /// server then rejects.
    public static func normalizedDeviceName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= deviceNameMaxLength else {
            return nil
        }
        return trimmed
    }
}

/// Why `POST /api/auth/native/exchange` refused a code.
///
/// The four values are the server's stable `detail` codes. All of them are terminal — a code is
/// burned by the attempt whatever its outcome — so none of them is retried: the app starts a new
/// login instead.
public enum NativeExchangeFailure: String, Sendable, Equatable, CaseIterable {
    case codeInvalid = "code_invalid"
    case codeExpired = "code_expired"
    case codeConsumed = "code_consumed"
    case verifierMismatch = "verifier_mismatch"

    /// Reads the `detail` out of a 400 body, or `nil` when this is not one of ours.
    ///
    /// A 422 from FastAPI carries a LIST under the same key, so the type is checked rather than
    /// assumed: reporting a validation error as `code_invalid` would send the app into a fresh
    /// login loop over a bug in the request it just built.
    public static func fromDetailBody(_ data: Data) -> NativeExchangeFailure? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"] as? String
        else { return nil }
        return NativeExchangeFailure(rawValue: detail)
    }

    /// What to tell the person holding the phone. None of these blames them, because none of them
    /// is their doing; all of them are fixed by signing in again.
    public var message: String {
        switch self {
        case .codeInvalid: "That sign-in could not be completed. Please sign in again."
        case .codeExpired: "The sign-in took too long. Please sign in again."
        case .codeConsumed: "That sign-in was already used. Please sign in again."
        case .verifierMismatch: "The sign-in could not be verified. Please sign in again."
        }
    }
}
