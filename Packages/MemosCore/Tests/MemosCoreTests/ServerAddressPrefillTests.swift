import Foundation
import MemosAPI
@testable import MemosCore
import Testing

/// What the sign-in field starts with now that no address is compiled in (MEMNG-1127): the
/// server of the account the session holds, else the server this device last signed in to, else
/// nothing. Driven through the real `SessionStore` over a scripted transport, never a stand-in.
@MainActor
@Suite("The sign-in field's server address")
struct ServerAddressPrefillTests {
    private func session(
        credentials: InMemoryCredentials = InMemoryCredentials(),
        memory: ServerAddressMemory?,
        handler: @escaping StubTransport.Handler = { _, _, _ in Stub.json(Stub.user) }
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { _ in throw CancellationError() },
            serverMemory: memory
        )
    }

    /// A vault holding an install's account, as one from before this change has it.
    private func storedAccount() -> InMemoryCredentials {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        return credentials
    }

    /// A `UserDefaults` of the test's own, so one test's memory is invisible to another's.
    private func scratchDefaults() throws -> (UserDefaults, String) {
        let suite = "ServerAddressPrefillTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("a device that never signed in offers no address at all")
    func emptyDeviceOffersNothing() {
        #expect(session(memory: ServerAddressMemory()).suggestedServerAddress == "")
        #expect(session(memory: nil).suggestedServerAddress == "")
    }

    @Test("the stored account's server fills the field over an empty memory")
    func storedAccountWinsOverEmpty() async {
        let memory = ServerAddressMemory()
        let session = session(credentials: storedAccount(), memory: memory)
        #expect(session.suggestedServerAddress == "", "control: nothing before the launch read")

        await session.restore()

        #expect(session.state.user?.subject == "fabian", "control: the stored account restored")
        #expect(session.suggestedServerAddress == "memos.example.invalid")
    }

    @Test("the account the session holds wins over a different remembered server")
    func heldAccountWinsOverMemory() async throws {
        let memory = ServerAddressMemory()
        let session = session(memory: memory)
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(session.state.user?.subject == "fabian", "control: the sign-in landed")

        memory.remember(try #require(ServerConfiguration(serverAddress: "other.example.invalid")))

        #expect(memory.lastUsed == "other.example.invalid", "control: the memory moved")
        #expect(session.suggestedServerAddress == "memos.example.invalid")
    }

    @Test("the last server signed in to survives the sign-out that empties the vault")
    func lastUsedSurvivesSignOut() async {
        let credentials = InMemoryCredentials()
        let session = session(credentials: credentials, memory: ServerAddressMemory())
        await session.signIn(
            serverAddress: "  https://memos.example.invalid/ ", token: "memos_pat_good"
        )
        #expect(session.state.user?.subject == "fabian", "control: the sign-in landed")

        await session.signOutWithoutRevoking()

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty, "control: the sign-out emptied the vault")
        #expect(session.serverBaseURL == nil, "control: the session holds no server")
        #expect(session.suggestedServerAddress == "memos.example.invalid")
    }

    @Test("an install whose stored token is refused at launch still finds its server")
    func refusedRestoreKeepsTheServer() async {
        let credentials = storedAccount()
        let session = session(credentials: credentials, memory: ServerAddressMemory()) { _, _, _ in
            Stub.empty(.unauthorized)
        }

        await session.restore()

        #expect(session.state == .signedOut, "control: the refusal ended the session")
        #expect(credentials.isEmpty, "control: the refusal emptied the vault")
        #expect(session.suggestedServerAddress == "memos.example.invalid")
    }

    /// The sign-in screen is already showing the remembered server when the launch read returns
    /// another one: the suggestion has to move to the vault's server, refused or not, because the
    /// field follows it until somebody types.
    @Test("a launch that restores another stored server, then refuses it, suggests that server")
    func refusedRestoreOverRememberedServer() async throws {
        let memory = ServerAddressMemory()
        memory.remember(try #require(ServerConfiguration(serverAddress: "other.example.invalid")))
        let credentials = storedAccount()
        let session = session(credentials: credentials, memory: memory) { _, _, _ in
            Stub.empty(.unauthorized)
        }
        #expect(session.suggestedServerAddress == "other.example.invalid", "control: A on appear")

        await session.restore()

        #expect(session.state == .signedOut, "control: the refusal ended the session")
        #expect(credentials.isEmpty, "control: the refusal emptied the vault")
        #expect(session.suggestedServerAddress == "memos.example.invalid")
    }

    @Test("a sign-in the server refused remembers nothing")
    func refusedSignInRemembersNothing() async {
        let memory = ServerAddressMemory()
        let session = session(memory: memory) { _, _, _ in Stub.empty(.unauthorized) }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_revoked")

        #expect(session.state == .signedOut)
        #expect(memory.lastUsed == nil)
        #expect(session.suggestedServerAddress == "")
    }

    @Test("the remembered server outlives the process that wrote it")
    func memoryPersistsInDefaults() async throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = session(
            credentials: storedAccount(), memory: ServerAddressMemory(defaults: defaults)
        )

        await session.restore()

        #expect(ServerAddressMemory(defaults: defaults).lastUsed == "memos.example.invalid")
    }

    @Test("a remembered value that is not an address is never offered")
    func junkInDefaultsIsIgnored() throws {
        let (defaults, suite) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("http://memos.example.invalid", forKey: ServerAddressMemory.defaultsKey)
        #expect(ServerAddressMemory(defaults: defaults).lastUsed == nil)

        defaults.set("memos.example.invalid:8443", forKey: ServerAddressMemory.defaultsKey)
        #expect(ServerAddressMemory(defaults: defaults).lastUsed == "memos.example.invalid:8443")
    }
}
