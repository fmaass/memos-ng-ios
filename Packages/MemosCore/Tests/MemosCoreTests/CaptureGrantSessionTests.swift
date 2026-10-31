import Foundation
import HTTPTypes
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

private let mintOperation = "mint_capture_grant_api_tokens_capture_grant_post"
private let revokeGrantOperation = "revoke_capture_grant_api_tokens_capture_grant__grant_id__delete"
private let logoutOperation = "native_logout_api_auth_native_logout_post"

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
private func mintedGrant(id: Int, token: String) -> (HTTPResponse, HTTPBody?) {
    Stub.json(
        #"{"id":\#(id),"name":"Capture grant, phone","created_at":"2026-10-31T09:00:00Z","#
            + #""expires_at":"2026-11-01T09:00:00Z","token":"\#(token)"}"#,
        status: .created)
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

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// `answer` decides the mint and the revoke; everything else answers as a signed-in server.
    private func rig(
        answer: @escaping @Sendable (String, HTTPRequest) async -> (HTTPResponse, HTTPBody?)? = {
            _, _ in nil
        }
    ) -> Rig {
        let root = FileManager.default.temporaryDirectory.appending(path: "grant-\(UUID())")
        let wire = Wire()
        let account = OutboxAccountStore(root: root)
        let grants = CaptureGrantStore(root: root)
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { request, _, operation in
                    wire.record(request, operation)
                    if let scripted = await answer(operation, request) { return scripted }
                    switch operation {
                    case mintOperation: return mintedGrant(id: 9, token: "memos_cap_one")
                    case revokeGrantOperation, logoutOperation: return Stub.empty(.noContent)
                    default: return Stub.json(Stub.user)
                    }
                }
            },
            account: account,
            captureGrants: grants
        )
        return Rig(root: root, session: session, account: account, grants: grants, wire: wire)
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
}
