import Foundation
import MemosCore
import MemosOutbox
import Testing

@Suite("What the outbox is allowed to upload as")
struct OutboxAccountTests {
    private func store(token: String? = "pat-token", server: String? = "memos.example.invalid")
        -> InMemoryCredentials
    {
        let store = InMemoryCredentials()
        if let token { try? store.set(token, for: SessionStore.tokenAccount) }
        if let server { try? store.set(server, for: SessionStore.serverAccount) }
        return store
    }

    @Test("the signed-in session becomes a server, an owner and a token")
    func resolvesCredentials() async throws {
        let provider = DeviceOutboxCredentials(credentials: store()) { "fabian" }
        let credentials = try #require(await provider.currentCredentials())
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

    @Test("nothing drains while nobody is signed in, or while a half-credential is stored")
    func refusesIncompleteCredentials() async {
        #expect(
            await DeviceOutboxCredentials(credentials: store()) { nil }
                .currentCredentials() == nil)
        #expect(
            await DeviceOutboxCredentials(credentials: store()) { "" }
                .currentCredentials() == nil)
        #expect(
            await DeviceOutboxCredentials(credentials: store(token: nil)) { "fabian" }
                .currentCredentials() == nil)
        #expect(
            await DeviceOutboxCredentials(credentials: store(token: "")) { "fabian" }
                .currentCredentials() == nil)
        #expect(
            await DeviceOutboxCredentials(credentials: store(server: nil)) { "fabian" }
                .currentCredentials() == nil)
        #expect(
            await DeviceOutboxCredentials(credentials: store(server: "not a url")) { "fabian" }
                .currentCredentials() == nil)
    }

    @Test("a token is read per drain, so signing out stops the next one")
    func readsPerDrain() async throws {
        let store = store()
        let provider = DeviceOutboxCredentials(credentials: store) { "fabian" }
        #expect(await provider.currentCredentials() != nil)
        try store.remove(SessionStore.tokenAccount)
        #expect(await provider.currentCredentials() == nil)
    }
}
