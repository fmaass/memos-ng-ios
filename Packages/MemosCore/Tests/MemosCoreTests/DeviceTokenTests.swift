import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let tokenReadOperation = "native_token_api_auth_native_token_get"
private let tokenRenameOperation = "rename_native_token_api_auth_native_token_patch"
private let tokenRenewOperation = "native_renew_api_auth_native_renew_post"
private let whoamiOperation = "whoami_api_auth_user_get"
private let settingsOperation = "get_settings_api_settings_get"

private let settingsBody = """
    {"default_visibility":"PUBLIC","theme":"d","avatar":null}
    """

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

    /// The same rule, one await later — the gap the audit found. `performRenewal` fences every
    /// effect it has on `owns(generation)`, and the storage write it does BEFORE that guard is an
    /// await of its own. A sign-in completing inside it owns the session, and the warning the
    /// failed write produced ("Renewed, but the new credential could not be saved…") was being
    /// written anyway — a sentence about a rotation the account reading it never asked for.
    @Test("a renewal whose storage failed after the session changed says nothing to the successor")
    func renewalStorageWarningIsNotWrittenToASuccessor() async {
        let box = LockedValue<SessionStore?>(nil)
        let seen = LockedValue<[SeenRequest]>([])
        let credentials = SupersedingCredentials {
            guard let store = await box.get() else { return }
            await store.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")
        }
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .json(Stub.exchange(token: "memos_pat_next"))
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }
        box.set(store)
        // Only the SUCCESSOR's write interrupts and throws; the sign-in above wrote normally.
        credentials.arm()

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed, "the renewal lost its session, whatever storage did")
        #expect(store.state.user != nil, "the premise: the sign-in inside the write owns this")
        #expect(
            store.lastError == nil,
            "a renewal that lost its session put its storage warning on the successor's screen"
        )
        #expect(store.deviceTokenNotice == nil, "and nothing on the successor's row either")
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

    // MARK: - a refusal of the token this device has already replaced

    /// Waits until the transport has been handed `operation`, so a test can act on a request that
    /// is genuinely on the wire rather than on one it hopes has started.
    private func onTheWire(_ operation: String, _ seen: LockedValue<[SeenRequest]>) async {
        for _ in 0..<10_000 where !seen.get().contains(where: { $0.operation == operation }) {
            await Task.yield()
        }
    }

    /// The renewal's own window. A request that left with the PREDECESSOR token can be answered
    /// 401 after the swap — the server destroyed that token, so of course it refuses it — and that
    /// refusal says nothing whatever about the successor this device is now holding. Obeying it
    /// signs somebody out of a session that is perfectly alive, moments after they renewed it.
    @Test("a 401 for the token a renewal replaced does not end the renewed session")
    func staleUnauthorizedDoesNotEndTheSession() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let release = Box(false)
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: return .json(Stub.user)
            case settingsOperation:
                // Parked: still unanswered while the renewal runs, then refused.
                while !release.value { await Task.yield() }
                return .status(.unauthorized)
            case tokenRenewOperation: return .json(Stub.exchange(token: "memos_pat_next"))
            default: return .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        let parked = Task { await store.loadSettings() }
        await onTheWire(settingsOperation, seen)
        let outcome = await store.renewDeviceToken()
        release.value = true
        await parked.value

        #expect(outcome == .renewed)
        #expect(store.state.user != nil, "the stale 401 ended a session that had just been renewed")
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_next")
        // And the successor is still what goes out, so the session did not merely survive on paper.
        let client = try #require(store.api)
        _ = try? await SessionStore.whoami(client)
        #expect(seen.get().last?.authorization == "Bearer memos_pat_next")
    }

    /// The control, and the reason the test above is a fence rather than a hole: the SAME parked
    /// request, refused the same way, with no renewal in between. That 401 is about the credential
    /// this device is holding, and it still ends the session.
    @Test("a 401 for the token this device IS holding still ends the session")
    func currentUnauthorizedStillEndsTheSession() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let release = Box(false)
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: return .json(Stub.user)
            case settingsOperation:
                while !release.value { await Task.yield() }
                return .status(.unauthorized)
            default: return .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        let parked = Task { await store.loadSettings() }
        await onTheWire(settingsOperation, seen)
        release.value = true
        await parked.value

        #expect(store.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    // MARK: - a renewal whose outcome the device cannot see

    /// A 5xx or a lost connection is not "the renewal did not happen" — the server may have
    /// committed the rotation and failed to say so, in which case the token this device is still
    /// presenting is already destroyed. So the device asks, with the token it has.
    @Test("an unanswered renewal is probed, and a probe that succeeds means nothing rotated")
    func ambiguousRenewalProbesAndKeepsTheOldToken() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .status(.internalServerError)
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }
        let beforeRenewal = seen.get().filter { $0.operation == whoamiOperation }.count

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
        let probes = seen.get().filter { $0.operation == whoamiOperation }.count - beforeRenewal
        #expect(probes == 1, "an ambiguous renewal has to ask whether the rotation happened")
        #expect(store.state.user != nil)
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_first")
        #expect(store.deviceTokenNotice != nil)
    }

    /// The other answer, and the one that cannot be papered over: the probe is refused, so the
    /// rotation DID happen and the successor was in the reply that never arrived. There is no
    /// credential left on this device that works, and saying "the old token still works" would be
    /// a lie the next request would expose.
    @Test("a probe that is refused means the successor is lost, and the session ends honestly")
    func ambiguousRenewalThatLostTheSuccessorEndsTheSession() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let whoamis = Counter()
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation:
                whoamis.increment()
                // The sign-in's own whoami succeeds; the probe afterwards is refused.
                return whoamis.count == 1 ? .json(Stub.user) : .status(.unauthorized)
            case tokenRenewOperation: return .status(.internalServerError)
            default: return .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
        #expect(store.state == .signedOut, "the device kept a session on a destroyed token")
        #expect(credentials.isEmpty)
        // And it says the true thing rather than the generic refusal sentence.
        #expect(
            store.lastError?.contains("sign in again") == true,
            "a lost successor has to tell the person to sign in again"
        )
    }

    /// A refusal the server ANSWERED is a decision, not a lost reply: nothing rotated, so there is
    /// nothing to ask about and no request to spend.
    @Test("a refusal the server answered is not probed")
    func definitiveRefusalIsNotProbed() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .status(.forbidden)
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }
        let beforeRenewal = seen.get().filter { $0.operation == whoamiOperation }.count

        let outcome = await store.renewDeviceToken()

        #expect(outcome == .failed)
        #expect(seen.get().filter { $0.operation == whoamiOperation }.count == beforeRenewal)
        #expect(store.state.user != nil)
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_first")
    }

    // MARK: - two renewals at once

    /// A rotation is not idempotent, and nothing outside this store serializes one: the Settings
    /// row disables its button, but a store may not lean on a screen's own discipline for a
    /// correctness property, and a background refresh or a second window would not be bound by it
    /// at all.
    ///
    /// Two rotations in flight is not merely wasteful. The second destroys the token the first is
    /// still holding, so the first's ambiguity probe — which asks with that token — is refused,
    /// concludes the successor is lost, and wipes the credential the second is about to install.
    /// A perfectly successful renewal ends as a sign-out. The fix is that the case cannot arise:
    /// there is one rotation, and the second caller is told about that one.
    @Test("two renewals at once are one rotation, and both callers get its answer")
    func concurrentRenewalsAreOneRotation() async throws {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let release = Box(false)
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: return .json(Stub.user)
            case tokenRenewOperation:
                while !release.value { await Task.yield() }
                return .json(Stub.exchange(token: "memos_pat_next"))
            default: return .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        let first = Task { await store.renewDeviceToken() }
        await onTheWire(tokenRenewOperation, seen)
        let second = Task { await store.renewDeviceToken() }
        // Let the second call get as far as it is ever going to get while the first is parked.
        for _ in 0..<500 { await Task.yield() }
        release.value = true
        let firstOutcome = await first.value
        let secondOutcome = await second.value

        let rotations = seen.get().filter { $0.operation == tokenRenewOperation }.count
        #expect(rotations == 1, "the second call started a sibling rotation")
        #expect(firstOutcome == .renewed)
        #expect(secondOutcome == firstOutcome, "the two callers disagreed about one rotation")
        #expect(store.state.user != nil)
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_next")
    }

    /// And a renewal after that one has finished is a new rotation, so serializing them is a queue
    /// rather than a latch that fires once.
    @Test("a renewal after the first has finished rotates again")
    func aLaterRenewalRotatesAgain() async {
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: InMemoryCredentials(), seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .json(Stub.exchange(token: "memos_pat_next"))
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }

        _ = await store.renewDeviceToken()
        _ = await store.renewDeviceToken()

        #expect(seen.get().filter { $0.operation == tokenRenewOperation }.count == 2)
    }

    // MARK: - the lanes that do not go through the middleware

    /// The download is refused because it presented the token a renewal replaced — which the epoch
    /// fence already stops from ending the session. What it must ALSO not do is tell the person
    /// their access was rejected: the session is alive, the credential is good, and "sign in again"
    /// is a false instruction that costs them a working sign-in.
    @Test("a download refused for a replaced credential says so, and is not a rejection")
    func supersededDownloadIsNotARejection() async {
        let credentials = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let session = Box<SessionStore?>(nil)
        let store = await signedIn(credentials: credentials, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .json(Stub.exchange(token: "memos_pat_next"))
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }
        session.value = store
        // The renewal lands while the download is on the wire, which is the whole scenario: the
        // request left with the predecessor and comes back refused.
        let transport = RotatingDownloads(status: 401) {
            if let store = session.value { _ = await store.renewDeviceToken() }
        }

        await #expect(throws: OriginalMediaError.superseded) {
            try await store.download(
                MemoAttachment(
                    uid: "a1",
                    mime: "image/jpeg",
                    status: .ready,
                    downloadURL: URL(string: "https://memos.example.invalid/x/original")!
                ),
                transport: transport
            )
        }

        #expect(store.state.user != nil, "a replaced credential is not a rejected one")
    }

    /// The outbox reaches the server with its own requests, not through the generated client, so
    /// the middleware's fence never sees them. It does not need to: the credential is granted by
    /// the session once per drain and never written into a queued job, so the rotation a renewal
    /// commits is simply what the next attempt picks up. Driven through the REAL renewal here,
    /// because that is the write whose effect is being claimed.
    @Test("a queued outbox attempt after a renewal presents the successor")
    func outboxDrainPresentsTheSuccessor() async throws {
        let vault = InMemoryCredentials()
        let seen = LockedValue<[SeenRequest]>([])
        let store = await signedIn(credentials: vault, seen: seen) { operation in
            switch operation {
            case whoamiOperation: .json(Stub.user)
            case tokenRenewOperation: .json(Stub.exchange(token: "memos_pat_next"))
            default: .json(Stub.nativeToken(name: "Fabian's iPhone"))
            }
        }
        let outbox = DeviceOutboxCredentials(epoch: { store.epoch.current }) {
            await MainActor.run { store.credentialGrant() }
        }
        let before = await outbox.currentCredentials()
        #expect(before?.token == "memos_pat_first", "the premise: it was holding the old one")

        let outcome = await store.renewDeviceToken()
        #expect(outcome == .renewed)

        let after = await outbox.currentCredentials()
        #expect(after?.token == "memos_pat_next")
        // And a grant taken BEFORE the rotation stops standing at the drain's next synchronous
        // check: it names a token the server destroyed in the same statement that minted this one.
        let granted = try #require(before)
        #expect(!outbox.isCurrent(granted))
    }

    /// The live channel is the other one. It builds its own request per CONNECTION and reads the
    /// credential fresh each time, so a reconnect after a rotation carries the successor. Proven
    /// across two connections with the rotation between them — a channel that captured its
    /// credential once would present the same token twice and this would not move.
    @Test("an SSE reconnect after a rotation presents the successor")
    func sseReconnectPresentsTheSuccessor() async throws {
        // The swap a renewal commits, made against the SESSION rather than the vault, because the
        // session is where this lane now reads its credential (F1). Made directly so this test is
        // about the LANE rather than about the renewal (which `outboxDrainPresentsTheSuccessor`
        // drives for real).
        let presenting = LockedValue<String>("memos_pat_first")
        // The REAL transport, answered below `URLSession`: every connection opens and closes at
        // once, and the stored credential rotates after the FIRST request has left — so what the
        // reconnect presents is what the production `connect` put on the wire.
        let route = try GuardStubProtocol.open(body: Data()) { number in
            if number == 1 { presenting.set("memos_pat_next") }
        }
        defer { GuardStubProtocol.close(route) }
        let server = route.url("")
        let configuration = URLSessionSSETransport.makeConfiguration()
        configuration.protocolClasses = GuardStubProtocol.only
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionSSETransport(session: session)
        let client = MediaEventClient.device(
            grant: {
                CredentialGrant(
                    subject: "fabian",
                    serverBaseURL: server,
                    token: presenting.get(),
                    epoch: 0
                )
            },
            identity: MediaIdentity(),
            transport: transport,
            sleeper: RecordingSleeper(budget: 2)
        )

        _ = await client.collect()

        let presented = route.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(presented.count >= 2, "the channel did not reconnect, so nothing was proven")
        #expect(presented.first == "Bearer memos_pat_first")
        #expect(presented.last == "Bearer memos_pat_next")
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

    /// The unit has to be the SERVER's unit. `String.count` counts grapheme clusters and Python's
    /// `len` — which is what `max_length=255` is checked with — counts code points, so a name made
    /// of multi-scalar graphemes can be well under 255 to Swift and well over it to the server:
    /// the app would send it, and the server would answer 422 for a bound the app believed it had
    /// already enforced.
    @Test("the length is counted the way the server counts it")
    func countsCodePointsRatherThanGraphemes() {
        // A regional-indicator pair is ONE grapheme and TWO code points.
        let flag = "🇩🇪"
        #expect(flag.count == 1 && flag.unicodeScalars.count == 2, "the premise of this test")

        let overLong = String(repeating: flag, count: 200)
        #expect(overLong.count == 200, "well inside 255 graphemes")
        #expect(overLong.unicodeScalars.count == 400, "and well outside 255 code points")
        #expect(DeviceTokenName.sanitized(overLong) == nil)

        // The control, so the rule is a bound rather than a ban on emoji: 254 code points of
        // flags plus one letter is 255 to the server, and it goes.
        let fits = String(repeating: flag, count: 127) + "n"
        #expect(fits.unicodeScalars.count == 255)
        #expect(DeviceTokenName.sanitized(fits) != nil)
    }
}

/// A download that does something to the session BEFORE it answers — here, renewing it, so the
/// reply lands on a credential the request did not present.
private struct RotatingDownloads: MediaDownloadTransport {
    let status: Int
    let rotate: @Sendable () async -> Void

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        await rotate()
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("original".utf8).write(to: url)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (url, response)
    }
}

/// A credential store whose single-item write, once armed, lets a sign-in complete inside it and
/// THEN refuses — the renewal's own failure shape, with the session changing underneath it.
///
/// `setAll` is left to the protocol default so that the sign-in landing inside this write stores
/// normally: what is under test is the sentence the renewal writes afterwards, not the sign-in.
final class SupersedingCredentials: CredentialStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var armed = false
    private let duringWrite: @Sendable () async -> Void

    init(duringWrite: @escaping @Sendable () async -> Void) {
        self.duringWrite = duringWrite
    }

    func arm() { lock.withLock { armed = true } }

    func set(_ value: String, for account: String) async throws {
        let fire: Bool = lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
        guard fire else {
            lock.withLock { storage[account] = value }
            return
        }
        await duringWrite()
        throw Refused()
    }

    func string(for account: String) async throws -> String? { lock.withLock { storage[account] } }

    func remove(_ account: String) async throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }
}
