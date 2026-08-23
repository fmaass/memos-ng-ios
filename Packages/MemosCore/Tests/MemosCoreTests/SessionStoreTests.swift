import Foundation
import MemosAPI
import MemosCore
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

    @Test("sign-out wipes the credential even when the revoke call fails")
    func signOutWipesOnFailure() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation
                ? Stub.json(Stub.user)
                : Stub.empty(.internalServerError)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        await session.signOut()

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty, "a device that thinks it is signed out must hold no token")
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
