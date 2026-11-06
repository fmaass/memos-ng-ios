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
    nonisolated private static let register =
        "register_live_activity_token_api_devices_live_activity_token_post"
    nonisolated private static let unregister =
        "unregister_live_activity_token_api_devices_live_activity_token_delete"
    nonisolated private static let logout = "native_logout_api_auth_native_logout_post"
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
        let parked = Parking()
        let session = Self.session(wire: wire) { await parked.wait() }
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let generation = try #require(session.activeHandle?.generation)
        let store = Self.store(for: session)

        // The first POST is held on the wire while the second ask arrives: only the join can
        // keep the second off the transport, since nothing is recorded yet.
        let first = Task { await store.tokenArrived(Self.token, observedUnder: generation) }
        try await Self.until { wire.bodies(of: Self.register).count == 1 }
        let second = Task { await store.tokenArrived(Self.token, observedUnder: generation) }
        for _ in 0..<200 { await Task.yield() }
        #expect(wire.bodies(of: Self.register).count == 1, "the second ask reached the wire")
        parked.open()
        let answers = [await first.value, await second.value]

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

    @Test("a stale arrival never posts under its session; resubmit posts it once under the next")
    func staleArrivalIsResubmittedUnderTheNextSession() async throws {
        let wire = Wire()
        let session = Self.session(wire: wire)
        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token")
        let earlier = try #require(session.activeHandle?.generation)
        let store = Self.store(for: session)
        await session.signOutWithoutRevoking()

        // The token is the DEVICE's: it arrives after session A ended and is not posted under A.
        #expect(await store.tokenArrived(Self.token, observedUnder: earlier) == false)
        #expect(wire.bodies(of: Self.register).isEmpty)

        await session.signIn(serverAddress: "memos.example.invalid", token: "pat-token-2")
        let later = try #require(session.activeHandle?.generation)
        #expect(await store.resubmit(under: later))
        #expect(await store.resubmit(under: later))

        let hex = LiveActivityTokenStore.hex(Self.token)
        #expect(wire.bodies(of: Self.register) == [["token": hex, "environment": "production"]])
        #expect(store.registeredToken == hex)
    }

    /// Polls until `condition` holds; fails the test after ~5 s.
    private static func until(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<5000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("the condition never held")
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

/// Holds every caller of `wait()` until `open()`; a caller after the opening passes straight on.
private final class Parking: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock {
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock {
            opened = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in released { continuation.resume() }
    }
}
