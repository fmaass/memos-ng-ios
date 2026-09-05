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

/// SHA-256 of the tokens these suites use, computed OUTSIDE this app.
///
/// `CredentialFingerprint.of` is the thing under test wherever a file's binding matters; asking it
/// for the expected value would only prove it agrees with itself. These come from
/// `printf '%s' <token> | sha256sum`.
private let storedTokenDigest =
    "5d2a365dd73d07176c16a36d32cdcd04f11bbdc5f78484b8a9828003a5d1fa65"
private let firstTokenDigest = "6ecd928668c00c27e3331ea8766db560545fea862ee6292b668e8549748b0a1c"
private let successorTokenDigest =
    "448fef6e89c704541eb6fc5db4b20742bad99ab2f40d608de6e91a6add1685bb"
private let freshTokenDigest = "01d0ff22c1e4a04f8258805d136fe55d96c14ee83c3248a0694809bda4a3bf79"
private let renewedTokenDigest = "ae70f29131b473c0d593fee213ffda42de1c10f9568308512817c87d0f431e58"

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

    /// - Parameter fingerprint: the literal digest for the default token, so a launch that admits
    ///   proves the store's own hasher produced THAT value rather than merely agreeing with
    ///   itself. The `token:` form is for the cases that want a deliberately different one.
    private func boundFile(
        subject: String = "fabian",
        server: String = storedAddress,
        token: String? = nil,
        fingerprint: String = storedTokenDigest
    ) -> StubLastKnownUser {
        StubLastKnownUser(
            LastKnownUser(
                subject: subject,
                displayName: "Fabian",
                email: "f@example.invalid",
                role: "admin",
                authKind: "oidc",
                serverBaseURL: server,
                credentialFingerprint: token.map(CredentialFingerprint.of) ?? fingerprint
            )
        )
    }

    private func makeSession(
        credentials: any CredentialStore,
        file: (any LastKnownUserStoring)? = nil,
        account: SpyAccountStore? = nil,
        identity: MediaIdentity = MediaIdentity(),
        sleeper: RetryLadderSleeper = RetryLadderSleeper(),
        onVerified: (@MainActor @Sendable () -> Void)? = nil,
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
        await session.enteredForeground()

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
            await session.enteredForeground()

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
        await session.enteredForeground()

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
        await session.enteredForeground()

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
        await session.enteredForeground()

        session.enteredBackground()
        await session.restore()

        #expect(sleeper.recorded.isEmpty, "a phone in a pocket has nobody to show an answer to")
    }

    /// B6. A process the system woke to finish an upload has no scene at all. Nothing here has
    /// ever reported itself active, so nothing may schedule a ladder against a window that does
    /// not exist — the default has to be "no scene", not "in front of somebody".
    @Test("a headless launch schedules no retries at all")
    func aHeadlessLaunchSchedulesNothing() async {
        let sleeper = RetryLadderSleeper(stoppingAfter: 4)
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            sleeper: sleeper
        ) { _, _, _ in throw offline() }

        await session.restore()
        await settle(until: { !sleeper.recorded.isEmpty }, turns: 40)

        #expect(session.state.user != nil, "the launch still opened the app for the outbox")
        #expect(sleeper.recorded.isEmpty, "and asked for no ladder behind a window nobody has")
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
            file.stored?.credentialFingerprint == freshTokenDigest,
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
                == renewedTokenDigest,
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

    /// B5. The renewal moves the token while the LAUNCH CHECK is in the air. The 200 that lands
    /// names the PREDECESSOR, and writing its fingerprint would name a token the server destroyed
    /// in the same statement that minted the one this device now holds — so the next launch would
    /// decline to admit a device that did everything right.
    @Test("a check answered for a replaced credential does not rewrite the fingerprint")
    func aStaleSuccessKeepsTheSuccessorsFingerprint() async throws {
        let vault = FlakyCredentials()
        try await vault.set(storedToken, for: SessionStore.tokenAccount)
        try await vault.set(storedAddress, for: SessionStore.serverAccount)
        let file = boundFile()
        let box = LockedValue<SessionStore?>(nil)
        let renewing = LockedValue<Bool>(true)
        let session = makeSession(credentials: vault, file: file) { _, _, operation in
            switch operation {
            case renewOperation: return Stub.json(Stub.exchange(token: "pat-successor"))
            case tokenRowOperation: return Stub.json(Stub.nativeToken(name: "iPhone"))
            default:
                // The rotation happens WHILE the launch check is on the wire, so the 200 below is
                // an answer about a token that no longer exists by the time it lands.
                if renewing.get(), let session = box.get() {
                    renewing.set(false)
                    _ = await session.renewDeviceToken()
                }
                return Stub.json(Stub.user)
            }
        }
        box.set(session)

        await session.restore()

        let stored = try #require(file.stored)
        #expect(
            stored.credentialFingerprint == successorTokenDigest,
            "a stale 200 rewrote the file with a token the server had already destroyed"
        )
        #expect(session.state.user != nil, "and the session itself is untouched by it")
    }

    /// B2. The revoke is a request, and A's 204 for it can land after B has signed in. Unfenced,
    /// A's sign-out destroys B's credential — the app's most destructive single act, performed for
    /// an account nobody is signed in as.
    @Test("a sign-out answered after somebody else signed in does not wipe them")
    func aStaleSignOutDoesNotWipeTheSuccessor() async {
        let box = LockedValue<SessionStore?>(nil)
        let switching = LockedValue<Bool>(false)
        let credentials = InMemoryCredentials()
        let session = makeSession(credentials: credentials, file: StubLastKnownUser()) {
            _, _, operation in
            guard operation == logoutOperation else { return Stub.json(Stub.user) }
            // B signs in while A's revoke is on the wire.
            if switching.get(), let session = box.get() {
                switching.set(false)
                await session.signIn(serverAddress: storedHost, token: "pat-b")
            }
            return Stub.empty(.noContent)
        }
        box.set(session)
        await session.signIn(serverAddress: storedHost, token: "pat-a")

        switching.set(true)
        _ = await session.signOut()

        #expect(session.state.user != nil, "A's revoke ended the session that replaced it")
        #expect(session.credentialGrant()?.token == "pat-b")
        #expect(!credentials.isEmpty, "and threw away a credential that was never A's")
    }

    /// N1. A restored session's replacement check must REPLACE the flight the restore
    /// invalidated, not join it. Joined, the caller waits on an occupant whose own generation
    /// guard makes it write nothing, and the session stays `.verifying` with no request out.
    @Test("a replacement validation does not join the flight it supersedes")
    func aReplacementDoesNotJoinASupersededFlight() async {
        let calls = Counter()
        let holding = LockedValue<Bool>(true)
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            account: account,
            // The replacement is SCHEDULED, so this suite's default sleeper — which stops the
            // ladder at its first wait — would take the very thing under test away.
            sleeper: RetryLadderSleeper(stoppingAfter: 3)
        ) { _, _, _ in
            calls.increment()
            // The launch check is HELD, so the flight is occupied when the session moves.
            if calls.count == 1 {
                for _ in 0..<5000 where holding.get() { await Task.yield() }
            }
            return Stub.json(Stub.user)
        }
        await session.enteredForeground()
        let launch = Task { await session.restore() }
        await settle(until: { calls.count == 1 })
        #expect(session.verification == .verifying, "the premise: a check is out and unanswered")

        // A switch the licence refuses: the session is put back, its generation moves, and the
        // check in flight can no longer answer for it.
        account.refuseNextClears(1)
        await session.signIn(serverAddress: storedHost, token: "memos_pat_b")
        await settle(until: { session.verification == .verified })

        #expect(session.lastError == SessionStore.licenceBlockedSignIn, "the switch was refused")
        #expect(
            session.verification == .verified,
            "the replacement joined the flight it superseded and asked nobody anything"
        )
        holding.set(false)
        await launch.value
    }

    /// R-B5. A sign-in whose write threw keeps working from memory and deletes the file. Its
    /// credential epoch never moves, so a later revalidation matches it — and would put the file
    /// back for a token storage may not hold. The proof of a WRITE is a different fact from the
    /// identity of the credential, and only one of them is what the file needs.
    @Test("a revalidation does not re-create a file an unproven write deleted")
    func revalidationDoesNotResurrectAnUnprovenFile() async {
        let file = boundFile()
        let session = makeSession(credentials: RefusingCredentials(), file: file) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: storedHost, token: "memos_pat_fresh")
        #expect(session.state.user != nil, "the session works from memory; that is the premise")
        #expect(file.stored == nil, "and the unproven write took the file with it")

        session.noteTransportFailure(.offline, issuedUnder: session.activeHandle?.generation ?? -1)
        await session.enteredForeground()

        #expect(session.verification == .verified, "the revalidation really did succeed")
        #expect(file.stored == nil, "and still wrote no file for a credential never written down")
    }

    /// R-N1. A refused switch puts back a `.verifying` session — and the bump that keeps
    /// pre-attempt answers from becoming current also makes the check in flight exit. Restoring
    /// the STATE without restoring the lifecycle strands it there for ever.
    @Test("a refused switch over an unconfirmed session does not strand it")
    func aRefusedSwitchOverAnUnconfirmedSessionAsksAgain() async {
        let answering = LockedValue<Bool>(false)
        let sleeper = RetryLadderSleeper(stoppingAfter: 3)
        let account = SpyAccountStore()
        let session = makeSession(
            credentials: credentials(),
            file: boundFile(),
            account: account,
            sleeper: sleeper
        ) { _, _, _ in
            guard answering.get() else { throw offline() }
            return Stub.json(Stub.user)
        }
        await session.enteredForeground()
        await session.restore()
        guard case .unverified = session.verification else {
            Issue.record("expected .unverified, got \(session.verification)")
            return
        }

        account.refuseNextClears(1)
        answering.set(true)
        await session.signIn(serverAddress: storedHost, token: "memos_pat_b")
        await settle(until: { session.verification == .verified })

        #expect(session.lastError == SessionStore.licenceBlockedSignIn, "the switch was refused")
        #expect(
            session.verification == .verified,
            "a session put back unconfirmed with nothing running is stranded there"
        )
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

/// Two sign-ins are two intents, and a session has one identity.
@MainActor
@Suite("A sign-in is single-flight")
struct SignInSingleFlightTests {
    /// A third sign-in completing while a second was in flight is what let a state belonging to
    /// the FIRST account be put back beside a client belonging to the third. Refused rather than
    /// joined: the second caller wants a different token, possibly a different account, and
    /// handing it the first one's answer would be a lie about which account it is now signed in as.
    @Test("a sign-in that arrives while one is running is refused, with nothing sent")
    func aSecondSignInIsRefused() async {
        let calls = Counter()
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in
                    calls.increment()
                    entered.set(true)
                    // BOUNDED. Under the mutation that removes the refusal, the second sign-in
                    // reaches this too and nothing would ever release it — a test that HANGS
                    // instead of failing proves nothing and takes the suite with it.
                    for _ in 0..<5000 where !release.get() { await Task.yield() }
                    return Stub.json(Stub.user)
                }
            }
        )

        let first = Task { await session.signIn(serverAddress: storedHost, token: "pat-a") }
        for _ in 0..<5000 where !entered.get() { await Task.yield() }
        #expect(entered.get(), "the premise: the first sign-in is on the wire")
        await session.signIn(serverAddress: storedHost, token: "pat-b")
        let refusedAt = calls.count
        release.set(true)
        await first.value

        #expect(refusedAt == 1, "the second sign-in put nothing on the wire")
        #expect(session.credentialGrant()?.token == "pat-a", "the first one is what landed")
    }

    /// The other half: a sign-in the licence REFUSED puts the whole session back, not pieces of
    /// it. The grant is read as one value, so a subject from one account beside a token from
    /// another is a state this assertion can see.
    @Test("a refused switch puts back a session whose subject and token still belong together")
    func aRefusedSwitchRestoresOneSession() async throws {
        let account = SpyAccountStore()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            account: account
        )
        await session.signIn(serverAddress: storedHost, token: "pat-a")
        let before = try #require(session.credentialGrant())
        account.refuseNextClears(1)

        await session.signIn(serverAddress: storedHost, token: "pat-b")

        #expect(session.lastError == SessionStore.licenceBlockedSignIn)
        let after = try #require(session.credentialGrant())
        #expect(after.subject == before.subject)
        #expect(after.token == before.token, "A's subject beside B's token is the state to prevent")
        #expect(after.serverBaseURL == before.serverBaseURL)
    }
}

/// Nothing an installation or a check does may land on a session that ended inside its await.
@MainActor
@Suite("Invalidate-first fences the whole operation")
struct InvalidationFenceTests {
    /// B2. The wipe starts while the credential is being STORED — inside `persist`'s own await —
    /// so the sign-in resumes into a session that is already over.
    @Test("a wipe started mid-installation leaves nothing of that installation behind")
    func aWipeMidInstallationLandsNothing() async {
        let box = LockedValue<SessionStore?>(nil)
        let file = StubLastKnownUser()
        let account = SpyAccountStore()
        let restarts = Counter()
        let credentials = WipingCredentials { await box.get()?.signOutWithoutRevoking() }
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            account: account,
            lastKnownUser: file,
            onVerified: { restarts.increment() }
        )
        box.set(session)

        await session.signIn(serverAddress: storedHost, token: "pat-a")

        #expect(session.state == .signedOut)
        #expect(file.stored == nil, "no identity was written for a session that had ended")
        #expect(account.published == nil, "and no licence was published for it")
        #expect(restarts.count == 0, "and no drain was started on its behalf")
        #expect(session.credentialGrant() == nil, "and no authority was left behind for one")
    }

    /// R-B2(a). The sign-out completes while the sign-in is waiting on `whoami`. The sign-in then
    /// resumes and would persist and establish a credential for a session somebody ended — and its
    /// own `persist` mints a fresh generation, so a check against THAT number cannot see it.
    @Test("a sign-in overtaken by a sign-out installs nothing")
    func aSignInOvertakenBySignOutInstallsNothing() async {
        let box = LockedValue<SessionStore?>(nil)
        let file = StubLastKnownUser()
        let account = SpyAccountStore()
        let credentials = InMemoryCredentials()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in
                    // The sign-out lands INSIDE the whoami this sign-in is waiting on.
                    if let session = box.get() { await session.signOutWithoutRevoking() }
                    return Stub.json(Stub.user)
                }
            },
            account: account,
            lastKnownUser: file
        )
        box.set(session)

        await session.signIn(serverAddress: storedHost, token: "pat-a")

        #expect(session.state == .signedOut, "the sign-out is what the session ended as")
        #expect(session.credentialGrant() == nil)
        #expect(account.published == nil, "no licence for a session nobody asked for")
        #expect(file.stored == nil)
        #expect(credentials.isEmpty, "and nothing of it was written down")
    }

    /// R-B2(b), the other ordering. The wipe awaits its keychain delete; a sign-in completes
    /// inside that await and owns the session. The wipe's tail would otherwise clear the NEW
    /// session's configuration and settings and assign `.signedOut` over it.
    @Test("a sign-out overtaken by a sign-in does not clear the session it found")
    func aSignOutOvertakenBySignInLeavesItAlone() async {
        let box = LockedValue<SessionStore?>(nil)
        let signingIn = LockedValue<Bool>(false)
        let credentials = InterruptingCredentials {
            guard let session = await box.get(), signingIn.get() else { return }
            signingIn.set(false)
            await session.signIn(serverAddress: storedHost, token: "pat-b")
        }
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            }
        )
        box.set(session)
        await session.signIn(serverAddress: storedHost, token: "pat-a")
        #expect(session.state.user != nil)

        signingIn.set(true)
        await session.signOutWithoutRevoking()

        #expect(session.state.user != nil, "the sign-in that landed inside the delete owns this")
        #expect(session.credentialGrant()?.token == "pat-b")
        #expect(session.serverBaseURL != nil, "the wipe's tail cleared the wrong session")
    }

}

/// A credential store that lets something else happen in the middle of its DELETE.
final class InterruptingCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let duringRemove: @Sendable () async -> Void

    init(duringRemove: @escaping @Sendable () async -> Void) {
        self.duringRemove = duringRemove
    }

    func set(_ value: String, for account: String) async throws {
        lock.withLock { storage[account] = value }
    }

    func string(for account: String) async throws -> String? { lock.withLock { storage[account] } }

    func remove(_ account: String) async throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }

    func removeAll(_ accounts: [String]) async throws {
        await duringRemove()
        lock.withLock { for account in accounts { storage[account] = nil } }
    }
}

/// A credential store that lets somebody sign out in the middle of the write.
final class WipingCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let duringWrite: @Sendable () async -> Void
    private var fired = false

    init(duringWrite: @escaping @Sendable () async -> Void) {
        self.duringWrite = duringWrite
    }

    func setAll(_ values: [String: String]) async throws {
        let first: Bool = lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
        if first { await duringWrite() }
        lock.withLock { for (k, v) in values { storage[k] = v } }
    }

    func set(_ value: String, for account: String) async throws {
        lock.withLock { storage[account] = value }
    }

    func string(for account: String) async throws -> String? { lock.withLock { storage[account] } }

    func remove(_ account: String) async throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }
}
