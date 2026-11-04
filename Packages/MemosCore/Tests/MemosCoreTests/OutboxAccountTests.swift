import Foundation
import HTTPTypes
import MemosCore
import MemosOutbox
import Testing

private let signInServer = "memos.example.invalid"

/// What the outbox is allowed to upload as.
///
/// Every case here is about ONE property: the subject and the token it drains with come from the
/// same instant of the same object. Assembled from two sources they can disagree, and a capture
/// sent under a disagreement lands in the wrong account.
@MainActor
@Suite("What the outbox is allowed to upload as")
struct OutboxAccountTests {
    /// A whoami that answers with whichever account the presented token belongs to, so a switch
    /// really changes the SUBJECT as well as the credential — which is the pair this suite is
    /// about.
    private static let whoamiPerToken: StubTransport.Handler = { request, _, _ in
        let bearer = request.headerFields[.authorization] ?? ""
        let subject = bearer.contains("pat-b") ? "brenda" : "fabian"
        return Stub.json(
            #"{"subject":"\#(subject)","display_name":null,"#
                + #""email":null,"role":"user","auth_kind":"oidc"}"#
        )
    }

    private func session(
        credentials: any CredentialStore,
        handler: @escaping StubTransport.Handler = { _, _, _ in Stub.json(Stub.user) }
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
    }

    private func provider(for session: SessionStore) -> DeviceOutboxCredentials {
        DeviceOutboxCredentials(epoch: { session.epoch.current }) {
            await MainActor.run { session.credentialGrant() }
        }
    }

    @Test("the signed-in session becomes a server, an owner and a token")
    func resolvesCredentials() async throws {
        let session = session(credentials: InMemoryCredentials())
        await session.signIn(serverAddress: signInServer, token: "pat-token")

        let credentials = try #require(await provider(for: session).currentCredentials())

        #expect(credentials.serverBaseURL.absoluteString == "https://memos.example.invalid")
        #expect(credentials.ownerSubject == "fabian")
        #expect(credentials.token == "pat-token")
        #expect(
            credentials.binding
                == AccountBinding(
                    serverBaseURL: credentials.serverBaseURL, ownerSubject: "fabian"
                )
        )
    }

    @Test("nothing drains while nobody is signed in")
    func refusesWithoutASession() async {
        let session = session(credentials: InMemoryCredentials())
        #expect(await provider(for: session).currentCredentials() == nil)
    }

    /// The case an incarnation counter cannot see. A sign-in as B whose credential would not store
    /// still establishes B in memory — with B's token presented — while the keychain is left
    /// holding A's. Nothing changed between two reads, so no epoch moved; what makes the pair
    /// impossible is that both halves come from the same place.
    @Test("a sign-in whose credential would not store grants ITS token, never the stored one")
    func aStoredNowhereSignInGrantsItsOwnToken() async throws {
        let vault = FlakyCredentials()
        let session = session(credentials: vault, handler: Self.whoamiPerToken)
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        #expect(vault.snapshot()[SessionStore.tokenAccount] == "pat-a")
        #expect(session.state.user?.subject == "fabian")
        vault.refuseWrites()

        await session.signIn(serverAddress: signInServer, token: "pat-b")

        #expect(session.state.user?.subject == "brenda", "B is established; that is the premise")
        #expect(vault.snapshot()[SessionStore.tokenAccount] == "pat-a", "and storage still has A")
        let grant = try #require(await provider(for: session).currentCredentials())
        #expect(grant.ownerSubject == "brenda")
        #expect(
            grant.token == "pat-b",
            "brenda's subject beside fabian's token is a capture posted into the wrong account"
        )
    }

    @Test("a session that was withdrawn grants nothing at all")
    func aWithdrawnSessionGrantsNothing() async {
        let session = session(credentials: InMemoryCredentials())
        await session.signIn(serverAddress: signInServer, token: "pat-token")
        #expect(await provider(for: session).currentCredentials() != nil)

        await session.signOutWithoutRevoking()

        #expect(await provider(for: session).currentCredentials() == nil)
    }

    @Test("both ways of signing out tell the outbox once, after the authority has moved")
    func signingOutTellsTheOutbox() async {
        for revoking in [true, false] {
            let heard = Withdrawals()
            let session = SessionStore(
                credentials: InMemoryCredentials(),
                makeClient: { _, token in
                    Stub.client(token: token) { _, _, operation in
                        operation == "native_logout_api_auth_native_logout_post"
                            ? Stub.empty(.noContent) : Stub.json(Stub.user)
                    }
                },
                onAccountWithdrawn: { withdrawn in
                    heard.epochs.append(withdrawn)
                    heard.read.append(heard.session?.epoch.current ?? -1)
                    return nil
                }
            )
            heard.session = session
            await session.signIn(serverAddress: signInServer, token: "pat-token")
            let before = session.epoch.current
            // The sign-in itself withdrew whatever stood before it; only what follows is asked.
            let signedIn = heard.epochs.count

            if revoking {
                _ = await session.signOut()
            } else {
                await session.signOutWithoutRevoking()
            }

            let signingOut = heard.epochs.dropFirst(signedIn)
            #expect(signingOut.count == 1, "revoking: \(revoking)")
            #expect(heard.epochs == heard.read, "the epoch handed over is the one standing")
            // Told only once nothing can present the withdrawn credential any more.
            #expect(signingOut.allSatisfy { $0 > before }, "revoking: \(revoking)")
            #expect(await provider(for: session).currentCredentials() == nil)
        }
    }

    /// The outbox's cancellation is handed back by the hook, and a sign-out waits for it: a
    /// sign-out that reported itself done first could leave a background upload presenting the
    /// withdrawn credential behind a process the system then ends.
    @Test("both ways of signing out are done only once the outbox has issued its cancellation")
    func signingOutWaitsForTheCancellation() async {
        for revoking in [true, false] {
            let heard = Withdrawals()
            let session = SessionStore(
                credentials: InMemoryCredentials(),
                makeClient: { _, token in
                    Stub.client(token: token) { _, _, operation in
                        operation == "native_logout_api_auth_native_logout_post"
                            ? Stub.empty(.noContent) : Stub.json(Stub.user)
                    }
                },
                onAccountWithdrawn: { withdrawn in
                    heard.epochs.append(withdrawn)
                    return Task { @MainActor in
                        // Long enough that a sign-out not waiting for it is over first.
                        try? await Task.sleep(for: .milliseconds(300))
                        heard.read.append(withdrawn)
                    }
                }
            )
            await session.signIn(serverAddress: signInServer, token: "pat-token")

            if revoking {
                _ = await session.signOut()
            } else {
                await session.signOutWithoutRevoking()
            }

            let signedOut = heard.epochs.last
            #expect(signedOut != nil, "revoking: \(revoking)")
            #expect(
                heard.read.contains { $0 == signedOut },
                "the sign-out finished before the outbox issued its cancel (revoking: \(revoking))"
            )
            #expect(await provider(for: session).currentCredentials() == nil)
        }
    }

    @Test("another account signing in over this one tells the outbox, before anything is awaited")
    func accountReplacementTellsTheOutbox() async throws {
        let heard = Withdrawals()
        let whoami = Self.whoamiPerToken
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token, handler: whoami)
            },
            onAccountWithdrawn: { withdrawn in
                heard.epochs.append(withdrawn)
                heard.read.append(heard.session?.epoch.current ?? -1)
                return nil
            }
        )
        heard.session = session
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        let granted = try #require(await provider(for: session).currentCredentials())
        // A sign-in withdraws whatever licence stood before it, none included, so A's own counts
        // once; every one of them is handed over BEFORE the grant it installs exists.
        let before = heard.epochs.count
        #expect(heard.epochs.allSatisfy { $0 <= granted.epoch })

        await session.signIn(serverAddress: signInServer, token: "pat-b")

        #expect(heard.epochs.count == before + 1)
        // Handed over with the epoch the replacement moved to, past the one A's grant held.
        #expect(heard.epochs.last.map { $0 > granted.epoch } == true)
        #expect(heard.epochs == heard.read)
        #expect(try #require(await provider(for: session).currentCredentials()).token == "pat-b")
    }

    /// A session that tells the outbox, and a whoami that answers per token unless told to fail.
    private func withdrawingSession(
        credentials: any CredentialStore, heard: Withdrawals, failing: Failing = Failing()
    ) -> SessionStore {
        let whoami = Self.whoamiPerToken
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { request, body, operation in
                    let bearer = request.headerFields[.authorization] ?? ""
                    if failing.fails(bearer) { throw URLError(.timedOut) }
                    return try await whoami(request, body, operation)
                }
            },
            onAccountWithdrawn: { withdrawn in
                heard.epochs.append(withdrawn)
                heard.read.append(heard.session?.epoch.current ?? -1)
                return nil
            }
        )
        heard.session = session
        return session
    }

    @Test("a replacement sign-in that fails still tells the outbox the standing grant has gone")
    func aFailedReplacementSignInTellsTheOutbox() async throws {
        let heard = Withdrawals()
        let failing = Failing()
        let session = withdrawingSession(
            credentials: InMemoryCredentials(), heard: heard, failing: failing
        )
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        let granted = try #require(await provider(for: session).currentCredentials())
        let before = heard.epochs.count
        failing.fail("pat-b")

        await session.signIn(serverAddress: signInServer, token: "pat-b")

        #expect(session.state.user == nil, "the premise: the failure left nobody signed in")
        #expect(heard.epochs.count == before + 1)
        #expect(heard.epochs.last.map { $0 > granted.epoch } == true)
        #expect(heard.epochs == heard.read)
    }

    @Test("a restore over a grant held only in memory tells the outbox, admitting the stored one")
    func aRestoreThatAdmitsTellsTheOutbox() async throws {
        let heard = Withdrawals()
        let vault = FlakyCredentials()
        let session = withdrawingSession(credentials: vault, heard: heard)
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        vault.refuseWrites()
        await session.signIn(serverAddress: signInServer, token: "pat-b")
        let held = try #require(await provider(for: session).currentCredentials())
        #expect(held.token == "pat-b", "the premise: B is held in memory, A is stored")
        let before = heard.epochs.count

        await session.restore()

        #expect(try #require(await provider(for: session).currentCredentials()).token == "pat-a")
        #expect(heard.epochs.count == before + 1)
        #expect(heard.epochs.last.map { $0 > held.epoch } == true)
        #expect(heard.epochs == heard.read)
    }

    @Test("a restore over a grant held only in memory tells the outbox, parking")
    func aRestoreThatParksTellsTheOutbox() async throws {
        let heard = Withdrawals()
        let vault = FlakyCredentials()
        let failing = Failing()
        let session = withdrawingSession(credentials: vault, heard: heard, failing: failing)
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        vault.refuseWrites()
        await session.signIn(serverAddress: signInServer, token: "pat-b")
        let held = try #require(await provider(for: session).currentCredentials())
        #expect(held.token == "pat-b", "the premise: B is held in memory, A is stored")
        let before = heard.epochs.count
        failing.fail("pat-a")

        await session.restore()

        #expect(await provider(for: session).currentCredentials() == nil)
        #expect(session.state.user == nil, "the premise: the restore parked")
        #expect(heard.epochs.count == before + 1)
        #expect(heard.epochs.last.map { $0 > held.epoch } == true)
        #expect(heard.epochs == heard.read)
    }

    /// The control: a launch has presented nothing, and the tasks an earlier launch left are the
    /// stored account's own, sending a token that is still good.
    @Test("a launch's restore withdraws nothing, whether it admits or parks")
    func aLaunchRestoreTellsTheOutboxNothing() async throws {
        for parks in [false, true] {
            let vault = InMemoryCredentials()
            let first = session(credentials: vault, handler: Self.whoamiPerToken)
            await first.signIn(serverAddress: signInServer, token: "pat-a")
            let heard = Withdrawals()
            let failing = Failing()
            if parks { failing.fail("pat-a") }
            let launched = withdrawingSession(credentials: vault, heard: heard, failing: failing)

            await launched.restore()

            let admitted = await provider(for: launched).currentCredentials() != nil
            #expect(admitted != parks, "the premise, parks: \(parks)")
            #expect(heard.epochs.isEmpty, "parks: \(parks)")
        }
    }

    /// The synchronous half: what the drain asks immediately before each request it sends.
    @Test("a grant stops standing the moment the session's authority moves")
    func aGrantStopsStandingWhenAuthorityMoves() async throws {
        let session = session(credentials: InMemoryCredentials())
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        let provider = provider(for: session)
        let granted = try #require(await provider.currentCredentials())
        #expect(provider.isCurrent(granted), "the positive control: nothing has moved yet")

        await session.signIn(serverAddress: signInServer, token: "pat-b")

        #expect(
            !provider.isCurrent(granted),
            "a request about to go out under an account that is gone is not sent"
        )
    }
}

/// Which tokens the scripted server stops answering for, switched from the test.
private final class Failing: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<String> = []

    func fail(_ token: String) { lock.withLock { _ = tokens.insert(token) } }

    func fails(_ bearer: String) -> Bool {
        lock.withLock { tokens.contains { bearer.contains($0) } }
    }
}

/// What the outbox heard from a sign-out, and the session it came from, read in the handler.
@MainActor
private final class Withdrawals {
    var epochs: [Int] = []
    var read: [Int] = []
    weak var session: SessionStore?
}

/// The whole-file pilot checklist (page 4065), line 16, end to end: the session store and the real
/// outbox, composed as the app composes them, over scripted sessions of both lanes.
@MainActor
@Suite("A failed replacement sign-in stops the outgoing account's uploads")
struct FailedReplacementStopsUploadsTests {
    @Test("line 16: a replacement sign-in that fails cancels the outgoing account's tasks")
    func failedReplacementCancelsBothLanes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = Failing()
        let holder = OutboxHolder()
        let whoami = OutboxAccountTests.whoami
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { request, body, operation in
                    let bearer = request.headerFields[.authorization] ?? ""
                    if failing.fails(bearer) { throw URLError(.timedOut) }
                    return try await whoami(request, body, operation)
                }
            },
            onAccountWithdrawn: { epoch in
                guard let outbox = holder.outbox else { return nil }
                outbox.recordWithdrawal(at: epoch)
                return Task { @MainActor in await outbox.finishWithdrawal() }
            }
        )
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        let granted = try #require(
            await DeviceOutboxCredentials(epoch: { session.epoch.current }) {
                await MainActor.run { session.credentialGrant() }
            }.currentCredentials()
        )

        // A's upload is out on the whole lane, the member queue's only one (MEMNG-546): a
        // whole-file task minted under A's grant.
        let launch = UUID()
        let uploads = ListedUploads(
            WholeTaskListing(
                taskIdentifier: 7,
                taskDescription: WholeTaskIdentity(
                    jobID: UUID(), fileID: UUID(), attempt: 0, launch: launch,
                    epoch: granted.epoch
                ).taskDescription
            )
        )
        let preferences = "pilot-16-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: preferences) }
        let credentials = DeviceOutboxCredentials(epoch: { session.epoch.current }) {
            await MainActor.run { session.credentialGrant() }
        }
        holder.outbox = Outbox.composed(
            repository: try OutboxRepository(
                root: root, stillCurrent: { credentials.stillCurrent(epoch: $0) }
            ),
            credentials: credentials,
            http: RefusingHTTP(),
            uploads: BackgroundUploadScheduler(session: uploads, launch: launch),
            network: WifiPath(),
            preferences: UploadPreferences(defaults: UserDefaults(suiteName: preferences)!)
        )

        failing.fail("pat-b")
        await session.signIn(serverAddress: signInServer, token: "pat-b")
        #expect(session.state.user == nil, "the premise: the failure left nobody signed in")

        try await bounded("the whole-file task's cancel") { await uploads.untilCancelled() }
        #expect(uploads.cancelled == [7], "the outgoing account's whole-file upload still sends")
    }
}

extension OutboxAccountTests {
    /// The per-token whoami the suite above answers with, for the pilot suite beside it.
    fileprivate static var whoami: StubTransport.Handler { whoamiPerToken }
}

@MainActor
private final class OutboxHolder {
    var outbox: Outbox?
}

/// An upload session that lists what it was given and records what it is told to cancel.
private final class ListedUploads: UploadTaskSession, @unchecked Sendable {
    private let lock = NSLock()
    private let listing: [WholeTaskListing]
    private var cancels: [Int] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ listing: WholeTaskListing...) { self.listing = listing }

    var cancelled: [Int] { lock.withLock { cancels } }

    /// Returns once a cancel has reached this session.
    func untilCancelled() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock {
                guard cancels.isEmpty else { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func allTasks() async -> [WholeTaskListing] { listing }

    func uploadTask(with request: URLRequest, fromFile file: URL, description: String) -> Int {
        0
    }

    func cancel(taskIdentifier: Int) async {
        let due = lock.withLock {
            cancels.append(taskIdentifier)
            defer { waiters = [] }
            return waiters
        }
        for waiter in due { waiter.resume() }
    }
}

/// Raised when a bounded wait reaches its deadline first; the runner records it as the issue.
private struct WaitExpired: Error, CustomStringConvertible {
    let description: String
}

/// One answer, taken once, synchronously, by whichever side gets there first.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.withLock {
            guard !taken else { return false }
            taken = true
            return true
        }
    }
}

/// Returns when `operation` finishes, and throws once 30 s pass first. Both run unstructured, as
/// `bounded` in MemosOutboxTests does: a wait that ignores cancellation cannot hold the test.
private func bounded(
    _ what: String,
    _ operation: @escaping @Sendable () async -> Void
) async throws {
    let deadline: Duration = .seconds(30)
    let answer = FirstAnswer()
    let finished: Bool = await withCheckedContinuation { continuation in
        let timer = Task {
            try? await Task.sleep(for: deadline)
            if answer.claim() { continuation.resume(returning: false) }
        }
        Task {
            await operation()
            if answer.claim() {
                timer.cancel()
                continuation.resume(returning: true)
            }
        }
    }
    guard finished else {
        throw WaitExpired(description: "\(what) did not happen within \(deadline)")
    }
}

/// A server nothing should reach in this test: every request is answered 500.
private struct RefusingHTTP: OutboxHTTPPerforming {
    func perform(_ request: URLRequest, under authority: SendAuthority) async throws
        -> OutboxHTTPResponse
    {
        OutboxHTTPResponse(statusCode: 500)
    }
}

private struct WifiPath: NetworkPathProviding {
    func currentPath() -> NetworkPath {
        NetworkPath(usesCellular: false, isExpensive: false, isConstrained: false)
    }

    func onPathChange(_ handler: @escaping OutboxTrigger) {}
}
