import Foundation
import MemosAPI
import MemosCore
import MemosOutbox
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let whoamiOperation = "whoami_api_auth_user_get"
private let nativeLogoutOperation = "native_logout_api_auth_native_logout_post"
private let settingsOperation = "get_settings_api_settings_get"

@MainActor
@Suite("SessionStore")
struct SessionStoreTests {
    private func store(
        credentials: InMemoryCredentials,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
    }

    @Test("a valid token is validated against /api/auth/user and then stored")
    func signInStoresValidatedToken() async {
        let credentials = InMemoryCredentials()
        let seenAuthorization = LockedValue<String?>(nil)
        let session = store(credentials: credentials) { request, _, _ in
            seenAuthorization.set(request.headerFields[.authorization])
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(session.state.user?.subject == "fabian")
        #expect(seenAuthorization.get() == "Bearer memos_pat_good")
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_good")
        #expect(
            credentials.snapshot()[SessionStore.serverAccount] == "https://memos.example.invalid"
        )
    }

    @Test("a rejected token is never stored and leaves the app signed out")
    func signInRejects401() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, _ in Stub.empty(.unauthorized) }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_revoked")

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
        #expect(session.lastError != nil)
    }

    @Test("a plain-http address is refused before anything is sent")
    func refusesInsecureServer() async {
        let credentials = InMemoryCredentials()
        let calls = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            calls.increment()
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "http://memos.example.invalid", token: "memos_pat_x")

        #expect(calls.count == 0)
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("an empty token is refused before anything is sent")
    func refusesEmptyToken() async {
        let credentials = InMemoryCredentials()
        let calls = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            calls.increment()
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "   ")

        #expect(calls.count == 0)
        #expect(session.state == .signedOut)
    }

    @Test("sign-out revokes the presenting token and wipes the credential")
    func signOutRevokes() async {
        let credentials = InMemoryCredentials()
        let operations = LockedValue<[String]>([])
        let session = store(credentials: credentials) { _, _, operation in
            operations.set(operations.get() + [operation])
            return operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        await session.signOut()

        #expect(operations.get().contains(nativeLogoutOperation))
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("a failed revoke keeps the credential and says so")
    func signOutKeepsCredentialWhenRevokeFails() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation
                ? Stub.json(Stub.user)
                : Stub.empty(.internalServerError)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let outcome = await session.signOut()

        // The revoke never reached the server, so the token is still live out there — wiping the
        // only copy the app tracks would abandon it, signed out in appearance only.
        #expect(outcome.failureDescription != nil)
        #expect(session.state != .signedOut)
        #expect(!credentials.isEmpty, "a live token must stay tracked until its fate is settled")

        // The person can still decide otherwise, in the open.
        session.signOutWithoutRevoking()
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("a revoke that never left the device also keeps the credential")
    func signOutKeepsCredentialWhenTransportThrows() async {
        struct Offline: Error {}
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            guard operation == whoamiOperation else { throw Offline() }
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let outcome = await session.signOut()

        // Same rule as the 5xx case, different road there: the request THREW before any server
        // verdict existed, which says even less about the token than a 500 does.
        #expect(outcome.failureDescription != nil)
        #expect(session.state != .signedOut)
        #expect(!credentials.isEmpty)
    }

    @Test("a stored credential is re-validated at launch, not trusted")
    func restoreRevalidates() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stale", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)

        let session = store(credentials: credentials) { _, _, _ in Stub.empty(.unauthorized) }
        await session.restore()

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("a stored credential that still works signs the app back in")
    func restoreSucceeds() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)

        let session = store(credentials: credentials) { _, _, _ in Stub.json(Stub.user) }
        await session.restore()

        #expect(session.state.user?.subject == "fabian")
    }

    @Test("an unauthorized error anywhere ends the session")
    func unauthorizedSignsOut() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(session.state.user != nil)

        await session.handle(.unauthorized)

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }
}

/// A tiny box so a `@Sendable` closure can record what it saw.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

extension SessionStoreTests {
    @Test("an unreachable server parks the session instead of inviting a second sign-in")
    func restoreParksWhenUnreachable() async {
        struct Offline: Error {}
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)

        let session = store(credentials: credentials) { _, _, _ in throw Offline() }
        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
        #expect(!credentials.isEmpty, "an unconfirmed token is kept for the retry")
    }
}

/// The order two stores were written in, which is the only thing that says what an interruption
/// between them would have left behind.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ event: String) { lock.withLock { entries.append(event) } }
    func reset() { lock.withLock { entries = [] } }
    var events: [String] { lock.withLock { entries } }
}

/// What the app published about the signed-in account — which is everything a share extension
/// will ever know about it, since it has no session and no credential of its own.
final class SpyAccountStore: OutboxAccountPublishing, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var value: AccountBinding?
    private var clears = 0
    private var refusals: Int
    private let log: EventLog?

    /// - Parameter refusingClears: how many revocations fail before one succeeds — a file that
    ///   will not delete, which is the failure the session has to survive without going silent.
    init(log: EventLog? = nil, refusingClears: Int = 0) {
        self.log = log
        self.refusals = refusingClears
    }

    func current() -> AccountBinding? { lock.withLock { value } }

    func publish(_ binding: AccountBinding) {
        lock.withLock { value = binding }
        log?.record("licence.publish")
    }

    func clear() throws {
        let refuse: Bool = lock.withLock {
            guard refusals > 0 else { return false }
            refusals -= 1
            return true
        }
        if refuse {
            log?.record("licence.clear.failed")
            throw Refused()
        }
        lock.withLock {
            value = nil
            clears += 1
        }
        log?.record("licence.clear")
    }

    /// Aims the refusal at a particular moment — signing IN revokes the outgoing licence too, so
    /// a count fixed at construction would fail the wrong one.
    func refuseNextClears(_ count: Int) { lock.withLock { refusals = count } }

    var published: AccountBinding? { lock.withLock { value } }
    var clearCount: Int { lock.withLock { clears } }
}

/// The credential store, with every write it is asked for written down in the same log as the
/// licence's — so a test can assert which of the two went first.
final class RecordingCredentials: CredentialStore, @unchecked Sendable {
    private let inner = InMemoryCredentials()
    private let log: EventLog

    init(log: EventLog) { self.log = log }

    func set(_ value: String, for account: String) throws {
        try inner.set(value, for: account)
        log.record("credential.set")
    }

    func string(for account: String) throws -> String? { try inner.string(for: account) }

    func remove(_ account: String) throws {
        try inner.remove(account)
        log.record("credential.remove")
    }

    func snapshot() -> [String: String] { inner.snapshot() }
    var isEmpty: Bool { inner.isEmpty }
}

/// The account the share extension binds a capture to is published by the session, because the
/// owner's subject exists nowhere else on the device: the keychain holds a token and a server
/// address, and the subject comes back from the server.
extension SessionStoreTests {
    private func store(
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

    @Test("signing in publishes the server and the owner a shared capture is bound to")
    func signInPublishesTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.user) }
        #expect(account.published == nil)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(
            account.published
                == AccountBinding(
                    serverBaseURL: URL(string: "https://memos.example.invalid")!,
                    ownerSubject: "fabian"
                )
        )
    }

    @Test("a restored session publishes it too, so an update does not silence the extension")
    func restorePublishesTheAccount() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }

        await session.restore()

        #expect(account.published?.ownerSubject == "fabian")
    }

    @Test("the browser-brokered sign-in publishes the same account as a pasted token")
    func nativeSignInPublishesTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.exchange(token: "memos_pat_device")) }

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: StubPresenter(
                behaviour: .callback(
                    "https://memos.example.invalid/ios/auth/callback?code=handoff-123"
                )
            ),
            pkce: PKCE()
        )

        #expect(session.state.user?.subject == "fabian")
        #expect(session.serverBaseURL?.absoluteString == "https://memos.example.invalid")
        #expect(account.published?.ownerSubject == "fabian")
    }

    @Test("signing out revokes the extension's account in the same breath as the token")
    func signOutClearsTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(account.published != nil)

        await session.signOut()

        #expect(account.published == nil)
        #expect(
            account.clearCount == 2,
            "signing in revokes the outgoing licence and signing out revokes this one"
        )
    }

    @Test("a 401 anywhere clears it as well — the extension must not queue for a dead account")
    func unauthorizedClearsTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.user) }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(account.published != nil)

        await session.handle(.unauthorized)

        #expect(account.published == nil)
    }
}

/// The licence and the credential are two writes to two places, and a phone can die between any
/// two writes. What matters is not that the pair is always consistent — it cannot be — but that
/// every interruption leaves the state where the share extension REFUSES, never one where it
/// enqueues under an identity that has been revoked or replaced.
@MainActor
@Suite("The account licence, interrupted")
struct AccountLicenceOrderTests {
    private func store(
        credentials: any CredentialStore,
        account: SpyAccountStore,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            account: account
        )
    }

    @Test("signing out revokes the licence BEFORE the credential it belongs to")
    func revokesLicenceFirst() async {
        let log = EventLog()
        let credentials = RecordingCredentials(log: log)
        let account = SpyAccountStore(log: log)
        let session = store(credentials: credentials, account: account) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        log.reset()

        await session.signOut()

        let events = log.events
        #expect(events.first == "licence.clear")
        #expect(
            events == ["licence.clear", "credential.remove", "credential.remove"],
            "credential-then-licence would leave a revoked identity still able to queue"
        )
        #expect(account.published == nil)
        #expect(credentials.isEmpty)
    }

    @Test("switching accounts revokes the old licence, stores the credential, then publishes")
    func replacementOrderDeniesRatherThanMisleads() async {
        let log = EventLog()
        let credentials = RecordingCredentials(log: log)
        let account = SpyAccountStore(log: log)
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")
        log.reset()

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        #expect(
            log.events == [
                "licence.clear", "credential.set", "credential.set", "licence.publish",
            ],
            "every prefix of this sequence is a state with NO licence, which denies the extension"
        )
    }

    @Test("a licence that will not delete is said out loud, not swallowed")
    func revocationFailureIsVisible() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        account.refuseNextClears(1)

        let outcome = await session.signOut()

        #expect(outcome == .revoked, "a file that will not delete must not keep a live token")
        #expect(credentials.isEmpty)
        #expect(account.published != nil, "the licence really is still there")
        #expect(
            session.lastError?.contains("could not be removed") == true,
            "silence here is a revoked identity that can still queue captures"
        )
    }

    @Test("the next launch retries a revocation that failed, because the credential is gone")
    func restoreRetriesAFailedRevocation() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let signingOut = store(credentials: credentials, account: account) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await signingOut.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        account.refuseNextClears(1)
        await signingOut.signOut()
        #expect(account.published != nil)

        // A fresh process over the same two stores: the credential is gone, the licence is not.
        let relaunched = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await relaunched.restore()

        #expect(
            account.published == nil,
            "a licence with no credential behind it belongs to nobody"
        )
    }

    @Test("a licence naming another server is revoked before the credential is even validated")
    func restoreDeniesAMismatchedLicence() async {
        struct Offline: Error {}
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        account.publish(
            AccountBinding(
                serverBaseURL: URL(string: "https://other.example.invalid")!,
                ownerSubject: "someone"
            )
        )

        let session = store(credentials: credentials, account: account) { _, _, _ in
            throw Offline()
        }
        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
        #expect(
            account.published == nil,
            "an unreachable server is no reason to keep licensing the account being replaced"
        )
        #expect(!credentials.isEmpty, "the credential itself is still not evidence of anything")
    }

    @Test("a credential with no licence gets one again as soon as the server says whose it is")
    func restoreHealsAMissingLicence() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        #expect(account.published == nil)

        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.restore()

        #expect(
            account.published
                == AccountBinding(
                    serverBaseURL: URL(string: "https://memos.example.invalid")!,
                    ownerSubject: "fabian"
                )
        )
    }
}

extension AccountLicenceOrderTests {
    /// Swapping accounts on the SAME server is the case nothing downstream can catch: `restore`
    /// compares server addresses, and only the server knows whose a credential is. So a refused
    /// revocation has to stop the sign-in where it stands rather than carry on and hope.
    @Test("a licence that will not go stops the sign-in and changes nothing at all")
    func refusedRevocationAbortsSignIn() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")
        let credentialsBefore = credentials.snapshot()
        let licenceBefore = account.published
        #expect(licenceBefore != nil)

        account.refuseNextClears(1)
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        #expect(
            credentials.snapshot() == credentialsBefore,
            "the new credential must not be stored while the old licence is still standing"
        )
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_a")
        #expect(
            account.published == licenceBefore,
            "and the old licence is untouched, not half-replaced"
        )
        #expect(session.state.user != nil, "the session is left exactly as the sign-in found it")
        #expect(
            session.lastError?.contains("Try signing in again") == true,
            "a sign-in that changed nothing has to say so, or it looks like it worked"
        )
    }

    @Test("the browser-brokered sign-in aborts on the same refusal, and reports it")
    func refusedRevocationAbortsNativeSignIn() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, operation in
            // Two operations, two answers: the first sign-in is what establishes the account this
            // test then proves untouched, so its whoami cannot be answered with an exchange.
            operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")
        let credentialsBefore = credentials.snapshot()
        let licenceBefore = account.published
        #expect(credentialsBefore[SessionStore.tokenAccount] == "memos_pat_a")
        #expect(licenceBefore != nil)

        account.refuseNextClears(1)
        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: StubPresenter(
                behaviour: .callback(
                    "https://memos.example.invalid/ios/auth/callback?code=handoff-123"
                )
            ),
            pkce: PKCE()
        )

        #expect(!signedIn, "the caller has to learn that nothing happened")
        #expect(credentials.snapshot() == credentialsBefore)
        #expect(account.published == licenceBefore)
        #expect(session.lastError?.contains("Try signing in again") == true)
    }

    @Test("a sign-in whose licence WAS revoked still goes through")
    func revocationThatWorksDoesNotBlockASignIn() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_b")
        #expect(account.published?.ownerSubject == "fabian")
        #expect(session.lastError == nil)
    }
}

/// What "Default" means in the compose sheet is the ACCOUNT's setting, and until this the app
/// never asked for it — the pill said "Default" and left the reader to guess whether that meant
/// their memo would be private or public.
@MainActor
@Suite("The account's default visibility")
struct SessionSettingsTests {
    private func signedIn(
        handler: @escaping StubTransport.Handler
    ) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    @Test("the default is read from /api/settings and kept")
    func settingsAreRead() async {
        let asked = LockedValue<Bool>(false)
        let session = await signedIn { _, _, operation in
            if operation == settingsOperation {
                asked.set(true)
                return Stub.json(
                    """
                    {"default_visibility":"PROTECTED","theme":"dark","avatar":null}
                    """
                )
            }
            return Stub.json(Stub.user)
        }
        // Nothing is assumed before the server has answered.
        #expect(session.defaultVisibility == nil)

        await session.loadSettings()

        #expect(asked.get())
        #expect(session.defaultVisibility == .protected)
    }

    @Test("each visibility the server can name round-trips")
    func everyVisibilityIsUnderstood() async {
        for (wire, expected) in [
            ("PRIVATE", MemoVisibility.private),
            ("PROTECTED", .protected),
            ("PUBLIC", .public),
        ] {
            let session = await signedIn { _, _, operation in
                operation == settingsOperation
                    ? Stub.json(
                        "{\"default_visibility\":\"\(wire)\",\"theme\":\"d\",\"avatar\":null}"
                    )
                    : Stub.json(Stub.user)
            }
            await session.loadSettings()
            #expect(session.defaultVisibility == expected)
        }
    }

    /// The pill is allowed to say less. It is not allowed to say something wrong, and it is not
    /// allowed to take the screen down with it: this call sits on the timeline's appearance path.
    @Test("a server that will not answer leaves the default unnamed, not invented")
    func aFailedFetchIsSurvivable() async {
        let session = await signedIn { _, _, operation in
            operation == settingsOperation ? Stub.empty(.internalServerError) : Stub.json(Stub.user)
        }
        await session.loadSettings()
        #expect(session.defaultVisibility == nil)
        // The session itself is untouched — a settings failure is not a sign-out.
        #expect(session.state.user?.subject == "fabian")
        #expect(session.lastError == nil)
    }

    /// One account's setting must never be shown to the next one.
    @Test("signing out forgets the account's default")
    func theDefaultDoesNotOutliveTheAccount() async {
        let session = await signedIn { _, _, operation in
            operation == settingsOperation
                ? Stub.json("{\"default_visibility\":\"PUBLIC\",\"theme\":\"d\",\"avatar\":null}")
                : Stub.json(Stub.user)
        }
        await session.loadSettings()
        #expect(session.defaultVisibility == .public)

        session.signOutWithoutRevoking()

        #expect(session.defaultVisibility == nil)
    }
}
