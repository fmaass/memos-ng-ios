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

/// How a renewal ended.
///
/// Three answers rather than a `Bool`, because the middle one is not a failure and must not read
/// as one: a token with no expiry cannot be renewed and does not need to be, and telling its owner
/// that renewal "did not work" would invite them to keep pressing at something that is already
/// fine. `failed` is the only one that means try again; the sentence for all three is on
/// `deviceTokenNotice`.
public enum DeviceTokenRenewal: Sendable, Equatable {
    /// The successor is minted, stored and being presented.
    case renewed
    /// The server refused because this token carries no expiry (`token_not_renewable`). The
    /// credential is untouched and still works.
    case notRenewable
    /// The successor is not in hand. That is usually because nothing rotated — but where the
    /// device could not tell, it asked (`resolveAmbiguousRenewal`), so by the time this is
    /// returned the session state is the truthful part: still signed in means the old token is
    /// still good, and signed out means the rotation happened and its successor was lost.
    case failed
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
    /// Why `restore()` parked, as a VALUE beside the sentence `state` carries — `nil` unless the
    /// state is `.unreachable`.
    ///
    /// Same reason `lastFailure` exists one line up: the launch screen can act on exactly one of
    /// these failures, the Local Network denial, and finding it by matching on the sentence would
    /// make the wording of an error message load-bearing.
    public private(set) var restoreFailure: SessionRestoreFailure?
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
    /// What the server says about the credential THIS device is holding, or `nil` while it has not
    /// been read. Scoped to the session exactly as the two above are.
    public private(set) var deviceToken: DeviceToken?
    /// What went wrong the last time the row was read, renamed or renewed — `nil` when nothing
    /// did. Beside the row rather than in `lastError`, because none of these ends a session and a
    /// failed rename must not overwrite the sentence a failed sign-out left on the screen.
    public private(set) var deviceTokenNotice: String?

    private let credentials: any CredentialStore
    /// Takes the credential rather than a token closure, because the client has to keep reading it:
    /// a renewal moves the value and every client already built must present the successor on its
    /// next request (`PresentedCredential`).
    private let makeClient: @Sendable (ServerConfiguration, PresentedCredential) -> any APIProtocol
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
    /// The rotation in flight, if there is one, so a second `renewDeviceToken` joins it instead of
    /// starting a sibling that would destroy the token this one is still reasoning about.
    private var renewalInFlight: Task<DeviceTokenRenewal, Never>?
    private var client: (any APIProtocol)?
    /// The credential the client presents — the SAME object its middleware reads, not a copy.
    ///
    /// It is not a widening of what this process holds; it is the one place the token lives while
    /// the app is running, and it is never handed out. Two callers read it: `download`,
    /// which is the one request that cannot go through the generated client, and a renewal, which
    /// REPLACES the value so that the client already built — and every store holding it — presents
    /// the successor on its next request (see `PresentedCredential`). It is cleared wherever
    /// `client` is, which is the property it exists alongside.
    private var credential: PresentedCredential?
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
                ServerConfiguration, PresentedCredential
            ) -> any APIProtocol = { configuration, credential in
                APIClientFactory.make(configuration: configuration, credential: credential)
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
                makeClient(configuration, .anonymous), code: code, verifier: verifier
            )
            let token = exchanged.token
            let persistence = await persist(token: token, configuration: configuration)
            guard persistence != .licenceNotRevoked else {
                abandonSignIn(restoring: previousState)
                return false
            }
            let credential = PresentedCredential(token)
            adopt(
                client: makeClient(configuration, credential),
                configuration: configuration,
                user: exchanged.user,
                credential: credential
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

    /// Writes down that the credential check did not arrive — the classification, the domain and
    /// the code, and NOTHING else. Both legs that ask `whoami` about a credential write it, so
    /// there is one line to read and one rule to break rather than two.
    private func logWhoamiFailure(_ error: any Error) {
        let diagnostic = NativeLoginTransportFailure.diagnostic(for: error)
        MemosLog.session.error(
            "GET /api/auth/user did not arrive: \(diagnostic, privacy: .public)"
        )
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
        let credential = PresentedCredential(trimmed)
        let client = makeClient(configuration, credential)
        do {
            let user = try await Self.whoami(client)
            switch await persist(token: trimmed, configuration: configuration) {
            case .licenceNotRevoked:
                abandonSignIn(restoring: previousState)
                return
            case .stored:
                adopt(
                    client: client,
                    configuration: configuration,
                    user: user,
                    credential: credential
                )
            case .storedNowhere:
                adopt(
                    client: client,
                    configuration: configuration,
                    user: user,
                    credential: credential
                )
                lastError = Self.storageWarning
            }
        } catch let error as APIError {
            // The server answered and refused. Its sentence is built from a status code and
            // nothing the request carried.
            failSignIn(.api(error))
        } catch {
            // The same classification the NATIVE leg already applies to its own transport failures
            // (`signInNatively`'s generic catch), for the same reason and against the same rule:
            // what is caught here is the generated client's `ClientError`, whose `description`
            // spells out the operation, the `operationInput`, the request and the `requestBody`,
            // and whose `localizedDescription` is the "Client encountered an error invoking …"
            // line. Neither may be displayed, stored or logged. This leg used to store the second
            // one, which is how the two sign-in paths came to say different things about the same
            // failure.
            logWhoamiFailure(error)
            failSignIn(.transport(NativeLoginTransportFailure.classify(error)))
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
        restoreFailure = nil
        let credential = PresentedCredential(storedToken)
        let client = makeClient(configuration, credential)
        // Read before the request, because after it the only thing in hand is an error whose text
        // may not be read.
        let host = configuration.baseURL.host() ?? configuration.baseURL.absoluteString
        do {
            let user = try await Self.whoami(client)
            adopt(
                client: client,
                configuration: configuration,
                user: user,
                credential: credential
            )
        } catch let error as APIError where error == .unauthorized {
            await wipeCredential()
            lastError = error.errorDescription
        } catch let error as APIError {
            // The server answered and refused. Its own sentence is built from a status code and
            // nothing the request carried, so it is the better one.
            park(.server(error))
        } catch {
            // The token was neither confirmed nor rejected. Park, keep, retry — see `unreachable`.
            //
            // What arrives here is the generated client's `ClientError`. Its `description` spells
            // out the operation, the `operationInput`, the request and the `requestBody`, and its
            // `localizedDescription` is the "Client encountered an error invoking …" line the
            // owner read off a launch screen. Neither may be displayed, stored or logged, so
            // nothing here reads either: the error is classified into a value, the screen gets
            // that sentence, and the log gets the domain and the code.
            logWhoamiFailure(error)
            park(SessionRestoreFailure(NativeLoginTransportFailure.classify(error), host: host))
        }
    }

    /// Parks the session on a classified failure: the credential is kept, the client is not.
    ///
    /// The sentence the state carries and the value behind it are assigned together, in one hop,
    /// so no screen can ever read one against the other one's failure — the affordance a denial
    /// earns is decided from the value, and a value that disagreed with the sentence beside it
    /// would offer a Settings button over somebody else's timeout.
    private func park(_ failure: SessionRestoreFailure) {
        client = nil
        credential = nil
        restoreFailure = failure
        state = .unreachable(failure.message)
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
    private func adopt(
        client: any APIProtocol,
        configuration: ServerConfiguration,
        user: User,
        credential: PresentedCredential
    ) {
        self.configuration = configuration
        self.client = client
        self.credential = credential
        // The row belongs to the credential, and this is a different credential. Cleared here for
        // the same reason the account's settings below are: showing the previous device's name and
        // expiry against a new sign-in would be a screen describing a token nobody is holding.
        deviceToken = nil
        deviceTokenNotice = nil
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
        credential = nil
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
        credential = nil
        configuration = nil
        // The account's default belongs to the account. Carrying it into the next sign-in would
        // have the compose sheet promise someone else's setting. Cleared here, alongside the
        // licence this method revokes, because they scope to the identity together.
        defaultVisibility = nil
        avatar = nil
        // Same lifetime, one thing over: the row describes the credential this method just threw
        // away, so keeping it would leave Settings naming a token that is gone.
        deviceToken = nil
        deviceTokenNotice = nil
        sessionGeneration += 1
        identity.rotate()
        // Whatever the last launch could not confirm, it was about a credential that is now gone.
        restoreFailure = nil
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

    // MARK: - the credential this device is holding

    /// Reads the presenting token's own row — its name, its expiry and when it last spoke.
    ///
    /// The route reaches no further than the credential making the request, so this asks for
    /// nothing the device does not already hold. What it adds is the two dates: a phone knows its
    /// expiry from the mint response and nowhere else, which means a reinstalled app cannot tell
    /// its owner how long this device has left.
    ///
    /// Fenced by the session generation for the reason `loadSettings` is: a reply can outlive the
    /// question, and a row about the account that was signed in when this started must not be
    /// written into the session of the one signed in now. A 401 ends the session here exactly as
    /// it does everywhere else.
    public func loadDeviceToken() async {
        guard let client else { return }
        let generation = sessionGeneration
        do {
            let row = try await Self.deviceToken(client)
            guard generation == sessionGeneration else {
                MemosLog.session.info("GET /api/auth/native/token answered for an ended session")
                return
            }
            deviceToken = row
            deviceTokenNotice = nil
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return }
            await handle(.unauthorized)
        } catch {
            guard generation == sessionGeneration else { return }
            // Whatever was already on the row stays: a read that failed is not evidence that the
            // token changed, and blanking the name because the network dropped would be the screen
            // forgetting something it knows.
            deviceTokenNotice = Self.tokenUnreadable
        }
    }

    /// Renames the presenting token — the only field of it a device may change.
    ///
    /// Nothing moves optimistically. What the screen shows afterwards is the SERVER's copy out of
    /// the PATCH response, so a rename that did not take cannot leave the row claiming it did.
    @discardableResult
    public func renameDeviceToken(to name: String) async -> Bool {
        guard let client else { return false }
        // Checked here rather than by the field alone, so that the one rule is the one the request
        // is built from: a name the server would refuse is never sent.
        guard let sanitized = DeviceTokenName.sanitized(name) else {
            deviceTokenNotice = Self.tokenNameRefused
            return false
        }
        let generation = sessionGeneration
        do {
            let row = try await Self.renameDeviceToken(client, to: sanitized)
            guard generation == sessionGeneration else {
                MemosLog.session.info("PATCH /api/auth/native/token answered for an ended session")
                return false
            }
            deviceToken = row
            deviceTokenNotice = nil
            return true
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return false }
            await handle(.unauthorized)
            return false
        } catch {
            guard generation == sessionGeneration else { return false }
            deviceTokenNotice = Self.tokenRenameRefused
            return false
        }
    }

    /// Rotates this device's token: the server mints a successor and destroys the presenter in one
    /// statement, and this is the half of that which happens on the phone.
    ///
    /// The order is the whole of the safety. The credential is written to storage FIRST and only
    /// then swapped in memory, because the other way round leaves the device working from a token
    /// it never wrote down: a force-quit after that, and the next launch restores the credential
    /// the server already destroyed, which signs someone out for good. A storage write that fails
    /// still swaps — the successor is by then the ONLY working credential on the device, and
    /// keeping the dead one to punish the keychain helps nobody — but it says so out loud.
    ///
    /// The swap itself reaches every client through `PresentedCredential`, so the session carries
    /// on mid-flight: the timeline that is already on screen keeps loading, with the new token.
    ///
    /// Nothing is written for a session that has ended. A renewal is a MINT, and a mint landing in
    /// a credential slot somebody else is now using would sign the current account out at its next
    /// request. The successor is dropped instead — its predecessor is gone either way, and the
    /// session it belonged to is over.
    /// One rotation at a time, and a second caller is told about that one rather than starting a
    /// sibling.
    ///
    /// This is a correctness property, not a courtesy. A rotation is not idempotent: the second
    /// one destroys the token the first is still holding, so the first's ambiguity probe — which
    /// asks with exactly that token — is refused, concludes its successor was lost, and wipes the
    /// credential the second is about to install. A successful renewal would end as a sign-out.
    ///
    /// Serialized HERE rather than by whoever calls it. The Settings row disables its button while
    /// one is in flight, but a store may not rest a correctness property on a screen's discipline:
    /// a second window, a background refresh, or any later caller would not be bound by it, and the
    /// race would be back with nothing to show it had returned.
    @discardableResult
    public func renewDeviceToken() async -> DeviceTokenRenewal {
        if let renewalInFlight { return await renewalInFlight.value }
        let rotation = Task { [self] in
            let outcome = await performRenewal()
            // Cleared HERE rather than by the caller that started it. That caller can be resumed
            // long after a later one has legitimately begun the NEXT rotation, and clearing it
            // then would drop that rotation's handle and let a third call start a sibling — the
            // very thing this exists to prevent.
            self.renewalInFlight = nil
            return outcome
        }
        renewalInFlight = rotation
        return await rotation.value
    }

    private func performRenewal() async -> DeviceTokenRenewal {
        guard let client, let credential else { return .failed }
        let generation = sessionGeneration
        let successor: String
        do {
            successor = try await Self.renew(client)
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return .failed }
            await handle(.unauthorized)
            return .failed
        } catch is NotRenewable {
            guard generation == sessionGeneration else { return .failed }
            deviceTokenNotice = Self.tokenNotRenewable
            return .notRenewable
        } catch {
            guard generation == sessionGeneration else { return .failed }
            // "It failed" is not the same claim as "nothing happened", and only one of them is
            // safe to make. See `isAmbiguous`.
            guard Self.isAmbiguous(error) else {
                deviceTokenNotice = Self.tokenRenewalFailed
                return .failed
            }
            return await resolveAmbiguousRenewal(generation: generation)
        }
        guard generation == sessionGeneration else {
            MemosLog.session.info("a renewal answered for a session that has ended; it is dropped")
            return .failed
        }
        var storageRefused = false
        do {
            // ONE item, so nothing can land inside it. The server address is not touched: a
            // renewal changes the token and nothing else, and naming the address again would be a
            // second write for no reason.
            try await credentials.set(successor, for: Self.tokenAccount)
        } catch {
            storageRefused = true
            let detail = String(describing: error)
            MemosLog.session.error(
                "the renewed credential could not be stored: \(detail, privacy: .public)"
            )
            lastError = Self.renewalStorageWarning
        }
        credential.replace(with: successor)
        MemosLog.session.info("POST /api/auth/native/renew -> 200, the device swapped its token")
        // Read back rather than assembled from the renewal's answer: the successor is a new row
        // with its own dates, and inventing them here would put a `created_at` on the screen that
        // no server ever said.
        await loadDeviceToken()
        // AFTER the read, which clears the notice on success. `lastError` alone would not do:
        // the screen this renewal was started from draws the row and does not draw `lastError`,
        // so the warning would land nowhere the person pressing Renew can see it.
        if storageRefused { deviceTokenNotice = Self.renewalStorageWarning }
        return .renewed
    }

    /// Whether a failed renewal leaves this device unable to say WHETHER the rotation happened.
    ///
    /// The distinction is the difference between a true statement and a false one. The server
    /// rotates in a single statement and then answers; if the answer is lost, the token this device
    /// is still presenting has ALREADY been destroyed, and "the renewal failed, your old token
    /// still works" is a lie the next request would expose.
    ///
    /// A status the server chose is a decision: it judged the request and did not rotate. A 5xx, a
    /// dropped connection, or a 200 whose body would not decode are all the same shape — the write
    /// may have been committed and the reply lost — so all of them have to be asked about.
    static func isAmbiguous(_ error: any Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .unauthorized, .forbidden, .notFound: return false
        case .server(let status): return status >= 500
        case .transport, .decoding, .unexpected: return true
        }
    }

    /// Asks, with the token this device is still holding, whether the rotation happened.
    ///
    /// One cheap authenticated read settles it. If the old token still authenticates then nothing
    /// rotated and the device carries on with it. If it is refused then the rotation DID happen,
    /// the successor was in the reply that never arrived, and there is no credential left on this
    /// device that works — so the session ends, deliberately and with a sentence that says why,
    /// rather than by the generic 401 rule tripping over it later in the middle of something else.
    private func resolveAmbiguousRenewal(generation: Int) async -> DeviceTokenRenewal {
        guard let client else { return .failed }
        do {
            _ = try await Self.whoami(client)
            guard generation == sessionGeneration else { return .failed }
            deviceTokenNotice = Self.tokenRenewalFailed
            return .failed
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return .failed }
            MemosLog.session.error(
                "a renewal rotated and its successor was lost; this device has to sign in again"
            )
            await wipeCredential()
            lastError = Self.renewalLostCredential
            return .failed
        } catch {
            guard generation == sessionGeneration else { return .failed }
            // Still unanswerable. The device keeps what it has, which is right either way: if the
            // rotation did happen, the next ordinary request is refused and the usual rule ends the
            // session then, with the credential correctly treated as dead.
            deviceTokenNotice = Self.tokenRenewalUnconfirmed
            return .failed
        }
    }

    /// What a read that failed says. Deliberately not a sign-out and not a blank row.
    public static let tokenUnreadable =
        "This device's access could not be read just now."

    /// What a name this app will not send says. The bounds are the server's own.
    public static let tokenNameRefused =
        "A device name has to be between 1 and \(DeviceTokenName.maxLength) characters."

    public static let tokenRenameRefused =
        "The server did not accept that name, so the old one stands."

    /// Not a failure: an unbounded token cannot silently expire, so there is nothing to renew.
    public static let tokenNotRenewable =
        "This device's token does not expire, so there is nothing to renew."

    public static let tokenRenewalFailed =
        "The access could not be renewed. This device still works with the token it has."

    /// The renewal was neither confirmed nor denied — said as exactly that, because claiming the
    /// old token is fine would be a guess about a rotation that may well have happened.
    public static let tokenRenewalUnconfirmed =
        "The renewal could not be confirmed. This device is still using the token it had; "
        + "if that stops working, sign in again."

    /// The rotation happened and its answer was lost, so the successor is unrecoverable and the
    /// token it replaced is destroyed. There is nothing left on this device that works.
    public static let renewalLostCredential =
        "This device's access was renewed, but the new credential never arrived and the old one "
        + "is gone. You have to sign in again on this device."

    /// The successor works and could not be written down — the renewal's own `storageWarning`.
    public static let renewalStorageWarning =
        "Renewed, but the new credential could not be saved on this device. "
        + "It will not survive quitting the app - sign out properly before you do."

    /// The server refusing to renew a token that has no expiry. A refusal, not a transport
    /// failure, and the one 400 this route answers with.
    private struct NotRenewable: Error {}

    static func deviceToken(_ client: any APIProtocol) async throws -> DeviceToken {
        let response = try await client.nativeTokenApiAuthNativeTokenGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/auth/native/token -> 200")
            return DeviceToken(try ok.body.json)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }

    static func renameDeviceToken(
        _ client: any APIProtocol,
        to name: String
    ) async throws -> DeviceToken {
        let response = try await client.renameNativeTokenApiAuthNativeTokenPatch(
            .init(body: .json(.init(name: name)))
        )
        switch response {
        case .ok(let ok):
            MemosLog.session.info("PATCH /api/auth/native/token -> 200")
            return DeviceToken(try ok.body.json)
        case .unprocessableContent:
            throw APIError.server(status: 422)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }

    /// The successor token, or the reason there is not one.
    ///
    /// The 400 is read rather than reported as "HTTP 400", because `token_not_renewable` is the
    /// difference between "try again" and "this token never needed renewing".
    static func renew(_ client: any APIProtocol) async throws -> String {
        let response = try await client.nativeRenewApiAuthNativeRenewPost(.init())
        switch response {
        case .ok(let ok):
            return try ok.body.json.token
        case .undocumented(let statusCode, let payload):
            if statusCode == 400, let body = payload.body,
                let data = try? await Data(collecting: body, upTo: 4096),
                detail(in: data) == "token_not_renewable"
            {
                throw NotRenewable()
            }
            throw APIError.fromStatus(statusCode)
        }
    }

    /// FastAPI's `{"detail": "<code>"}`, when that is what arrived. A 422 carries a LIST under the
    /// same key, so the type is checked rather than assumed.
    private static func detail(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["detail"] as? String
    }

    /// Downloads one of an attachment's files, and answers where it was put.
    ///
    /// It lives on the session rather than on a media type of its own because of the credential:
    /// the original tier is served unsigned and authenticated, so this is the only request outside
    /// the generated client that has to present the device token — and the token stays in here
    /// (see `credential`) rather than being handed to the layer that wants the file. The server it
    /// is offered to is pinned to this session's own (`OriginalMedia.sameOrigin`).
    ///
    /// A `shared` clip rides the very same lane, credential and all. Its URL is signed, so the
    /// token is not what authorises it — the server's signed fast path never reads the header
    /// (memos-ng `app/routers/assets.py`) — and it goes anyway because this is ONE lane: one
    /// origin pin, one fence, one enclosure per request. A second lane that fetched media without
    /// a credential would be a second copy of those rules to keep in step, which is how one of
    /// them ends up missing the fence.
    ///
    /// It is FENCED by the session generation, the same fence `loadSettings` carries and for the
    /// same reason, which matters more here than anywhere else in this file. A download is the
    /// longest-lived request the app makes — an original is the archive master, so a clip can be on
    /// the wire for minutes — which makes it far and away the most likely reply to land after
    /// somebody has signed out or switched accounts. Landing unfenced it does two things, and both
    /// are worse than a failed download: it hands the successor session a file belonging to the
    /// account before it, and a 401 arriving from the DEAD credential ends the session of the LIVE
    /// one. So the generation is read before the request and checked on both ways back, the late
    /// file is deleted rather than returned, and the late 401 is discarded rather than obeyed.
    ///
    /// A 401 that belongs to the CURRENT session still ends it, exactly as on every other path. The
    /// error is thrown afterwards either way, because the screen that asked for the file needs to
    /// know it is not coming.
    public func download(
        _ attachment: MemoAttachment,
        _ rendition: AttachmentRendition = .original,
        transport: any MediaDownloadTransport = MediaSession.shared,
        into directory: URL = .temporaryDirectory
    ) async throws -> URL {
        guard let wanted = attachment.file(rendition) else { throw OriginalMediaError.unavailable }
        guard let server = configuration?.baseURL, let credential else {
            throw OriginalMediaError.notSignedIn
        }
        // The epoch fence the middleware applies has to be applied by hand here, because this
        // request does not go through it. It is not the only lane that bypasses the middleware —
        // the outbox builds its own requests (`DeviceOutboxCredentials`) and so does the live
        // channel (`MediaEventClient.device`) — but it is the only one that needs a fence: those
        // two re-read the credential from the vault per drain and per connection, so a rotation
        // is simply what their next attempt picks up, and neither of them ends a session on a 401.
        // This one holds its token across the request AND reports to `handle`, and a download is
        // the longest-lived request the app makes, which makes it the likeliest of all to be
        // answered after a renewal replaced the token it presented.
        let presented = credential.presented()
        guard !presented.token.isEmpty else { throw OriginalMediaError.notSignedIn }
        let generation = sessionGeneration
        do {
            let file = try await OriginalMedia.fetch(
                url: wanted.url,
                token: presented.token,
                uid: attachment.uid,
                mime: wanted.mime,
                server: server,
                transport: transport,
                into: directory
            )
            guard generation == sessionGeneration else {
                MemosLog.session.info("an original arrived for a session that has ended")
                // Thrown away, not merely unreturned: it is the previous account's photograph, and
                // leaving it in a temporary directory is leaving it for the next one. It removes
                // this request's OWN enclosure and nothing else — `fetch` gives every download a
                // directory to itself precisely so that a tidy-up here cannot reach a file some
                // other request has already handed to the share sheet.
                OriginalMedia.discard(file)
                throw OriginalMediaError.superseded
            }
            return file
        } catch OriginalMediaError.refused(let error) {
            guard generation == sessionGeneration else {
                MemosLog.session.info("a download failed for a session that has ended")
                throw OriginalMediaError.superseded
            }
            if error == .unauthorized, !credential.isCurrent(presented.epoch) {
                MemosLog.session.info(
                    "a download was refused for a credential this device replaced; not a sign-out"
                )
                // Reported as superseded rather than rethrown as a refusal. Ending the session is
                // only half of what `.refused(.unauthorized)` does — it is also the shape every
                // screen turns into "your access was rejected, sign in again", which on a live
                // session that has just renewed is a false instruction that costs someone a
                // working sign-in.
                throw OriginalMediaError.superseded
            }
            if error == .unauthorized { await handle(.unauthorized) }
            throw OriginalMediaError.refused(error)
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
