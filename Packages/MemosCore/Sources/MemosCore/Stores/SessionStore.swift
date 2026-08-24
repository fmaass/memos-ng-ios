import Foundation
import MemosAPI
import MemosOutbox
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
    /// Who sees a memo when nobody says otherwise — the account's own setting, not a guess.
    ///
    /// `nil` means "not known yet, or the server would not say". A screen that has to name the
    /// default says less rather than something invented: an app that tells someone their memo
    /// will be Private when the account says Public is worse than one that stays vague.
    public private(set) var defaultVisibility: MemoVisibility?

    private let credentials: any CredentialStore
    private let makeClient:
        @Sendable (ServerConfiguration, @escaping @Sendable () async -> String?) -> any APIProtocol
    /// Where the signed-in account is published for the processes that have no session of their
    /// own — the share extension. Nil unless the app composes one, so a test never writes into
    /// the real app group container.
    private let account: (any OutboxAccountPublishing)?
    /// A licence that would not delete. It is kept because the thing it describes — a revoked
    /// identity that can still queue captures — outlives the call that failed to remove it, and
    /// the next `restore()` is where it is tried again.
    private var licenceRevocationFailed = false
    private var client: (any APIProtocol)?

    // Nonisolated: these name the two keychain items, and the outbox reads them from its own
    // isolation. They are immutable strings, so there is nothing here for the main actor to guard.
    public nonisolated static let tokenAccount = "device-token"
    public nonisolated static let serverAccount = "server-url"

    public init(
        credentials: any CredentialStore = DeviceCredentials.keychain(),
        makeClient:
            @escaping @Sendable (
                ServerConfiguration, @escaping @Sendable () async -> String?
            ) -> any APIProtocol = { configuration, token in
                APIClientFactory.make(configuration: configuration, token: token)
            },
        account: (any OutboxAccountPublishing)? = nil
    ) {
        self.credentials = credentials
        self.makeClient = makeClient
        self.account = account
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

        let previousState = state
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
            let persistence = persist(token: token, configuration: configuration)
            guard persistence != .licenceNotRevoked else {
                abandonSignIn(restoring: previousState)
                return false
            }
            adopt(
                client: makeClient(configuration) { token },
                configuration: configuration,
                user: exchanged.user
            )
            if persistence == .storedNowhere { lastError = Self.storageWarning }
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

        let previousState = state
        state = .signingIn
        lastError = nil
        let client = makeClient(configuration) { trimmed }
        do {
            let user = try await Self.whoami(client)
            switch persist(token: trimmed, configuration: configuration) {
            case .licenceNotRevoked:
                abandonSignIn(restoring: previousState)
                return
            case .stored:
                adopt(client: client, configuration: configuration, user: user)
            case .storedNowhere:
                adopt(client: client, configuration: configuration, user: user)
                lastError = Self.storageWarning
            }
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
    /// It is also where the licence the share extension reads is reconciled with the credential
    /// this session actually holds. Both residues of an interrupted sign-out or account switch are
    /// healed here, and in the safe direction: a licence with no credential behind it is revoked,
    /// a licence naming another server is revoked before anything is validated, and a credential
    /// with no licence gets one again the moment the server says whose it is.
    public func restore() async {
        guard let storedToken = (try? credentials.string(for: Self.tokenAccount)) ?? nil,
            let storedAddress = (try? credentials.string(for: Self.serverAccount)) ?? nil,
            let configuration = ServerConfiguration(serverAddress: storedAddress)
        else {
            // No credential: whatever licence is lying about belongs to nobody. This is also the
            // retry for a revocation that failed during sign-out.
            clearAccountLicence()
            return
        }
        // A licence naming a different server than the stored credential is what an interrupted
        // account switch leaves behind. Deny first; `adopt` republishes once whoami says who this
        // is. The subject cannot be checked here — that is precisely what the server is for.
        if let published = account?.current(), published.serverBaseURL != configuration.baseURL {
            clearAccountLicence()
        }

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
            lastError = licenceComplaint
            return .revoked
        }
        do {
            let response = try await client.nativeLogoutApiAuthNativeLogoutPost(.init())
            switch response {
            case .noContent:
                MemosLog.session.info("POST /api/auth/native/logout -> 204")
                wipeCredential()
                lastError = licenceComplaint
                return .revoked
            case .undocumented(let statusCode, _):
                guard statusCode == 401 else {
                    let error = APIError.fromStatus(statusCode)
                    lastError = error.errorDescription
                    return .revokeFailed(error)
                }
                MemosLog.session.info("POST /api/auth/native/logout -> 401, token already gone")
                wipeCredential()
                lastError = licenceComplaint
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
        lastError = licenceComplaint
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

    /// The one place a session becomes a signed-in one, so it is also the one place the account
    /// is published: this is the moment both halves of the binding — which server, and whose
    /// subject — are known, and the subject is known nowhere else on the device.
    ///
    /// It is the LAST step of a sign-in, after the old licence was revoked and the new credential
    /// stored (see `persist`). Every interruption before this point leaves no licence at all, and
    /// no licence means the share extension refuses to enqueue — the only safe way to be wrong.
    private func adopt(client: any APIProtocol, configuration: ServerConfiguration, user: User) {
        self.configuration = configuration
        self.client = client
        // Whatever the last account's default was, it is not this one's until it is fetched.
        defaultVisibility = nil
        state = .signedIn(user)
        account?.publish(
            AccountBinding(serverBaseURL: configuration.baseURL, ownerSubject: user.subject)
        )
        // The file has just been overwritten with the right pair, so an earlier failure to delete
        // it no longer describes anything.
        licenceRevocationFailed = false
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

    /// How a sign-in's two writes went.
    private enum CredentialPersistence {
        case stored
        /// The keychain refused. The session still works from memory, and says so.
        case storedNowhere
        /// The OUTGOING licence would not go, so NOTHING was written: not the credential, not a
        /// new licence, and the session is left exactly as it was found.
        case licenceNotRevoked
    }

    /// Stores the credential, and revokes the outgoing licence BEFORE it does — or does neither.
    ///
    /// Signing in as B while A is signed in is two writes, and the order decides what an
    /// interruption leaves: this way, A's credential with no licence (the extension is denied, and
    /// the next `restore` republishes). The other way round it is B's credential with A's licence,
    /// and a shared photo lands in the wrong account.
    ///
    /// A revocation that FAILS is not an interruption but a refusal, and it aborts the sign-in
    /// rather than carrying on: swapping accounts on the SAME server leaves a stale licence that
    /// nothing else can detect — `restore` compares servers, and only the server knows who a
    /// credential belongs to
    /// — so A's licence would sit next to B's credential until some later publish happened to
    /// overwrite it, and for good if that publish failed too. A sign-in someone can retry is a
    /// far smaller harm than a capture posted into the wrong account.
    private func persist(
        token: String, configuration: ServerConfiguration
    ) -> CredentialPersistence {
        guard clearAccountLicence() else { return .licenceNotRevoked }
        do {
            try credentials.set(token, for: Self.tokenAccount)
            try credentials.set(configuration.baseURL.absoluteString, for: Self.serverAccount)
            return .stored
        } catch {
            return .storedNowhere
        }
    }

    /// What a sign-in says when it refused to touch anything.
    static let licenceBlockedSignIn =
        "The account already on this device could not be cleared, so nothing was changed. "
        + "Try signing in again."

    /// Puts the session back where the sign-in found it. Nothing was written, so there is nothing
    /// to undo — only the `.signingIn` this attempt announced.
    private func abandonSignIn(restoring previous: SessionState) {
        state = previous
        lastError = Self.licenceBlockedSignIn
    }

    /// Forgets the credential — and revokes the share extension's licence FIRST.
    ///
    /// The order is the whole of the safety here. Licence then credential: a crash in between
    /// leaves a credential nobody is signed in with, which denies the extension. Credential then
    /// licence: a crash leaves a revoked identity that can still queue captures, and the person
    /// who signed out has no way of knowing.
    private func wipeCredential() {
        clearAccountLicence()
        try? credentials.remove(Self.tokenAccount)
        try? credentials.remove(Self.serverAccount)
        client = nil
        configuration = nil
        // The account's default belongs to the account. Carrying it into the next sign-in would
        // have the compose sheet promise someone else's setting.
        defaultVisibility = nil
        state = .signedOut
    }

    /// Revokes the licence and REMEMBERS a failure to do so, so the next `restore` tries again.
    @discardableResult
    private func clearAccountLicence() -> Bool {
        guard let account else { return true }
        do {
            try account.clear()
            licenceRevocationFailed = false
            return true
        } catch {
            licenceRevocationFailed = true
            return false
        }
    }

    /// What a sign-out has to say when the credential is gone but its licence is not.
    ///
    /// Sign-out still happens: keeping a live token because a file would not delete is the worse
    /// failure. But it is said out loud rather than swallowed, because until the next launch
    /// reconciles it, a share made from the sheet would still be stamped with this account.
    static let licenceWarning =
        "Signed out, but the share extension's copy of this account could not be removed. "
        + "Open the app again to finish clearing it."

    /// `nil` unless the licence outlived the credential — the value the sign-out paths put in
    /// `lastError` in place of the "nothing went wrong" they used to assume.
    private var licenceComplaint: String? {
        licenceRevocationFailed ? Self.licenceWarning : nil
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

    /// Reads the account's settings. Best-effort by design: it is called from a screen that is
    /// already usable without it, and a failure leaves `defaultVisibility` as it was rather than
    /// interrupting anything.
    public func loadSettings() async {
        guard let client else { return }
        do {
            defaultVisibility = try await Self.settings(client)
        } catch {
            MemosLog.session.info("GET /api/settings did not answer; the default stays unnamed")
        }
    }

    static func settings(_ client: any APIProtocol) async throws -> MemoVisibility {
        let response = try await client.getSettingsApiSettingsGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/settings -> 200")
            return MemoVisibility(try ok.body.json.defaultVisibility)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
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
