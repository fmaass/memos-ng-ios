import Foundation
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
        let session = session(credentials: vault)
        await session.signIn(serverAddress: signInServer, token: "pat-a")
        #expect(vault.snapshot()[SessionStore.tokenAccount] == "pat-a")
        vault.refuseWrites()

        await session.signIn(serverAddress: signInServer, token: "pat-b")

        #expect(session.state.user != nil, "B is established in memory; that is the premise")
        #expect(vault.snapshot()[SessionStore.tokenAccount] == "pat-a", "and storage still has A")
        let grant = try #require(await provider(for: session).currentCredentials())
        #expect(grant.token == "pat-b", "the grant is B's own credential, not the stored one")
    }

    @Test("a session that was withdrawn grants nothing at all")
    func aWithdrawnSessionGrantsNothing() async {
        let session = session(credentials: InMemoryCredentials())
        await session.signIn(serverAddress: signInServer, token: "pat-token")
        #expect(await provider(for: session).currentCredentials() != nil)

        await session.signOutWithoutRevoking()

        #expect(await provider(for: session).currentCredentials() == nil)
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
