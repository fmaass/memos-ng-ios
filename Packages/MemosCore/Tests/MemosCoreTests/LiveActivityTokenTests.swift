import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Live Activity push-to-start token reaches the server through the generated client
/// (MEMNG-946): POST on arrival and on change, DELETE on sign-out, each fenced by the session
/// generation the token was observed under. The real client runs over `StubTransport`, so the
/// operation, the body and the middleware are all exercised; what is asserted is the wire.
@MainActor
@Suite("Live Activity push-to-start token")
struct LiveActivityTokenTests {
    private static let register = "register_live_activity_token_api_devices_live_activity_token_post"
    private static let unregister =
        "unregister_live_activity_token_api_devices_live_activity_token_delete"
    private static let logout = "native_logout_api_auth_native_logout_post"
    private static let token = Data((0..<32).map { UInt8($0 * 7 % 256) })

    /// What left, in order: the operation, and the JSON body it carried.
    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(operation: String, body: [String: String])] = []

        func record(_ operation: String, _ body: [String: String]) {
            lock.withLock { sent.append((operation, body)) }
        }

        var operations: [String] { lock.withLock { sent.map(\.operation) } }

        func bodies(of operation: String) -> [[String: String]] {
            lock.withLock { sent.filter { $0.operation == operation }.map(\.body) }
        }
    }

    private static func session(
        wire: Wire, onRegister: (@Sendable () async -> Void)? = nil
    ) -> SessionStore {
        let handler: StubTransport.Handler = { _, body, operation in
            var fields: [String: String] = [:]
            if let body, operation == register || operation == unregister {
                let data = try await Data(collecting: body, upTo: 1 << 16)
                fields = (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
            }
            if operation == register || operation == unregister || operation == logout {
                wire.record(operation, fields)
            }
            if operation == register {
                await onRegister?()
                return Stub.empty(.noContent)
            }
            if operation == unregister || operation == logout { return Stub.empty(.noContent) }
            return Stub.json(Stub.user)
        }
        return SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
    }

    private static func store(for session: SessionStore) -> LiveActivityTokenStore {
        let store = LiveActivityTokenStore(session: { [weak session] in session?.activeHandle })
        session.liveActivityTokens = store
        return store
    }

    @Test("POST names the hex token once for two overlapping asks; sign-out DELETEs it first")
    func registersOnceAndUnregistersOnSignOut() async throws {
        let wire = Wire()
        let session = Self.session(wire: wire)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let generation = try #require(session.activeHandle?.generation)
        let store = Self.store(for: session)

        async let first = store.tokenArrived(Self.token, observedUnder: generation)
        async let second = store.tokenArrived(Self.token, observedUnder: generation)
        let answers = await [first, second]

        let hex = LiveActivityTokenStore.hex(Self.token)
        #expect(answers == [true, true])
        #expect(wire.bodies(of: Self.register) == [["token": hex, "environment": "production"]])
        #expect(store.registeredToken == hex)
        // Asked again for the token the server already holds: nothing leaves.
        #expect(await store.tokenArrived(Self.token, observedUnder: generation))
        #expect(wire.bodies(of: Self.register).count == 1)

        await session.signOut()

        #expect(wire.bodies(of: Self.unregister) == [["token": hex]])
        let order = wire.operations
        let deleted = try #require(order.firstIndex(of: Self.unregister))
        let loggedOut = try #require(order.firstIndex(of: Self.logout))
        #expect(deleted < loggedOut, "the DELETE must leave while the token can still send it")
        #expect(store.registeredToken == nil)
    }

    @Test("a changed token is posted again, and only the latest is held")
    func reRegistersOnChange() async throws {
        let wire = Wire()
        let session = Self.session(wire: wire)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let generation = try #require(session.activeHandle?.generation)
        let store = Self.store(for: session)
        let next = Data(repeating: 0xab, count: 32)

        #expect(await store.tokenArrived(Self.token, observedUnder: generation))
        #expect(await store.tokenArrived(next, observedUnder: generation))

        #expect(
            wire.bodies(of: Self.register).map { $0["token"] }
                == [LiveActivityTokenStore.hex(Self.token), LiveActivityTokenStore.hex(next)])
        #expect(store.registeredToken == LiveActivityTokenStore.hex(next))
    }

    @Test("a token observed under a previous sign-in never posts under the next one")
    func previousSignInNeverPosts() async throws {
        let wire = Wire()
        let session = Self.session(wire: wire)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let earlier = try #require(session.activeHandle?.generation)
        await session.signOutWithoutRevoking()
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token-2")
        let later = try #require(session.activeHandle?.generation)
        #expect(earlier != later, "precondition: the second sign-in is another generation")
        let store = Self.store(for: session)

        #expect(await store.tokenArrived(Self.token, observedUnder: earlier) == false)

        #expect(wire.bodies(of: Self.register).isEmpty)
        #expect(store.registeredToken == nil)
    }

    @Test("a POST answered after its session ended records nothing")
    func answerOutlivingItsSessionRecordsNothing() async throws {
        let wire = Wire()
        let ended = SessionSlot<SessionStore?>(nil)
        let session = Self.session(wire: wire) {
            // The session ends while the POST is on the wire.
            await Task { @MainActor in await ended.value?.signOutWithoutRevoking() }.value
        }
        ended.value = session
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let generation = try #require(session.activeHandle?.generation)
        let store = Self.store(for: session)

        let accepted = await store.tokenArrived(Self.token, observedUnder: generation)

        #expect(wire.bodies(of: Self.register).count == 1, "positive control: the POST left")
        #expect(accepted == false)
        #expect(store.registeredToken == nil)
    }
}

/// A mutable reference a `@Sendable` closure can read once the test has filled it.
private final class SessionSlot<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
