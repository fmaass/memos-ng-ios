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
                onCredentialWiped: { heard.epochs.append(heard.session?.epoch.current ?? -1) }
            )
            heard.session = session
            await session.signIn(serverAddress: signInServer, token: "pat-token")
            let before = session.epoch.current

            if revoking {
                _ = await session.signOut()
            } else {
                await session.signOutWithoutRevoking()
            }

            #expect(heard.epochs.count == 1, "revoking: \(revoking)")
            // Told only once nothing can present the withdrawn credential any more.
            #expect(heard.epochs.allSatisfy { $0 > before }, "revoking: \(revoking)")
            #expect(await provider(for: session).currentCredentials() == nil)
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

/// What the outbox heard from a sign-out, and the session it came from, read in the handler.
@MainActor
private final class Withdrawals {
    var epochs: [Int] = []
    weak var session: SessionStore?
}
