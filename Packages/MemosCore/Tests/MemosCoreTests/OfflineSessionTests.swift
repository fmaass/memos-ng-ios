import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

private let whoami = "whoami_api_auth_user_get"
private let settingsOperation = "get_settings_api_settings_get"
private let logoutOperation = "native_logout_api_auth_native_logout_post"
private let renewOperation = "native_renew_api_auth_native_renew_post"
private let tokenRowOperation = "native_token_api_auth_native_token_get"

private let storedToken = "memos_pat_stored_secret"
private let storedAddress = "https://memos.example.invalid"
private let storedHost = "memos.example.invalid"

/// What a phone with no route to its server throws. `-1009` with no stream errno beside it is the
/// `offline` classification rather than the Local Network denial (`NativeLoginTransportFailure`).
private func offline() -> URLError { URLError(.notConnectedToInternet) }

/// The last-known-user file, in memory, counting what was done to it.
final class StubLastKnownUser: LastKnownUserStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: LastKnownUser?
    private var writes = 0
    private var deletes = 0

    init(_ record: LastKnownUser? = nil) { self.record = record }

    func read() -> LastKnownUser? { lock.withLock { record } }

    func write(_ record: LastKnownUser) {
        lock.withLock {
            self.record = record
            writes += 1
        }
    }

    func delete() {
        lock.withLock {
            record = nil
            deletes += 1
        }
    }

    var stored: LastKnownUser? { lock.withLock { record } }
    var writeCount: Int { lock.withLock { writes } }
    var deleteCount: Int { lock.withLock { deletes } }
}

/// A credential store that works until it is told to stop — the renewal case, where the write of
/// the successor throws after the predecessor was already stored.
final class FlakyCredentials: CredentialStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var refusing = false

    func refuseWrites() { lock.withLock { refusing = true } }

    func set(_ value: String, for account: String) async throws {
        let refuse: Bool = lock.withLock { refusing }
        if refuse { throw Refused() }
        lock.withLock { storage[account] = value }
    }

    func string(for account: String) async throws -> String? { lock.withLock { storage[account] } }

    func remove(_ account: String) async throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }

    func snapshot() -> [String: String] { lock.withLock { storage } }
}

/// Every wait the session asked for, and a bound so a schedule cannot run a suite for ever.
///
/// The throw is how a test stops the ladder: `scheduleRetry` treats a sleeper that throws as a
/// schedule that has been cancelled, which is exactly what a backgrounded app does to it.
final class RetryLadderSleeper: @unchecked Sendable {
    struct Stop: Error {}

    private let lock = NSLock()
    private var waits: [Duration] = []
    private let limit: Int

    init(stoppingAfter limit: Int = 0) { self.limit = limit }

    var recorded: [Duration] { lock.withLock { waits } }

    func sleep(_ wait: Duration) throws {
        let over: Bool = lock.withLock {
            waits.append(wait)
            return waits.count > limit
        }
        if over { throw Stop() }
    }
}

/// The seconds a `Duration` stands for, so a jittered wait can be measured against its band.
private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

@MainActor
@Suite("A stored credential opens the app before the server answers")
struct OfflineSessionTests {
    private func credentials(token: String = storedToken) -> InMemoryCredentials {
        let store = InMemoryCredentials()
        try? store.set(token, for: SessionStore.tokenAccount)
        try? store.set(storedAddress, for: SessionStore.serverAccount)
        return store
    }

    private func boundFile(
        subject: String = "fabian",
        server: String = storedAddress,
        token: String = storedToken
    ) -> StubLastKnownUser {
        StubLastKnownUser(
            LastKnownUser(
                subject: subject,
                displayName: "Fabian",
                email: "f@example.invalid",
                role: "admin",
                authKind: "oidc",
                serverBaseURL: server,
                credentialFingerprint: CredentialFingerprint.of(token)
            )
        )
    }

    private func makeSession(
        credentials: any CredentialStore,
        file: (any LastKnownUserStoring)? = nil,
        account: SpyAccountStore? = nil,
        identity: MediaIdentity = MediaIdentity(),
        sleeper: RetryLadderSleeper = RetryLadderSleeper(),
        onVerified: (@MainActor @Sendable () async -> Void)? = nil,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { try sleeper.sleep($0) },
            account: account,
            identity: identity,
            lastKnownUser: file,
            onVerified: onVerified
        )
    }

    /// Pumps the main actor until a scheduled task has had its turn, or gives up.
    ///
    /// A retry runs in a task of its own — that is what makes it a schedule — so a test that
    /// asserted the instant `restore()` returned would be asserting about work that has not
    /// started. A bound rather than a wait: a condition that never becomes true is a failure to
    /// report, not a suite to hang.
    private func settle(until condition: () -> Bool, turns: Int = 200) async {
        for _ in 0..<turns where !condition() { await Task.yield() }
    }

    // MARK: - admission

    @Test("a bound last-known user opens the app when the server cannot be reached")
    func admitsProvisionally() async {
        let credentials = credentials()
        let file = boundFile()
        let session = makeSession(credentials: credentials, file: file) { _, _, _ in
            throw offline()
        }

        await session.restore()

        #expect(session.state.user?.subject == "fabian")
        guard case .unverified(let reason) = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }
        #expect(reason.contains(storedHost), "the banner names the server it could not reach")
        #expect(!credentials.isEmpty, "an unconfirmed token is kept for the retry")
    }

    /// Read from INSIDE the transport, which is the only moment `.verifying` exists: the request is
    /// on the wire and the answer has not come back.
    @Test("the app is admitted and verifying before the server answers")
    func verifyingBeforeTheAnswer() async {
        let box = LockedValue<SessionStore?>(nil)
        let seenSubject = LockedValue<String?>(nil)
        let seenVerification = LockedValue<SessionVerification?>(nil)
        let session = makeSession(credentials: credentials(), file: boundFile()) { _, _, _ in
            if let session = box.get() {
                let snapshot = await MainActor.run {
                    (session.state.user?.subject, session.verification)
                }
                seenSubject.set(snapshot.0)
                seenVerification.set(snapshot.1)
            }
            return Stub.json(Stub.user)
        }
        box.set(session)

        await session.restore()

        #expect(seenSubject.get() == "fabian", "the app was already open while the check was out")
        #expect(seenVerification.get() == .verifying, "and it showed no banner while it was")
        #expect(session.verification == .verified)
    }

    /// Codex's interrupted same-server switch: sign in as B, B's token stored, the process dies
    /// before B's file is written, and the relaunch finds A's file naming the same server.
    @Test("a file whose fingerprint does not match the stored token admits nobody")
    func fingerprintMismatchIsNotAdmitted() async {
        let account = SpyAccountStore()
        let file = boundFile(subject: "someone-else", token: "memos_pat_a_different_token")
        let session = makeSession(
            credentials: credentials(),
            file: file,
            account: account
        ) { _, _, _ in throw offline() }

        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
        #expect(session.state.user == nil)
        #expect(account.published == nil, "no licence for an identity the token does not bind to")
    }

    @Test("a file naming another server admits nobody")
    func serverMismatchIsNotAdmitted() async {
        let file = boundFile(server: "https://other.example.invalid")
        let session = makeSession(credentials: credentials(), file: file) { _, _, _ in
            throw offline()
        }

        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
    }

    @Test("no last-known user parks the launch exactly as it always did")
    func noFileIsNotAdmitted() async {
        let file = StubLastKnownUser()
        let session = makeSession(credentials: credentials(), file: file) { _, _, _ in
            throw offline()
        }

        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
    }

    // MARK: - what the answer does

    @Test("confirming the same account touches neither the media identity nor the settings")
    func confirmDoesNotRotateOrReset() async {
        let identity = MediaIdentity()
        let answering = LockedValue<Bool>(false)
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            identity: identity
        ) { _, _, operation in
            if operation == settingsOperation {
                return Stub.json(#"{"default_visibility":"PUBLIC","theme":"dark","avatar":null}"#)
            }
            guard answering.get() else { throw offline() }
            return Stub.json(Stub.user)
        }

        await session.restore()
        await session.loadSettings()
        let rotations = identity.generation
        #expect(session.verification != .verified, "the launch really did not confirm anything")
        #expect(session.defaultVisibility != nil, "the account's own setting was read")

        answering.set(true)
        await session.enteredForeground()

        #expect(session.verification == .verified)
        #expect(identity.generation == rotations, "a routine confirmation empties no image cache")
        #expect(session.defaultVisibility != nil, "and blanks no account setting")
    }

    @Test("a check that names a different account establishes it whole")
    func differentSubjectIsAFullEstablish() async {
        let identity = MediaIdentity()
        let answering = LockedValue<Bool>(false)
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            account: account,
            identity: identity
        ) { _, _, _ in
            guard answering.get() else { throw offline() }
            return Stub.json(
                """
                {"subject":"someone-else","display_name":"Else","email":null,\
                "role":"user","auth_kind":"oidc"}
                """
            )
        }

        await session.restore()
        let rotations = identity.generation

        answering.set(true)
        await session.enteredForeground()

        #expect(session.state.user?.subject == "someone-else")
        #expect(identity.generation > rotations, "a new identity's photos are not the old one's")
        #expect(account.published?.ownerSubject == "someone-else")
    }

    @Test("a 401 for the credential in hand ends the session and wipes it")
    func currentEpoch401SignsOut() async {
        let credentials = credentials()
        let file = boundFile()
        let answering = LockedValue<Bool>(false)
        let session = makeSession(credentials: credentials, file: file) { _, _, _ in
            guard answering.get() else { throw offline() }
            return Stub.empty(.unauthorized)
        }

        await session.restore()
        answering.set(true)
        await session.enteredForeground()

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
        #expect(file.stored == nil, "the identity goes with the credential it was bound to")
    }

    /// The middleware turns a refusal of a replaced credential into `CredentialSuperseded` before
    /// it can ever reach the rule that ends sessions. Whichever of the two guards catches it, the
    /// session has to survive AND something has to be scheduled — a discarded answer that
    /// scheduled nothing leaves the app in `.verifying` for ever.
    @Test("a refusal of a replaced credential is discarded and replaced at once")
    func supersededIsDiscardedAndReplaced() async {
        let calls = Counter()
        let answering = LockedValue<Bool>(false)
        let sleeper = RetryLadderSleeper(stoppingAfter: 2)
        let credentials = credentials()
        let session = makeSession(
            credentials: credentials,
            file: boundFile(),
            sleeper: sleeper
        ) { _, _, _ in
            calls.increment()
            guard answering.get() else { throw offline() }
            throw CredentialSuperseded()
        }

        await session.restore()
        let before = calls.count
        answering.set(true)
        await session.enteredForeground()
        await settle(until: { calls.count > before + 1 })

        #expect(session.state.user != nil, "a stale refusal is not this credential's verdict")
        #expect(!credentials.isEmpty)
        #expect(calls.count > before + 1, "a replacement really went out")
    }

    @Test("a 403 and a 500 keep the session and keep asking")
    func reachableRefusalsStayAdmitted() async {
        for status in [403, 500] {
            let answering = LockedValue<Bool>(false)
            let sleeper = RetryLadderSleeper(stoppingAfter: 1)
            let credentials = credentials()
            let session = makeSession(
                credentials: credentials,
                file: boundFile(),
                sleeper: sleeper
            ) { _, _, _ in
                guard answering.get() else { throw offline() }
                return Stub.empty(.init(code: status))
            }

            await session.restore()
            answering.set(true)
            await session.enteredForeground()

            #expect(session.state.user != nil, "HTTP \(status) is not a revoked token")
            #expect(!credentials.isEmpty)
            guard case .unverified = session.verification else {
                Issue.record("expected .unverified for \(status), got \(session.verification)")
                return
            }
            #expect(!sleeper.recorded.isEmpty, "and it is still asking")
        }
    }

    @Test("two overlapping launch checks put ONE request on the wire")
    func concurrentRestoresAreOneRequest() async {
        let calls = Counter()
        let session = makeSession(credentials: credentials(), file: boundFile()) { _, _, _ in
            calls.increment()
            await Task.yield()
            return Stub.json(Stub.user)
        }

        async let first: Void = session.restore()
        async let second: Void = session.restore()
        _ = await (first, second)

        #expect(calls.count == 1, "the second call joins the first; it does not re-ask")
    }

    @Test("a cancelled check answers nothing and a replacement goes out at once")
    func cancellationIsNotAnAnswer() async {
        let calls = Counter()
        let sleeper = RetryLadderSleeper(stoppingAfter: 1)
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            sleeper: sleeper
        ) { _, _, _ in
            calls.increment()
            if calls.count == 1 { throw CancellationError() }
            return Stub.json(Stub.user)
        }

        await session.restore()
        await settle(until: { session.verification == .verified })

        #expect(calls.count == 2, "the replacement is immediate, not left to the next trigger")
        #expect(sleeper.recorded.first == .zero, "and it does not wait out a retry interval")
        #expect(session.verification == .verified)
    }

    @Test("the outbox is restarted once per transition into a confirmed session")
    func onVerifiedFiresOncePerTransition() async {
        let restarts = Counter()
        let answering = LockedValue<Bool>(false)
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            onVerified: { restarts.increment() }
        ) { _, _, _ in
            guard answering.get() else { throw offline() }
            return Stub.json(Stub.user)
        }

        await session.restore()
        #expect(restarts.count == 0, "a transport failure is not a confirmation")

        answering.set(true)
        await session.enteredForeground()
        await settle(until: { restarts.count == 1 })
        #expect(restarts.count == 1)

        await session.enteredForeground()
        await settle(until: { restarts.count > 1 }, turns: 20)
        #expect(restarts.count == 1, "a confirmed session confirming again is not a transition")
    }

    @Test("the retry ladder climbs to a cap, each wait inside its band")
    func retryLadderClimbs() async {
        let sleeper = RetryLadderSleeper(stoppingAfter: 4)
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            sleeper: sleeper
        ) { _, _, _ in throw offline() }

        await session.restore()
        // The ladder runs itself: each failed retry schedules the next, and the sleeper stops it.
        await settle(until: { sleeper.recorded.count >= 5 }, turns: 500)

        let waits = sleeper.recorded.map(seconds)
        #expect(waits.count >= 4, "got \(waits)")
        let nominal = [3.0, 10.0, 30.0, 45.0]
        for (index, expected) in nominal.enumerated() where index < waits.count {
            #expect(
                waits[index] >= expected * 0.8 && waits[index] <= expected * 1.2,
                "wait \(index) was \(waits[index]), outside ±20 % of \(expected)"
            )
        }
    }

    @Test("nothing is scheduled behind an app that went away")
    func nothingIsScheduledInTheBackground() async {
        let sleeper = RetryLadderSleeper(stoppingAfter: 0)
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            sleeper: sleeper
        ) { _, _, _ in throw offline() }

        session.enteredBackground()
        await session.restore()

        #expect(sleeper.recorded.isEmpty, "a phone in a pocket has nobody to show an answer to")
    }

    // MARK: - the file's own rules

    @Test("a proven persist writes the identity bound to the token it was confirmed with")
    func provenPersistWritesTheFile() async {
        let file = StubLastKnownUser()
        let session = makeSession(credentials: InMemoryCredentials(), file: file) { _, _, _ in
            Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: storedHost, token: "memos_pat_fresh")

        #expect(file.stored?.subject == "fabian")
        #expect(file.stored?.serverBaseURL == storedAddress)
        #expect(
            file.stored?.credentialFingerprint == CredentialFingerprint.of("memos_pat_fresh"),
            "the fingerprint is of the token whoami answered for"
        )
    }

    @Test("a sign-in whose credential would not store leaves no identity behind")
    func storedNowhereDeletesTheFile() async {
        let file = boundFile()
        let session = makeSession(credentials: RefusingCredentials(), file: file) { _, _, _ in
            Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: storedHost, token: "memos_pat_fresh")

        #expect(session.state.user != nil, "the session still works from memory")
        #expect(file.stored == nil, "a write that threw does not prove the predecessor survived")
    }

    @Test("a successful renewal rebinds the identity to the successor")
    func renewalRebindsTheFile() async {
        let credentials = FlakyCredentials()
        let file = StubLastKnownUser()
        let session = makeSession(credentials: credentials, file: file) { _, _, operation in
            switch operation {
            case renewOperation: return Stub.json(Stub.exchange(token: "memos_pat_successor"))
            case tokenRowOperation: return Stub.json(Stub.nativeToken(name: "iPhone"))
            default: return Stub.json(Stub.user)
            }
        }
        await session.signIn(serverAddress: storedHost, token: "memos_pat_first")

        let renewal = await session.renewDeviceToken()
        #expect(renewal == .renewed)

        #expect(
            file.stored?.credentialFingerprint
                == CredentialFingerprint.of("memos_pat_successor"),
            "a file naming the predecessor would fail the NEXT launch's fingerprint check"
        )

        // And the next launch really does open on it.
        let relaunched = makeSession(credentials: credentials, file: file) { _, _, _ in
            throw offline()
        }
        await relaunched.restore()
        #expect(relaunched.state.user?.subject == "fabian")
    }

    @Test("a renewal whose persist throws leaves no identity, so the next launch asks")
    func renewalStorageFailureDeletesTheFile() async {
        let credentials = FlakyCredentials()
        let file = StubLastKnownUser()
        let session = makeSession(credentials: credentials, file: file) { _, _, operation in
            switch operation {
            case renewOperation: return Stub.json(Stub.exchange(token: "memos_pat_successor"))
            case tokenRowOperation: return Stub.json(Stub.nativeToken(name: "iPhone"))
            default: return Stub.json(Stub.user)
            }
        }
        await session.signIn(serverAddress: storedHost, token: "memos_pat_first")
        #expect(file.stored != nil)
        credentials.refuseWrites()

        _ = await session.renewDeviceToken()

        #expect(file.stored == nil)
    }

    @Test("a launch that finds no credential clears the identity beside the licence")
    func orphanFileIsReconciled() async {
        let account = SpyAccountStore()
        account.publish(AccountBinding(serverBaseURL: Stub.baseURL, ownerSubject: "fabian"))
        let file = boundFile()
        let session = makeSession(
            credentials: InMemoryCredentials(),
            file: file,
            account: account
        ) { _, _, _ in Stub.json(Stub.user) }

        await session.restore()

        #expect(account.published == nil)
        #expect(file.stored == nil, "an identity with no token behind it belongs to nobody")
    }

    @Test("signing out while unconfirmed keeps a credential the server would not take back")
    func signOutWhileUnverifiedKeepsTheCredential() async {
        let credentials = credentials()
        let file = boundFile()
        let answering = LockedValue<Bool>(false)
        let session = makeSession(credentials: credentials, file: file) { _, _, operation in
            guard answering.get() else { throw offline() }
            guard operation == logoutOperation else { return Stub.json(Stub.user) }
            return Stub.empty(.init(code: 500))
        }
        await session.restore()
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }

        answering.set(true)
        let outcome = await session.signOut()

        guard case .revokeFailed = outcome else {
            Issue.record("expected .revokeFailed, got \(outcome)")
            return
        }
        #expect(!credentials.isEmpty, "a token that is still live is not abandoned")
        #expect(file.stored != nil, "and neither is the identity it is bound to")
    }

    // MARK: - the invalidation fence

    /// R2: a wipe that STARTS while a check is in flight must publish nothing when that check
    /// comes back, and joining concurrent checks cannot cover it — a sign-out is a different
    /// operation from the validation it races.
    @Test("a wipe started mid-check makes that check's success publish nothing")
    func aWipeMidCheckPublishesNothing() async {
        let box = LockedValue<SessionStore?>(nil)
        let file = boundFile()
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: credentials(),
            file: file,
            account: account
        ) { _, _, _ in
            // The wipe COMPLETES before the answer goes back, which is the race: a sign-out is a
            // different operation from the check it interrupts, so nothing serialises them.
            if let session = box.get() { await session.signOutWithoutRevoking() }
            return Stub.json(Stub.user)
        }
        box.set(session)

        await session.restore()

        #expect(session.state == .signedOut)
        #expect(account.published == nil, "a success for a session that ended publishes nothing")
        #expect(file.stored == nil, "and writes no identity for it either")
    }

    /// The positive control for the case above: the SAME success, with nothing racing it, does
    /// publish and does write.
    @Test("the same success with nothing racing it publishes and writes")
    func theUnracedSuccessPublishes() async {
        let file = boundFile()
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: credentials(),
            file: file,
            account: account
        ) { _, _, _ in Stub.json(Stub.user) }

        await session.restore()

        #expect(account.published?.ownerSubject == "fabian")
        #expect(file.stored != nil)
    }
}

/// A server that answers whoami, the settings read and the native exchange — so a test can prove
/// a request really went out after a refusal.
private let answersEverything: StubTransport.Handler = { _, _, operation in
    switch operation {
    case settingsOperation:
        return Stub.json(#"{"default_visibility":"PUBLIC","theme":"dark","avatar":null}"#)
    case "native_exchange_api_auth_native_exchange_post":
        return Stub.json(Stub.exchange(token: "memos_pat_device"))
    default:
        return Stub.json(Stub.user)
    }
}

/// A sign-in this session REFUSED to start must leave the session it found exactly as it was —
/// including its ability to make requests.
///
/// The order in `persist` is what decides it. The synchronous refusal check comes first, and only
/// then is the incarnation ended and the client withdrawn: the other way round, a refusal would
/// hand `abandonSignIn` a session with no client, and the screen it put back would be a timeline
/// that could no longer read anything.
@MainActor
@Suite("A refused sign-in leaves a session that still works")
struct RefusedSignInTests {
    private let callbackURL = "https://memos.example.invalid/ios/auth/callback?code=handoff-123"

    private func makeSession(
        credentials: InMemoryCredentials,
        account: SpyAccountStore,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            account: account
        )
    }

    @Test("a pasted-token sign-in the licence refused leaves the session able to ask the server")
    func refusedPastedSignInKeepsAWorkingSession() async {
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: InMemoryCredentials(),
            account: account,
            handler: answersEverything
        )
        await session.signIn(serverAddress: storedHost, token: "memos_pat_a")
        #expect(session.state.user != nil)
        account.refuseNextClears(1)

        await session.signIn(serverAddress: storedHost, token: "memos_pat_b")

        #expect(session.lastError == SessionStore.licenceBlockedSignIn)
        #expect(session.state.user != nil, "nothing was written, so nothing was replaced")
        await session.loadSettings()
        #expect(
            session.defaultVisibility != nil,
            "a refusal that had withdrawn the client would leave a session that cannot read"
        )
    }

    @Test("a native sign-in the licence refused leaves the session able to ask the server")
    func refusedNativeSignInKeepsAWorkingSession() async {
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: InMemoryCredentials(),
            account: account,
            handler: answersEverything
        )
        await session.signIn(serverAddress: storedHost, token: "memos_pat_a")
        #expect(session.state.user != nil)
        account.refuseNextClears(1)

        let signedIn = await session.signInNatively(
            serverAddress: storedHost,
            deviceName: "Fabian's iPhone",
            presenter: StubPresenter(behaviour: .callback(callbackURL))
        )

        #expect(!signedIn)
        #expect(session.lastError == SessionStore.licenceBlockedSignIn)
        #expect(session.state.user != nil)
        await session.loadSettings()
        #expect(
            session.defaultVisibility != nil,
            "a refusal that had withdrawn the client would leave a session that cannot read"
        )
    }
}
