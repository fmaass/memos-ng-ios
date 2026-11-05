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

/// What the refusal rule decided about one refusal.
///
/// Returned rather than implied. A caller that must tell a superseded refusal from a rejected
/// session — `download` does, and the reporting stores do for the sentence they leave behind —
/// cannot re-derive it without re-deriving the epoch, which is the thing this design removes from
/// every site but the funnel.
public enum RefusalOutcome: Sendable, Equatable {
    /// The credential that earned it is the one this device holds. The session is over.
    case endedSession
    /// It named a credential this device has already replaced. Nothing happened.
    case superseded
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
    /// When this session stopped being confirmed — nil while it is.
    ///
    /// Written only by the one setter below, and only when it is nil, so it dates the OUTAGE
    /// rather than the last thing that noticed it: a ladder that fails four times in a row is one
    /// outage, and re-stamping it would keep the notice permanently `bannerDelay` away.
    public private(set) var unverifiedSince: Date?
    /// Whether the "can't reach the server" notice belongs on screen, as the store last decided it.
    ///
    /// It is a published answer rather than a question the view asks, because the question has a
    /// clock in it: nothing redraws when a second passes. The value is only ever
    /// `UnreachableNotice.shows(…)` taken at a moment the store can name — the instant a
    /// verification was written, or the instant a wake armed for this outage came due.
    public private(set) var showsUnreachableNotice = false
    /// Whether the server this session signed in to speaks an OLDER API major than the contract
    /// this build was generated from (`VendoredRelease.apiMajor`), as the sign-in handshake found.
    ///
    /// Raised only by `checkServerMajor`, and taken down by a sign-out's wipe and at the start of
    /// each sign-in — never by a revalidation, which confirms the credential and says nothing about
    /// the server's contract. It informs and never blocks: the session works as far as the older
    /// server lets it.
    public private(set) var showsOlderServerNotice = false
    /// The handshake the last sign-in launched, kept so a test can await its end: releasing the
    /// transport does not by itself prove the continuation that writes the notice has run.
    private(set) var serverMajorCheck: Task<Void, Never>?
    /// Moved by every withdrawal of the older-server notice (`withdrawOlderServerNotice`), and read
    /// by a handshake beside the session generation before it writes.
    ///
    /// The generation alone cannot fence the handshake: a sign-in only moves it once its credential
    /// is stored, so between an accepted sign-in's start and that point the PREVIOUS session's
    /// handshake still owns the generation, and its late answer would put back the notice the new
    /// sign-in has just taken down — for a server the new sign-in may not even be talking to.
    private var handshakeEpoch = 0
    /// How many times the screens have been asked to read again because the server came back.
    ///
    /// A number rather than a flag, because what a screen does with it is notice that it CHANGED:
    /// a screen that was showing whatever it had while the server was away reloads once per
    /// recovery, and nothing reloads on a first appearance. Two lines raise it, and each is one
    /// outage ending: a session that was owed a confirmation getting one (`enterVerified`), and a
    /// route regain delivered to a session that is owed none (`routeRegained`), which asks the
    /// server nothing because there is nothing worth asking. A confirmed session confirmed again
    /// is not a recovery, and a sign-out is not one either — it writes `.verified` through
    /// `setVerification` directly, past both of those lines.
    public private(set) var reachabilityRecoveries = 0
    /// How long the app stays quiet about an unconfirmed session before it says anything.
    ///
    /// A healthy launch and a brief drop-out both pass through `.unverified` in less than this, and
    /// a notice that appeared for either would be a flicker somebody has to read to dismiss.
    public static let bannerDelay = Duration.seconds(2)
    public private(set) var lastError: String? { didSet { sentenceWrites += 1 } }
    /// The same failure as a VALUE, beside the sentence `lastError` carries.
    ///
    /// A screen can act on one of these and only one — the Local Network denial, which has a
    /// switch behind it — and matching on a sentence to find out which failure it is would make
    /// the wording of an error message load-bearing.
    public private(set) var lastFailure: NativeLoginError? { didSet { sentenceWrites += 1 } }
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
    /// What `/api/uploads/limits` said for this session; nil until `loadUploadLimits` has an
    /// answer, and whatever is unknown refuses nothing.
    public private(set) var uploadLimits: UploadLimits?
    /// The generation `loadUploadLimits` has asked under, so a session asks once.
    @ObservationIgnored private var uploadLimitsAsked: Int?
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
    /// The capture grant's file beside that licence (MEMNG-938): the upload-only credential the
    /// share extension may present. Nil unless the app composes one, for the same reason.
    private let captureGrants: CaptureGrantStore?
    /// The mint in flight, with the authority epoch and the retirement count it was asked under.
    /// A second foreground under the same pair JOINS it — one request on the wire; under another
    /// pair it is replaced, and the old answer's own fence writes nothing.
    private var captureGrantMint: (epoch: Int, retirement: Int, task: Task<Void, Never>)?
    /// Moved by every retirement of the grant (`retireCaptureGrant`), so a mint that was on the
    /// wire across a sign-out writes nothing when it lands, even before the epoch has moved.
    private var captureGrantRetirements = 0
    /// The grant THIS process last wrote, with the authority epoch it was minted under: the only
    /// one a foreground may keep. A file from an earlier launch can name a grant the server has
    /// revoked — a renewal on an older build kept the file and lost the grant — and nothing on
    /// disk says so, so the first foreground of every launch mints.
    private var captureGrantKept: (epoch: Int, id: Int)?
    /// The session generations a sign-out is ending right now, one entry per sign-out in flight.
    /// While the current generation is listed, `mintCaptureGrant` REFUSES (it does not join): a
    /// mint started then would put a fresh grant on the server under a token that is being
    /// revoked, and a file beside a licence that is about to go.
    private var captureGrantRetiring: [Int] = []
    /// The clock the MEDIA layer fences its decoded-image cache against. Rotated at the same two
    /// sites as the account licence below, because it scopes to identity in exactly the same way:
    /// a decoded photo is filed under an attachment uid, and a uid means nothing across servers.
    /// Kept separate from `sessionGeneration` deliberately — that one fences this store's own
    /// in-flight replies, and merging the two would couple a media decision to a settings one.
    private let identity: MediaIdentity
    /// The timeline snapshots on this device — read by the timeline, removed only from here.
    ///
    /// This store owns their removal for one reason: it is the only object that knows when the
    /// answer to "whose device is this" changes, and a cached timeline that outlives its credential
    /// is somebody's memos left behind on a phone nobody is signed in to. It is `public` because
    /// the timeline writes through the SAME writer — one chain, or a removal and a write in flight
    /// could pass each other.
    ///
    /// BUILT here, over `epoch`, rather than handed in: the writer's only fence is that counter,
    /// and a writer constructed elsewhere could be given one this session never moves.
    ///
    /// Nil unless the app composes one, so a test never deletes out of the running app's cache.
    public let snapshots: TimelineSnapshotWriter?
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
    private(set) var sessionGeneration = 0
    /// The default-visibility PATCH and the token rename on the wire, each the one a second caller
    /// joins or is refused by (`setDefaultVisibility`, `renameDeviceToken`).
    @ObservationIgnored private var visibilityWrite: InFlightWrite<MemoVisibility>?
    @ObservationIgnored private var tokenRename: InFlightWrite<String>?
    /// The generation a client was last INSTALLED under. Moved by an establishment, and by
    /// nothing else — a withdrawal leaves it exactly where it was.
    ///
    /// `sessionGeneration` cannot answer the question an effect that resumes after a wipe has to
    /// ask. Its own sign-out moved that number, and so did a replacement that came and went, and
    /// "no client now" reads the same in both — yet only one of them means the screen the effect
    /// is about to write on has been through somebody else. Standing still across a withdrawal is
    /// the whole of the difference (`SessionReporting.nothingEstablishedSince`).
    private var establishedGeneration = 0
    /// The credential this process has put in front of the server since the incarnation began, if
    /// any. Its tasks are the ones a withdrawal has to reach: an earlier launch's belong to the
    /// stored account, which a launch that has presented nothing has not withdrawn.
    private var presentedGrant: PresentedCredential?
    /// The same number, in a box anything can read without hopping to this actor.
    ///
    /// It exists for the writers that commit from wherever their work finished. A hop to ask "is
    /// this session still the one I started under" is a suspension, and the suspension is exactly
    /// where the session can end.
    ///
    /// Assigned in `init` rather than here because the snapshot writer is built over this very
    /// box: one object, held by the session that moves it and by the writer that refuses by it.
    public nonisolated let epoch: SessionEpoch
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
    /// Readable so a test can wait for the flight that held a question to end, rather than for a
    /// number of turns it hopes is enough.
    private(set) var validationInFlight: Task<Void, Never>?
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
    /// Which rung of the ladder the schedule has reached, so a check asked for from OUTSIDE the
    /// schedule does not reset it.
    ///
    /// A store's success asks through the same slot the ladder uses, and it has to carry a rung
    /// number with it. Passing zero would make every applied page restart the ladder at three
    /// seconds — and the network that is flapping badly enough to produce those pages is exactly
    /// the one whose retries should be spreading out, not bunching up.
    private var ladderAttempt = 0
    /// Whether a SCENE has reported itself active. Retries only run then: a phone in a pocket
    /// asking every 45 seconds is a battery cost with nobody to read the answer, and a process the
    /// system woke to finish an upload has no scene at all — it must not start a ladder nobody
    /// will ever see the end of. False until a scene says otherwise, because a headless launch is
    /// the state this app is in more often than not.
    private var isForegrounded = false
    /// Which route outage has already had its reload ASKED FOR, by the ordinal the monitor counted
    /// that loss under.
    ///
    /// Written at the two places that ASK for the reload and nowhere else: beside the increment in
    /// `enterVerified`, inside `wasUnconfirmed`, and beside the increment in the branch
    /// `routeRegained` takes when NOTHING is awaiting confirmation. That second predicate is not
    /// "confirmed": a signed-out session awaits nothing either, and a regain delivered after a
    /// sign-out goes down the same branch — the screens are told, and the reload they perform
    /// finds no handle and returns without a request. Each sits on the line that raises
    /// `reachabilityRecoveries`, which is what entitles it to record that the outage has had its
    /// reload asked for. A confirmation that incremented nothing asked for no reload and cannot
    /// stand in for one, however successful it was: what is recorded is "the reload this outage
    /// owed has been requested", not "a validation succeeded".
    private var lossesSeenAtRecovery = 0
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
    /// The notice's debounce wait, on a seam of its OWN. Two kinds of wait, two seams: the retry
    /// ladder's record stays the ladder's, so a suite that asserts what the ladder scheduled is
    /// not reading a notice wake, and nothing has to tell them apart by length — a test that did
    /// that would break the day either constant moved.
    private let noticeSleeper: @Sendable (Duration) async throws -> Void
    /// What time it is, injected for the reason the sleeper is: the notice's rule is about how
    /// long something has been true, and a suite that really waited for it would pay the delay per
    /// case. The test moves this by hand and releases the wake itself.
    private let now: @Sendable () -> Date
    /// The wake that publishes the notice once the delay has run, or nil when none is waiting.
    private var noticeWake: Task<Void, Never>?
    /// Which outage the wakes belong to. Advanced when a session becomes confirmed — the outage is
    /// over, and anything still asleep on its account has nothing left to say.
    private var noticeWakeToken = 0
    /// What the wake in the slot was armed for, so a second assignment inside the same outage of
    /// the same session does not arm a duplicate beside it.
    private var noticeWakeArmedFor: (generation: Int, token: Int)?
    /// Where the identity a launch may open on is kept. Nil in a suite that is not about it, for
    /// the reason `account` is nil there: a test must never write into the real container.
    private let lastKnownUser: (any LastKnownUserStoring)?
    /// What to do the moment a session becomes confirmed — the app wires its outbox drain to it.
    ///
    /// It is a handler rather than something this store calls directly because the queue lives a
    /// layer above: a capture parked while the phone was off the network needs somebody to try
    /// again, and the only event that says trying is worth it is this one.
    private let onVerified: (@MainActor @Sendable () -> Void)?
    /// What to do the moment an account's grant is withdrawn — a wipe, or another account signing
    /// in over it — with the authority epoch that withdrawal moved to. The app wires the outbox's
    /// cancellation of the background uploads still presenting the old credential to it: whatever
    /// must happen at the epoch move happens in the call, and the cancellation it starts is handed
    /// back, so a sign-out can wait for it before it says it is done. It is called while the
    /// outgoing handle is still installed beside the new generation (`endIncarnation`), so it must
    /// not read `api` or `activeHandle` or take a fresh `sendAuthority()`.
    private let onAccountWithdrawn: (@MainActor @Sendable (Int) -> Task<Void, Never>?)?
    /// Where a diagnostic line goes, injected the same way the sleeper is.
    ///
    /// It exists so the log BOUNDARY can be watched rather than re-derived. A guardrail that
    /// re-computes what the store ought to have written proves only that the test agrees with
    /// itself: a line that interpolated the error's own text here would leave it green, and the
    /// error's own text is precisely what may not be written.
    private let diagnostics: @Sendable (String) -> Void
    /// Where "the route came back" arrives from, and where the loss count a check is issued under
    /// is read synchronously. Nil in a process that has no route to recover — a suite, and the
    /// share extension.
    private let routes: (any RouteStatusMonitoring)?

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
        noticeSleeper: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        account: (any OutboxAccountPublishing)? = nil,
        captureGrants: CaptureGrantStore? = nil,
        identity: MediaIdentity = .shared,
        lastKnownUser: (any LastKnownUserStoring)? = nil,
        // The DIRECTORY, not a writer over it. The writer is built below, against this
        // store's own epoch, so nothing can hand it a counter this session does not move.
        snapshots: TimelineSnapshotStore? = nil,
        routes: (any RouteStatusMonitoring)? = nil,
        onVerified: (@MainActor @Sendable () -> Void)? = nil,
        onAccountWithdrawn: (@MainActor @Sendable (Int) -> Task<Void, Never>?)? = nil,
        // Optional rather than defaulted to a closure: an `OSLogMessage` interpolation cannot be
        // built in a default argument value (`os` is imported by `MemosLog`, not by this file),
        // and a named default would have to be public to be referenced from one.
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        // ONE box, named before it is stored, because the writer below is built over it and
        // `self.epoch` cannot be read until every property is in place.
        let epoch = SessionEpoch()
        self.epoch = epoch
        self.snapshots = snapshots.map { TimelineSnapshotWriter(store: $0, epoch: epoch) }
        self.credentials = credentials
        self.makeClient = makeClient
        self.sleeper = sleeper
        self.noticeSleeper = noticeSleeper
        self.now = now
        self.account = account
        self.captureGrants = captureGrants
        self.identity = identity
        self.lastKnownUser = lastKnownUser
        self.onVerified = onVerified
        self.onAccountWithdrawn = onAccountWithdrawn
        self.diagnostics =
            diagnostics ?? { line in MemosLog.session.error("\(line, privacy: .public)") }
        self.routes = routes
        guard let routes else { return }
        // ONE consuming task, so regains reach the rule in the order the monitor's callback saw
        // them. A task per callback orders nothing — which is the right shape for a decision that
        // does not care, and the wrong one here.
        Task { @MainActor [weak self] in
            for await regain in routes.regains {
                guard let self else { return }
                await self.routeRegained(regain)
            }
        }
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
            epoch: epoch.current,
            uploadLimit: uploadLimits?.maxBytes
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

        // FIRST, before anything that writes: a call refused as busy changes nothing but its
        // sentence, so the running sign-in's session and generation are exactly as it left them.
        guard !signingIn else {
            lastError = Self.signInAlreadyRunning
            return false
        }
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

        signingIn = true
        defer { signingIn = false }

        let previous = snapshot
        state = .signingIn
        lastError = nil
        lastFailure = nil
        withdrawOlderServerNotice()
        // Taken before the browser leg, which is the longest await in the app: a sign-out or
        // another installation completing inside it owns the session by the time the code comes
        // back. See the pasted leg for why `persist`'s own generation cannot answer this.
        let issued = sessionGeneration
        let establishedAtStart = establishedGeneration
        let sentencesAtStart = sentenceMark
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
                return overtakenSignIn(
                    nil, establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
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
            let established = makeClient(configuration, credential)
            establish(
                client: established,
                configuration: configuration,
                user: exchanged.user,
                credential: credential
            )
            // AFTER `establish`, which moved the generation: see `checkServerMajor`.
            checkServerMajor(client: established, issuedUnder: sessionGeneration)
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
            guard owns(issued) else {
                return overtakenSignIn(
                    .alreadySigningIn, establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
            }
            // A second tap on a sign-in that is already on screen. The state this method set on
            // its way in is put back rather than torn down: the FIRST attempt is still running,
            // still showing its browser view, and `failSignIn` here would sign its screen out
            // from under it and leave an error notice on a sign-in that then succeeds.
            abandonSignIn(restoring: previous)
            return false
        } catch let error as NativeLoginError {
            guard owns(issued) else {
                return overtakenSignIn(
                    error, establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
            }
            failSignIn(error)
            return false
        } catch {
            guard owns(issued) else {
                return overtakenSignIn(
                    .transport(NativeLoginTransportFailure.classify(error)),
                    establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
            }
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
        // FIRST, before anything that writes: a call refused as busy changes nothing but its
        // sentence, so the running sign-in's session and generation are exactly as it left them.
        guard !signingIn else {
            lastError = Self.signInAlreadyRunning
            return
        }
        guard let configuration = ServerConfiguration(serverAddress: serverAddress) else {
            lastError = "That does not look like an https server address."
            return
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Paste the access token from the memos web app."
            return
        }

        signingIn = true
        defer { signingIn = false }

        let previous = snapshot
        state = .signingIn
        lastError = nil
        lastFailure = nil
        withdrawOlderServerNotice()
        let credential = PresentedCredential(trimmed)
        let client = makeClient(configuration, credential)
        // Taken BEFORE the first await. `persist` mints a generation of its own, so checking only
        // that one asks whether the sign-in still owns the session it just took over — which it
        // trivially does. The question that matters is whether it still owned the session it
        // STARTED in, and a sign-out completing while `whoami` was on the wire is exactly the
        // answer no.
        let issued = sessionGeneration
        // Which establishment the session was in when this sign-in started — see `overtakenSignIn`.
        let establishedAtStart = establishedGeneration
        let sentencesAtStart = sentenceMark
        do {
            let user = try await Self.whoami(client)
            guard owns(issued) else {
                MemosLog.session.info("a sign-in was overtaken before its credential was stored")
                overtakenSignIn(
                    nil, establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
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
                // AFTER `establish`, which moved the generation: see `checkServerMajor`.
                checkServerMajor(client: client, issuedUnder: sessionGeneration)
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
                // AFTER `establish`, which moved the generation: see `checkServerMajor`.
                checkServerMajor(client: client, issuedUnder: sessionGeneration)
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
                overtakenSignIn(
                    .api(error), establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
                return
            }
            // The server answered and refused. Its sentence is built from a status code and
            // nothing the request carried.
            failSignIn(.api(error))
        } catch {
            guard owns(issued) else {
                overtakenSignIn(
                    .transport(NativeLoginTransportFailure.classify(error)),
                    establishedAtStart: establishedAtStart,
                    sentencesAtStart: sentencesAtStart
                )
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

    /// The launch question asked again for a session a refused sign-in put back while it was
    /// still waiting on it. The sentence on screen is the sign-in's, so this ask leaves it.
    private func restoreAfterRefusedSignIn(expecting generation: Int) async {
        await validating { [self] in
            // A hop through the injected clock, INSIDE the flight and before the question, so a
            // test can hold the gap between taking the slot and asking open and finish a sign-in
            // in it. A clock that throws ends the wait, not the question.
            try? await sleeper(.zero)
            // Asked HERE, inside the flight, with nothing awaited between it and the generation
            // `performRestore` takes: the task that scheduled this is hops behind, and a sign-in
            // that ended in between owns whatever this would otherwise re-admit.
            guard generation == sessionGeneration else { return }
            await performRestore(recovering: true)
        }
    }

    /// Asks the server about the credential the session is already holding.
    ///
    /// The re-validation half of the lifecycle: the foreground trigger and the retry schedule both
    /// come through here, and both join whatever is already in flight rather than sending a second
    /// question.
    private func revalidate(attempt: Int, expecting generation: Int? = nil) async {
        await validating { [self] in
            // This body runs inside a task of `validating`'s own, so the client and the credential
            // it is about to read are whatever the session holds NOW — not what it held when the
            // check was asked for. A caller that knows which incarnation earned its request says
            // so, and the comparison happens HERE, with nothing awaited between it and the read,
            // because that read is the instant it is about.
            if let generation, generation != sessionGeneration { return }
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

    private func performRestore(recovering: Bool = false) async {
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
            // A launch reads before it announces anything, so its failure is still `.signedOut`.
            // A recovery starts in `.signingIn`, the one state the sign-in screen will not act in,
            // so it lands where that launch does.
            if recovering { state = .signedOut }
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
            // No credential: whatever licence is lying about belongs to nobody, and neither does
            // any timeline left on the disk. This is also the retry for a revocation — or a
            // removal — that failed during sign-out.
            clearAccountLicence()
            // And whatever identity is lying about has no token behind it. The keychain item is
            // `ThisDeviceOnly`, so a device restore lands here with a file and nothing to bind it
            // to — the orphan this branch exists to reconcile. And a timeline cached under a
            // credential that is not there is the same orphan, one file over.
            await invalidateIdentityScopedState()
            return
        }
        let storedToken = stored.token
        // A licence naming a different server than the stored credential is what an interrupted
        // account switch leaves behind. Deny first; the admission below republishes, and so does
        // the confirmation. The subject cannot be checked here — that is what the server is for.
        if let published = account?.current(), published.serverBaseURL != configuration.baseURL {
            clearAccountLicence()
            // The same interrupted switch that left the licence behind left a timeline behind.
            await snapshots?.removeAll()
            // And that removal is an await: a sign-out or a sign-in landing inside it owns the
            // session now, and admitting this stored credential below would install a session
            // nobody asked for on top of theirs.
            guard owns(issued) else {
                MemosLog.session.info("a launch check was overtaken while it cleared a timeline")
                return
            }
        }

        if !recovering { lastError = nil }
        restoreFailure = nil
        let credential = PresentedCredential(storedToken)
        // It came OUT of the keychain, so it is this device's before anything asks the server:
        // a launch whose stored credential is genuinely refused MUST end the session, and only an
        // installed credential's refusal carries the epoch that decides. True on both branches
        // below, the provisional admission and `.signingIn`.
        credential.install()
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
            setVerification(.verifying)
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
        // The route as it was when this question was ASKED, read with nothing awaited around it. A
        // loss counted while this is on the wire belongs to the outage AFTER the one this answer
        // can close, and recording it at the answer would silence that outage's own regain.
        let issuedAtLosses = lossesSeen()
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
            // A sign-in has taken the session over without ending it: it moves the generation only
            // once it stores, puts back or fails, so the fence above still passes. Adopted here, an
            // answer about the credential it is replacing reads `.signingIn`'s missing user as a
            // different account, installs that credential and moves the generation out from under
            // the sign-in, which then returns without a word — a refused switch whose sentence is
            // never written. Whatever the sign-in ends in replaces this session, signs it out, or
            // puts it back and asks again.
            guard !signingIn else {
                MemosLog.session.info("GET /api/auth/user answered while a sign-in held it")
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
            enterVerified(confirming: issuedAtLosses)
        } catch let error as APIError {
            // The server answered and refused. Its own sentence is built from a status code and
            // nothing the request carried, so it is the better one. It is never terminal: a
            // reachable server that is unwell is not a revoked token. A refusal cannot arrive
            // here — the middleware throws it as a value of its own, inside the generated client's
            // envelope — so this arm no longer has to say so.
            guard generation == sessionGeneration else { return }
            unconfirmed(.server(error), admitted: admitted, attempt: attempt)
        } catch {
            guard generation == sessionGeneration else { return }
            // The rule spelled out here rather than routed through `handle`, and this is one of
            // exactly two places that is true: a discarded check has to reach `discard`, which is
            // what schedules the replacement, and the sentence a wipe leaves behind is this call's
            // own. The PREDICATE is the shared one; only the call is local.
            if let refusal = StoreFailure.refusal(error) {
                guard refusal.concernsCurrentCredential(of: credential) else {
                    MemosLog.session.info("a check answered for a credential this device replaced")
                    // Neither outcome. The state stands, the attempt is not counted, and a
                    // replacement goes out at once.
                    discard(error, admitted: admitted, attempt: attempt, host: host)
                    return
                }
                let wiped = await wipeCredential()
                // The wipe is an await of its own, and its tail refuses when something overtook
                // it. The sentence it leaves behind is one more write and follows the same rule —
                // judged against the generation the WIPE installed, because that is the only
                // number that can still be current when nothing overtook it.
                if owns(wiped) { sayRefused(refusal) }
                return
            }
            // Neither outcome. A cancellation is this app's own doing — a suspension, a screen
            // going away. The state stands, the attempt is not counted, and a replacement goes out
            // at once rather than waiting for whatever trigger comes next. The chain cannot spin:
            // what cancels a check is the app leaving the foreground, and `scheduleRetry` runs
            // nowhere else.
            if StoreFailure.isCancellation(error) {
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
        setVerification(.unverified(failure.message))
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
        // Recorded whatever the guards below decide: the rung is a property of the schedule this
        // session has climbed to, not of whether there is a scene in front of it to climb further.
        ladderAttempt = attempt
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
        if awaitingConfirmation { await revalidate(attempt: 0) }
        // After the check, so a foreground that ended the session mints nothing for it.
        await mintCaptureGrant()
    }

    // MARK: - the capture grant (MEMNG-938)

    /// Mints the share extension's capture grant with the device token and leaves it beside the
    /// licence, stamped with the licence issue it was asked under. Only when the grant on file is
    /// not this issue's and binding's, or has less than `PublishedCaptureGrant.remintBelow` left:
    /// the server ROTATES on every mint, revoking the grant before it, so a foreground that minted
    /// regardless would cut off an extension upload still running under that grant (MEMNG-1083).
    ///
    /// SINGLE-FLIGHT per authority: overlapping calls under the same epoch join the one request.
    /// The answer is judged against what ISSUED it — the authority epoch (a renewal destroys the
    /// token a grant dies with), the retirement count (a sign-out under way) and the licence on
    /// disk — synchronously, with nothing awaited between that judgement and the write.
    public func mintCaptureGrant() async {
        await mintCaptureGrant(keepingAFreshGrant: true)
    }

    /// `keepingAFreshGrant: false` is the renewal's: the grant on file died with the token it
    /// replaced, however much time the file says it has left.
    private func mintCaptureGrant(keepingAFreshGrant: Bool) async {
        guard let captureGrants, let client, let configuration, let user = state.user,
            let licence = account?.currentLicence(), let issue = licence.incarnation,
            licence.binding
                == AccountBinding(serverBaseURL: configuration.baseURL, ownerSubject: user.subject)
        else { return }
        guard !captureGrantRetiring.contains(sessionGeneration) else {
            MemosLog.session.info("no capture grant while this session is signing out")
            return
        }
        if keepingAFreshGrant, let kept = captureGrantKept, kept.epoch == epoch.current,
            let standing = captureGrants.current(), standing.id == kept.id,
            standing.incarnation == issue, standing.binding == licence.binding,
            standing.expiresAt.timeIntervalSince(now()) > PublishedCaptureGrant.remintBelow
        {
            return
        }
        let issued = epoch.current
        let generation = sessionGeneration
        let retirement = captureGrantRetirements
        if let flight = captureGrantMint, flight.epoch == issued, flight.retirement == retirement {
            return await flight.task.value
        }
        let task = Task { @MainActor [self] in
            await performCaptureGrantMint(
                client: client, into: captureGrants, licence: licence, issue: issue,
                issued: issued, retirement: retirement, generation: generation)
        }
        captureGrantMint = (issued, retirement, task)
        await task.value
        // Only the flight that owns the slot clears it: a replaced one finishing later must not
        // drop its successor's handle.
        if captureGrantMint?.task == task { captureGrantMint = nil }
    }

    private func performCaptureGrantMint(
        client: any APIProtocol, into grants: CaptureGrantStore, licence: PublishedLicence,
        issue: UUID, issued: Int, retirement: Int, generation: Int
    ) async {
        do {
            let response = try await client.mintCaptureGrantApiTokensCaptureGrantPost(.init())
            guard case .created(let created) = response else {
                MemosLog.session.info("POST /api/tokens/capture-grant answered without a grant")
                return
            }
            let minted = try created.body.json
            guard epoch.current == issued, captureGrantRetirements == retirement,
                account?.currentLicence() == licence
            else {
                MemosLog.session.info("a capture grant answered for an authority that has moved")
                return
            }
            try grants.write(
                PublishedCaptureGrant(
                    id: minted.id, token: minted.token, expiresAt: minted.expiresAt,
                    binding: licence.binding, incarnation: issue))
            captureGrantKept = (issued, minted.id)
        } catch {
            if let refusal = StoreFailure.refusal(error) {
                // A session that ended while the mint was out is not the one to judge it against:
                // a new sign-in's credential counts its generations from the start again, so the
                // epoch alone would take A's refusal for B's. The same guard as every other read.
                guard owns(generation) else { return }
                // The device token itself was turned down: the same rule as every other read,
                // judged against the credential that earned it.
                await handle(refusal)
                return
            }
            let detail = String(describing: error)
            MemosLog.session.info("no capture grant this time: \(detail, privacy: .public)")
        }
    }

    /// Ends the capture grant with the session, synchronously: any mint in flight is fenced out
    /// and the file is gone before this returns. Hands back the grant's id for the revoke, which
    /// the caller sends with the token that minted it.
    private func retireCaptureGrant() -> Int? {
        guard let captureGrants else { return nil }
        captureGrantRetirements += 1
        captureGrantMint = nil
        let standing = captureGrants.current()
        // A failure here is retried by the licence's own revocation, which removes the grant
        // first and remembers when it could not (`clearAccountLicence`).
        try? captureGrants.clear()
        return standing?.id
    }

    /// DELETE /api/tokens/capture-grant/{id}, best effort. The grant dies with its token on the
    /// server anyway, so nothing here decides anything: whatever the token's fate is, the request
    /// that follows (the sign-out's own revoke) is the one that settles it.
    private static func revokeCaptureGrant(_ id: Int, with client: any APIProtocol) async {
        do {
            _ = try await client.revokeCaptureGrantApiTokensCaptureGrantGrantIdDelete(
                .init(path: .init(grantId: id)))
        } catch {
            MemosLog.session.info("the capture grant revoke did not go through")
        }
    }

    /// Somebody asked for the check now — the notice's own button, and the only trigger a reader
    /// owns.
    ///
    /// What is cancelled is the WAIT, never a check: a ladder asleep on a 45-second rung has
    /// nobody to answer to while somebody is looking at the screen, so the schedule starts again
    /// from its first rung. A check already in the air is a different thing — two taps over one
    /// flight JOIN it through `validating` and are both told what it said, because the answer they
    /// are waiting for is already on its way.
    ///
    /// The attempt is 0 where that can be observed and is whatever the joined flight carried where
    /// it cannot: a join never runs this body, and a check in flight owns the rung it was asked
    /// under.
    public func retryNow() async {
        retryInFlight?.cancel()
        retryInFlight = nil
        await revalidate(attempt: 0)
    }

    /// The route-loss count as it stands NOW, with nothing awaited around the read — the ordinal a
    /// check is ISSUED under.
    private func lossesSeen() -> Int { routes?.lossesSeen() ?? 0 }

    /// A route came back, and the one rule that says what that means — asked on the actor that
    /// performs the effect, with nothing awaited between the question and the write.
    ///
    /// What associates this regain with the recovery it belongs to is the ORDINAL it carries,
    /// taken under the monitor's lock at the callback, against `lossesSeenAtRecovery`. Delivery
    /// order enters nothing: a verification already in flight can confirm — counter moved, screens
    /// reloaded — before this runs, and the loss itself can be delivered later still, so a rule
    /// that read the session's current state alone would count a second recovery for an outage
    /// that has already had one.
    ///
    /// The one window it leaves: a check issued BEFORE a loss whose answer still arrives counts as
    /// a recovery from an outage it predates, and the regain then reloads once more. One extra
    /// read, never a lost one.
    func routeRegained(_ regain: RouteRegain) async {
        guard regain.lossOrdinal > lossesSeenAtRecovery else { return }
        guard awaitingConfirmation else {
            // Nothing is owed an answer, so there is no question worth sending: the screens are
            // told directly, exactly as a confirmation tells them.
            reachabilityRecoveries += 1
            lossesSeenAtRecovery = regain.lossOrdinal
            return
        }
        // What is cancelled is the WAIT and never a check in flight, which `revalidate` joins —
        // the same thing the notice's own button does. The confirmation that check earns records
        // the ordinal it was issued under, so this outage's reload is asked for exactly once.
        retryInFlight?.cancel()
        retryInFlight = nil
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
        // Withdrawing the client withdraws the authority with it, so anything holding a grant
        // taken under it stops at its next synchronous check. The authority goes FIRST, before
        // the handle: a sender off the main actor checks the incarnation, never the handle.
        endIncarnation()
        client = nil
        credential = nil
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
            _ = retireCaptureGrant()
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
        // The generation is taken BEFORE the first await (the grant's revoke below), so every
        // effect after it is judged against the session this sign-out set out to end.
        let issued = sessionGeneration
        // Retiring from here to the end: no new mint may start for this session meanwhile.
        captureGrantRetiring.append(issued)
        defer {
            if let index = captureGrantRetiring.firstIndex(of: issued) {
                captureGrantRetiring.remove(at: index)
            }
        }
        // The capture grant goes FIRST, while the token that minted it can still revoke it.
        if let grant = retireCaptureGrant() { await Self.revokeCaptureGrant(grant, with: client) }
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
            // Documented since v2.1.0; answered exactly as its `.undocumented(503)` was.
            case .serviceUnavailable:
                let error = APIError.fromStatus(503)
                lastError = error.errorDescription
                return .revokeFailed(error)
            case .undocumented(let statusCode, _):
                // A refusal no longer arrives here: the middleware throws it, and the catch below
                // is where "the token was already gone" is told apart from "the token this revoke
                // named was replaced while it was on the wire". Everything else is a server that
                // failed to revoke, and the credential stays exactly where it is.
                let error = APIError.fromStatus(statusCode)
                lastError = error.errorDescription
                return .revokeFailed(error)
            }
        } catch {
            guard owns(issued) else { return .revokeFailed(.transport(description: "superseded")) }
            if let refusal = StoreFailure.refusal(error) {
                guard refusal.concernsCurrentCredential(of: credential) else {
                    // The token this revoke named was replaced while it was on the wire. The
                    // SUCCESSOR is live and has NOT been revoked, so wiping now would leave a
                    // working token in whatever holds it while this device shows a sign-in
                    // screen — precisely the state `revokeFailed` exists to prevent. The
                    // credential is kept and the screen offers the sign-out again, which then
                    // revokes the token this device is actually holding.
                    lastError = refusal.errorDescription
                    return .revokeFailed(.unauthorized)
                }
                MemosLog.session.info("the revoke was refused: this token was already gone")
                let wiped = await wipeCredential()
                // The `owns(issued)` above fenced the ANSWER; this fences the SENTENCE — see the
                // 204 branch.
                if owns(wiped) { lastError = signOutComplaint }
                return .alreadyRevoked
            }
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

    /// The refusal rule, in one place: any feature that meets one calls this.
    ///
    /// No revoke is attempted. A 401 is the server saying this token is already dead, so there is
    /// nothing to revoke and nothing to keep — this is not the failed-revoke case.
    ///
    /// The answer is RETURNED rather than implied. A caller that has to tell a superseded refusal
    /// from a rejected session — `download` does, and the reporting stores do for the sentence
    /// they leave behind — cannot re-derive it without re-deriving the epoch, which is the thing
    /// this rule exists to remove from every call site but this one.
    @discardableResult
    public func handle(_ refusal: CredentialRefusal) async -> RefusalOutcome {
        // SYNCHRONOUSLY, before the first await: the answer has to be about the credential this
        // device holds at the instant the wipe STARTS, not at the instant the answer arrived.
        guard refusal.concernsCurrentCredential(of: credential) else {
            MemosLog.session.info("a refusal of a credential this device replaced does not end it")
            return .superseded
        }
        let wiped = await wipeCredential()
        // The refusal keeps the headline: a dead token is what the person needs to hear. A wipe
        // that also failed is on the log and in `credentialWipeFailed`, and the next sign-out or
        // restore says so.
        if owns(wiped) { sayRefused(refusal) }
        return .endedSession
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
        // The incarnation this replaces ends FIRST, before its handle is replaced: a sender off the
        // main actor checks the incarnation, never the handle.
        endIncarnation()
        presentedGrant = credential
        self.configuration = configuration
        self.client = client
        // The one place a session ADOPTS a credential — the native sign-in, and the pasted one
        // after it succeeded. From here a renewal can move it, which is what makes its refusals
        // ambiguous about which token they name.
        credential.install()
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
        uploadLimits = nil
        // AFTER the bump, so it names the incarnation the client above is handed out under:
        // this is one of the two places a non-nil client is installed, and therefore one of the
        // two that may move it.
        establishedGeneration = sessionGeneration
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

    /// The one place `verification` is written.
    ///
    /// Everything the notice needs to know follows from a verification being ASSIGNED, so it is
    /// decided here rather than at the six places that assign one: whoami's own failure, a
    /// provisional admission, a store's report, a restored snapshot, a wipe and a confirmation
    /// each become "the session is unconfirmed as of now" without any of them having to remember
    /// to stamp a clock or to take a notice down. That is also what makes the offline launch raise
    /// the notice with no store involved at all.
    private func setVerification(_ value: SessionVerification) {
        verification = value
        guard value != .verified else {
            // The outage is over: nothing dates it, nothing shows for it, and anything still
            // asleep on its account belongs to a token this session has moved past.
            unverifiedSince = nil
            showsUnreachableNotice = false
            noticeWake?.cancel()
            noticeWake = nil
            noticeWakeArmedFor = nil
            noticeWakeToken += 1
            return
        }
        // The rule is about the value ASSIGNED, not about leaving `.verified`: a ladder that fails
        // four times running writes `.unverified` four times, and all four are the same outage. So
        // the stamp is taken only where there is none.
        if unverifiedSince == nil { unverifiedSince = now() }
        reconcileNoticeWake()
    }

    /// Brings the notice, and the wake that would raise it, into line with what is true now.
    ///
    /// Called from the setter alone, synchronously with the assignment, so there is no instant at
    /// which the state and the notice disagree about the same outage.
    private func reconcileNoticeWake() {
        if UnreachableNotice.shows(
            verification, unverifiedSince: unverifiedSince, now: now(), after: Self.bannerDelay)
        {
            // The launch that took six seconds to fail: the delay is already behind us, and
            // waiting another `bannerDelay` to say so would be a second silence nobody asked for.
            showsUnreachableNotice = true
            return
        }
        guard case .unverified = verification, let since = unverifiedSince else { return }
        // A wake armed under an EARLIER generation does not count: `putBack` bumps the generation
        // before it restores, so a snapshot restored over the same outage replaces a wake that can
        // no longer publish with one that can, and keeps the stamp — it is the same outage.
        if let armed = noticeWakeArmedFor,
            armed.generation == sessionGeneration, armed.token == noticeWakeToken
        {
            return
        }
        let elapsed = now().timeIntervalSince(since)
        armNoticeWake(after: .seconds(max(0, Self.bannerDelay.seconds - elapsed)))
    }

    /// Puts the notice on the clock for what is left of the delay.
    private func armNoticeWake(after remaining: Duration) {
        let token = noticeWakeToken
        let generation = sessionGeneration
        noticeWake?.cancel()
        noticeWakeArmedFor = (generation: generation, token: token)
        noticeWake = Task { @MainActor [self] in
            // FIRST in the body, so it runs on every exit — the three early returns below
            // included, a cancelled wake's among them — and it compares what it owns before
            // clearing, the rule `validating` uses for the same hazard: only the wake that holds
            // the slot may drop its handle, or a late one takes its replacement's with it.
            defer {
                if noticeWakeArmedFor?.generation == generation,
                    noticeWakeArmedFor?.token == token
                {
                    noticeWake = nil
                    noticeWakeArmedFor = nil
                }
            }
            try? await noticeSleeper(remaining)
            guard !Task.isCancelled else { return }
            // The outage this was armed for, and the session it was armed for. Either can be over
            // by now, and a wake is not evidence about anything but the moment it was armed in.
            guard token == noticeWakeToken, generation == sessionGeneration else { return }
            // Asked of the PRESENT rather than asserted from the past: whatever was true when this
            // was armed, what goes on screen is what is true now.
            showsUnreachableNotice = UnreachableNotice.shows(
                verification, unverifiedSince: unverifiedSince, now: now(),
                after: Self.bannerDelay)
        }
    }

    /// The session is confirmed — and the outbox is told, exactly once per transition.
    ///
    /// `losses` is the route-loss count the check that earned this confirmation was ISSUED under.
    /// A sign-in carries none: it is not a recovery from an outage, so a regain that is still owed
    /// a reload gets one.
    ///
    /// The claim is made HERE, synchronously, rather than by whoever noticed the answer: a capture
    /// parked while the phone was off the network is drained by a handler that must run once, and
    /// two paths into `.verified` firing it twice is two drains of the same queue.
    private func enterVerified(confirming losses: Int = 0) {
        let wasUnconfirmed = verification != .verified
        // Counted HERE rather than under the guard below, because that guard also wants an
        // `onVerified` handler and most sessions have none — and the screens' reason to reload is
        // the transition itself, whoever is or is not listening for the drain.
        if wasUnconfirmed {
            reachabilityRecoveries += 1
            // Beside the increment and nowhere else: THIS is the line that asks the screens to
            // read again, so this is the line entitled to say that the outage the check was issued
            // under has had its reload asked for.
            lossesSeenAtRecovery = losses
        }
        setVerification(.verified)
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

    /// Whether this device has established a session since the one `generation` names.
    ///
    /// Deliberately not `owns`. `owns` asks whether the session is still the same one, which a
    /// withdrawal answers no — and an effect that awaited the refusal rule has just CAUSED that
    /// withdrawal, so asking it there would silence every ordinary refusal there is. What has to
    /// silence one is an establishment in between, and that is a different number
    /// (`establishedGeneration`).
    private func nothingEstablishedSince(_ generation: Int) -> Bool {
        generation == establishedGeneration
    }

    /// Ends the incarnation the session is in — synchronously, and BEFORE the caller's first
    /// await.
    ///
    /// The order is the whole of it. `wipeCredential` used to bump at its END, after awaiting the
    /// keychain, and `persist` left the bump to `adopt` after awaiting the write: a request that
    /// started inside either of those awaits found a live client belonging to a session that was
    /// already over. Bumped first, it finds no client at all, and every answer still on the wire
    /// is fenced out by a number that has already moved.
    ///
    /// It is also the one place the outbox hears that a grant is withdrawn, at the epoch it moved
    /// to and before the caller's first await: a background task keeps its bearer header until it
    /// is cancelled. It hears it when the stored account itself is going (`withdrawingAccount`),
    /// and whenever a credential this process presented stops being the one presented — a failed
    /// replacement sign-in, a restore over a grant held only in memory — unless the caller puts
    /// that same credential back (`keeping`).
    ///
    /// Every site that ends an identity calls it BEFORE it clears or replaces the handle
    /// (`scripts/incarnation-order-rule.sh` holds that order): a sender off the main actor checks
    /// the incarnation, never `client`, so its boundary closes at the bump. The cost is that the
    /// withdrawal callback runs while the outgoing handle is still installed beside the NEW
    /// generation, so it must not read `api` or `activeHandle` — the one the app passes reads
    /// neither.
    @discardableResult
    private func endIncarnation(
        withdrawingAccount: Bool = false, keeping kept: PresentedCredential? = nil
    ) -> Task<Void, Never>? {
        let outgoing = presentedGrant
        presentedGrant = nil
        sessionGeneration += 1
        sessionIncarnation.bump()
        // The authority epoch moves with it, where a reader outside this actor can see it without
        // hopping. It is a DIFFERENT number from the generation because it also moves on a
        // renewal, which replaces the token without ending the session (`SessionEpoch`).
        epoch.bump()
        let withdrawnHere = outgoing.map { $0 !== kept } ?? false
        guard withdrawingAccount || withdrawnHere else { return nil }
        return onAccountWithdrawn?(epoch.current)
    }

    /// Everything scoped to the identity that is ending, removed at ONE boundary.
    ///
    /// Called from the three places an identity stops being this device's: a wipe, an account
    /// switch, and a launch that finds a licence with no credential behind it. It is deliberately
    /// the only such list — a second place to remember is how one of them ends up missing.
    ///
    /// The snapshot wipe is AWAITED, and it is the last thing here: everything above it is
    /// synchronous, so by the time the disk is touched the incarnation has already ended and the
    /// authority epoch has already moved — a picture still on its way to the writer is stamped
    /// with the epoch before it and is refused there rather than landing behind this removal.
    /// That ordering is the whole of the guarantee, and it is what `endIncarnation` being called
    /// FIRST at every one of these three sites buys.
    private func invalidateIdentityScopedState() async {
        supersedeValidationInFlight()
        forgetLastKnownUser()
        await snapshots?.removeAll()
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

    /// What a sign-in says when a withdrawal overtook it before it stored anything.
    public static let signInInterrupted =
        "Signing in was interrupted: the account already on this device was signed out while it "
        + "ran. Sign in again."

    /// A sign-in that something overtook before it stored anything.
    ///
    /// Which something decides it, and the one question is whether a session was ESTABLISHED
    /// since the sign-in started (`nothingEstablishedSince`). If one was — a launch admitted, a
    /// put-back reinstalled a client — the screen belongs to that session and this attempt says
    /// nothing (`supersededSignIn`). If none was, what overtook it was a withdrawal: a sign-out, or
    /// the refusal rule wiping the credential this sign-in was replacing. That withdrawal owns
    /// the session's state and installs nothing, so the sign-in still installs nothing either —
    /// but the screen is the sign-in's, and leaving it to a withdrawal's sentence (or to none)
    /// tells the person about a token they were replacing rather than the one they just entered.
    /// So it writes its own outcome, and only that: no state, no client, no generation, so a
    /// withdrawal still in flight finishes exactly as it would have.
    ///
    /// And the sentence must still be its to write. Every write of `lastError` or `lastFailure`
    /// since the sign-in started is counted; the only ones it may write over are the refusal
    /// rule's own, which can only be about the credential it was replacing. Anything else — a
    /// sign-out's warning that the credential would not delete, another sign-in's refusal — was
    /// written by somebody later, and this sign-in says nothing over it.
    @discardableResult
    private func overtakenSignIn(
        _ failure: NativeLoginError?, establishedAtStart: Int,
        sentencesAtStart: (all: Int, refusals: Int)
    ) -> Bool {
        guard nothingEstablishedSince(establishedAtStart) else { return supersededSignIn() }
        let written = sentenceWrites - sentencesAtStart.all
        guard written == refusalSentenceWrites - sentencesAtStart.refusals else {
            return supersededSignIn()
        }
        MemosLog.session.info("a sign-in was overtaken by a withdrawal; it says so")
        lastError = failure?.message ?? Self.signInInterrupted
        lastFailure = failure
        return false
    }

    /// Writes of `lastError` and `lastFailure`, and how many of them were the refusal rule's own
    /// sentence — what an overtaken sign-in asks before it writes (`overtakenSignIn`).
    @ObservationIgnored private var sentenceWrites = 0
    @ObservationIgnored private var refusalSentenceWrites = 0
    private var sentenceMark: (all: Int, refusals: Int) { (sentenceWrites, refusalSentenceWrites) }

    /// The refusal rule's sentence, after a wipe it caused.
    private func sayRefused(_ refusal: CredentialRefusal) {
        lastError = refusal.errorDescription
        refusalSentenceWrites += 1
    }

    private func failSignIn(_ error: NativeLoginError) {
        state = .signedOut
        // The authority before the handle, as at every site that ends an identity.
        endIncarnation()
        client = nil
        credential = nil
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
        // An account change ends the outgoing session's capture grant: the file goes now, and the
        // outgoing client — still presenting the token that minted it — asks the server to
        // revoke it, without holding this sign-in up.
        if let grant = retireCaptureGrant(), let outgoing = client {
            Task { await Self.revokeCaptureGrant(grant, with: outgoing) }
        }
        guard clearAccountLicence() else {
            // Nothing was withdrawn, so the incarnation is the one the caller is still in.
            return Persistence(outcome: .licenceNotRevoked, installing: sessionGeneration)
        }
        // INVALIDATE FIRST, before the write is awaited. A request that starts inside the keychain
        // await belongs to the account being replaced; finding no client is right, and finding the
        // previous one is how an answer about A lands in B's session. The last-known identity goes
        // with it: a process that dies inside the write must not leave A's file beside B's token.
        // The account the licence above belonged to — none, on a first sign-in — is withdrawn at
        // this epoch, exactly as a wipe withdraws it; its uploads still hold its token. The
        // incarnation ends before the handle is cleared: a sender off the main actor checks it.
        endIncarnation(withdrawingAccount: true)
        client = nil
        credential = nil
        let installing = sessionGeneration
        await invalidateIdentityScopedState()
        // That call awaits the snapshot removal, and a sign-out or another installation can
        // complete inside it. Writing the credential afterwards would store one for a session
        // this device has already left — asked here, before the write, because after it the
        // token is on the device whatever the caller then decides.
        guard owns(installing) else {
            MemosLog.session.info("a sign-in was overtaken before its credential was written")
            return Persistence(outcome: .storedNowhere, installing: installing)
        }
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
        // Putting back the credential that was standing withdraws nothing; anything else does.
        endIncarnation(keeping: snapshot.client == nil ? nil : snapshot.credential)
        if snapshot.client != nil { presentedGrant = snapshot.credential }
        supersedeValidationInFlight()
        state = snapshot.state
        client = snapshot.client
        // The other place a client can be installed. Conditional because this one may also put
        // back nothing, and restoring an absence is a withdrawal however it is spelled.
        if snapshot.client != nil { establishedGeneration = sessionGeneration }
        credential = snapshot.credential
        configuration = snapshot.configuration
        setVerification(snapshot.verification)
        // Restoring the STATE is not restoring the lifecycle. The bump above is what stops a
        // pre-attempt answer becoming current again — and it is also what makes the check in
        // flight exit without doing anything, so a session put back as `.verifying` would sit
        // there with no task and no retry behind it. The same rule as a cancelled check: whatever
        // is not confirmed gets a replacement, immediately.
        if snapshot.state == .signingIn, snapshot.client == nil {
            // A launch check that had not admitted anybody: no user to re-verify, so the retry
            // ladder has nothing to ask about. Its own answer was dropped while the sign-in held
            // the session, or is fenced out by the bump above, so the launch question itself is
            // asked again — or the spinner stays up with nothing behind it.
            let generation = sessionGeneration
            Task { @MainActor [self] in
                await restoreAfterRefusedSignIn(expecting: generation)
            }
            return
        }
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
        // away. The incarnation ends before the handle is cleared: a sender off the main actor
        // checks it, never the handle.
        // The outbox hears it inside, after the epoch moved, so nothing it starts from here
        // presents this credential, and before any await: a background upload holds its own copy
        // of the token and goes on sending it until it is cancelled.
        let cancelling = endIncarnation(withdrawingAccount: true)
        client = nil
        credential = nil
        // Nothing is owed an answer any more, and nothing is waiting to ask for one.
        setVerification(.verified)
        persistenceProven = false
        withdrawOlderServerNotice()
        retryInFlight?.cancel()
        retryInFlight = nil
        // Everything above this line is synchronous and belongs to the incarnation this method
        // just ended. Everything below it happens AFTER an await, and a sign-in can complete
        // inside one — so the number the tail fences on is read while nothing has suspended yet.
        let issued = sessionGeneration
        // The identity-scoped list, LAST of the synchronous withdrawal: its own tail awaits the
        // snapshot removal, and nothing above may be left until after that.
        await invalidateIdentityScopedState()
        // Not signed out until the outbox has at least issued the cancel of every upload still
        // presenting this credential: awaited here, after the synchronous withdrawal above and
        // before anything reports this sign-out done. A process ended before that point leaves
        // the outbox's record of the withdrawal for the next launch to finish.
        await cancelling?.value
        // A sign-in can complete inside those awaits, and the credential in the keychain is then
        // ITS credential. Deleting it would sign out a session this method never knew about.
        guard owns(issued) else {
            MemosLog.session.info("a sign-out was overtaken before it deleted the credential")
            return issued
        }
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
        uploadLimits = nil
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw NativeLoginError.api(.fromStatus(503))
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
        } catch {
            guard generation == sessionGeneration else { return }
            if let refusal = StoreFailure.refusal(error) {
                await handle(refusal)
                return
            }
            MemosLog.session.info("GET /api/settings did not answer; the default stays unnamed")
        }
    }

    /// Reads the server's upload limits, once per session.
    ///
    /// Best-effort like `loadSettings`, and fenced the same way: the generation is taken before
    /// the call and checked before the write, so an answer about a session that has ended is
    /// dropped. A second call in the same session sends nothing — the first one's ask stands,
    /// in flight or answered. A failure leaves the limits unknown and lets a later call ask
    /// again; unknown limits refuse nothing, so the queue sends exactly as it did before the
    /// server published them. A 401 ends the session here as it does everywhere else.
    public func loadUploadLimits() async {
        guard let client else { return }
        let generation = sessionGeneration
        guard uploadLimitsAsked != generation else { return }
        uploadLimitsAsked = generation
        do {
            let limits = try await Self.uploadLimits(client)
            guard generation == sessionGeneration else {
                MemosLog.session.info("GET /api/uploads/limits answered for an ended session")
                return
            }
            uploadLimits = limits
        } catch {
            guard generation == sessionGeneration else { return }
            uploadLimitsAsked = nil
            if let refusal = StoreFailure.refusal(error) {
                await handle(refusal)
                return
            }
            MemosLog.session.info("GET /api/uploads/limits did not answer; nothing is refused")
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
    ///
    /// One write at a time (CLAUDE.md, «A store serializes its own mutations»): a second call with
    /// the SAME visibility while one is on the wire JOINS it and answers with its result; a call
    /// with a DIFFERENT one is REFUSED — false, nothing sent — because two PATCHes racing each
    /// other would leave whichever the server answered last as the default. A slot left by an
    /// earlier session generation is never joined.
    ///
    /// The slot's task runs a turn later than the call that made it, and a session can end or be
    /// replaced in between, so the sender is handed the generation the CALLER asked in and checks
    /// it before it reads the client: a default asked for in one session is never sent in the next.
    @discardableResult
    public func setDefaultVisibility(_ visibility: MemoVisibility) async -> Bool {
        if let pending = visibilityWrite, pending.generation == sessionGeneration {
            guard pending.payload == visibility else { return false }
            return await pending.task.value
        }
        let asked = sessionGeneration
        let slot = InFlightWrite(
            payload: visibility, generation: asked,
            task: Task { await self.sendDefaultVisibility(visibility, askedIn: asked) }
        )
        visibilityWrite = slot
        let saved = await slot.task.value
        if visibilityWrite?.id == slot.id { visibilityWrite = nil }
        return saved
    }

    func sendDefaultVisibility(
        _ visibility: MemoVisibility, askedIn generation: Int
    ) async -> Bool {
        guard generation == sessionGeneration, let client else { return false }
        do {
            let settings = try await Self.updateSettings(client, defaultVisibility: visibility)
            guard generation == sessionGeneration else {
                MemosLog.session.info("PATCH /api/settings answered for a session that has ended")
                return false
            }
            apply(settings)
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if let refusal = StoreFailure.refusal(error) {
                await handle(refusal)
                return false
            }
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
        } catch {
            guard generation == sessionGeneration else { return }
            if let refusal = StoreFailure.refusal(error) {
                await handle(refusal)
                return
            }
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
    ///
    /// One rename at a time, the rule `setDefaultVisibility` keeps: the same name while one is on
    /// the wire joins it, a different name is refused with nothing sent — and, the same way, the
    /// sender checks the generation the caller asked in before it reads the client.
    @discardableResult
    public func renameDeviceToken(to name: String) async -> Bool {
        guard client != nil else { return false }
        // Checked here rather than by the field alone, so that the one rule is the one the request
        // is built from: a name the server would refuse is never sent.
        guard let sanitized = DeviceTokenName.sanitized(name) else {
            deviceTokenNotice = Self.tokenNameRefused
            return false
        }
        if let pending = tokenRename, pending.generation == sessionGeneration {
            guard pending.payload == sanitized else { return false }
            return await pending.task.value
        }
        let asked = sessionGeneration
        let slot = InFlightWrite(
            payload: sanitized, generation: asked,
            task: Task { await self.sendDeviceTokenRename(sanitized, askedIn: asked) }
        )
        tokenRename = slot
        let renamed = await slot.task.value
        if tokenRename?.id == slot.id { tokenRename = nil }
        return renamed
    }

    func sendDeviceTokenRename(_ sanitized: String, askedIn generation: Int) async -> Bool {
        guard generation == sessionGeneration, let client else { return false }
        do {
            let row = try await Self.renameDeviceToken(client, to: sanitized)
            guard generation == sessionGeneration else {
                MemosLog.session.info("PATCH /api/auth/native/token answered for an ended session")
                return false
            }
            deviceToken = row
            deviceTokenNotice = nil
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            if let refusal = StoreFailure.refusal(error) {
                await handle(refusal)
                return false
            }
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
        } catch is NotRenewable {
            guard generation == sessionGeneration else { return .failed }
            deviceTokenNotice = Self.tokenNotRenewable
            return .notRenewable
        } catch {
            guard generation == sessionGeneration else { return .failed }
            if let refusal = StoreFailure.refusal(error) {
                await handle(refusal)
                return .failed
            }
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
        // The renewal revoked the capture grant with its token on the server, so the file names a
        // dead grant: it goes in the same step, and no revoke is sent. Its successor is minted
        // below, once the session is known to still be this one.
        try? captureGrants?.clear()
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
        if owns(generation) { await mintCaptureGrant(keepingAFreshGrant: false) }
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
        } catch {
            guard generation == sessionGeneration else { return .failed }
            // The OTHER place the rule is spelled out by hand, and the reason is the sentence.
            // This refusal means the opposite of a supersede — the rotation happened and its
            // successor was lost — so `renewalLostCredential` is what belongs on the screen and
            // `handle` would write something else. The probe presents the token the device is
            // still holding, so the predicate passes it through; `replace` has one call site and
            // it is inside the single-flight renewal, so nothing can move the generation under it.
            if let refusal = StoreFailure.refusal(error),
                refusal.concernsCurrentCredential(of: credential)
            {
                MemosLog.session.error(
                    "a renewal rotated and its successor was lost; this device has to sign in again"
                )
                let wiped = await wipeCredential()
                if owns(wiped) { lastError = Self.renewalLostCredential }
                return .failed
            }
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
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
        } catch OriginalMediaError.credentialRefused(let refused) {
            guard generation == sessionGeneration else {
                MemosLog.session.info("a download failed for a session that has ended")
                throw OriginalMediaError.superseded
            }
            // The refusal carries the epoch the send PRESENTED, read off the grant the transport
            // recorded. It names none only when nothing ever asked the authority, which no
            // production transport does; then this caller's own pre-send snapshot is the best
            // there is, and handing over an unnamed epoch instead would end the session on a
            // refusal nobody can date.
            let refusal =
                refused.issuedUnder == nil
                ? CredentialRefusal(issuedUnder: presented.epoch) : refused
            switch await handle(refusal) {
            // Reported as superseded rather than rethrown as a refusal. Ending the session is only
            // half of what a refusal does — it is also the shape every screen turns into "your
            // access was rejected, sign in again", which on a live session that has just renewed
            // is a false instruction that costs someone a working sign-in.
            case .superseded: throw OriginalMediaError.superseded
            case .endedSession:
                // The fourth effect that depends on that answer, and the same question the three
                // reporting stores ask after the same await: a sign-in can complete inside the
                // wipe, and "your access was rejected" is then about an account nobody is looking
                // at. The supersede is not silence — the save flow says the sign-in changed,
                // which is the true thing to say to whoever is holding the phone.
                guard nothingEstablishedSince(generation) else {
                    throw OriginalMediaError.superseded
                }
                throw OriginalMediaError.credentialRefused(refusal)
            }
        } catch OriginalMediaError.refused(let error) {
            // Every NON-refusal status, unchanged.
            guard generation == sessionGeneration else {
                MemosLog.session.info("a download failed for a session that has ended")
                throw OriginalMediaError.superseded
            }
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }

    static func uploadLimits(_ client: any APIProtocol) async throws -> UploadLimits {
        let response = try await client.uploadLimitsApiUploadsLimitsGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/uploads/limits -> 200")
            let json = try ok.body.json
            return UploadLimits(
                maxBytes: Int64(json.maxBytes),
                wifiRecommendedAboveBytes: Int64(json.wifiRecommendedAboveBytes),
                bodiesPerUser: json.bodiesPerUser
            )
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
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
        _ failure: ServerReachability.Reason,
        issuedUnder generation: Int
    ) {
        guard generation == sessionGeneration else {
            MemosLog.session.info("a transport failure from an ended session is not this one's")
            return
        }
        guard state.user != nil, verification == .verified, let configuration else { return }
        let host = configuration.baseURL.host() ?? configuration.baseURL.absoluteString
        setVerification(.unverified(SessionRestoreFailure(failure, host: host).message))
        scheduleRetry(attempt: 1)
    }

    /// A store reached the server, reported by the incarnation that issued the request.
    ///
    /// It asks for a check and it decides nothing, which is the whole of the asymmetry with its
    /// sibling. A page that arrived says the server answered ONE request, under ONE credential, at
    /// an instant that has already passed; the question this app has to answer is whether the
    /// credential it is holding is still good, and the only thing that answers that is a whoami.
    /// Confirming a session from a page instead would resurrect exactly the session a revoked
    /// token should have ended, because the revoked token's list read can still be in the air.
    ///
    /// A confirmed session is a no-op — no counter, no request, no work — so the stores may
    /// call this on every page they apply.
    public func noteTransportSuccess(issuedUnder generation: Int) {
        guard generation == sessionGeneration else { return }
        guard state.user != nil else { return }
        guard verification != .verified else { return }
        // The one thing it does. The generation crosses the hop WITH the task, because the
        // session it is about can be over before the task gets its turn.
        Task { [generation] in await probe(issuedUnder: generation) }
    }

    /// Asks the question that can confirm a session, on behalf of a request that got through.
    ///
    /// The comparison at the top is the same one the caller already made, and it is not
    /// decoration: the caller made it in the instant the page landed, and this runs a hop later —
    /// long enough for a sign-out, a wipe or another sign-in to have put a different session
    /// behind the same store. It joins whatever check is already in flight rather than sending a
    /// second one, and it carries the rung the ladder had reached rather than zero, so a success
    /// seen at the capped wait does not drop the schedule back to three seconds.
    private func probe(issuedUnder generation: Int) async {
        guard generation == sessionGeneration else { return }
        await revalidate(attempt: ladderAttempt, expecting: generation)
    }

    /// The sign-in handshake: asks the server which API major it speaks, and raises
    /// `showsOlderServerNotice` when that is older than the contract this build was generated from.
    ///
    /// Unstructured, so the sign-in returns without waiting for `/health`: a structured child would
    /// hold the sign-in open until the server answered, and the handshake informs rather than
    /// gates. `generation` is read by the caller AFTER `establish` returned — `persist` and
    /// establishment each move it, so the sign-in's own `issued` would never match — and the
    /// answer is written only while that session still owns the store (`owns`, not
    /// `nothingEstablishedSince`, which tolerates a withdrawal and would let a notice about a
    /// server this device has signed out of reach the screen) and while no sign-in or wipe has
    /// withdrawn the notice since it was launched (`handshakeEpoch`). Nothing is awaited between
    /// the decision and the write.
    private func checkServerMajor(client: any APIProtocol, issuedUnder generation: Int) {
        let epoch = handshakeEpoch
        serverMajorCheck = Task { [generation, epoch] in
            let answer: Result<Operations.HealthHealthGet.Output, any Error>
            do {
                answer = .success(try await client.healthHealthGet(.init()))
            } catch {
                answer = .failure(error)
            }
            let older = Self.serverIsOlder(answer, than: VendoredRelease.apiMajor)
            // Both fences, on this actor, with nothing awaited between them and the write: the
            // session is still the one the handshake was launched for, AND nothing has withdrawn
            // the notice since — a sign-in accepted after the launch has, even before it owns the
            // generation.
            guard owns(generation), epoch == handshakeEpoch else { return }
            if older {
                MemosLog.session.info("GET /health -> an API major older than this build's")
                showsOlderServerNotice = true
            }
        }
    }

    /// Takes the older-server notice down and invalidates every handshake launched before now.
    ///
    /// One function so the two can never be separated: a reset that left an earlier handshake able
    /// to write would be undone by that handshake's late answer.
    private func withdrawOlderServerNotice() {
        showsOlderServerNotice = false
        handshakeEpoch += 1
    }

    /// The handshake's ONE decision: whether what `/health` answered says the server speaks an
    /// older API major than `appMajor`.
    ///
    /// A decoded 200 is compared. A 200 whose body does not decode as `HealthResponse` is a server
    /// from before `apiMajor` existed — v2.0.0 made the field required — and that is older too. It
    /// cannot be decided at `try ok.body.json`: the generated client decodes the body INSIDE
    /// `healthHealthGet` before it hands back `.ok`, so a missing field throws from the call as a
    /// `ClientError` that still carries the 200. A body the network cut off arrives in that same
    /// shape, which is why the underlying error has to be a `DecodingError` — the body arrived and
    /// did not fit — and not merely any error after a 200. A transport failure (no response at
    /// all) and any other status say nothing, because reachability belongs to the outbox probe and
    /// the verification ladder. A NEWER major says nothing either, as the owner's standing default.
    private static func serverIsOlder(
        _ answer: Result<Operations.HealthHealthGet.Output, any Error>,
        than appMajor: Int
    ) -> Bool {
        switch answer {
        case .success(.ok(let ok)):
            guard let health = try? ok.body.json else { return false }
            return health.apiMajor < appMajor
        // Documented since v2.1.0; says nothing, exactly as its `.undocumented(503)` did.
        case .success(.undocumented), .success(.serviceUnavailable):
            return false
        case .failure(let error):
            guard let clientError = error as? ClientError,
                clientError.receivedStatusCode == 200
            else { return false }
            return clientError.underlyingError is DecodingError
        }
    }

    static func whoami(_ client: any APIProtocol) async throws -> User {
        let response = try await client.whoamiApiAuthUserGet(.init())
        switch response {
        case .ok(let ok):
            MemosLog.session.info("GET /api/auth/user -> 200")
            return User(try ok.body.json)
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}

/// The session as the reporting stores see it — see `SessionReporting`.
extension SessionStore: SessionReporting {
    /// The rule without the effect. Same predicate as the funnel's, asked by a store that reports
    /// a refusal rather than acting on one.
    public func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool {
        refusal.concernsCurrentCredential(of: credential)
    }

    /// The fence a store takes between the refusal rule's answer and the sentence it writes —
    /// answered from the one retained number, never re-derived (`nothingEstablishedSince`).
    public func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        nothingEstablishedSince(handle.generation)
    }
}

/// A write on the wire, as the slot a second caller is judged against: what it sends, the session
/// generation that sent it, and the answer to wait for when the second caller asks for the same.
private struct InFlightWrite<Payload: Equatable> {
    let id = UUID()
    let payload: Payload
    let generation: Int
    let task: Task<Bool, Never>
}
