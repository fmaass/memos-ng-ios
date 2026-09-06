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
    /// Whether the server has confirmed the credential this session is running on.
    ///
    /// Separate from `state` because the app can be signed in and unconfirmed at once: a stored
    /// credential opens the app before the server answers. `.verified` is what a session that was
    /// never in doubt reads, so nothing that does not admit provisionally has to think about it.
    public private(set) var verification: SessionVerification = .verified
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
    /// The same number, in a box anything can read without hopping to this actor.
    ///
    /// It exists for the writers that commit from wherever their work finished. A hop to ask "is
    /// this session still the one I started under" is a suspension, and the suspension is exactly
    /// where the session can end.
    public nonisolated let epoch = SessionEpoch()
    /// The INCARNATION, in a box of its own that a sender can read without hopping.
    ///
    /// Distinct from `epoch` above, and the difference matters to exactly one kind of caller. The
    /// authority epoch also moves on a RENEWAL, because the token a grant names has been
    /// destroyed. An upload in flight is not in that position: it goes through the generated
    /// client, which reads the credential per request and so follows the successor by itself. What
    /// must stop it is the session ENDING, and that is this number.
    public nonisolated let sessionIncarnation = SessionEpoch()
    /// The rotation in flight, if there is one, so a second `renewDeviceToken` joins it instead of
    /// starting a sibling that would destroy the token this one is still reasoning about.
    private var renewalInFlight: Task<DeviceTokenRenewal, Never>?
    /// The launch check or re-validation in flight, if there is one.
    ///
    /// ONE slot for both, because they ask the server the same question. `RootView`'s task and the
    /// background launch's `startOutbox` both call `restore()` while `state.user` is nil, and two
    /// admissions would bump the generation twice and then each discard the other's answer.
    private var validationInFlight: Task<Void, Never>?
    /// Whether the check in flight can still answer for the session on this device.
    ///
    /// A check that was invalidated will write nothing — every effect it has asks first — so a
    /// later trigger that JOINED it would be handed that non-answer and leave the session with
    /// nothing running at all. Joining is for the overlap it was designed for: two triggers asking
    /// the SAME question of the same session. A superseded flight is replaced instead.
    private var validationSuperseded = false
    /// Which flight owns the slot, so a superseded one finishing later cannot clear a live one's.
    private var validationToken = 0
    /// The retry waiting to run, if the session is unconfirmed and the app is in front of
    /// somebody.
    private var retryInFlight: Task<Void, Never>?
    /// Whether a SCENE has reported itself active. Retries only run then: a phone in a pocket
    /// asking every 45 seconds is a battery cost with nobody to read the answer, and a process the
    /// system woke to finish an upload has no scene at all — it must not start a ladder nobody
    /// will ever see the end of. False until a scene says otherwise, because a headless launch is
    /// the state this app is in more often than not.
    private var isForegrounded = false
    /// Whether the credential this session is running on was ever written down successfully.
    ///
    /// Not the same question as "is the credential in memory the current one". A sign-in whose
    /// write threw keeps working from memory and deletes the last-known-user file, because storage
    /// may hold the PREDECESSOR and a file naming this identity beside that token is the
    /// wrong-identity admission the fingerprint exists to prevent. A later revalidation matches
    /// the credential epoch — nothing about it moved — and would happily write the file back. The
    /// epoch cannot see the difference; this flag is what remembers it.
    private var persistenceProven = false
    /// Whether a sign-in is running. A second one is REFUSED, not joined.
    ///
    /// Joined would be wrong: two sign-ins are two different intents — a different token, possibly
    /// a different account — and the second caller would be told the first one's answer. Refused,
    /// the person taps again after the first settles. What it prevents is worse than a confusing
    /// answer: a third sign-in completing while a second was in flight let the second's abandon
    /// path put back a state belonging to the first, beside a client belonging to the third.
    private var signingIn = false
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
    /// Where the identity a launch may open on is kept. Nil in a suite that is not about it, for
    /// the reason `account` is nil there: a test must never write into the real container.
    private let lastKnownUser: (any LastKnownUserStoring)?
    /// What to do the moment a session becomes confirmed — the app wires its outbox drain to it.
    ///
    /// It is a handler rather than something this store calls directly because the queue lives a
    /// layer above: a capture parked while the phone was off the network needs somebody to try
    /// again, and the only event that says trying is worth it is this one.
    private let onVerified: (@MainActor @Sendable () -> Void)?
    /// Where a diagnostic line goes, injected the same way the sleeper is.
    ///
    /// It exists so the log BOUNDARY can be watched rather than re-derived. A guardrail that
    /// re-computes what the store ought to have written proves only that the test agrees with
    /// itself: a line that interpolated the error's own text here would leave it green, and the
    /// error's own text is precisely what may not be written.
    private let diagnostics: @Sendable (String) -> Void

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
        identity: MediaIdentity = .shared,
        lastKnownUser: (any LastKnownUserStoring)? = nil,
        onVerified: (@MainActor @Sendable () -> Void)? = nil,
        // Optional rather than defaulted to a closure: an `OSLogMessage` interpolation cannot be
        // built in a default argument value (`os` is imported by `MemosLog`, not by this file),
        // and a named default would have to be public to be referenced from one.
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.makeClient = makeClient
        self.sleeper = sleeper
        self.account = account
        self.identity = identity
        self.lastKnownUser = lastKnownUser
        self.onVerified = onVerified
        self.diagnostics =
            diagnostics ?? { line in MemosLog.session.error("\(line, privacy: .public)") }
    }

    /// The client every feature talks through, or `nil` while signed out.
    public var api: (any APIProtocol)? { client }

    /// The client and the incarnation it belongs to, read as ONE value — what a store captures at
    /// the start of an operation and carries through every retry of it.
    public var activeHandle: SessionHandle? {
        client.map { SessionHandle(client: $0, generation: sessionGeneration) }
    }

    /// The authority a lane that sends from ANOTHER executor carries with it.
    ///
    /// Read here, on the main actor, at the instant the operation starts; asked again by the
    /// executor doing the sending. The incarnation rather than `epoch`, because a renewal replaces
    /// the token a request presents without ending anything it is doing.
    public func sendAuthority() -> SendAuthority {
        let incarnation = sessionIncarnation
        let granted = incarnation.current
        // The credential goes with it, read through the SAME object the client presents from, so
        // the send resolves the token at the instant it asks the verdict. A renewal replaces the
        // value in that object without moving the incarnation — deliberately, because a renewal
        // does not end anything — so a lane that carried a snapshot would be cleared to send a
        // token the server destroyed. This closure is the only thing that stops that.
        let presenting = credential
        return SendAuthority(
            { incarnation.isCurrent(granted) },
            credential: {
                guard let snapshot = presenting?.presented() else { return nil }
                // The epoch travels WITH the token. What a response is judged against has to be
                // the generation that earned it, and a token on its own cannot answer that.
                return PresentedGrant(token: snapshot.token, epoch: snapshot.epoch)
            }
        )
    }

    /// The authority to act as this device's account, assembled from this session's own state in
    /// ONE synchronous step — and the only source of it inside the app.
    ///
    /// The lanes that build their own requests (the outbox) used to assemble the same three facts
    /// themselves, from three different places: the subject from the session, the token and the
    /// address from the keychain. Three reads are three instants, and the pair they produce can be
    /// incoherent in a way no counter can see — a sign-in as B whose credential would not store
    /// leaves B established in memory and A's token in the keychain, and an assembly across those
    /// two sources pairs B's identity with A's credential under an epoch that never moved. Read
    /// from here, that state cannot be expressed: the subject and the token come from the same
    /// object graph, in the same instant.
    ///
    /// `nil` whenever there is no authority to grant — no client, no user, or an empty token.
    public func credentialGrant() -> CredentialGrant? {
        guard client != nil, let configuration, let credential, let user = state.user else {
            return nil
        }
        let presented = credential.presented()
        guard !presented.token.isEmpty else { return nil }
        return CredentialGrant(
            subject: user.subject,
            serverBaseURL: configuration.baseURL,
            token: presented.token,
            epoch: epoch.current
        )
    }

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

        guard !signingIn else {
            lastError = Self.signInAlreadyRunning
            return false
        }
        signingIn = true
        defer { signingIn = false }

        let previous = snapshot
        state = .signingIn
        lastError = nil
        lastFailure = nil
        // Taken before the browser leg, which is the longest await in the app: a sign-out or
        // another installation completing inside it owns the session by the time the code comes
        // back. See the pasted leg for why `persist`'s own generation cannot answer this.
        let issued = sessionGeneration
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
            guard owns(issued) else {
                MemosLog.session.info("a sign-in was overtaken before its credential was stored")
                return false
            }
            let persistence = await persist(token: token, configuration: configuration)
            guard persistence.outcome != .licenceNotRevoked else {
                abandonSignIn(restoring: previous)
                return false
            }
            // Synchronously, immediately before the first effect: a wipe or another installation
            // that landed inside the keychain write owns the session now, and building this one on
            // top of it would publish a licence and a file for an account that is already gone.
            guard persistence.installing == sessionGeneration else {
                MemosLog.session.info("a sign-in was overtaken while its credential was stored")
                return false
            }
            let credential = PresentedCredential(token)
            establish(
                client: makeClient(configuration, credential),
                configuration: configuration,
                user: exchanged.user,
                credential: credential
            )
            enterVerified()
            if persistence.outcome == .storedNowhere {
                lastError = Self.storageWarning
                persistenceProven = false
                forgetLastKnownUser()
            } else {
                persistenceProven = true
                record(exchanged.user, of: configuration, boundTo: token)
            }
            return true
        } catch NativeLoginError.alreadySigningIn {
            guard owns(issued) else { return supersededSignIn() }
            // A second tap on a sign-in that is already on screen. The state this method set on
            // its way in is put back rather than torn down: the FIRST attempt is still running,
            // still showing its browser view, and `failSignIn` here would sign its screen out
            // from under it and leave an error notice on a sign-in that then succeeds.
            abandonSignIn(restoring: previous)
            return false
        } catch let error as NativeLoginError {
            guard owns(issued) else { return supersededSignIn() }
            failSignIn(error)
            return false
        } catch {
            guard owns(issued) else { return supersededSignIn() }
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
        diagnostics("GET /api/auth/user did not arrive: \(diagnostic)")
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

        guard !signingIn else {
            lastError = Self.signInAlreadyRunning
            return
        }
        signingIn = true
        defer { signingIn = false }

        let previous = snapshot
        state = .signingIn
        lastError = nil
        lastFailure = nil
        let credential = PresentedCredential(trimmed)
        let client = makeClient(configuration, credential)
        // Taken BEFORE the first await. `persist` mints a generation of its own, so checking only
        // that one asks whether the sign-in still owns the session it just took over — which it
        // trivially does. The question that matters is whether it still owned the session it
        // STARTED in, and a sign-out completing while `whoami` was on the wire is exactly the
        // answer no.
        let issued = sessionGeneration
        do {
            let user = try await Self.whoami(client)
            guard owns(issued) else {
                MemosLog.session.info("a sign-in was overtaken before its credential was stored")
                return
            }
            let persistence = await persist(token: trimmed, configuration: configuration)
            if persistence.outcome == .licenceNotRevoked {
                abandonSignIn(restoring: previous)
                return
            }
            // Synchronously, immediately before the first effect — see the native leg.
            guard persistence.installing == sessionGeneration else {
                MemosLog.session.info("a sign-in was overtaken while its credential was stored")
                return
            }
            switch persistence.outcome {
            case .licenceNotRevoked:
                return
            case .stored:
                establish(
                    client: client,
                    configuration: configuration,
                    user: user,
                    credential: credential
                )
                enterVerified()
                persistenceProven = true
                record(user, of: configuration, boundTo: trimmed)
            case .storedNowhere:
                establish(
                    client: client,
                    configuration: configuration,
                    user: user,
                    credential: credential
                )
                enterVerified()
                lastError = Self.storageWarning
                persistenceProven = false
                // The write threw, which does not prove the PREDECESSOR survived it — the vault
                // writes before its verifying read, and `setAll` can throw after one item has
                // already landed. Keeping A's fingerprint beside B's user on screen is the
                // wrong-identity admission the fingerprint exists to prevent, so the file goes and
                // the next launch waits on the server.
                forgetLastKnownUser()
            }
        } catch let error as APIError {
            guard owns(issued) else {
                supersededSignIn()
                return
            }
            // The server answered and refused. Its sentence is built from a status code and
            // nothing the request carried.
            failSignIn(.api(error))
        } catch {
            guard owns(issued) else {
                supersededSignIn()
                return
            }
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
    ///
    /// SINGLE-FLIGHT, and that is a correctness property rather than a courtesy. `RootView`'s task
    /// and the background launch's `startOutbox` both call this while `state.user` is nil, and the
    /// "Try again" button is a third caller. Two of them running would admit twice — two
    /// generation bumps, after which each request's answer is fenced out by the other's bump and
    /// the session is left with no client and nothing scheduled.
    public func restore() async {
        await validating { await self.performRestore() }
    }

    /// Asks the server about the credential the session is already holding.
    ///
    /// The re-validation half of the lifecycle: the foreground trigger and the retry schedule both
    /// come through here, and both join whatever is already in flight rather than sending a second
    /// question.
    private func revalidate(attempt: Int) async {
        await validating { [self] in
            guard let client, let configuration, let credential, state.user != nil else { return }
            await validate(
                client: client,
                configuration: configuration,
                credential: credential,
                attempt: attempt
            )
        }
    }

    /// The one slot every check goes through. A second caller JOINS the one in flight and sends
    /// nothing.
    private func validating(_ body: @escaping @MainActor @Sendable () async -> Void) async {
        if let validationInFlight, !validationSuperseded {
            // The overlap joining exists for: two triggers asking the same question of the same
            // session. One request on the wire, one answer, both callers told it.
            return await validationInFlight.value
        }
        // A flight the session has moved past cannot answer for the session running now: its own
        // fences will make it write nothing. REPLACED, not joined — joining it is how a restored
        // `.verifying` ends up with neither a task nor a retry behind it.
        validationInFlight?.cancel()
        validationSuperseded = false
        validationToken += 1
        let mine = validationToken
        let work = Task { @MainActor [self] in
            await body()
            // Cleared HERE rather than by the caller that started it, for the reason the renewal
            // clears its own: that caller can be resumed long after a later one has legitimately
            // begun the next check. Only the flight that OWNS the slot may clear it — a superseded
            // one finishing afterwards would otherwise drop the live one's handle.
            if validationToken == mine { validationInFlight = nil }
        }
        validationInFlight = work
        await work.value
    }

    /// Says that whatever check is in flight is about a session that is over.
    ///
    /// Called wherever an incarnation ends, beside the counter bump: the counter makes the flight
    /// harmless, and this makes the next trigger replace it rather than wait on it.
    private func supersedeValidationInFlight() {
        validationSuperseded = validationInFlight != nil
    }

    private func performRestore() async {
        // Taken BEFORE the first read, not after it: the credential read is an await, and a wipe
        // or a sign-in landing inside it owns the session by the time it returns. Checked again
        // the moment it does.
        let issued = sessionGeneration
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
            // Before the complaint, not only before the admission: a sentence about a credential
            // read that failed belongs to the session that asked for it, and writing it over a
            // session installed since would put a storage warning on somebody else's screen.
            guard owns(issued) else { return }
            lastError = Self.storageUnreadable
            return
        }
        guard issued == sessionGeneration else {
            MemosLog.session.info("a launch check was overtaken while it read the credential")
            return
        }
        guard let stored,
            let configuration = ServerConfiguration(serverAddress: stored.address)
        else {
            // No credential: whatever licence is lying about belongs to nobody. This is also the
            // retry for a revocation that failed during sign-out.
            clearAccountLicence()
            // And whatever identity is lying about has no token behind it. The keychain item is
            // `ThisDeviceOnly`, so a device restore lands here with a file and nothing to bind it
            // to — the orphan this branch exists to reconcile.
            invalidateIdentityScopedState()
            return
        }
        let storedToken = stored.token
        // A licence naming a different server than the stored credential is what an interrupted
        // account switch leaves behind. Deny first; the admission below republishes, and so does
        // the confirmation. The subject cannot be checked here — that is what the server is for.
        if let published = account?.current(), published.serverBaseURL != configuration.baseURL {
            clearAccountLicence()
        }

        lastError = nil
        restoreFailure = nil
        let credential = PresentedCredential(storedToken)
        let client = makeClient(configuration, credential)

        // PROVISIONAL ADMISSION. Both halves or neither: a file naming this server is what an
        // interrupted same-server account switch also leaves, and only the fingerprint can tell
        // that apart from the ordinary case. Anything less than both takes the path this launch
        // always took — announce `.signingIn` and wait on the server.
        if let known = lastKnownUser?.read(),
            known.binds(serverBaseURL: configuration.baseURL, token: storedToken)
        {
            establish(
                client: client,
                configuration: configuration,
                user: known.user,
                credential: credential
            )
            // Immediately after, with nothing awaited in between: `establish` leaves a session
            // that looks confirmed, and it is not — the server has not been asked yet.
            verification = .verifying
            // This credential came OUT of storage, so storage demonstrably holds it — the one
            // installation whose proof is the read itself rather than a write.
            persistenceProven = true
        } else {
            state = .signingIn
            // Same proof, same reason: whatever this check confirms, it confirms about a token
            // that was read out of storage a moment ago.
            persistenceProven = true
        }

        await validate(
            client: client,
            configuration: configuration,
            credential: credential,
            attempt: 0
        )
    }

    /// Asks `whoami` about a credential and applies the answer to the session that ASKED.
    ///
    /// Every outcome is judged against two things taken before the request: the session generation
    /// and the credential epoch. A reply can outlive both — a sign-out, an account switch or a
    /// renewal can land while this is on the wire — and an answer about a credential that is gone
    /// must not end, confirm or repopulate the session running now.
    private func validate(
        client: any APIProtocol,
        configuration: ServerConfiguration,
        credential: PresentedCredential,
        attempt: Int
    ) async {
        let generation = sessionGeneration
        let presented = credential.presented()
        let admitted = state.user != nil
        // Read before the request, because after it the only thing in hand is an error whose text
        // may not be read.
        let host = configuration.baseURL.host() ?? configuration.baseURL.absoluteString
        do {
            let user = try await Self.whoami(client)
            // Synchronously, with no await between this check and every effect below it. A wipe
            // or a sign-in as somebody else is a DIFFERENT operation from this one, so joining
            // concurrent checks does not cover it and cannot: nothing serialises a validation
            // against a sign-out.
            guard generation == sessionGeneration else {
                MemosLog.session.info("GET /api/auth/user answered for a session that has ended")
                return
            }
            if let current = state.user, current.subject == user.subject {
                // The SAME account confirming the credential it was already using. It updates the
                // user and nothing else: rotating the media identity here would empty the response
                // cache on every routine revalidation, and resetting the account's settings would
                // blank the compose sheet's default every time the phone came back on the network.
                confirm(user, of: configuration)
            } else {
                // A different subject is a different account, whatever the token was stored as.
                establish(
                    client: client,
                    configuration: configuration,
                    user: user,
                    credential: credential
                )
            }
            // The credential this answer was made FOR may have been replaced while it was on the
            // wire. Writing its fingerprint then would name a token the server destroyed, and the
            // next launch would decline to admit a device that did everything right.
            if credential.isCurrent(presented.epoch), persistenceProven {
                record(user, of: configuration, boundTo: presented.token)
            } else if !persistenceProven {
                MemosLog.session.info("this device's credential was never written down; no file")
            } else {
                MemosLog.session.info("a check answered for a credential this device replaced")
            }
            enterVerified()
        } catch let error as APIError where error == .unauthorized {
            guard generation == sessionGeneration else { return }
            // NOT re-judged here. This used to compare `presented.epoch`, read before the await,
            // and that is a different credential from the one the request carried whenever a
            // renewal landed in between: the middleware presents what the device holds NOW, so a
            // 401 earned by the successor was being filed as a refusal of the predecessor and the
            // rejected session was kept. The classification belongs where the credential is
            // attached — `BearerAuthMiddleware` records the epoch it presented and turns a refusal
            // of a replaced one into `CredentialSuperseded`, which lands in the generic catch below
            // as neither outcome. An `APIError.unauthorized` reaching HERE is therefore already a
            // refusal of the credential this device is holding.
            let wiped = await wipeCredential()
            // The wipe is an await of its own, and its tail refuses when something overtook it.
            // The sentence it leaves behind is one more write and follows the same rule — judged
            // against the generation the WIPE installed, because that is the only number that can
            // still be current when nothing overtook it.
            if owns(wiped) { lastError = error.errorDescription }
        } catch let error as APIError {
            // The server answered and refused. Its own sentence is built from a status code and
            // nothing the request carried, so it is the better one. It is never terminal: a
            // reachable server that is unwell is not a revoked token.
            guard generation == sessionGeneration else { return }
            unconfirmed(.server(error), admitted: admitted, attempt: attempt)
        } catch {
            guard generation == sessionGeneration else { return }
            // Neither outcome. A cancellation is this app's own doing — a suspension, a screen
            // going away — and a supersede is an answer about a credential that is gone. The state
            // stands, the attempt is not counted, and a replacement goes out at once rather than
            // waiting for whatever trigger comes next. The chain cannot spin: what cancels a check
            // is the app leaving the foreground, and `scheduleRetry` runs nowhere else.
            if StoreFailure.isCancellation(error) || StoreFailure.isSuperseded(error) {
                MemosLog.session.info("a cancelled credential check is not an answer about it")
                discard(error, admitted: admitted, attempt: attempt, host: host)
                return
            }
            // The token was neither confirmed nor rejected. Park or stay admitted, keep the
            // credential, ask again — see `unreachable`.
            //
            // What arrives here is the generated client's `ClientError`. Its `description` spells
            // out the operation, the `operationInput`, the request and the `requestBody`, and its
            // `localizedDescription` is the "Client encountered an error invoking …" line the
            // owner read off a launch screen. Neither may be displayed, stored or logged, so
            // nothing here reads either: the error is classified into a value, the screen gets
            // that sentence, and the log gets the domain and the code.
            logWhoamiFailure(error)
            unconfirmed(
                SessionRestoreFailure(NativeLoginTransportFailure.classify(error), host: host),
                admitted: admitted,
                attempt: attempt
            )
        }
    }

    /// The check did not confirm the credential, and did not refuse it either.
    ///
    /// A session that was admitted stays admitted and says so in one line; one that never got that
    /// far parks on the launch screen exactly as it always did. Both keep the credential: an
    /// unreachable server is not evidence about a token.
    private func unconfirmed(
        _ failure: SessionRestoreFailure,
        admitted: Bool,
        attempt: Int
    ) {
        guard admitted else {
            park(failure)
            return
        }
        verification = .unverified(failure.message)
        scheduleRetry(attempt: attempt + 1)
    }

    /// An answer that is not evidence: a check this app cancelled, or one about a credential this
    /// device has already replaced.
    ///
    /// Neither outcome. The state stands, the attempt is not counted, and a replacement goes out
    /// AT ONCE — a discarded answer that scheduled nothing is what leaves a session parked in
    /// `.verifying` with no task and no retry behind it. A launch that never got admitted has no
    /// session to leave standing and `.signingIn` is the sign-in screen, so it parks with the
    /// classification exactly as this launch always did, and "Try again" is its trigger.
    private func discard(_ error: any Error, admitted: Bool, attempt: Int, host: String) {
        guard admitted else {
            park(SessionRestoreFailure(NativeLoginTransportFailure.classify(error), host: host))
            return
        }
        scheduleRetry(attempt: attempt, delay: .zero)
    }

    // MARK: - asking again

    /// The waits between re-validations: three that climb, then a cap.
    ///
    /// Jittered because they are not one phone's problem. Brooker (AWS, 2015): "The return on
    /// implementation complexity of using jittered backoff is huge, and it should be considered a
    /// standard approach for remote clients."
    static let retryWaits: [Duration] = [.seconds(3), .seconds(10), .seconds(30)]
    static let retryCap = Duration.seconds(45)
    /// ±20 %, so the cap is at most 54 seconds.
    static let retryJitter = 0.2

    /// What the nth retry waits, before jitter. The first retry is `retryWaits[0]`.
    static func retryWait(afterAttempt attempt: Int) -> Duration {
        let index = max(0, attempt - 1)
        guard index < retryWaits.count else { return retryCap }
        return retryWaits[index]
    }

    /// Whether anything is still owed an answer — the whole precondition of the schedule.
    ///
    /// An admitted session that is not confirmed, and nothing else. A confirmed one schedules
    /// nothing, which is what stops the app asking every 45 seconds for ever; a launch that parked
    /// has its own screen with its own "Try again" on it.
    private var awaitingConfirmation: Bool {
        state.user != nil && verification != .verified
    }

    /// Puts the next check on the clock, cancelling whatever was already waiting.
    ///
    /// Only in the foreground. Backgrounded, the schedule stops entirely — the phone in a pocket
    /// has nobody to show an answer to, and the return to the foreground is itself a trigger.
    private func scheduleRetry(attempt: Int, delay: Duration? = nil) {
        retryInFlight?.cancel()
        retryInFlight = nil
        guard isForegrounded, awaitingConfirmation else { return }
        let wait = delay ?? Self.jittered(Self.retryWait(afterAttempt: attempt))
        let generation = sessionGeneration
        retryInFlight = Task { @MainActor [self] in
            // A sleeper that throws is a schedule that stops — which is what cancellation of this
            // task means and what a test uses to bound the chain.
            do { try await sleeper(wait) } catch { return }
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            await revalidate(attempt: attempt)
        }
    }

    /// ±20 % around the nominal wait.
    static func jittered(_ wait: Duration) -> Duration {
        let parts = wait.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let factor = Double.random(in: (1 - retryJitter)...(1 + retryJitter))
        return .seconds(seconds * factor)
    }

    /// The app came back in front of somebody. The one trigger the Features layer owns.
    public func enteredForeground() async {
        isForegrounded = true
        guard awaitingConfirmation else { return }
        await revalidate(attempt: 0)
    }

    /// The app went away. Nothing is scheduled behind it, and nothing is left running.
    ///
    /// The check in flight is cancelled too: it is a request nobody is waiting for, and the system
    /// is about to suspend the process around it anyway. A cancelled check is neither outcome, so
    /// the session it belongs to stands exactly as it was and the next foreground asks again.
    public func enteredBackground() {
        isForegrounded = false
        retryInFlight?.cancel()
        retryInFlight = nil
        validationInFlight?.cancel()
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
        // Withdrawing the client withdraws the authority with it, so anything holding a grant
        // taken under it stops at its next synchronous check.
        endIncarnation()
        supersedeValidationInFlight()
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
            let wiped = await wipeCredential()
            // Fenced like every other complaint this file writes after a keychain await: anything
            // that completed inside the delete owns the session now, and a sentence about the
            // credential this sign-out threw away is not about the one that session is holding.
            if owns(wiped) { lastError = signOutComplaint }
            return .revoked
        }
        // The revoke is a request, and A's answer to it can land after B has signed in. Every
        // branch below WIPES or writes, so each one asks whether the session it set out to end is
        // still the session on this device — a 204 for A's token must not destroy B's.
        let issued = sessionGeneration
        do {
            let response = try await client.nativeLogoutApiAuthNativeLogoutPost(.init())
            guard owns(issued) else {
                MemosLog.session.info("a sign-out answered for a session that has been replaced")
                return .revoked
            }
            switch response {
            case .noContent:
                MemosLog.session.info("POST /api/auth/native/logout -> 204")
                let wiped = await wipeCredential()
                // The `owns(issued)` above fenced the ANSWER; this fences the SENTENCE. The wipe
                // between them is another await, and anything that completes inside it owns the
                // session by the time this line runs.
                if owns(wiped) { lastError = signOutComplaint }
                return .revoked
            case .undocumented(let statusCode, _):
                guard statusCode == 401 else {
                    let error = APIError.fromStatus(statusCode)
                    lastError = error.errorDescription
                    return .revokeFailed(error)
                }
                MemosLog.session.info("POST /api/auth/native/logout -> 401, token already gone")
                let wiped = await wipeCredential()
                // Same await, same fence — see the 204 branch above.
                if owns(wiped) { lastError = signOutComplaint }
                return .alreadyRevoked
            }
        } catch {
            guard owns(issued) else { return .revokeFailed(.transport(description: "superseded")) }
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
        let wiped = await wipeCredential()
        // `wipeCredential` refuses its own tail when it was overtaken; the complaint it would
        // leave behind is one more write, and it belongs to the same operation.
        guard owns(wiped) else { return }
        lastError = signOutComplaint
    }

    /// The 401 rule, in one place: any feature that sees `.unauthorized` calls this.
    ///
    /// No revoke is attempted. A 401 is the server saying this token is already dead, so there is
    /// nothing to revoke and nothing to keep — this is not the failed-revoke case.
    public func handle(_ error: APIError) async {
        guard error == .unauthorized else { return }
        let wiped = await wipeCredential()
        guard owns(wiped) else { return }
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
    ///
    /// It is the IDENTITY-SETUP half of a sign-in, and it runs once per identity: at a sign-in, at
    /// a provisional admission, or when a check comes back naming somebody else. The confirmation
    /// of a credential the session was ALREADY using is `confirm`, which does none of this — see
    /// the note there for what re-running it would cost.
    ///
    /// It does not touch `verification`. Every caller says what its own answer means, and the one
    /// caller that admits before the server has spoken has to leave `.verifying` behind it.
    private func establish(
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
        endIncarnation()
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

    /// The server confirmed the credential the session was ALREADY running on, for the SAME
    /// account.
    ///
    /// Everything `establish` does besides naming the user is scoped to an identity CHANGE, and
    /// none of it belongs on a routine confirmation. Rotating the media identity empties the
    /// decoded-image cache; resetting `defaultVisibility` and `avatar` blanks the account's own
    /// settings until they are re-read; bumping the generation fences out every request the app
    /// has in flight. Once per revalidation — which is once per return to the foreground — that is
    /// a session that flickers back to placeholders every time the phone comes back on the wifi.
    private func confirm(_ user: User, of configuration: ServerConfiguration) {
        state = .signedIn(user)
        // Republished rather than assumed: the launch that admitted provisionally never published
        // one, and a licence is what the share extension enqueues against.
        account?.publish(
            AccountBinding(serverBaseURL: configuration.baseURL, ownerSubject: user.subject)
        )
        licenceRevocationFailed = false
    }

    /// The session is confirmed — and the outbox is told, exactly once per transition.
    ///
    /// The claim is made HERE, synchronously, rather than by whoever noticed the answer: a capture
    /// parked while the phone was off the network is drained by a handler that must run once, and
    /// two paths into `.verified` firing it twice is two drains of the same queue.
    private func enterVerified() {
        let wasUnconfirmed = verification != .verified
        verification = .verified
        retryInFlight?.cancel()
        retryInFlight = nil
        guard wasUnconfirmed, let onVerified else { return }
        // Called HERE, not from a task this method leaves behind. A deferred call runs after an
        // arbitrary amount of other work, including a sign-out — and it would then start a drain
        // for a session that no longer exists. The handler is synchronous for exactly that reason:
        // whatever it wants to do asynchronously, it starts itself and re-reads the authority
        // (`credentialGrant`) when it gets there.
        onVerified()
    }

    /// Whether the operation that started under `generation` still owns this session.
    ///
    /// One question, asked by every operation that spans an await, immediately before each effect
    /// it would have. A sign-in, a wipe, a renewal and a launch check are DIFFERENT operations
    /// from each other: nothing serialises them, so joining does not cover this and cannot. What
    /// covers it is that each of them refuses to write anything once the number it started under
    /// has moved.
    private func owns(_ generation: Int) -> Bool { generation == sessionGeneration }

    /// Ends the incarnation the session is in — synchronously, and BEFORE the caller's first
    /// await.
    ///
    /// The order is the whole of it. `wipeCredential` used to bump at its END, after awaiting the
    /// keychain, and `persist` left the bump to `adopt` after awaiting the write: a request that
    /// started inside either of those awaits found a live client belonging to a session that was
    /// already over. Bumped first, it finds no client at all, and every answer still on the wire
    /// is fenced out by a number that has already moved.
    private func endIncarnation() {
        sessionGeneration += 1
        sessionIncarnation.bump()
        // The authority epoch moves with it, where a reader outside this actor can see it without
        // hopping. It is a DIFFERENT number from the generation because it also moves on a
        // renewal, which replaces the token without ending the session (`SessionEpoch`).
        epoch.bump()
    }

    /// Everything scoped to the identity that is ending, removed at ONE boundary.
    ///
    /// Called from the three places an identity stops being this device's: a wipe, an account
    /// switch, and a launch that finds a licence with no credential behind it. It is deliberately
    /// the only such list — a second place to remember is how one of them ends up missing.
    private func invalidateIdentityScopedState() {
        supersedeValidationInFlight()
        forgetLastKnownUser()
    }

    /// Writes down who this device is signed in as, bound to the credential the server answered
    /// FOR.
    ///
    /// Never a value read back out of storage: the question this file answers is "is the token on
    /// this device the one this identity was confirmed with", and hashing a re-read copy answers
    /// "is storage self-consistent", which is not the same question and is true in exactly the
    /// case the check exists to catch.
    private func record(
        _ user: User,
        of configuration: ServerConfiguration,
        boundTo token: String
    ) {
        lastKnownUser?.write(
            LastKnownUser(
                user: user,
                serverBaseURL: configuration.baseURL,
                credentialFingerprint: CredentialFingerprint.of(token)
            )
        )
    }

    private func forgetLastKnownUser() {
        lastKnownUser?.delete()
    }

    /// A sign-in whose failure belongs to a session something else has already replaced.
    ///
    /// It writes NOTHING — not the state, not the sentence. Signing the current session out on the
    /// strength of an attempt a restore or another installation has superseded is the mixed state
    /// the whole fence exists to stop, and the sentence belongs on nobody's screen.
    @discardableResult
    private func supersededSignIn() -> Bool {
        MemosLog.session.info("a sign-in failed for a session that has been replaced")
        return false
    }

    private func failSignIn(_ error: NativeLoginError) {
        state = .signedOut
        client = nil
        credential = nil
        endIncarnation()
        supersedeValidationInFlight()
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
    /// How a sign-in's two writes went, and the incarnation they were made under.
    private struct Persistence {
        let outcome: CredentialPersistence
        /// The incarnation this installation withdrew the previous session into, taken
        /// SYNCHRONOUSLY before the write. Anything that moved it since is a wipe or another
        /// installation that landed inside the write, and this one must not be built on top of it.
        let installing: Int
    }

    private func persist(
        token: String, configuration: ServerConfiguration
    ) async -> Persistence {
        guard clearAccountLicence() else {
            // Nothing was withdrawn, so the incarnation is the one the caller is still in.
            return Persistence(outcome: .licenceNotRevoked, installing: sessionGeneration)
        }
        // INVALIDATE FIRST, before the write is awaited. A request that starts inside the keychain
        // await belongs to the account being replaced; finding no client is right, and finding the
        // previous one is how an answer about A lands in B's session. The last-known identity goes
        // with it: a process that dies inside the write must not leave A's file beside B's token.
        client = nil
        credential = nil
        endIncarnation()
        let installing = sessionGeneration
        invalidateIdentityScopedState()
        do {
            // ONE call. Two awaits are two critical sections with a gap between them, and this
            // method's own callers run in that gap: a 401 handled or a sign-out tapped between
            // the token landing and the address landing would wipe the token and leave the
            // address — a state nothing else produces and nothing repairs.
            try await credentials.setAll([
                Self.tokenAccount: token,
                Self.serverAccount: configuration.baseURL.absoluteString,
            ])
            // PROVEN: the vault writes and then reads back to verify, and a throw from either half
            // reaches the catch below. Only this branch may write the last-known identity.
            return Persistence(outcome: .stored, installing: installing)
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error(
                "the device credential could not be stored: \(detail, privacy: .public)"
            )
            return Persistence(outcome: .storedNowhere, installing: installing)
        }
    }

    /// Everything a sign-in that touched nothing has to put back, as ONE value.
    ///
    /// Restored piecemeal it is not a restore at all. `abandonSignIn` used to put `state` back and
    /// leave whatever else the attempt had installed, which is how a state belonging to one
    /// account could end up beside a credential belonging to another — the mixed grant the
    /// fingerprint exists to make impossible. Taken and put back as one value, no interleaving can
    /// express that.
    private struct SessionSnapshot {
        let state: SessionState
        let client: (any APIProtocol)?
        let credential: PresentedCredential?
        let configuration: ServerConfiguration?
        let verification: SessionVerification
    }

    private var snapshot: SessionSnapshot {
        SessionSnapshot(
            state: state,
            client: client,
            credential: credential,
            configuration: configuration,
            verification: verification
        )
    }

    /// Restored under a FRESH incarnation, never the one the snapshot was taken in.
    ///
    /// A sign-in attempt intervened between the two, and anything still in flight under the
    /// pre-attempt generation has been through that: it may have been issued with a client this
    /// method is now putting back, but it belongs to a session the attempt already interrupted.
    /// Today every reachable `previous.client` happens to be nil, so nothing is resurrected — but
    /// that is an accident of which paths reach here, not a property of this method, and the next
    /// path that reaches it with a live client would silently make it one.
    private func putBack(_ snapshot: SessionSnapshot) {
        endIncarnation()
        supersedeValidationInFlight()
        state = snapshot.state
        client = snapshot.client
        credential = snapshot.credential
        configuration = snapshot.configuration
        verification = snapshot.verification
        // Restoring the STATE is not restoring the lifecycle. The bump above is what stops a
        // pre-attempt answer becoming current again — and it is also what makes the check in
        // flight exit without doing anything, so a session put back as `.verifying` would sit
        // there with no task and no retry behind it. The same rule as a cancelled check: whatever
        // is not confirmed gets a replacement, immediately.
        guard verification != .verified, state.user != nil else { return }
        scheduleRetry(attempt: 0, delay: .zero)
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

    /// Puts the session back where the sign-in found it — all of it, in one step.
    private func abandonSignIn(restoring previous: SessionSnapshot) {
        putBack(previous)
        lastError = Self.licenceBlockedSignIn
        lastFailure = nil
    }

    /// What a sign-in says when one is already running.
    public static let signInAlreadyRunning =
        "A sign-in is already in progress on this device. "
        + "Wait for it to finish and try again."

    /// Forgets the credential — and revokes the share extension's licence FIRST.
    ///
    /// The order is the whole of the safety here. Licence then credential: a crash in between
    /// leaves a credential nobody is signed in with, which denies the extension. Credential then
    /// licence: a crash leaves a revoked identity that can still queue captures, and the person
    /// who signed out has no way of knowing.
    /// - Returns: the generation this wipe installed. Every sentence a caller writes AFTER it is
    ///   fenced on that number and on nothing else: the wipe bumps the generation itself, so the
    ///   caller's own starting generation can never match, and the `state.user == nil` escape that
    ///   used to stand in for it was wrong — a NEWER sign-in that failed leaves the user nil too,
    ///   and its failure is the sentence on the screen.
    @discardableResult
    private func wipeCredential() async -> Int {
        clearAccountLicence()
        // INVALIDATE FIRST, before the keychain delete is awaited — see `endIncarnation`. The
        // client goes here rather than at the end so that a request starting inside that await
        // finds nothing to send instead of a credential this method is in the middle of throwing
        // away.
        client = nil
        credential = nil
        endIncarnation()
        invalidateIdentityScopedState()
        // Nothing is owed an answer any more, and nothing is waiting to ask for one.
        verification = .verified
        persistenceProven = false
        retryInFlight?.cancel()
        retryInFlight = nil
        // Everything above this line is synchronous and belongs to the incarnation this method
        // just ended. Everything below it happens AFTER a keychain await, and a sign-in can
        // complete inside that await — so the tail asks whether the session it is about to clear
        // is still the one it set out to clear.
        let issued = sessionGeneration
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
            let detail = String(describing: error)
            MemosLog.session.error(
                "the stored credential would not delete: \(detail, privacy: .public)"
            )
            // The complaint belongs to the sign-out that made it. Left unfenced it would be read
            // out by the NEXT sign-out, about a credential that was never this one's.
            if owns(issued) { credentialWipeFailed = true }
        }
        // A sign-in landed inside the delete and owns the session now. Its client, its
        // configuration, its settings and its state are not this method's to clear — and
        // `identity.rotate()` below would empty the image cache it has just filled.
        guard owns(issued) else {
            MemosLog.session.info("a sign-out finished for a session already replaced")
            return issued
        }
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
        identity.rotate()
        // Whatever the last launch could not confirm, it was about a credential that is now gone.
        restoreFailure = nil
        state = .signedOut
        return issued
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
        }
        // The storage write above is an await, and a sign-out or a sign-in completing inside it
        // owns the session now. Swapping the credential then would hand a live session a token
        // minted for one that is over, and every effect below it would be written for the wrong
        // account. The successor is dropped instead — its predecessor is gone either way.
        guard owns(generation) else {
            MemosLog.session.info("a renewal finished for a session that has ended; it is dropped")
            return .failed
        }
        // AFTER the guard, not in the catch that set the flag. The write is an await, and a
        // sentence about a renewal this session did not make belongs on nobody else's screen —
        // the same rule the notice below it already followed.
        if storageRefused { lastError = Self.renewalStorageWarning }
        credential.replace(with: successor)
        // The token this device presents has MOVED, so every grant taken under the old one names a
        // credential the server has destroyed. The session itself carries on — that is the whole
        // point of `PresentedCredential` — so the incarnation does not move; only the authority
        // epoch does, which is what the outbox's next synchronous check reads.
        epoch.bump()
        // The last-known identity is bound to a credential, and the credential has just MOVED. A
        // file still naming the predecessor would fail the next launch's fingerprint check and
        // take the offline launch away from a device that did everything right — and a file
        // written after a persist that THREW would claim a binding the keychain may not hold. So
        // a proven persist rewrites it with the successor, and a refused one deletes it. The
        // generation is re-read here rather than trusted from before the storage await: a session
        // that ended inside it must not have a file written on its behalf.
        if storageRefused {
            forgetLastKnownUser()
            // The write threw, so nothing downstream may treat this device as holding a proven
            // credential again until one is proven (see `persistenceProven`).
            persistenceProven = false
        } else if let user = state.user, let configuration {
            persistenceProven = true
            record(user, of: configuration, boundTo: successor)
        }
        MemosLog.session.info("POST /api/auth/native/renew -> 200, the device swapped its token")
        // Read back rather than assembled from the renewal's answer: the successor is a new row
        // with its own dates, and inventing them here would put a `created_at` on the screen that
        // no server ever said.
        await loadDeviceToken()
        // AFTER the read, which clears the notice on success. `lastError` alone would not do:
        // the screen this renewal was started from draws the row and does not draw `lastError`,
        // so the warning would land nowhere the person pressing Renew can see it.
        if storageRefused, owns(generation) { deviceTokenNotice = Self.renewalStorageWarning }
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
            let wiped = await wipeCredential()
            if owns(wiped) { lastError = Self.renewalLostCredential }
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
        // Held rather than passed inline: after the send it is the only thing that knows which
        // credential went out, and that is what the refusal below has to be judged against.
        let authority = sendAuthority()
        do {
            let file = try await OriginalMedia.fetch(
                url: wanted.url,
                token: presented.token,
                uid: attachment.uid,
                mime: wanted.mime,
                server: server,
                transport: transport,
                into: directory,
                // Carried INTO the transport as well as fenced on both ways back here: an original
                // is the longest-lived request this app makes, and the send itself happens on
                // another executor where this actor's own check cannot reach.
                under: authority
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
            // The epoch that was SENT, not the one read before the send. A renewal landing in
            // between installs T1 and revokes T0; the transport correctly presents T1, and judging
            // its refusal by T0's epoch would report a rejection of the credential this device is
            // holding as an answer about one it had replaced — retaining a session the server has
            // just ended. `presented()` is nil only if nothing ever asked the authority, which no
            // production transport does; then the caller's own snapshot is the best it has.
            let sentEpoch = authority.presented()?.epoch ?? presented.epoch
            if error == .unauthorized, !credential.isCurrent(sentEpoch) {
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

    /// A store could not reach the server, reported by the incarnation that ISSUED the request.
    ///
    /// The fence is not decoration. A store's own guards are local attempt counters — they can say
    /// a later load has overtaken this one, and they cannot say whose session asked. A page issued
    /// under A that fails after B is verified would otherwise put B's confirmed session into
    /// `.unverified` and start a schedule for a failure that was never about it.
    ///
    /// A report that arrives while the session is ALREADY unconfirmed changes nothing: the
    /// schedule is running and the sentence on screen is as good as this one.
    public func noteTransportFailure(
        _ failure: NativeLoginTransportFailure,
        issuedUnder generation: Int
    ) {
        guard generation == sessionGeneration else {
            MemosLog.session.info("a transport failure from an ended session is not this one's")
            return
        }
        guard state.user != nil, verification == .verified, let configuration else { return }
        let host = configuration.baseURL.host() ?? configuration.baseURL.absoluteString
        verification = .unverified(SessionRestoreFailure(failure, host: host).message)
        scheduleRetry(attempt: 1)
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

/// The session as the reporting stores see it — see `SessionReporting`.
extension SessionStore: SessionReporting {}
