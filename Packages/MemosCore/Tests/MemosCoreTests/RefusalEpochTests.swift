import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

@testable import MemosCore

private let whoamiOperation = "whoami_api_auth_user_get"
private let logoutOperation = "native_logout_api_auth_native_logout_post"

private let storedToken = "memos_pat_a"
private let successorToken = "memos_pat_next"
private let storedAddress = "https://memos.example.invalid"

private func vault() -> InMemoryCredentials {
    let store = InMemoryCredentials()
    try? store.set(storedToken, for: SessionStore.tokenAccount)
    try? store.set(storedAddress, for: SessionStore.serverAccount)
    return store
}

/// The last-known-user file a launch admits on, bound to the token the vault holds.
///
/// Without it the second `restore()` finds no bound file, announces `.signingIn`, and `validate`
/// reads `admitted` as false — so a discarded answer PARKS instead of scheduling, and the retry
/// assertion below would fail for a reason that has nothing to do with the rule under test.
private func boundFile() -> StubLastKnownUser {
    StubLastKnownUser(
        LastKnownUser(
            subject: "fabian",
            displayName: "Fabian",
            email: "f@example.invalid",
            role: "admin",
            authKind: "oidc",
            serverBaseURL: storedAddress,
            credentialFingerprint: CredentialFingerprint.of(storedToken)
        )
    )
}

/// The windows this ticket exists to close: a refusal earned by the token a renewal replaced,
/// answered after the renewal landed, reaching the effect that acts on it.
///
/// Every one of them drives the REAL store over `StubTransport` through the app's own generated
/// client — never a substituted store, which would prove only that the test agrees with itself.
@MainActor
@Suite("A refusal carries the epoch of the credential that earned it")
struct RefusalEpochTests {

    // MARK: - window 1: the launch check

    /// The renewal lands between `BearerAuthMiddleware` throwing the refusal and `validate`
    /// resuming on the main actor. Judged where the answer arrived, that 401 ends a session the
    /// device renewed a moment ago; judged where the wipe would happen, it names a token that is
    /// gone and nothing happens — but something still has to be SCHEDULED, or the session sits in
    /// `.verifying` for ever with nothing behind it.
    @Test("a refusal earned by the replaced token does not wipe the successor")
    func aSupersededRefusalDoesNotEndTheRenewedSession() async throws {
        let credentials = vault()
        let seen = LockedValue<[String?]>([])
        let refusing = LockedValue<Bool>(false)
        let installed = LockedValue<Bool>(false)
        let calls = Counter()
        let sleeper = RetryLadderSleeper(stoppingAfter: 2)
        let held = LockedValue<PresentedCredential?>(nil)

        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, credential in
                held.set(credential)
                return Stub.client(
                    token: credential,
                    afterRefusal: {
                        guard refusing.get() else { return }
                        // The window itself: the middleware has already compared the epoch and
                        // thrown, and the store has not resumed.
                        credential.replace(with: successorToken)
                        installed.set(true)
                    }
                ) { request, _, _ in
                    calls.increment()
                    seen.set(seen.get() + [request.headerFields[.authorization]])
                    guard refusing.get() else { return Stub.json(Stub.user) }
                    return Stub.empty(.unauthorized)
                }
            },
            sleeper: { try sleeper.sleep($0) },
            lastKnownUser: boundFile()
        )
        // Without it `scheduleRetry` returns without scheduling, and the retry assertion below
        // would be vacuous.
        await session.enteredForeground()
        await session.restore()
        #expect(session.state.user != nil, "control: the launch signed in")

        refusing.set(true)
        let before = calls.count
        await session.restore()

        // The three premises of the mechanism, asserted rather than trusted.
        #expect(
            seen.get().last == "Bearer \(storedToken)",
            "the premise: the request that earned the 401 carried the PREDECESSOR"
        )
        #expect(installed.get(), "the premise: the bearer middleware threw, so the hook fired")
        #expect(
            held.get()?.presented().epoch == 1,
            "the premise: the successor was installed before the effect"
        )

        #expect(session.state.user != nil, "a stale refusal ended a session it says nothing about")
        #expect(!credentials.isEmpty, "the credential was wiped by a refusal of its predecessor")
        #expect(
            session.credentialGrant()?.token == successorToken,
            "the successor is no longer the credential this device presents"
        )
        // A discarded answer that scheduled nothing leaves the session in `.verifying` with no
        // task behind it, which is the second half of the rule and the easier half to lose.
        for _ in 0..<200 where calls.count <= before + 1 { await Task.yield() }
        #expect(calls.count > before + 1, "nothing was scheduled behind the discarded answer")
    }

    // MARK: - window 3: the raced sign-out

    /// A renewal commits while the revoke is on the wire. The server refuses the logout because
    /// the token it named is gone — and wiping on that destroys the SUCCESSOR, which is live, was
    /// never revoked, and is valid for up to a year in whatever holds it.
    @Test("a revoke refused because the token was renewed keeps the successor")
    func aRacedSignOutDoesNotOrphanTheSuccessor() async throws {
        let credentials = vault()
        let refusing = LockedValue<Bool>(false)
        let installed = LockedValue<Bool>(false)
        let seen = LockedValue<[String?]>([])
        let held = LockedValue<PresentedCredential?>(nil)

        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, credential in
                held.set(credential)
                return Stub.client(
                    token: credential,
                    afterRefusal: {
                        guard refusing.get() else { return }
                        credential.replace(with: successorToken)
                        installed.set(true)
                    }
                ) { request, _, operation in
                    seen.set(seen.get() + [request.headerFields[.authorization]])
                    guard operation == logoutOperation else { return Stub.json(Stub.user) }
                    refusing.set(true)
                    return Stub.empty(.unauthorized)
                }
            },
            lastKnownUser: boundFile()
        )
        await session.restore()
        #expect(session.state.user != nil, "control: the launch signed in")

        let outcome = await session.signOut()

        #expect(
            seen.get().last == "Bearer \(storedToken)",
            "the premise: the revoke that earned the 401 carried the PREDECESSOR"
        )
        #expect(installed.get(), "the premise: the bearer middleware threw, so the hook fired")
        #expect(held.get()?.presented().epoch == 1, "the premise: the successor was installed")

        #expect(
            outcome == .revokeFailed(.unauthorized),
            "a raced revoke was read as a token that was already gone"
        )
        #expect(session.state.user != nil, "the session ended on a refusal of a replaced token")
        #expect(!credentials.isEmpty, "a live token nobody revoked was deleted from the keychain")
        #expect(
            session.credentialGrant()?.token == successorToken,
            "the successor this device is holding was thrown away by a revoke of its predecessor"
        )
    }

    // MARK: - every effect the funnel reaches

    /// The other half of the coverage, effect by effect: a refusal naming a generation this device
    /// has already left behind must leave every one of them untouched, AND each call must return
    /// to its caller what it always did.
    ///
    /// A superseded refusal is built by handing the funnel an epoch nothing holds, which is what
    /// the middleware produces for a request whose token was replaced under it.
    @Test("a superseded refusal ends nothing, whichever effect it reaches")
    func aSupersededRefusalLeavesEveryEffectAlone() async throws {
        let credentials = vault()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, credential in
                Stub.client(token: credential) { _, _, _ in Stub.json(Stub.user) }
            },
            lastKnownUser: boundFile()
        )
        await session.restore()
        #expect(session.state.user != nil, "control: the launch signed in")

        let superseded = CredentialRefusal(issuedUnder: 99)
        #expect(await session.handle(superseded) == .superseded)
        #expect(session.stillNamesCurrentCredential(superseded) == false)

        #expect(session.state.user != nil, "the funnel ended a session it was told not to")
        #expect(!credentials.isEmpty)

        // And the current one still does everything it always did.
        let current = CredentialRefusal(issuedUnder: 0)
        #expect(session.stillNamesCurrentCredential(current))
        #expect(await session.handle(current) == .endedSession)
        #expect(session.state == .signedOut, "a refusal of the credential in hand did not end it")
        #expect(credentials.isEmpty)
    }

    /// The reporting stores' half of the same rule: the SESSION owns the verdict, and a store owns
    /// only what it says about it. A superseded refusal must leave no sentence behind — the N1
    /// case, where a renewal during a scroll painted an error card over a working timeline.
    @Test("a superseded refusal leaves no sentence on a list, and a current one does")
    func aSupersededRefusalWritesNoSentence() async throws {
        for outcome in [RefusalOutcome.superseded, .endedSession] {
            let reached = LockedValue<Bool>(false)
            let store = TimelineStore(onUnauthorized: { _ in
                reached.set(true)
                return outcome
            })
            let client = Stub.client { _, _, _ in Stub.empty(.unauthorized) }

            await store.refresh(using: client.handle, baseURL: Stub.baseURL)

            #expect(reached.get(), "the refusal never reached the session")
            #expect(
                (store.lastError != nil) == (outcome == .endedSession),
                "the list wrote a sentence the session's verdict did not earn: \(outcome)"
            )
        }
    }

    /// `TagStore` and `HeatmapStore` say something and end nothing, so they ask the read-only half
    /// of the rule — and, this is the half that is easy to lose, they must clear their own spinner
    /// on every path, superseded or not. Their refusal arm is one more `else if` in the existing
    /// chain with NO `return`, for exactly that reason.
    @Test("a reporting store's spinner comes down whatever the refusal turns out to be")
    func aReportingStoreAlwaysClearsItsSpinner() async throws {
        for renewed in [true, false] {
            let credentials = vault()
            let refusing = LockedValue<Bool>(false)
            let session = SessionStore(
                credentials: credentials,
                makeClient: { _, credential in
                    Stub.client(
                        token: credential,
                        afterRefusal: {
                            // The renewal lands inside the refusal itself, so the answer names a
                            // generation the device has already left behind.
                            guard renewed, refusing.get() else { return }
                            credential.replace(with: successorToken)
                        }
                    ) { _, _, operation in
                        operation == whoamiOperation
                            ? Stub.json(Stub.user) : Stub.empty(.unauthorized)
                    }
                },
                lastKnownUser: boundFile()
            )
            await session.restore()
            #expect(session.state.user != nil, "control: the launch signed in")
            let handle = try #require(session.activeHandle)
            refusing.set(true)

            let tags = TagStore()
            tags.reports(to: session)
            await tags.load(using: handle)

            #expect(!tags.isLoading, "the spinner was stranded by the refusal arm")
            #expect(
                (tags.lastError != nil) != renewed,
                "a refusal of a replaced credential told this row to sign in again"
            )
            #expect(session.state.user != nil, "a reporting store ended a session")
        }
    }
}
