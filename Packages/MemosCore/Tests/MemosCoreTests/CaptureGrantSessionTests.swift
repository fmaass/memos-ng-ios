import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

private let mintOperation = "mint_capture_grant_api_tokens_capture_grant_post"
private let revokeGrantOperation = "revoke_capture_grant_api_tokens_capture_grant__grant_id__delete"
private let logoutOperation = "native_logout_api_auth_native_logout_post"
private let renewOperation = "native_renew_api_auth_native_renew_post"
private let tokenReadOperation = "native_token_api_auth_native_token_get"

/// One request as the scripted server saw it.
private struct SeenRequest: Sendable, Equatable {
    var operation: String
    var path: String
    var bearer: String
}

private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [SeenRequest] = []

    func record(_ request: HTTPRequest, _ operation: String) {
        let entry = SeenRequest(
            operation: operation, path: request.path ?? "",
            bearer: request.headerFields[.authorization] ?? "")
        lock.withLock { seen.append(entry) }
    }

    func calls(_ operation: String) -> [SeenRequest] {
        lock.withLock { seen.filter { $0.operation == operation } }
    }
}

/// What `POST /api/tokens/capture-grant` answers: the row and the plaintext, once.
private func mintedGrant(
    id: Int, token: String, expiresAt: String = "2026-11-01T09:00:00Z"
) -> (HTTPResponse, HTTPBody?) {
    Stub.json(
        #"{"id":\#(id),"name":"Capture grant, phone","created_at":"2026-10-31T09:00:00Z","#
            + #""expires_at":"\#(expiresAt)","token":"\#(token)"}"#,
        status: .created)
}

/// An instant one hour into the default grant's 24: 23 hours left.
private let hourOne = ISO8601DateFormatter().date(from: "2026-10-31T10:00:00Z")!

/// Every refusal the app's bearer middleware threw, exactly as it threw it.
private final class Refusals: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [CredentialRefusal] = []

    func record(_ refusal: CredentialRefusal) { lock.withLock { seen.append(refusal) } }
    var all: [CredentialRefusal] { lock.withLock { seen } }
}

/// Sits in front of the app's own middleware chain and only watches: what a 401 becomes on its way
/// to the store is read here, as the typed value, rather than inferred from the effect.
private struct RefusalWitness: ClientMiddleware {
    typealias Answer = (HTTPResponse, HTTPBody?)
    /// `@concurrent` for the reason `RenewingOnRefusal` gives.
    typealias Next = @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> Answer

    let refusals: Refusals

    nonisolated func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: Next
    ) async throws -> Answer {
        do {
            return try await next(request, body, baseURL)
        } catch {
            // The runtime hands an outer middleware the inner one's error inside its envelope.
            let thrown = (error as? ClientError)?.underlyingError ?? error
            if let refusal = thrown as? CredentialRefusal { refusals.record(refusal) }
            throw error
        }
    }
}

/// The share extension's capture grant, from the app's side (MEMNG-938): minted per foreground
/// with the device token, written beside the licence stamped with its issue, and ended with the
/// session. Driven through the real generated client over a scripted transport.
@MainActor
@Suite("The capture grant the app mints for the share extension")
struct CaptureGrantSessionTests {
    private struct Rig {
        let root: URL
        let session: SessionStore
        let account: OutboxAccountStore
        let grants: CaptureGrantStore
        let wire: Wire
        let credentials: InMemoryCredentials
        let refusals: Refusals
        /// The credential the newest client was built with — the one a refusal is judged against.
        let presented: LockedValue<PresentedCredential?>

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// `answer` decides the mint and the revoke; everything else answers as a signed-in server.
    private func rig(
        clock: LockedValue<Date>? = nil,
        answer: @escaping @Sendable (String, HTTPRequest) async -> (HTTPResponse, HTTPBody?)? = {
            _, _ in nil
        }
    ) -> Rig {
        let root = FileManager.default.temporaryDirectory.appending(path: "grant-\(UUID())")
        let wire = Wire()
        let account = OutboxAccountStore(root: root)
        let grants = CaptureGrantStore(root: root)
        let credentials = InMemoryCredentials()
        let refusals = Refusals()
        let presented = LockedValue<PresentedCredential?>(nil)
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                presented.set(token)
                let transport = StubTransport(handler: { request, _, operation in
                    wire.record(request, operation)
                    if let scripted = await answer(operation, request) { return scripted }
                    switch operation {
                    case mintOperation: return mintedGrant(id: 9, token: "memos_cap_one")
                    case revokeGrantOperation, logoutOperation: return Stub.empty(.noContent)
                    case renewOperation: return Stub.json(Stub.exchange(token: "pat-next"))
                    case tokenReadOperation: return Stub.json(Stub.nativeToken(name: "phone"))
                    default: return Stub.json(Stub.user)
                    }
                })
                // The app's own chain (`APIClientFactory.make(configuration:credential:)`), with
                // the witness in front of it.
                return Client(
                    serverURL: Stub.baseURL,
                    configuration: APIClientFactory.runtimeConfiguration,
                    transport: transport,
                    middlewares: [
                        RefusalWitness(refusals: refusals),
                        BearerAuthMiddleware(credential: token),
                        BusyAnswerMiddleware(),
                        ExplicitNullMiddleware(),
                    ]
                )
            },
            // A value, not a closure, so that a trailing `answer` still reaches `answer`.
            now: { clock?.get() ?? Date() },
            account: account,
            captureGrants: grants
        )
        return Rig(
            root: root, session: session, account: account, grants: grants, wire: wire,
            credentials: credentials, refusals: refusals, presented: presented)
    }

    @Test("a foreground mints the grant with the device token and stamps it with the licence issue")
    func foregroundMintsAndStamps() async throws {
        let rig = rig()
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await rig.session.enteredForeground()

        let licence = try #require(rig.account.currentLicence())
        let grant = try #require(rig.grants.current())
        #expect(grant.token == "memos_cap_one")
        #expect(grant.id == 9)
        #expect(grant.incarnation == licence.incarnation)
        #expect(grant.binding == licence.binding)
        #expect(rig.wire.calls(mintOperation).map(\.bearer) == ["Bearer pat-token"])
    }

    @Test("two overlapping foregrounds are one mint on the wire")
    func overlappingMintsJoin() async throws {
        let held = Gate()
        let rig = rig { operation, _ in
            guard operation == mintOperation else { return nil }
            await held.wait()
            return mintedGrant(id: 9, token: "memos_cap_one")
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let first = Task { await rig.session.mintCaptureGrant() }
        let second = Task { await rig.session.mintCaptureGrant() }
        for _ in 0..<200 where rig.wire.calls(mintOperation).isEmpty { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        held.open()
        await first.value
        await second.value
        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(rig.grants.current()?.token == "memos_cap_one")
    }

    @Test("a sign-out that races a mint leaves no grant behind")
    func signOutRacingAMintLeavesNothing() async throws {
        let mintHeld = Gate()
        let logoutHeld = Gate()
        let rig = rig { operation, _ in
            switch operation {
            case mintOperation:
                await mintHeld.wait()
                return mintedGrant(id: 9, token: "memos_cap_late")
            case logoutOperation:
                await logoutHeld.wait()
                return Stub.empty(.noContent)
            default: return nil
            }
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let mint = Task { await rig.session.mintCaptureGrant() }
        for _ in 0..<200 where rig.wire.calls(mintOperation).isEmpty { await Task.yield() }
        // The sign-out is under way — its revoke on the wire, nothing wiped yet, the licence
        // still published and the epoch unmoved — when the mint answers.
        let signOut = Task { await rig.session.signOut() }
        for _ in 0..<200 where rig.wire.calls(logoutOperation).isEmpty { await Task.yield() }
        mintHeld.open()
        await mint.value
        #expect(rig.grants.current() == nil)
        logoutHeld.open()
        #expect(await signOut.value == .revoked)
        #expect(rig.grants.current() == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.grants.url.path()))
    }

    @Test("a stale mint answer writes nothing over the grant of a newer licence issue")
    func staleMintWritesNothingOverNewerIssue() async throws {
        let held = Gate()
        let rig = rig { operation, request in
            guard operation == mintOperation,
                request.headerFields[.authorization] == "Bearer pat-a"
            else { return nil }
            await held.wait()
            return mintedGrant(id: 4, token: "memos_cap_stale")
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        let stale = Task { await rig.session.mintCaptureGrant() }
        for _ in 0..<200 where rig.wire.calls(mintOperation).isEmpty { await Task.yield() }
        // A sign-in over the session: a new licence issue, and its own foreground mint.
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-b")
        await rig.session.enteredForeground()
        let fresh = try #require(rig.grants.current())
        held.open()
        await stale.value
        #expect(rig.grants.current() == fresh)
        #expect(fresh.token == "memos_cap_one")
        #expect(fresh.incarnation == rig.account.currentLicence()?.incarnation)
    }

    @Test("signing out revokes the grant with the token that minted it, then the token; file gone")
    func signOutRevokesTheGrant() async throws {
        let rig = rig()
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await rig.session.enteredForeground()
        #expect(rig.grants.current() != nil)

        #expect(await rig.session.signOut() == .revoked)

        let revoke = rig.wire.calls(revokeGrantOperation)
        #expect(revoke.map(\.path) == ["/api/tokens/capture-grant/9"])
        #expect(revoke.map(\.bearer) == ["Bearer pat-token"])
        #expect(rig.wire.calls(logoutOperation).count == 1)
        #expect(rig.grants.current() == nil)
        #expect(rig.account.currentLicence() == nil)
    }

    @Test("an account change revokes the outgoing grant with the outgoing token; file gone")
    func accountChangeRevokesTheGrant() async throws {
        let rig = rig()
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        await rig.session.enteredForeground()
        let outgoing = try #require(rig.grants.current())

        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-b")

        #expect(rig.grants.current() == nil)
        for _ in 0..<500 where rig.wire.calls(revokeGrantOperation).isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        let revoke = rig.wire.calls(revokeGrantOperation)
        #expect(revoke.map(\.path) == ["/api/tokens/capture-grant/\(outgoing.id)"])
        #expect(revoke.map(\.bearer) == ["Bearer pat-a"])
    }

    @Test("a sign-out whose grant revoke outlives a new sign-in leaves the new session intact")
    func signOutParkedOnTheGrantRevokeSparesTheNextSession() async throws {
        let revokeHeld = Gate()
        let rig = rig { operation, request in
            guard operation == revokeGrantOperation,
                request.headerFields[.authorization] == "Bearer pat-a"
            else { return nil }
            await revokeHeld.wait()
            return Stub.empty(.noContent)
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        await rig.session.enteredForeground()
        #expect(rig.grants.current() != nil)
        // A's sign-out parks on the grant's revoke, its first await.
        let signOut = Task { await rig.session.signOut() }
        for _ in 0..<200 where rig.wire.calls(revokeGrantOperation).isEmpty { await Task.yield() }
        // Parked where it should be — a mutant that skips the revoke fails here, not by hanging.
        try #require(rig.wire.calls(revokeGrantOperation).count == 1)
        // B signs in over it and comes to the front — B's mint is not A's retirement's to
        // refuse — and only then do A's revoke and logout answer.
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-b")
        await rig.session.enteredForeground()
        #expect(rig.wire.calls(mintOperation).map(\.bearer) == ["Bearer pat-a", "Bearer pat-b"])
        let grantOfB = try #require(rig.grants.current())
        revokeHeld.open()
        #expect(await signOut.value == .revoked)

        #expect(rig.wire.calls(logoutOperation).map(\.bearer) == ["Bearer pat-a"])
        guard case .signedIn = rig.session.state else {
            Issue.record("A's sign-out ended B's session: \(rig.session.state)")
            return
        }
        let licence = try #require(rig.account.currentLicence())
        #expect(rig.grants.current() == grantOfB)
        #expect(grantOfB.incarnation == licence.incarnation)
    }

    @Test("no mint starts while a sign-out is retiring the grant: it refuses, it does not join")
    func mintRefusedWhileRetiring() async throws {
        let revokeHeld = Gate()
        let rig = rig { operation, _ in
            guard operation == revokeGrantOperation else { return nil }
            await revokeHeld.wait()
            return Stub.empty(.noContent)
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await rig.session.enteredForeground()
        #expect(rig.wire.calls(mintOperation).count == 1)
        let signOut = Task { await rig.session.signOut() }
        for _ in 0..<200 where rig.wire.calls(revokeGrantOperation).isEmpty { await Task.yield() }
        // Parked where it should be — a mutant that skips the revoke fails here, not by hanging.
        try #require(rig.wire.calls(revokeGrantOperation).count == 1)

        // Retirement has begun — the file is gone, the revoke parked, the licence still there.
        await rig.session.mintCaptureGrant()
        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(rig.grants.current() == nil)

        revokeHeld.open()
        #expect(await signOut.value == .revoked)
        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(!FileManager.default.fileExists(atPath: rig.grants.url.path()))
    }

    @Test("two overlapping sign-outs: the first ending leaves the mint refused until the last ends")
    func overlappingSignOutsRefuseUntilTheLast() async throws {
        let revokeHeld = Gate()
        let logoutHeld = Gate()
        let logouts = Counter()
        defer {
            revokeHeld.open()
            logoutHeld.open()
        }
        let rig = rig { operation, _ in
            switch operation {
            case revokeGrantOperation:
                await revokeHeld.wait()
                return Stub.empty(.noContent)
            case logoutOperation:
                logouts.increment()
                // The second sign-out's logout reaches the wire first and parks; the first
                // sign-out's, behind its grant revoke, is turned down and ends it unrevoked.
                guard logouts.count == 1 else { return Stub.databaseBusy() }
                await logoutHeld.wait()
                return Stub.empty(.noContent)
            default: return nil
            }
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await rig.session.enteredForeground()
        let first = Task { await rig.session.signOut() }
        for _ in 0..<200 where rig.wire.calls(revokeGrantOperation).isEmpty { await Task.yield() }
        // Parked where it should be — a mutant that skips the revoke fails here, not by hanging.
        try #require(rig.wire.calls(revokeGrantOperation).count == 1)
        let second = Task { await rig.session.signOut() }
        for _ in 0..<200 where rig.wire.calls(logoutOperation).isEmpty { await Task.yield() }
        try #require(rig.wire.calls(logoutOperation).count == 1)
        revokeHeld.open()
        #expect(await first.value == .revokeFailed(.server(status: 503)))

        // The session is still this one and the second sign-out is still retiring it.
        await rig.session.mintCaptureGrant()
        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(rig.grants.current() == nil)

        logoutHeld.open()
        #expect(await second.value == .revoked)
        #expect(rig.wire.calls(mintOperation).count == 1)
    }

    // MARK: - a mint the server refuses (MEMNG-1083 item 1)

    @Test("a mint refused under the credential still presented signs out; no grant is written")
    func mintRefusedUnderTheCurrentCredentialSignsOut() async throws {
        let rig = rig { operation, _ in
            operation == mintOperation ? Stub.empty(.unauthorized) : nil
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let presented = try #require(rig.presented.get()).presented()

        await rig.session.mintCaptureGrant()

        // The premise: the 401 reached the store as the typed refusal, carrying the generation the
        // mint presented — not as a status somebody re-classified.
        #expect(rig.wire.calls(mintOperation).map(\.bearer) == ["Bearer pat-token"])
        #expect(rig.refusals.all == [CredentialRefusal(issuedUnder: presented.epoch)])
        #expect(rig.session.state.user == nil, "a refusal of the live token ended nothing")
        #expect(try rig.credentials.string(for: SessionStore.tokenAccount) == nil)
        #expect(rig.grants.current() == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.grants.url.path()))
    }

    @Test("a mint refused after a renewal replaced its token leaves the renewed session alone")
    func staleMintRefusalSparesTheRenewedSession() async throws {
        let held = Gate()
        let rig = rig { operation, request in
            guard operation == mintOperation,
                request.headerFields[.authorization] == "Bearer pat-a"
            else { return nil }
            await held.wait()
            return Stub.empty(.unauthorized)
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        let credential = try #require(rig.presented.get())
        let before = credential.presented().epoch
        let stale = Task { await rig.session.mintCaptureGrant() }
        for _ in 0..<200 where rig.wire.calls(mintOperation).isEmpty { await Task.yield() }
        try #require(rig.wire.calls(mintOperation).count == 1)

        #expect(await rig.session.renewDeviceToken() == .renewed)
        let onFile = rig.grants.current()
        held.open()
        await stale.value

        let refusal = try #require(rig.refusals.all.first)
        #expect(refusal == CredentialRefusal(issuedUnder: before))
        #expect(!refusal.concernsCurrentCredential(of: credential), "premise: the old token")
        #expect(rig.session.state.user != nil, "a stale refusal ended the renewed session")
        #expect(try rig.credentials.string(for: SessionStore.tokenAccount) == "pat-next")
        #expect(rig.session.credentialGrant()?.token == "pat-next")
        #expect(rig.grants.current() == onFile, "the stale refusal changed the grant on file")
    }

    @Test("a mint refused after a new sign-in leaves the new session alone")
    func staleMintRefusalSparesTheNextSignIn() async throws {
        let held = Gate()
        let rig = rig { operation, request in
            guard operation == mintOperation,
                request.headerFields[.authorization] == "Bearer pat-a"
            else { return nil }
            await held.wait()
            return Stub.empty(.unauthorized)
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        let outgoing = try #require(rig.presented.get()).presented()
        let stale = Task { await rig.session.mintCaptureGrant() }
        for _ in 0..<200 where rig.wire.calls(mintOperation).isEmpty { await Task.yield() }
        try #require(rig.wire.calls(mintOperation).count == 1)

        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-b")
        await rig.session.enteredForeground()
        let grantOfB = try #require(rig.grants.current())
        held.open()
        await stale.value

        #expect(rig.refusals.all == [CredentialRefusal(issuedUnder: outgoing.epoch)])
        guard case .signedIn = rig.session.state else {
            Issue.record("A's refused mint ended B's session: \(rig.session.state)")
            return
        }
        #expect(try rig.credentials.string(for: SessionStore.tokenAccount) == "pat-b")
        #expect(rig.session.credentialGrant()?.token == "pat-b")
        #expect(rig.grants.current() == grantOfB)
    }

    // MARK: - re-mint only near expiry (MEMNG-1083 item 3)

    @Test("a foreground with a fresh grant of this licence issue on file sends no mint")
    func freshGrantIsKept() async throws {
        let rig = rig(clock: LockedValue(hourOne))
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await rig.session.enteredForeground()
        let standing = try #require(rig.grants.current())

        await rig.session.enteredForeground()

        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(rig.grants.current() == standing)
    }

    @Test("a foreground with a grant inside the re-mint margin mints a new one")
    func grantNearExpiryIsReminted() async throws {
        let clock = LockedValue(hourOne)
        let minted = Counter()
        let rig = rig(clock: clock) { operation, _ in
            guard operation == mintOperation else { return nil }
            minted.increment()
            return mintedGrant(id: 9 + minted.count, token: "memos_cap_\(minted.count)")
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        await rig.session.enteredForeground()
        let first = try #require(rig.grants.current())
        // A second short of the margin before the grant lapses.
        clock.set(first.expiresAt.addingTimeInterval(-PublishedCaptureGrant.remintBelow + 1))

        await rig.session.enteredForeground()

        #expect(rig.wire.calls(mintOperation).count == 2)
        #expect(rig.grants.current()?.token == "memos_cap_2")
    }

    @Test("a fresh grant of another licence issue or binding on file is replaced by a mint")
    func grantOfAnotherIssueIsReminted() async throws {
        let rig = rig(clock: LockedValue(hourOne))
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let licence = try #require(rig.account.currentLicence())
        let fresh = hourOne.addingTimeInterval(23 * 3600)
        try rig.grants.write(
            PublishedCaptureGrant(
                id: 4, token: "memos_cap_other_issue", expiresAt: fresh,
                binding: licence.binding, incarnation: UUID()))
        await rig.session.enteredForeground()
        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(rig.grants.current()?.token == "memos_cap_one")

        let elsewhere = AccountBinding(
            serverBaseURL: URL(string: "https://other.example.invalid")!, ownerSubject: "fabian")
        try rig.grants.write(
            PublishedCaptureGrant(
                id: 5, token: "memos_cap_other_binding", expiresAt: fresh, binding: elsewhere,
                incarnation: try #require(licence.incarnation)))
        await rig.session.enteredForeground()
        #expect(rig.wire.calls(mintOperation).count == 2)
        #expect(rig.grants.current()?.token == "memos_cap_one")
    }

    @Test("a fresh-looking grant this launch did not mint is replaced; this launch's own is kept")
    func onlyAGrantThisLaunchMintedIsKept() async throws {
        let renewedMints = Counter()
        let rig = rig(clock: LockedValue(hourOne)) { operation, request in
            guard operation == mintOperation,
                request.headerFields[.authorization] == "Bearer pat-next"
            else { return nil }
            renewedMints.increment()
            // The renewal's own mint fails, so only the next foreground can replace the dead grant.
            guard renewedMints.count > 1 else { return Stub.empty(.internalServerError) }
            return mintedGrant(id: 12, token: "memos_cap_next")
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        let licence = try #require(rig.account.currentLicence())
        // Left by an earlier launch — say a renewal on an older build, which kept the file while
        // the server revoked the grant: this issue, this binding, 20 hours left.
        try rig.grants.write(
            PublishedCaptureGrant(
                id: 4, token: "memos_cap_earlier_launch",
                expiresAt: hourOne.addingTimeInterval(20 * 3600),
                binding: licence.binding, incarnation: try #require(licence.incarnation)))

        await rig.session.enteredForeground()
        #expect(rig.wire.calls(mintOperation).map(\.bearer) == ["Bearer pat-a"])
        #expect(rig.grants.current()?.token == "memos_cap_one")

        await rig.session.enteredForeground()
        #expect(rig.wire.calls(mintOperation).count == 1, "this launch's own grant was re-minted")

        #expect(await rig.session.renewDeviceToken() == .renewed)
        #expect(rig.grants.current() == nil, "the renewal left the dead grant on file")
        await rig.session.enteredForeground()
        #expect(
            rig.wire.calls(mintOperation).map(\.bearer)
                == ["Bearer pat-a", "Bearer pat-next", "Bearer pat-next"])
        #expect(rig.grants.current()?.token == "memos_cap_next")
    }

    // MARK: - a renewal mints again (MEMNG-1083 item 4)

    @Test("a renewal drops the dead grant and mints under the successor, revoking nothing")
    func renewalMintsUnderTheSuccessor() async throws {
        let rig = rig(clock: LockedValue(hourOne)) { operation, request in
            guard operation == mintOperation,
                request.headerFields[.authorization] == "Bearer pat-next"
            else { return nil }
            return mintedGrant(id: 12, token: "memos_cap_next")
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        await rig.session.enteredForeground()
        #expect(rig.grants.current()?.id == 9, "control: a fresh grant under the old token")

        #expect(await rig.session.renewDeviceToken() == .renewed)

        #expect(
            rig.wire.calls(mintOperation).map(\.bearer) == ["Bearer pat-a", "Bearer pat-next"])
        let grant = try #require(rig.grants.current())
        #expect(grant.id == 12)
        #expect(grant.token == "memos_cap_next")
        #expect(grant.incarnation == rig.account.currentLicence()?.incarnation)
        // The server revoked the old grant with its token; there is nothing to ask it.
        #expect(rig.wire.calls(revokeGrantOperation).isEmpty)
    }

    @Test("a renewal answered after the session ended mints nothing")
    func renewalForAnEndedSessionMintsNothing() async throws {
        let held = Gate()
        let rig = rig { operation, _ in
            guard operation == renewOperation else { return nil }
            await held.wait()
            return Stub.json(Stub.exchange(token: "pat-next"))
        }
        defer { rig.cleanUp() }
        await rig.session.signIn(serverAddress: "memos.example.invalid", token: "pat-a")
        await rig.session.enteredForeground()
        let renewal = Task { await rig.session.renewDeviceToken() }
        for _ in 0..<200 where rig.wire.calls(renewOperation).isEmpty { await Task.yield() }
        try #require(rig.wire.calls(renewOperation).count == 1)
        #expect(await rig.session.signOut() == .revoked)
        held.open()

        #expect(await renewal.value == .failed)
        #expect(rig.wire.calls(mintOperation).count == 1)
        #expect(rig.grants.current() == nil)
    }
}
