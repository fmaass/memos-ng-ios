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
    /// The same failure as a VALUE, beside the sentence `lastError` carries.
    ///
    /// A screen can act on one of these and only one — the Local Network denial, which has a
    /// switch behind it — and matching on a sentence to find out which failure it is would make
    /// the wording of an error message load-bearing.
    public private(set) var lastFailure: NativeLoginError?
    public private(set) var configuration: ServerConfiguration?
    /// Who sees a memo when nobody says otherwise — the account's own setting, not a guess.
    ///
    /// `nil` means "not known yet, or the server would not say". A screen that has to name the
    /// default says less rather than something invented: an app that tells someone their memo
    /// will be Private when the account says Public is worse than one that stays vague.
    public private(set) var defaultVisibility: MemoVisibility?
    /// The account's picture, exactly as the server stores it: a `data:image/…` URL, or `nil`.
    ///
    /// Kept as the STRING rather than as decoded bytes, because decoding it is a screen's problem
    /// and most screens never ask. It arrives on the same `/api/settings` read as the default
    /// above and has the same lifetime — it belongs to the account, not to the app.
    public private(set) var avatar: String?

    private let credentials: any CredentialStore
    private let makeClient:
        @Sendable (ServerConfiguration, @escaping @Sendable () async -> String?) -> any APIProtocol
    /// Where the signed-in account is published for the processes that have no session of their
    /// own — the share extension. Nil unless the app composes one, so a test never writes into
    /// the real app group container.
    private let account: (any OutboxAccountPublishing)?
    /// The clock the MEDIA layer fences its decoded-image cache against. Rotated at the same two
    /// sites as the account licence below, because it scopes to identity in exactly the same way:
    /// a decoded photo is filed under an attachment uid, and a uid means nothing across servers.
    /// Kept separate from `sessionGeneration` deliberately — that one fences this store's own
    /// in-flight replies, and merging the two would couple a media decision to a settings one.
    private let identity: MediaIdentity
    /// A licence that would not delete. It is kept because the thing it describes — a revoked
    /// identity that can still queue captures — outlives the call that failed to remove it, and
    /// the next `restore()` is where it is tried again.
    private var licenceRevocationFailed = false
    /// A credential that would not delete. Like the licence above it outlives the call that
    /// failed to remove it, and it is what the sign-out screens say instead of nothing.
    private var credentialWipeFailed = false
    /// Which session this is. Bumped wherever the account licence is published or revoked — the
    /// same two moments, and the only two, at which "who this device is signed in as" changes.
    ///
    /// It exists because a reply can outlive the question. A request already on the wire is not
    /// reliably cancelled by dropping the client that made it, so an answer about account A can
    /// arrive after someone has signed in as B, and anything that assigns it without checking
    /// would be telling B a fact about A.
    private var sessionGeneration = 0
    private var client: (any APIProtocol)?
    /// The wait between the exchange's two attempts. Injected so a test can take it away: a
    /// suite that really slept would pay 1.5 s per retry case for nothing.
    private let sleeper: @Sendable (Duration) async throws -> Void

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
        sleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        account: (any OutboxAccountPublishing)? = nil,
        identity: MediaIdentity = .shared
    ) {
        self.credentials = credentials
        self.makeClient = makeClient
        self.sleeper = sleeper
        self.account = account
        self.identity = identity
    }

    /// The client every feature talks through, or `nil` while signed out.
    public var api: (any APIProtocol)? { client }

    public var serverBaseURL: URL? { configuration?.baseURL }

    // MARK: - signing in

    /// The browser-brokered device login: the app presents the ordinary web login in a browser
    /// it owns (`SFSafariViewController`), the server hands the finished login back on one of two
    /// return lanes, and the one-shot code on it is traded — together with the PKCE verifier that
    /// never left the device — for a token.
    ///
    /// The custom scheme (`memosng://auth-callback`) is the primary lane and stays that way here:
    /// the server is on internal-only DNS, so the HTTPS lane's domain association can never be
    /// fetched by Apple's CDN. The HTTPS lane is kept for the estates where it can be, and would
    /// activate itself there with nothing to change.
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
        lastFailure = nil
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
            let exchanged = try await exchangeWithRetry(
                makeClient(configuration) { nil }, code: code, verifier: verifier
            )
            let token = exchanged.token
            let persistence = await persist(token: token, configuration: configuration)
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
        } catch NativeLoginError.alreadySigningIn {
            // A second tap on a sign-in that is already on screen. The state this method set on
            // its way in is put back rather than torn down: the FIRST attempt is still running,
            // still showing its browser view, and `failSignIn` here would sign its screen out
            // from under it and leave an error notice on a sign-in that then succeeds.
            abandonSignIn(restoring: previousState)
            return false
        } catch let error as NativeLoginError {
            failSignIn(error)
            return false
        } catch {
            // Named by domain and code, never by its own description. Anything that reaches here
            // from the exchange describes the request it was making, and this request's body is
            // the handoff code and the PKCE verifier.
            failSignIn(.transport(NativeLoginTransportFailure.classify(error)))
            return false
        }
    }

    /// How long the second attempt waits. Long enough for someone to answer the permission sheet
    /// the first attempt raised, short enough that a sign-in still feels like one tap.
    static let exchangeRetryDelay = Duration.milliseconds(1500)

    /// The exchange, with the ONE retry a Local Network denial earns.
    ///
    /// The first connection an app process makes to a private-range host is what raises the Local
    /// Network permission sheet, and iOS fails THAT connection while the sheet is up. The browser
    /// leg is another process, so it completes and the app arrives here with a valid handoff code
    /// and a connect that never happened. Retrying it is safe for one reason only: ENETDOWN at
    /// connect means nothing was transmitted, so the one-shot code cannot have been consumed and
    /// the same pair may be sent again. Every other failure — a timeout, a lost connection, a
    /// -1009 without that stream code — may have been delivered, and sending the code a second
    /// time would be asking the server to spend it twice.
    ///
    /// A refusal the server ANSWERED is never retried either: it is a decision, not a delivery
    /// failure.
    private func exchangeWithRetry(
        _ client: any APIProtocol,
        code: String,
        verifier: String
    ) async throws -> (token: String, user: User) {
        do {
            return try await Self.exchange(client, code: code, verifier: verifier)
        } catch let refusal as NativeLoginError {
            throw refusal
        } catch {
            let failure = NativeLoginTransportFailure.classify(error)
            log(failure: error)
            guard failure == .localNetworkDenied else { throw NativeLoginError.transport(failure) }
        }
        try await sleeper(Self.exchangeRetryDelay)
        do {
            return try await Self.exchange(client, code: code, verifier: verifier)
        } catch NativeLoginError.exchangeRejected(let refusal) where refusal == .codeConsumed {
            // Only reachable if the classification above was wrong: a consumed code means the
            // first attempt DID reach the server. It is still said out loud rather than reported
            // as a bad code, because from the phone nothing was wrong with the code at all.
            throw NativeLoginError.answerLost
        } catch let refusal as NativeLoginError {
            throw refusal
        } catch {
            log(failure: error)
            // Reported as whatever it WAS, not as another denial. The retry is a second chance for
            // the connection, not a verdict on what the second failure means: a timeout here is a
            // timeout, and telling someone to open Local Network for it would be a wrong answer
            // stated confidently.
            throw NativeLoginError.transport(NativeLoginTransportFailure.classify(error))
        }
    }

    /// Writes down that the exchange did not arrive — the classification, the domain and the
    /// code, and NOTHING else. The error's own description carries the request body.
    private func log(failure error: any Error) {
        let diagnostic = NativeLoginTransportFailure.diagnostic(for: error)
        MemosLog.session.error(
            "POST /api/auth/native/exchange did not arrive: \(diagnostic, privacy: .public)"
        )
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
        lastFailure = nil
        let client = makeClient(configuration) { trimmed }
        do {
            let user = try await Self.whoami(client)
            switch await persist(token: trimmed, configuration: configuration) {
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
        let stored: StoredCredential?
        do {
            stored = try await storedCredential()
        } catch {
            // Storage answered, and what it answered with could not be read: a status, an item of
            // the wrong type, bytes that are not a token. That is not evidence that nobody is
            // signed in, so nothing here deletes anything and nothing announces a sign-out — it
            // is said out loud instead, the same way a credential that would not save is.
            let detail = String(describing: error)
            MemosLog.session.error(
                "the stored device credential would not read: \(detail, privacy: .public)"
            )
            lastError = Self.storageUnreadable
            return
        }
        guard let stored,
            let configuration = ServerConfiguration(serverAddress: stored.address)
        else {
            // No credential: whatever licence is lying about belongs to nobody. This is also the
            // retry for a revocation that failed during sign-out.
            clearAccountLicence()
            return
        }
        let storedToken = stored.token
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
            await wipeCredential()
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
            await wipeCredential()
            lastError = signOutComplaint
            return .revoked
        }
        do {
            let response = try await client.nativeLogoutApiAuthNativeLogoutPost(.init())
            switch response {
            case .noContent:
                MemosLog.session.info("POST /api/auth/native/logout -> 204")
                await wipeCredential()
                lastError = signOutComplaint
                return .revoked
            case .undocumented(let statusCode, _):
                guard statusCode == 401 else {
                    let error = APIError.fromStatus(statusCode)
                    lastError = error.errorDescription
                    return .revokeFailed(error)
                }
                MemosLog.session.info("POST /api/auth/native/logout -> 401, token already gone")
                await wipeCredential()
                lastError = signOutComplaint
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
    public func signOutWithoutRevoking() async {
        await wipeCredential()
        lastError = signOutComplaint
    }

    /// The 401 rule, in one place: any feature that sees `.unauthorized` calls this.
    ///
    /// No revoke is attempted. A 401 is the server saying this token is already dead, so there is
    /// nothing to revoke and nothing to keep — this is not the failed-revoke case.
    public func handle(_ error: APIError) async {
        guard error == .unauthorized else { return }
        await wipeCredential()
        // The 401 keeps the headline: a dead token is what the person needs to hear. A wipe that
        // also failed is on the log and in `credentialWipeFailed`, and the next sign-out or
        // restore says so.
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
        // This lifecycle is deliberately the licence's: the default is account-scoped in exactly
        // the way the published binding is, so it is reset where that is published and cleared
        // where that is revoked, and never anywhere else.
        defaultVisibility = nil
        avatar = nil
        sessionGeneration += 1
        // Same lifecycle, one layer over: whatever the previous account's photos were, they are
        // not this one's, and a uid is only unique within one server.
        identity.rotate()
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
        lastFailure = error
    }

    /// The device credential could not be written where it survives the process. Sign-in still
    /// succeeds — the token works from memory and a proper sign-out can still revoke it — but
    /// silence here is how a live server credential gets orphaned by a force-quit.
    public static let storageWarning =
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
    ) async -> CredentialPersistence {
        guard clearAccountLicence() else { return .licenceNotRevoked }
        do {
            // ONE call. Two awaits are two critical sections with a gap between them, and this
            // method's own callers run in that gap: a 401 handled or a sign-out tapped between
            // the token landing and the address landing would wipe the token and leave the
            // address — a state nothing else produces and nothing repairs.
            try await credentials.setAll([
                Self.tokenAccount: token,
                Self.serverAccount: configuration.baseURL.absoluteString,
            ])
            return .stored
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error(
                "the device credential could not be stored: \(detail, privacy: .public)"
            )
            return .storedNowhere
        }
    }

    /// The pair a restore needs, read through one seam so a failure to READ is distinguishable
    /// from nothing being stored.
    private struct StoredCredential {
        var token: String
        var address: String
    }

    private func storedCredential() async throws -> StoredCredential? {
        guard let token = try await credentials.string(for: Self.tokenAccount),
            let address = try await credentials.string(for: Self.serverAccount)
        else { return nil }
        return StoredCredential(token: token, address: address)
    }

    /// What a sign-in says when it refused to touch anything.
    public static let licenceBlockedSignIn =
        "The account already on this device could not be cleared, so nothing was changed. "
        + "Try signing in again."

    /// Puts the session back where the sign-in found it. Nothing was written, so there is nothing
    /// to undo — only the `.signingIn` this attempt announced.
    private func abandonSignIn(restoring previous: SessionState) {
        state = previous
        lastError = Self.licenceBlockedSignIn
        lastFailure = nil
    }

    /// Forgets the credential — and revokes the share extension's licence FIRST.
    ///
    /// The order is the whole of the safety here. Licence then credential: a crash in between
    /// leaves a credential nobody is signed in with, which denies the extension. Credential then
    /// licence: a crash leaves a revoked identity that can still queue captures, and the person
    /// who signed out has no way of knowing.
    private func wipeCredential() async {
        clearAccountLicence()
        // Both halves, whatever either does: a wipe that stopped at the first failure would
        // leave the server address next to a token it could not delete. A failure is REMEMBERED
        // rather than dropped — a device that believes it is signed out while a credential is
        // still on it is the one thing a sign-out must never do quietly.
        credentialWipeFailed = false
        do {
            // ONE call, the mirror of the sign-in's: a sign-in that landed between two deletions
            // would have half of itself deleted behind it.
            try await credentials.removeAll([Self.tokenAccount, Self.serverAccount])
        } catch {
            credentialWipeFailed = true
            let detail = String(describing: error)
            MemosLog.session.error(
                "the stored credential would not delete: \(detail, privacy: .public)"
            )
        }
        client = nil
        configuration = nil
        // The account's default belongs to the account. Carrying it into the next sign-in would
        // have the compose sheet promise someone else's setting. Cleared here, alongside the
        // licence this method revokes, because they scope to the identity together.
        defaultVisibility = nil
        avatar = nil
        sessionGeneration += 1
        identity.rotate()
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
    public static let licenceWarning =
        "Signed out, but the share extension's copy of this account could not be removed. "
        + "Open the app again to finish clearing it."

    /// What a sign-out has to say when a credential could not be removed from the device.
    public static let credentialWipeWarning =
        "Signed out, but the stored credential could not be removed from this device. "
        + "Nothing uses it now - signing in again replaces it."

    /// What a launch says when there IS something stored and it will not read. Deliberately not a
    /// sign-out: nothing was deleted, and the credential may well read on the next launch.
    public static let storageUnreadable =
        "There is a saved sign-in on this device that could not be read. "
        + "Sign in again to replace it."

    /// `nil` unless something outlived the sign-out — the value the sign-out paths put in
    /// `lastError` in place of the "nothing went wrong" they used to assume. The credential is
    /// named first: a token still on the device outranks a stale licence beside the queue.
    private var signOutComplaint: String? {
        if credentialWipeFailed { return Self.credentialWipeWarning }
        return licenceRevocationFailed ? Self.licenceWarning : nil
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
    /// already usable without it, and most failures leave `defaultVisibility` as it was rather
    /// than interrupting anything.
    ///
    /// Two things it is NOT allowed to be casual about.
    ///
    /// It may not answer a question nobody asked any more. The generation is taken before the
    /// call and checked before the assignment, because dropping a client does not reliably cancel
    /// a request already on the wire: without the check, a reply about the account that was signed
    /// in when this started could be written into the session of the one signed in now.
    ///
    /// And a 401 is not a failure to read a setting, it is the server saying this credential is
    /// dead — which ends the session here exactly as it does everywhere else. A token revoked
    /// between opening the timeline and reading the settings is still a revoked token.
    public func loadSettings() async {
        guard let client else { return }
        let generation = sessionGeneration
        do {
            let settings = try await Self.settings(client)
            guard generation == sessionGeneration else {
                MemosLog.session.info("GET /api/settings answered for a session that has ended")
                return
            }
            apply(settings)
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return }
            await handle(.unauthorized)
        } catch {
            MemosLog.session.info("GET /api/settings did not answer; the default stays unnamed")
        }
    }

    /// Changes who sees a memo when nobody says otherwise, on the SERVER.
    ///
    /// The account already owns this setting — the compose sheet's unmarked "Default" resolves
    /// through `defaultVisibility`, which `loadSettings` reads from `/api/settings`, and the web
    /// app edits the same field. So a Settings screen that kept a second answer on the phone would
    /// give one account two defaults that disagree, and the compose pill would name whichever of
    /// them was consulted last. There is one setting, it lives where it already lived, and this is
    /// how it is written.
    ///
    /// Nothing is moved optimistically. What is displayed afterwards is the SERVER's copy out of
    /// the PATCH response, so a change that did not take cannot leave the screen claiming it did.
    /// The generation guard is the one `loadSettings` carries and is there for the same reason: a
    /// reply can outlive the session that asked.
    @discardableResult
    public func setDefaultVisibility(_ visibility: MemoVisibility) async -> Bool {
        guard let client else { return false }
        let generation = sessionGeneration
        do {
            let settings = try await Self.updateSettings(client, defaultVisibility: visibility)
            guard generation == sessionGeneration else {
                MemosLog.session.info("PATCH /api/settings answered for a session that has ended")
                return false
            }
            apply(settings)
            return true
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return false }
            await handle(.unauthorized)
            return false
        } catch {
            MemosLog.session.info("PATCH /api/settings was refused; the default is unchanged")
            return false
        }
    }

    private func apply(_ settings: AccountSettings) {
        defaultVisibility = settings.defaultVisibility
        avatar = settings.avatar
    }

    /// What `/api/settings` says about the account, in the app's own vocabulary. The server also
    /// carries a `theme` string; it is the web app's, and the native app deliberately does not
    /// read or write it (see `AppSettings`).
    struct AccountSettings: Sendable, Equatable {
        let defaultVisibility: MemoVisibility
        let avatar: String?
    }

    static func settings(_ client: any APIProtocol) async throws -> AccountSettings {
        let response = try await client.getSettingsApiSettingsGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/settings -> 200")
            let json = try ok.body.json
            return AccountSettings(
                defaultVisibility: MemoVisibility(json.defaultVisibility),
                avatar: json.avatar
            )
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }

    /// Sends exactly the field being changed. Every property of the patch is optional and the
    /// server applies only the ones present, so naming the others — even with what it just said
    /// they were — would turn a change of one setting into a write of all of them.
    static func updateSettings(
        _ client: any APIProtocol,
        defaultVisibility: MemoVisibility
    ) async throws -> AccountSettings {
        let response = try await client.updateSettingsApiSettingsPatch(
            .init(body: .json(.init(defaultVisibility: defaultVisibility.generated)))
        )
        switch response {
        case .ok(let ok):
            MemosLog.session.info("PATCH /api/settings -> 200")
            let json = try ok.body.json
            return AccountSettings(
                defaultVisibility: MemoVisibility(json.defaultVisibility),
                avatar: json.avatar
            )
        case .unprocessableContent:
            throw APIError.server(status: 422)
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
