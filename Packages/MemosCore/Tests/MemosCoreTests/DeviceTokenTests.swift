import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let tokenReadOperation = "native_token_api_auth_native_token_get"
private let tokenRenameOperation = "rename_native_token_api_auth_native_token_patch"
private let tokenRenewOperation = "native_renew_api_auth_native_renew_post"
private let whoamiOperation = "whoami_api_auth_user_get"

/// One request as the transport saw it: which operation, and what credential it presented.
///
/// The credential is the point. A renewal that swapped the token everywhere EXCEPT in the
/// middleware would leave a Keychain a test could inspect and be perfectly happy with, while the
/// phone carried on presenting a token the server has already destroyed. So every assertion about
/// the swap is made against the header a request actually carried.
private struct SeenRequest: Sendable {
    let operation: String
    let authorization: String?
}

@MainActor
@Suite("The device token this phone is holding")
struct DeviceTokenTests {
    private func session(
        credentials: any CredentialStore,
        seen: LockedValue<[SeenRequest]>,
        handler: @escaping @Sendable (String) async throws -> HTTPResponseLike
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { request, _, operation in
                    seen.set(
                        seen.get()
                            + [
                                SeenRequest(
                                    operation: operation,
                                    authorization: request.headerFields[.authorization]
                                )
                            ]
                    )
                    return try await handler(operation).parts
                }
            }
        )
    }

    /// Signs in with `memos_pat_first` so that every test below starts from a real session holding
    /// a real credential — the state a renewal has to move from.
    private func signedIn(
        credentials: any CredentialStore,
        seen: LockedValue<[SeenRequest]>,
        handler: @escaping @Sendable (String) async throws -> HTTPResponseLike
    ) async -> SessionStore {
        let store = session(credentials: credentials, seen: seen, handler: handler)
        await store.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_first")
        return store
    }

    private func date(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    // MARK: - reading the row

    @Test("the row is read from the presenting token, and carries what the server said about it")
    func readsItsOwnRow() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenReadOperation:
                .json(
                    Stub.nativeToken(
                        name: "Fabian's iPhone",
                        createdAt: "2026-08-01T09:00:00Z",
                        lastUsed: "2026-08-27T09:00:00Z",
                        expiresAt: "2027-08-01T09:00:00Z"
                    )
                )
            default: .status(.internalServerError)
            }
        }

        await store.loadDeviceToken()

        let token = try #require(store.deviceToken)
        #expect(token.name == "Fabian's iPhone")
        #expect(token.createdAt == date("2026-08-01T09:00:00Z"))
        #expect(token.lastUsed == date("2026-08-27T09:00:00Z"))
        #expect(token.expiresAt == date("2027-08-01T09:00:00Z"))
        #expect(store.deviceTokenNotice == nil)
        // Read as the credential this device holds, which is the whole of the route's scope.
        let read = try #require(seen.get().last { $0.operation == tokenReadOperation })
        #expect(read.authorization == "Bearer memos_pat_first")
    }

    @Test("a token with no expiry comes back with no expiry, not with an invented one")
    func readsANeverExpiringToken() async throws {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            operation == whoamiOperation
                ? .json(Stub.user)
                : .json(Stub.nativeToken(name: "old pat", lastUsed: nil, expiresAt: nil))
        }

        await store.loadDeviceToken()

        let token = try #require(store.deviceToken)
        #expect(token.expiresAt == nil)
        #expect(token.lastUsed == nil)
    }

    @Test("a read the server refuses leaves the row unset and says so")
    func readFailureIsHonest() async {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            operation == whoamiOperation ? .json(Stub.user) : .status(.internalServerError)
        }

        await store.loadDeviceToken()

        #expect(store.deviceToken == nil)
        #expect(store.deviceTokenNotice != nil)
    }

    @Test("a 401 on the read ends the session")
    func readUnauthorizedEndsTheSession() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            operation == whoamiOperation ? .json(Stub.user) : .status(.unauthorized)
        }
        #expect(store.state.user != nil)

        await store.loadDeviceToken()

        #expect(store.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    // MARK: - renaming

    @Test("a rename sends the new name and then shows what the SERVER answered")
    func renameSendsAndAdoptsTheAnswer() async throws {
        let seen = LockedValue<[SeenRequest]>([])
        let sentName = LockedValue<String?>(nil)
        let store = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { request, body, operation in
                    seen.set(
                        seen.get()
                            + [
                                SeenRequest(
                                    operation: operation,
                                    authorization: request.headerFields[.authorization]
                                )
                            ]
                    )
                    switch operation {
                    case whoamiOperation: return Stub.json(Stub.user)
                    case tokenRenameOperation:
                        sentName.set(try await Stub.body(body)["name"] as? String)
                        // Deliberately NOT the name that was sent: what the screen shows has to be
                        // the server's copy, so a rename that half-applied cannot leave the row
                        // claiming otherwise.
                        return Stub.json(Stub.nativeToken(name: "server says kitchen phone"))
                    default: return Stub.empty(.internalServerError)
                    }
                }
            }
        )
        await store.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_first")

        let renamed = await store.renameDeviceToken(to: "Kitchen phone")

        #expect(renamed)
        #expect(sentName.get() == "Kitchen phone")
        #expect(store.deviceToken?.name == "server says kitchen phone")
        let patch = try #require(seen.get().last { $0.operation == tokenRenameOperation })
        #expect(patch.authorization == "Bearer memos_pat_first")
    }

    @Test("a rename the server refuses leaves the name exactly as it was")
    func renameRefusedKeepsTheName() async {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenReadOperation: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            default: .validation("that name will not do")
            }
        }
        await store.loadDeviceToken()

        let renamed = await store.renameDeviceToken(to: "Kitchen phone")

        #expect(!renamed)
        #expect(store.deviceToken?.name == "Fabian's iPhone")
        #expect(store.deviceTokenNotice != nil)
    }

    @Test("a name the server would refuse is never sent at all")
    func refusesAnUnusableNameBeforeSending() async {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            operation == whoamiOperation ? .json(Stub.user) : .json(Stub.nativeToken(name: "x"))
        }

        for unusable in ["", "   ", String(repeating: "n", count: 256)] {
            let renamed = await store.renameDeviceToken(to: unusable)
            #expect(!renamed, "\(unusable.count) characters should not have been sent")
        }

        #expect(!seen.get().contains { $0.operation == tokenRenameOperation })
        #expect(store.deviceTokenNotice != nil)
        // Positive control: the same store DOES send a name that fits the server's bounds, so the
        // three refusals above are the bounds rather than a rename that never worked at all.
        let accepted = await store.renameDeviceToken(to: String(repeating: "n", count: 255))
        #expect(accepted)
        #expect(seen.get().contains { $0.operation == tokenRenameOperation })
    }

    @Test("a 401 on the rename ends the session")
    func renameUnauthorizedEndsTheSession() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            operation == whoamiOperation ? .json(Stub.user) : .status(.unauthorized)
        }

        _ = await store.renameDeviceToken(to: "Kitchen phone")

        #expect(store.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    // MARK: - renewing

    /// The one that matters. The server destroys the presenting token in the same statement that
    /// mints the successor, so a swap that does not reach the credential every request is built
    /// with leaves the phone holding a token that is already dead.
    @Test("a renewal swaps the credential, and the NEXT request presents the successor")
    func renewalSwapsTheCredential() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .json(Stub.exchange(token: "memos_pat_next"))
            case tokenReadOperation: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            default: .status(.internalServerError)
            }
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .renewed)
        // Stored: a relaunch has to find the successor, not the token the server just destroyed.
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_next")
        // Presented: the session kept working across the swap, through the client it already had.
        let client = try #require(store.api)
        _ = try? await SessionStore.whoami(client)
        let last = try #require(seen.get().last)
        #expect(last.operation == whoamiOperation)
        #expect(last.authorization == "Bearer memos_pat_next")
        // And the renewal itself was made with the OLD credential, which is the only one the
        // server would have accepted for it.
        let renew = try #require(seen.get().first { $0.operation == tokenRenewOperation })
        #expect(renew.authorization == "Bearer memos_pat_first")
    }

    @Test("a renewal that fails keeps the old token, stored and presented")
    func renewalFailureKeepsTheOldToken() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .status(.internalServerError)
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
        #expect(store.state.user != nil, "a failed renewal is not a sign-out")
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_first")
        let client = try #require(store.api)
        _ = try? await SessionStore.whoami(client)
        #expect(seen.get().last?.authorization == "Bearer memos_pat_first")
        #expect(store.deviceTokenNotice != nil)
    }

    @Test("an unbounded token is told it has nothing to renew, and carries on working")
    func renewalOfAnUnboundedTokenIsNamed() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .detail("token_not_renewable", status: .badRequest)
            default: .json(Stub.nativeToken(name: "old pat", expiresAt: nil))
            }
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .notRenewable)
        #expect(store.state.user != nil)
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_first")
        let client = try #require(store.api)
        _ = try? await SessionStore.whoami(client)
        #expect(seen.get().last?.authorization == "Bearer memos_pat_first")
    }

    @Test("a 400 that is NOT the renewability refusal is reported as an ordinary failure")
    func renewalOfSomeOther400IsNotMisread() async {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .detail("something_else", status: .badRequest)
            default: .json(Stub.nativeToken(name: "x"))
            }
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
    }

    @Test("a 401 on the renewal ends the session")
    func renewalUnauthorizedEndsTheSession() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            operation == whoamiOperation ? .json(Stub.user) : .status(.unauthorized)
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
        #expect(store.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    /// The successor works and the device cannot write it down. Keeping the OLD one would be the
    /// worse answer by far — the server destroyed it — so the swap still happens in memory and the
    /// screen is told the credential will not survive quitting.
    @Test("a renewal whose storage refuses still swaps in memory, and says so")
    func renewalSaysWhenItCouldNotBeStored() async throws {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: RefusingCredentials(), seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .json(Stub.exchange(token: "memos_pat_next"))
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .renewed)
        #expect(store.lastError == SessionStore.renewalStorageWarning)
        // And on the ROW, which is the surface the renewal was started from: the screen that draws
        // this does not draw `lastError`, so a warning that lived only there would be invisible
        // exactly where it matters. It survives the row reload that follows a renewal.
        #expect(store.deviceTokenNotice == SessionStore.renewalStorageWarning)
        let client = try #require(store.api)
        _ = try? await SessionStore.whoami(client)
        #expect(seen.get().last?.authorization == "Bearer memos_pat_next")
    }

    /// A renewal is a mint, and a mint that lands after the session ended must not be written
    /// anywhere: the credential slot belongs to whoever is signed in NOW, and the successor's
    /// predecessor was destroyed for a session that no longer exists.
    @Test("a renewal that answers after the session ended writes nothing")
    func renewalForAnEndedSessionWritesNothing() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let ended = LockedValue<SessionStore?>(nil)
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: return .json(Stub.user)
            case tokenRenewOperation:
                // The session ends while the renewal is on the wire. `signOutWithoutRevoking`
                // rather than `signOut`, because a revoke would re-enter this same handler.
                if let store = ended.get() { await store.signOutWithoutRevoking() }
                return .json(Stub.exchange(token: "memos_pat_next"))
            default: return .status(.internalServerError)
            }
        }
        ended.set(store)

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
        #expect(store.state == .signedOut)
        #expect(credentials.isEmpty, "the successor must not be written into an empty slot")
    }

    // MARK: - the row's lifetime

    @Test("signing out forgets the row along with the credential it described")
    func signOutForgetsTheRow() async {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenReadOperation: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            default: .status(.noContent)
            }
        }
        await store.loadDeviceToken()
        #expect(store.deviceToken != nil)

        await store.signOut()

        #expect(store.deviceToken == nil)
        #expect(store.deviceTokenNotice == nil)
    }
}

/// The bounds a device token's name is held to, which are the server's own.
@Suite("What may be sent as a device token's name")
struct DeviceTokenNameTests {
    @Test("a name is trimmed, and what is left has to be something")
    func trimsAndRefusesEmpty() {
        #expect(DeviceTokenName.sanitized("  Kitchen phone  ") == "Kitchen phone")
        #expect(DeviceTokenName.sanitized("") == nil)
        #expect(DeviceTokenName.sanitized("   \n ") == nil)
    }

    /// 255 is `pats.name`'s width and `PatCreate`'s bound, and the rename endpoint declares the
    /// same one. Sending 256 would be asking for a 422 the app can see coming.
    @Test("255 characters fit and 256 do not")
    func holdsTheServersLength() {
        #expect(DeviceTokenName.sanitized(String(repeating: "n", count: 255)) != nil)
        #expect(DeviceTokenName.sanitized(String(repeating: "n", count: 256)) == nil)
        // Measured after trimming, so trailing spaces cannot push a legal name over the edge.
        #expect(DeviceTokenName.sanitized(String(repeating: "n", count: 255) + "   ") != nil)
    }
}

/// What a stubbed answer is, so a handler written as a `switch` can return one line per case.
///
/// The `Stub` helpers hand back a tuple, and a `switch` whose arms are tuples of an
/// `HTTPResponse` and an optional body is unreadable. This is the same three answers with a name.
enum HTTPResponseLike: Sendable {
    case json(String)
    case status(HTTPResponse.Status)
    case detail(String, status: HTTPResponse.Status)
    case validation(String)

    var parts: (HTTPResponse, HTTPBody?) {
        switch self {
        case .json(let payload): Stub.json(payload)
        case .status(let status): Stub.empty(status)
        case .detail(let detail, let status): Stub.detail(detail, status: status)
        case .validation(let message): Stub.validationError(message)
        }
    }
}
