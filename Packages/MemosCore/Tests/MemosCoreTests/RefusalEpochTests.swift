import Foundation
import HTTPTypes
import MemosAPI
import MemosOutbox
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
        // The discarded answer schedules its replacement AT ONCE, and that retry presents the
        // successor and earns a refusal of its own, which fires the hook again. Read after it, the
        // premises below describe the retry instead of the request that earned the first 401, so
        // every request sent after the successor was installed waits until they have been read.
        let retryMayAnswer = Gate()

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
                    if installed.get() { await retryMayAnswer.wait() }
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
        retryMayAnswer.open()
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

    // MARK: - §3.2: every effect, current refusal against superseded refusal

    // Both halves of every row below run through the REAL session and the REAL store over
    // `StubTransport`. Nothing is handed a predetermined `RefusalOutcome`: the superseded case
    // earns
    // its refusal from a credential the renewal replaced INSIDE the throw, which is the only
    // mechanism that opens the window on demand, and the current case earns it from the credential
    // the device is holding. Each row asserts the session state AND what the call returned.

    /// One signed-in session whose next refusal either lands on the credential in hand or on one a
    /// renewal has just replaced.
    private struct Signed {
        let session: SessionStore
        let vault: InMemoryCredentials
        let refusing: LockedValue<Bool>
        let credential: LockedValue<PresentedCredential?>
    }

    /// - Parameter renewing: whether a renewal commits inside the refusal — after the middleware
    ///   recorded the epoch the request presented and threw, and before the store resumes.
    private func signedIn(renewing: Bool) async -> Signed {
        let vault = vault()
        let refusing = LockedValue<Bool>(false)
        let credential = LockedValue<PresentedCredential?>(nil)
        let session = SessionStore(
            credentials: vault,
            makeClient: { _, presented in
                credential.set(presented)
                return Stub.client(
                    token: presented,
                    afterRefusal: {
                        guard renewing, refusing.get() else { return }
                        presented.replace(with: successorToken)
                    }
                ) { _, _, operation in
                    // whoami always answers, so the launch signs in and the row below decides what
                    // is refused.
                    guard operation != whoamiOperation else { return Stub.json(Stub.user) }
                    guard refusing.get() else {
                        return Stub.json(Stub.memoList([], nextCursor: nil))
                    }
                    return Stub.empty(.unauthorized)
                }
            },
            lastKnownUser: boundFile()
        )
        await session.restore()
        refusing.set(true)
        return Signed(session: session, vault: vault, refusing: refusing, credential: credential)
    }

    /// The session ended, and everything that goes with it.
    private func expectEnded(_ signed: Signed, _ label: Comment) {
        #expect(signed.session.state == .signedOut, label)
        #expect(signed.vault.isEmpty, label)
    }

    /// The session stands, the successor is what the device presents, and the vault is intact.
    private func expectStanding(_ signed: Signed, _ label: Comment) {
        #expect(signed.session.state.user != nil, label)
        #expect(!signed.vault.isEmpty, label)
        #expect(signed.credential.get()?.presented().epoch == 1, "the premise: a renewal landed")
    }

    @Test("loadSettings")
    func settingsRead() async throws {
        let current = await signedIn(renewing: false)
        await current.session.loadSettings()
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        await superseded.session.loadSettings()
        expectStanding(superseded, "a refusal of a replaced credential ended the session")
    }

    @Test("setDefaultVisibility — and it still answers false either way")
    func visibilityWrite() async throws {
        let current = await signedIn(renewing: false)
        #expect(await current.session.setDefaultVisibility(.private) == false)
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        #expect(await superseded.session.setDefaultVisibility(.private) == false)
        expectStanding(superseded, "a refusal of a replaced credential ended the session")
    }

    @Test("loadDeviceToken")
    func tokenRead() async throws {
        let current = await signedIn(renewing: false)
        await current.session.loadDeviceToken()
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        await superseded.session.loadDeviceToken()
        expectStanding(superseded, "a refusal of a replaced credential ended the session")
    }

    @Test("renameDeviceToken — and it still answers false either way")
    func tokenRename() async throws {
        let current = await signedIn(renewing: false)
        #expect(await current.session.renameDeviceToken(to: "iPhone") == false)
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        #expect(await superseded.session.renameDeviceToken(to: "iPhone") == false)
        expectStanding(superseded, "a refusal of a replaced credential ended the session")
    }

    @Test("renewDeviceToken — and it still answers .failed either way")
    func renewalRefused() async throws {
        let current = await signedIn(renewing: false)
        #expect(await current.session.renewDeviceToken() == .failed)
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        #expect(await superseded.session.renewDeviceToken() == .failed)
        expectStanding(superseded, "a refusal of a replaced credential ended the session")
    }

    /// The raced sign-out has a window test of its own above; this is its row in the matrix, and
    /// the
    /// half that matters here is the CURRENT one — a refusal of the token being revoked still means
    /// "already gone" and still wipes.
    @Test("signOut — .alreadyRevoked for the token in hand, .revokeFailed for a replaced one")
    func signOutRefused() async throws {
        let current = await signedIn(renewing: false)
        #expect(await current.session.signOut() == .alreadyRevoked)
        expectEnded(current, "a revoke refused for the token in hand did not wipe it")

        let superseded = await signedIn(renewing: true)
        #expect(await superseded.session.signOut() == .revokeFailed(.unauthorized))
        expectStanding(superseded, "a raced revoke threw away a token nobody revoked")
    }

    @Test("download — .credentialRefused for the credential in hand, .superseded for a replaced")
    func downloadRefused() async throws {
        for renewing in [false, true] {
            let signed = await signedIn(renewing: renewing)
            let transport = RenewingDownloads(status: 401) {
                guard renewing else { return }
                signed.credential.get()?.replace(with: successorToken)
            }
            let thrown = await #expect(throws: OriginalMediaError.self) {
                try await signed.session.download(attachment(), transport: transport)
            }
            if renewing {
                #expect(thrown == OriginalMediaError.superseded)
                expectStanding(signed, "a download refused for a replaced credential ended it")
            } else {
                #expect(
                    thrown
                        == OriginalMediaError.credentialRefused(
                            CredentialRefusal(issuedUnder: 0)
                        )
                )
                expectEnded(signed, "a download refused for the credential in hand did not end it")
            }
        }
    }

    @Test("TimelineStore.report — the list's sentence follows the session's verdict")
    func timelineReport() async throws {
        let current = await signedIn(renewing: false)
        let currentStore = timeline(for: current)
        let currentHandle = try #require(current.session.activeHandle)
        await currentStore.refresh(using: currentHandle, baseURL: Stub.baseURL)
        expectEnded(current, "a refusal of the credential in hand did not end the session")
        #expect(currentStore.lastError != nil, "and the list said nothing about it")

        let superseded = await signedIn(renewing: true)
        let supersededStore = timeline(for: superseded)
        await supersededStore.refresh(
            using: try #require(superseded.session.activeHandle), baseURL: Stub.baseURL
        )
        expectStanding(superseded, "a stale refusal ended the session")
        #expect(
            supersededStore.lastError == nil,
            "a renewal during a scroll painted 'sign in again' over a timeline that is working"
        )
    }

    @Test("TimelineStore.setPinned — and it still answers false either way")
    func timelinePin() async throws {
        let current = await signedIn(renewing: false)
        let currentStore = timeline(for: current)
        let currentHandle = try #require(current.session.activeHandle)
        let pinnedCurrent = await currentStore.setPinned(
            true, uid: "a", using: currentHandle, baseURL: Stub.baseURL
        )
        #expect(pinnedCurrent == false)
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        let supersededStore = timeline(for: superseded)
        let supersededHandle = try #require(superseded.session.activeHandle)
        let pinnedSuperseded = await supersededStore.setPinned(
            true, uid: "a", using: supersededHandle, baseURL: Stub.baseURL
        )
        #expect(pinnedSuperseded == false)
        expectStanding(superseded, "a stale refusal ended the session")
    }

    @Test("TimelineStore.fetchMemo — and it still answers nil either way")
    func timelineMemoLookup() async throws {
        let current = await signedIn(renewing: false)
        let currentStore = timeline(for: current)
        let currentHandle = try #require(current.session.activeHandle)
        let fetchedCurrent = await currentStore.fetchMemo(
            uid: "a", using: currentHandle, baseURL: Stub.baseURL
        )
        #expect(fetchedCurrent == nil)
        expectEnded(current, "a refusal of the credential in hand did not end the session")

        let superseded = await signedIn(renewing: true)
        let supersededStore = timeline(for: superseded)
        let supersededHandle = try #require(superseded.session.activeHandle)
        let fetchedSuperseded = await supersededStore.fetchMemo(
            uid: "a", using: supersededHandle, baseURL: Stub.baseURL
        )
        #expect(fetchedSuperseded == nil)
        expectStanding(superseded, "a stale refusal ended the session")
    }

    /// `refreshMemo`'s catch is its OWN — it never reaches `report`, so it leaves no sentence
    /// behind and answers `false` either way. The design's C21 cited this catch and named it
    /// `setPinned`; `setPinned` is a real effect with a row of its own above, and this is the one
    /// C21 was actually about.
    @Test("TimelineStore.refreshMemo — and it still answers false, and says nothing, either way")
    func timelineMemoRefresh() async throws {
        let current = await signedIn(renewing: false)
        let currentStore = timeline(for: current)
        let currentHandle = try #require(current.session.activeHandle)
        let refreshedCurrent = await currentStore.refreshMemo(
            uid: "a", using: currentHandle, baseURL: Stub.baseURL
        )
        #expect(refreshedCurrent == false)
        expectEnded(current, "a refusal of the credential in hand did not end the session")
        #expect(currentStore.lastError == nil, "this catch leaves no sentence, and never did")

        let superseded = await signedIn(renewing: true)
        let supersededStore = timeline(for: superseded)
        let supersededHandle = try #require(superseded.session.activeHandle)
        let refreshedSuperseded = await supersededStore.refreshMemo(
            uid: "a", using: supersededHandle, baseURL: Stub.baseURL
        )
        #expect(refreshedSuperseded == false)
        expectStanding(superseded, "a stale refusal ended the session")
        #expect(supersededStore.lastError == nil)
    }

    @Test("MediaLibraryStore.report — the grid's sentence follows the session's verdict")
    func mediaLibraryReport() async throws {
        let current = await signedIn(renewing: false)
        let currentStore = MediaLibraryStore(
            onUnauthorized: { [session = current.session] refusal in
                await session.handle(refusal)
            }
        )
        currentStore.reports(to: current.session)
        let currentHandle = try #require(current.session.activeHandle)
        await currentStore.refresh(using: currentHandle, baseURL: Stub.baseURL)
        expectEnded(current, "a refusal of the credential in hand did not end the session")
        #expect(currentStore.lastError != nil, "and the grid said nothing about it")

        let superseded = await signedIn(renewing: true)
        let supersededStore = MediaLibraryStore(
            onUnauthorized: { [session = superseded.session] refusal in
                await session.handle(refusal)
            }
        )
        supersededStore.reports(to: superseded.session)
        await supersededStore.refresh(
            using: try #require(superseded.session.activeHandle), baseURL: Stub.baseURL
        )
        expectStanding(superseded, "a stale refusal ended the session")
        #expect(supersededStore.lastError == nil, "and it wrote a sentence nobody earned")
    }

    // MARK: - a refusal overtaken by an ESTABLISHMENT

    // The fence every store takes before `onUnauthorized` cannot see this ordering: at the instant
    // it is taken, nothing has happened yet. The account switch lands INSIDE the await, and the
    // store then resumes and writes one identity's sentence onto another identity's screen.
    //
    // Each store has two rows, and the second is the one a question about what is ACTIVE gets
    // wrong: the replacement is withdrawn again before the store resumes, so nothing is active
    // either way — the same reading an ordinary sign-out leaves, and the rows above assert that
    // the sentence IS written there, which is the whole point of the refusal.

    /// The window, as a place the test can stand in: the session's rule runs to completion — the
    /// wipe happens, `.endedSession` is the truth — and the store is then HELD there, before the
    /// line that writes the sentence. Whatever the test does next happens inside the store's own
    /// await, which is exactly where the switch gets in.
    private func heldRule(
        of session: SessionStore,
        reached: Latch,
        release: Latch
    ) -> @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome {
        { refusal in
            let outcome = await session.handle(refusal)
            reached.signal()
            await release.wait()
            return outcome
        }
    }

    /// A whole other session, established through the REAL sign-in path while a store is held —
    /// and, in the second row, withdrawn again before it is let go.
    private func overtake(_ signed: Signed, withdrawing: Bool) async {
        await signed.session.signIn(serverAddress: storedAddress, token: successorToken)
        #expect(signed.session.state.user != nil, "the premise: a session was established")
        if withdrawing {
            await signed.session.signOutWithoutRevoking()
            #expect(signed.session.activeHandle == nil, "the premise: and it went again")
        }
    }

    @Test("TimelineStore.report — a refusal overtaken by a sign-in leaves the list no sentence")
    func timelineReportOvertaken() async throws {
        for withdrawing in [false, true] {
            let signed = await signedIn(renewing: false)
            let reached = Latch()
            let release = Latch()
            let store = TimelineStore(
                onUnauthorized: heldRule(of: signed.session, reached: reached, release: release)
            )
            store.reports(to: signed.session)
            let handle = try #require(signed.session.activeHandle)
            let refreshing = Task { await store.refresh(using: handle, baseURL: Stub.baseURL) }
            await reached.wait()

            await overtake(signed, withdrawing: withdrawing)
            // What the screen itself does on a swap, done here too — hygiene, not the fence: a
            // reset cannot stop a write that lands after it, which is what this asserts.
            store.sessionIdentityChanged(
                to: TimelineSnapshotIdentity(server: Stub.baseURL, subject: "next")
            )
            release.signal()
            await refreshing.value

            #expect(store.lastError == nil, "one identity's sentence landed on another's list")
        }
    }

    @Test("MediaLibraryStore.report — a refusal overtaken by a sign-in leaves the grid no sentence")
    func mediaLibraryReportOvertaken() async throws {
        for withdrawing in [false, true] {
            let signed = await signedIn(renewing: false)
            let reached = Latch()
            let release = Latch()
            let store = MediaLibraryStore(
                onUnauthorized: heldRule(of: signed.session, reached: reached, release: release)
            )
            store.reports(to: signed.session)
            let handle = try #require(signed.session.activeHandle)
            let refreshing = Task { await store.refresh(using: handle, baseURL: Stub.baseURL) }
            await reached.wait()

            await overtake(signed, withdrawing: withdrawing)
            store.sessionIdentityChanged()
            release.signal()
            await refreshing.value

            #expect(store.lastError == nil, "one identity's sentence landed on another's grid")
        }
    }

    @Test("PlacesStore.report — a refusal overtaken by a sign-in leaves the map no sentence")
    func placesReportOvertaken() async throws {
        for withdrawing in [false, true] {
            let signed = await signedIn(renewing: false)
            let reached = Latch()
            let release = Latch()
            let store = PlacesStore(
                onUnauthorized: heldRule(of: signed.session, reached: reached, release: release)
            )
            store.reports(to: signed.session)
            let handle = try #require(signed.session.activeHandle)
            let loading = Task { await store.load(using: handle, baseURL: Stub.baseURL) }
            await reached.wait()

            // This store has no identity reset and needs none: the signed-in view creates it and
            // drops it with itself, so the incoming identity gets a new one (`PlacesStore`).
            await overtake(signed, withdrawing: withdrawing)
            release.signal()
            await loading.value

            #expect(store.lastError == nil, "one identity's sentence landed on another's map")
        }
    }

    /// The fourth effect, and the one that writes no sentence itself: `download` forwards the
    /// session's answer and `MediaSaveFlow` turns it into the words on the save. Overtaken, what
    /// it must forward is the supersede — not silence, but the true sentence about the sign-in
    /// having changed, in place of a rejection the account now on screen never earned.
    ///
    /// The switch has to land inside the WIPE here, because this lane has no rule of its own to
    /// hold: the credential store is what lets a sign-in in there.
    @Test("download — a refusal overtaken by a sign-in is superseded, not a rejection")
    func downloadOvertaken() async throws {
        let box = LockedValue<SessionStore?>(nil)
        let signingIn = LockedValue<Bool>(false)
        let credentials = InterruptingCredentials {
            guard let session = await box.get(), signingIn.get() else { return }
            signingIn.set(false)
            await session.signIn(serverAddress: storedAddress, token: successorToken)
        }
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            }
        )
        box.set(session)
        await session.signIn(serverAddress: storedAddress, token: storedToken)
        #expect(session.state.user != nil, "the premise: there is a session to refuse")

        signingIn.set(true)
        let thrown = await #expect(throws: OriginalMediaError.self) {
            try await session.download(attachment(), transport: RenewingDownloads(status: 401) {})
        }
        #expect(session.state.user != nil, "the premise: the sign-in inside the wipe owns this")
        #expect(thrown == OriginalMediaError.superseded, "the incoming account got the rejection")
    }

    private func timeline(for signed: Signed) -> TimelineStore {
        let store = TimelineStore(
            onUnauthorized: { [session = signed.session] refusal in
                await session.handle(refusal)
            }
        )
        store.reports(to: signed.session)
        return store
    }

    private func attachment() -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            downloadURL: URL(string: "\(storedAddress)/x/original")!
        )
    }
}

/// A download that renews the session BEFORE it answers, so the reply lands on a credential the
/// request did not present.
private struct RenewingDownloads: MediaDownloadTransport {
    let status: Int
    let renew: @Sendable () async -> Void

    func download(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (URL, URLResponse)
    {
        await renew()
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
