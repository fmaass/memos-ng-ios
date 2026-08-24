import Foundation
import MemosAPI
import OpenAPIRuntime

/// Where the app is with respect to a credential.
public enum SessionState: Sendable, Equatable {
    case signedOut
    case signingIn
    case signedIn(User)
    /// A stored credential exists but the server could not be asked about it. NOT signed out:
    /// showing the sign-in screen here invites a second sign-in that would orphan the stored,
    /// still-valid token. The screen for this state retries, and abandoning the credential is
    /// its explicit, labelled choice.
    case unreachable(String)

    public var user: User? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}

/// How a sign-out ended, which decides whether the credential may be destroyed.
///
/// Wiping a token whose revocation FAILED is the dangerous case: the device shows a sign-in
/// screen, the person believes they are signed out, and a token that is still valid for up to a
/// year is sitting in whatever took it. So a failed revoke keeps the credential and says so, and
/// throwing it away anyway becomes a deliberate choice someone makes (`signOutWithoutRevoking`).
public enum SignOutOutcome: Sendable, Equatable {
    /// The server accepted the revocation; nothing is left here or there.
    case revoked
    /// The server answered 401 — the token was already dead, so wiping it is not a loss.
    case alreadyRevoked
    /// The revoke could not be delivered or the server failed. The credential is KEPT.
    case revokeFailed(APIError)

    /// What went wrong, when something did — surfaced here so the UI layer never has to reach
    /// into the API error type (which it does not link) to say it.
    public var failureDescription: String? {
        guard case .revokeFailed(let error) = self else { return nil }
        return error.errorDescription
    }
}

/// The session: one credential, one server, and the rule that a 401 ends it.
///
/// There is no refresh lifecycle to fall back on (the personal access token IS the credential)
/// so an unauthorised response is terminal by design, and a silent retry would only turn a
/// revoked token into a spinner.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: SessionState = .signedOut
    public private(set) var lastError: String?
    public private(set) var configuration: ServerConfiguration?

    private let credentials: any CredentialStore
    private let makeClient:
        @Sendable (ServerConfiguration, @escaping @Sendable () async -> String?) -> any APIProtocol
    private var client: (any APIProtocol)?

    public static let tokenAccount = "device-token"
    public static let serverAccount = "server-url"

    public init(
        credentials: any CredentialStore = DeviceCredentials.keychain(),
        makeClient:
            @escaping @Sendable (
                ServerConfiguration, @escaping @Sendable () async -> String?
            ) -> any APIProtocol = { configuration, token in
                APIClientFactory.make(configuration: configuration, token: token)
            }
    ) {
        self.credentials = credentials
        self.makeClient = makeClient
    }

    /// The client every feature talks through, or `nil` while signed out.
    public var api: (any APIProtocol)? { client }

    public var serverBaseURL: URL? { configuration?.baseURL }

    // MARK: - signing in

    /// The browser-brokered device login: the app opens the ordinary web login in an
    /// authentication session, the server hands the finished login back on an HTTPS callback only
    /// this app can receive, and the one-shot code on it is traded — together with the PKCE
    /// verifier that never left the device — for a token.
    ///
    /// The verifier is destroyed on EVERY path out of here, success or failure: it is the half of
    /// the pair that makes an intercepted code useless, and it has no purpose after the exchange.
    @discardableResult
    public func signInNatively(
        serverAddress: String,
        deviceName: String,
        presenter: any NativeLoginPresenter,
        pkce: PKCE = PKCE()
    ) async -> Bool {
        defer { pkce.zeroize() }

        guard let configuration = ServerConfiguration(serverAddress: serverAddress) else {
            failSignIn(.invalidServer)
            return false
        }
        guard
            let authorizeURL = NativeLogin.authorizeURL(
                configuration: configuration, codeChallenge: pkce.challenge, device: deviceName
            ),
            let callbackHost = NativeLogin.callbackHost(for: configuration)
        else {
            failSignIn(.unusableRequest)
            return false
        }

        state = .signingIn
        lastError = nil
        do {
            let callbackURL = try await presenter.authenticate(
                authorizeURL: authorizeURL,
                callbackHost: callbackHost,
                callbackPath: NativeLogin.callbackPath
            )
            let code = try Self.code(from: callbackURL)
            guard let verifier = pkce.verifier else { throw NativeLoginError.unusableRequest }
            // Anonymous by construction: the exchange is how a device gets its FIRST credential,
            // so presenting one here would be circular.
            let exchanged = try await Self.exchange(
                makeClient(configuration) { nil }, code: code, verifier: verifier
            )
            let token = exchanged.token
            let stored = persist(token: token, configuration: configuration)
            self.configuration = configuration
            self.client = makeClient(configuration) { token }
            state = .signedIn(exchanged.user)
            if !stored { lastError = Self.storageWarning }
            return true
        } catch let error as NativeLoginError {
            failSignIn(error)
            return false
        } catch {
            failSignIn(.api(.unexpected(description: error.localizedDescription)))
            return false
        }
    }

    /// Validates a pasted token against `GET /api/auth/user` before storing it: a credential that
    /// is only checked at first use fails later, in the middle of something else.
    public func signIn(serverAddress: String, token candidate: String) async {
        guard let configuration = ServerConfiguration(serverAddress: serverAddress) else {
            lastError = "That does not look like an https server address."
            return
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Paste the access token from the memos web app."
            return
        }

        state = .signingIn
        lastError = nil
        let client = makeClient(configuration) { trimmed }
        do {
            let user = try await Self.whoami(client)
            let stored = persist(token: trimmed, configuration: configuration)
            adopt(client: client, configuration: configuration, user: user)
            if !stored { lastError = Self.storageWarning }
        } catch {
            state = .signedOut
            self.client = nil
            lastError = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Restores a stored credential at launch and re-validates it, so a token revoked while the
    /// app was closed shows a sign-in screen rather than an empty timeline.
    ///
    /// Only a REJECTED credential is deleted. An unreachable server is not evidence about the
    /// token, and deleting it because the phone had no signal at launch would sign someone out
    /// for the price of a lift ride.
    public func restore() async {
        guard let storedToken = (try? credentials.string(for: Self.tokenAccount)) ?? nil,
            let storedAddress = (try? credentials.string(for: Self.serverAccount)) ?? nil,
            let configuration = ServerConfiguration(serverAddress: storedAddress)
        else { return }

        state = .signingIn
        lastError = nil
        let client = makeClient(configuration) { storedToken }
        do {
            let user = try await Self.whoami(client)
            adopt(client: client, configuration: configuration, user: user)
        } catch let error as APIError where error == .unauthorized {
            wipeCredential()
            lastError = error.errorDescription
        } catch {
            // The token was neither confirmed nor rejected. Park, keep, retry — see `unreachable`.
            self.client = nil
            state = .unreachable(
                (error as? APIError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    // MARK: - signing out

    /// Revokes the presenting token and, if that settled its fate, forgets it.
    ///
    /// 2xx means the token is gone server-side and 401 means it was already gone; either way
    /// nothing is left to leak. Anything else — no network, a 500 — leaves the credential exactly
    /// where it is and reports the failure, because a token that is still live must not be
    /// abandoned by an app that has stopped tracking it.
    @discardableResult
    public func signOut() async -> SignOutOutcome {
        guard let client else {
            wipeCredential()
            return .revoked
        }
        do {
            let response = try await client.nativeLogoutApiAuthNativeLogoutPost(.init())
            switch response {
            case .noContent:
                MemosLog.session.info("POST /api/auth/native/logout -> 204")
                wipeCredential()
                lastError = nil
                return .revoked
            case .undocumented(let statusCode, _):
                guard statusCode == 401 else {
                    let error = APIError.fromStatus(statusCode)
                    lastError = error.errorDescription
                    return .revokeFailed(error)
                }
                MemosLog.session.info("POST /api/auth/native/logout -> 401, token already gone")
                wipeCredential()
                lastError = nil
                return .alreadyRevoked
            }
        } catch {
            let apiError =
                (error as? APIError) ?? .transport(description: error.localizedDescription)
            lastError = apiError.errorDescription
            return .revokeFailed(apiError)
        }
    }

    /// Forgets the credential without revoking it — the deliberate way out of a failed sign-out.
    ///
    /// It exists so that "I could not reach the server, sign me out anyway" is a choice made in
    /// the open, on a screen that also says what it means, rather than the silent default.
    public func signOutWithoutRevoking() {
        wipeCredential()
        lastError = nil
    }

    /// The 401 rule, in one place: any feature that sees `.unauthorized` calls this.
    ///
    /// No revoke is attempted. A 401 is the server saying this token is already dead, so there is
    /// nothing to revoke and nothing to keep — this is not the failed-revoke case.
    public func handle(_ error: APIError) async {
        guard error == .unauthorized else { return }
        wipeCredential()
        lastError = error.errorDescription
    }

    // MARK: - internals

    private func adopt(client: any APIProtocol, configuration: ServerConfiguration, user: User) {
        self.configuration = configuration
        self.client = client
        state = .signedIn(user)
    }

    private func failSignIn(_ error: NativeLoginError) {
        state = .signedOut
        client = nil
        lastError = error.message
    }

    /// The device credential could not be written where it survives the process. Sign-in still
    /// succeeds — the token works from memory and a proper sign-out can still revoke it — but
    /// silence here is how a live server credential gets orphaned by a force-quit.
    static let storageWarning =
        "Signed in, but the credential could not be saved on this device. "
        + "It will not survive quitting the app - sign out properly before you do."

    private func persist(token: String, configuration: ServerConfiguration) -> Bool {
        do {
            try credentials.set(token, for: Self.tokenAccount)
            try credentials.set(configuration.baseURL.absoluteString, for: Self.serverAccount)
            return true
        } catch {
            return false
        }
    }

    private func wipeCredential() {
        try? credentials.remove(Self.tokenAccount)
        try? credentials.remove(Self.serverAccount)
        client = nil
        configuration = nil
        state = .signedOut
    }

    static func code(from callbackURL: URL) throws -> String {
        switch NativeLogin.callback(from: callbackURL) {
        case .code(let code): return code
        case .failed(let reason): throw NativeLoginError.refused(reason: reason)
        case .malformed: throw NativeLoginError.malformedCallback
        }
    }

    static func exchange(
        _ client: any APIProtocol,
        code: String,
        verifier: String
    ) async throws -> (token: String, user: User) {
        let response = try await client.nativeExchangeApiAuthNativeExchangePost(
            .init(body: .json(.init(code: code, codeVerifier: verifier)))
        )
        switch response {
        case .ok(let ok):
            let payload = try ok.body.json
            MemosLog.session.info("POST /api/auth/native/exchange -> 200")
            return (payload.token, User(payload.user))
        case .unprocessableContent:
            throw NativeLoginError.api(.server(status: 422))
        case .undocumented(let statusCode, let payload):
            // Every refusal is a 400 with one of four stable detail codes. They are read here
            // rather than reported as "HTTP 400" because they are the difference between "try
            // again" and "this cannot work".
            if statusCode == 400, let body = payload.body,
                let data = try? await Data(collecting: body, upTo: 4096),
                let failure = NativeExchangeFailure.fromDetailBody(data)
            {
                throw NativeLoginError.exchangeRejected(failure)
            }
            throw NativeLoginError.api(.fromStatus(statusCode))
        }
    }

    static func whoami(_ client: any APIProtocol) async throws -> User {
        let response = try await client.whoamiApiAuthUserGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/auth/user -> 200")
            return User(try ok.body.json)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
