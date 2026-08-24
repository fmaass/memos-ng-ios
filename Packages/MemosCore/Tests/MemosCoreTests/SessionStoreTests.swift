import Foundation
import MemosAPI
import MemosCore
import MemosOutbox
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let whoamiOperation = "whoami_api_auth_user_get"
private let nativeLogoutOperation = "native_logout_api_auth_native_logout_post"

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

/// What the app published about the signed-in account — which is everything a share extension
/// will ever know about it, since it has no session and no credential of its own.
final class SpyAccountStore: OutboxAccountPublishing, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AccountBinding?
    private var clears = 0

    func publish(_ binding: AccountBinding) { lock.withLock { value = binding } }

    func clear() {
        lock.withLock {
            value = nil
            clears += 1
        }
    }

    var current: AccountBinding? { lock.withLock { value } }
    var clearCount: Int { lock.withLock { clears } }
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
        #expect(account.current == nil)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(
            account.current
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

        #expect(account.current?.ownerSubject == "fabian")
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
        #expect(account.current?.ownerSubject == "fabian")
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
        #expect(account.current != nil)

        await session.signOut()

        #expect(account.current == nil)
        #expect(account.clearCount == 1)
    }

    @Test("a 401 anywhere clears it as well — the extension must not queue for a dead account")
    func unauthorizedClearsTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.user) }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(account.current != nil)

        await session.handle(.unauthorized)

        #expect(account.current == nil)
    }
}
