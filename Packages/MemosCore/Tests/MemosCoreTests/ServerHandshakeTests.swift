import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

private let healthOperation = Stub.healthOperation
private let logoutOperation = "native_logout_api_auth_native_logout_post"
private let exchangeOperation = "native_exchange_api_auth_native_exchange_post"

/// The sign-in handshake: the app asks the server which API major it speaks, and says so when that
/// is older than the contract this build was generated from (`VendoredRelease.apiMajor`).
///
/// Every case goes through the REAL generated client over `StubTransport`, because the decision
/// hangs on where the generated client puts things: a body that does not decode as
/// `HealthResponse` throws from the call itself, with the 200 still attached, and only a stubbed
/// transport under the real client can make it do that. Each case counts the `/health` requests
/// and awaits the handshake's own task, so "no notice" can never mean "the handshake never ran" or
/// "it had not finished yet".
@MainActor
@Suite("The sign-in handshake")
struct ServerHandshakeTests {
    private typealias Answer = @Sendable () async throws -> (HTTPResponse, HTTPBody?)

    /// A session signed in through the PASTED leg, whose server answers `/health` with `health`.
    private func signedIn(asked: Counter, health: @escaping Answer) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token, healthFromHandler: true) { _, _, operation in
                    guard operation == healthOperation else { return Stub.json(Stub.user) }
                    asked.increment()
                    return try await health()
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    /// Waits for the handshake the sign-in launched, and fails the case if there was none.
    private func handshakeFinished(_ session: SessionStore) async throws {
        let check = try #require(session.serverMajorCheck, "the sign-in launched no handshake")
        await check.value
    }

    nonisolated private static func health(
        major: Int,
        version: String
    ) -> (HTTPResponse, HTTPBody?) {
        Stub.json(#"{"status":"ok","version":"\#(version)","apiMajor":\#(major)}"#)
    }

    @Test("a server one major behind the app is named on screen")
    func anOlderMajorRaisesTheNotice() async throws {
        let asked = Counter()
        let session = await signedIn(asked: asked) {
            Self.health(major: VendoredRelease.apiMajor - 1, version: "1.11.0")
        }
        try await handshakeFinished(session)

        #expect(asked.count == 1)
        #expect(session.showsOlderServerNotice)
        // It informs; it never undoes the sign-in.
        #expect(session.state.user?.subject == "fabian")
    }

    @Test("a server of the app's own major says nothing")
    func theSameMajorSaysNothing() async throws {
        let asked = Counter()
        let session = await signedIn(asked: asked) {
            Self.health(major: VendoredRelease.apiMajor, version: "2.0.0")
        }
        try await handshakeFinished(session)

        #expect(asked.count == 1)
        #expect(!session.showsOlderServerNotice)
    }

    /// A server from before the handshake existed answers `/health` without `apiMajor`, which
    /// v2.0.0 made required — so the body does not decode, and that IS the answer "older".
    @Test("a 200 without apiMajor is a server from before the field, so older")
    func aMissingMajorIsOlder() async throws {
        let asked = Counter()
        let session = await signedIn(asked: asked) {
            Stub.json(#"{"status":"ok","version":"1.11.0"}"#)
        }
        try await handshakeFinished(session)

        #expect(asked.count == 1)
        #expect(session.showsOlderServerNotice)
        #expect(session.state.user?.subject == "fabian")
    }

    /// Reachability belongs to the outbox probe and the verification ladder; a server that will
    /// not answer this one question has told the app nothing about its major.
    @Test("a server that answers 503 says nothing about its major")
    func aRefusedHealthSaysNothing() async throws {
        let asked = Counter()
        let session = await signedIn(asked: asked) { Stub.empty(.serviceUnavailable) }
        try await handshakeFinished(session)

        #expect(asked.count == 1)
        #expect(!session.showsOlderServerNotice)
    }

    /// The 200 arrived and then the network went: the generated client throws with the 200 still
    /// attached, exactly as it does for a body that does not decode. What tells the two apart is
    /// the underlying error — a lost connection is not a server from before `apiMajor`. The error
    /// is thrown while the BODY is iterated, not by the handler, because that is where a real
    /// connection loss after the status line surfaces.
    @Test("a 200 whose body is cut off by the network says nothing")
    func aBodyLostMidwaySaysNothing() async throws {
        let asked = Counter()
        let session = await signedIn(asked: asked) {
            let cutOff = AsyncThrowingStream<ArraySlice<UInt8>, any Error> { continuation in
                continuation.yield(ArraySlice(Array(#"{"status":"ok","vers"#.utf8)))
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            let body = HTTPBody(cutOff, length: .unknown, iterationBehavior: .single)
            return (response, body)
        }
        try await handshakeFinished(session)

        #expect(asked.count == 1)
        #expect(!session.showsOlderServerNotice)
    }

    /// The answer outlived the session that asked. It is judged against the generation the
    /// handshake was launched under — the one establishment left behind — and a sign-out has moved
    /// that, so an "older" answer about a server this device has left must not reach the screen.
    /// The held health request also shows the sign-in did not wait for it: `signIn` returned while
    /// the answer was still held in the transport.
    @Test("an older-major answer that arrives after a sign-out is discarded")
    func aLateAnswerAfterSignOutIsDiscarded() async throws {
        let entered = Gate()
        let release = Gate()
        let asked = Counter()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token, healthFromHandler: true) { _, _, operation in
                    switch operation {
                    case healthOperation:
                        asked.increment()
                        entered.open()
                        await release.wait()
                        return Self.health(major: VendoredRelease.apiMajor - 1, version: "1.11.0")
                    case logoutOperation:
                        return Stub.empty(.noContent)
                    default:
                        return Stub.json(Stub.user)
                    }
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let check = try #require(session.serverMajorCheck, "the sign-in launched no handshake")
        await entered.wait()

        let outcome = await session.signOut()
        #expect(outcome == .revoked)
        #expect(session.state.user == nil)

        release.open()
        await check.value

        #expect(asked.count == 1)
        #expect(!session.showsOlderServerNotice)
    }

    /// The NATIVE leg runs the same handshake: a device that signed in through the browser is told
    /// the same thing as one that pasted a token.
    @Test("the native sign-in runs the handshake too")
    func theNativeLegRunsTheHandshake() async throws {
        let asked = Counter()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token, healthFromHandler: true) { _, _, operation in
                    switch operation {
                    case healthOperation:
                        asked.increment()
                        return Self.health(major: VendoredRelease.apiMajor - 1, version: "1.11.0")
                    case exchangeOperation:
                        return Stub.json(Stub.exchange(token: "memos_pat_device"))
                    default:
                        return Stub.json(Stub.user)
                    }
                }
            }
        )
        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "Fabian's iPhone",
            presenter: StubPresenter(
                behaviour: .callback(
                    "https://memos.example.invalid/ios/auth/callback?code=handoff-123"
                )
            )
        )
        #expect(signedIn)
        try await handshakeFinished(session)

        #expect(asked.count == 1)
        #expect(session.showsOlderServerNotice)
    }

    /// A new sign-in starts with nothing said about the server it is about to reach: the previous
    /// account's "older" notice is about a server this sign-in may not be talking to.
    @Test("a new sign-in takes the previous server's notice down before it asks again")
    func aNewSignInClearsTheNotice() async throws {
        let major = LockedValue(VendoredRelease.apiMajor - 1)
        let asked = Counter()
        let session = await signedIn(asked: asked) {
            Self.health(major: major.get(), version: "x")
        }
        try await handshakeFinished(session)
        #expect(session.showsOlderServerNotice)

        major.set(VendoredRelease.apiMajor)
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_other")
        #expect(!session.showsOlderServerNotice)
        try await handshakeFinished(session)

        #expect(asked.count == 2)
        #expect(!session.showsOlderServerNotice)
    }

    /// The reset at a sign-in's start has to invalidate the handshake still on the wire, not only
    /// take the notice down. A new sign-in moves the session generation only once its credential
    /// is stored, so until then A's handshake still owns the generation: released inside that
    /// window, its "older" would put the notice back, and B — whose own server answers the app's
    /// major and so writes nothing — would inherit A's notice about a different server.
    @Test("an older-major answer held across the start of the next sign-in cannot reach it")
    func anEarlierHandshakeCannotReachTheNextSignIn() async throws {
        let healthEntered = Gate()
        let healthRelease = Gate()
        let whoamiEntered = Gate()
        let whoamiRelease = Gate()
        let healths = Counter()
        let whoamis = Counter()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token, healthFromHandler: true) { _, _, operation in
                    switch operation {
                    case healthOperation:
                        healths.increment()
                        guard healths.count == 1 else {
                            return Self.health(major: VendoredRelease.apiMajor, version: "2.0.0")
                        }
                        // A's handshake: held until B's sign-in is under way.
                        healthEntered.open()
                        await healthRelease.wait()
                        return Self.health(major: VendoredRelease.apiMajor - 1, version: "1.11.0")
                    default:
                        whoamis.increment()
                        if whoamis.count == 2 {
                            // B's whoami: held, so B has reset the notice but owns nothing yet.
                            whoamiEntered.open()
                            await whoamiRelease.wait()
                        }
                        return Stub.json(Stub.user)
                    }
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "token_for_a")
        let checkA = try #require(session.serverMajorCheck, "sign-in A launched no handshake")
        await healthEntered.wait()

        let signInB = Task {
            await session.signIn(serverAddress: "memos.example.invalid", token: "token_for_b")
        }
        await whoamiEntered.wait()
        #expect(!session.showsOlderServerNotice)

        healthRelease.open()
        await checkA.value
        // A's answer has been judged, and B is still waiting on its whoami.
        #expect(!session.showsOlderServerNotice)

        whoamiRelease.open()
        await signInB.value
        try await handshakeFinished(session)

        #expect(healths.count == 2)
        #expect(session.state.user?.subject == "fabian")
        #expect(!session.showsOlderServerNotice)
    }
}
