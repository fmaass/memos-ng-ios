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

    /// `TagStore` and `HeatmapStore` end nothing — they ask the read-only half of the rule — and
    /// their arm is one more `else if` with NO `return`, so the spinner comes down either way.
    @Test("TagStore.load and HeatmapStore.load — a sentence for one refusal, none for the other")
    func reportingStores() async throws {
        for renewing in [false, true] {
            let signed = await signedIn(renewing: renewing)
            let handle = try #require(signed.session.activeHandle)
            let tags = TagStore()
            tags.reports(to: signed.session)
            let heatmap = HeatmapStore()
            heatmap.reports(to: signed.session)

            await tags.load(using: handle)
            await heatmap.load(using: handle)

            #expect(!tags.isLoading, "TagStore stranded its spinner")
            #expect(!heatmap.isLoading, "HeatmapStore stranded its spinner")
            #expect((tags.lastError != nil) == !renewing, "TagStore's sentence ignored the epoch")
            #expect(
                (heatmap.lastError != nil) == !renewing, "HeatmapStore's sentence ignored the epoch"
            )
            // Neither of them may end anything, whichever refusal it was.
            #expect(signed.session.state.user != nil, "a reporting store ended a session")
        }
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
