import Foundation
import MemosAPI
import MemosCore
import Testing

/// The one retry the exchange is allowed, and the failures that must never get one.
///
/// The first native sign-in on a home LAN fails by design: iOS Local Network privacy denies the
/// app process's FIRST connection to a private-range host — the one that raises the permission
/// prompt — and the browser leg, being another process, completes anyway. That denial arrives as
/// -1009 carrying ENETDOWN at connect, which is the proof that nothing was transmitted: the
/// one-shot handoff code is unconsumed and the verifier is still in hand, so the SAME pair may be
/// sent again. No other transport failure carries that proof, and a second send of a code that may
/// already have been consumed is not a retry, it is a second sign-in.
/// File scope, not the suite's: the suite is `@MainActor` and the transport handler that reads
/// these is a `@Sendable` closure the client calls from wherever it likes.
private let exchangeOperation = "native_exchange_api_auth_native_exchange_post"

/// The denial exactly as the device reported it: -1009 carrying ENETDOWN at connect, on a path
/// the system itself calls satisfied.
private func localNetworkDenial() -> URLError {
    URLError(
        .notConnectedToInternet,
        userInfo: ["_kCFStreamErrorCodeKey": 50, "_NSURLErrorNWPathKey": "satisfied"]
    )
}

@MainActor
@Suite("The exchange's one retry")
struct NativeSignInRetryTests {
    private let callbackURL = "https://memos.example.invalid/ios/auth/callback?code=handoff-123"

    private func store(
        credentials: InMemoryCredentials,
        sleeps: LockedValue<[Duration]>,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            sleeper: { sleeps.set(sleeps.get() + [$0]) }
        )
    }

    /// A transport that answers the exchange from a script, recording the code each attempt sent.
    private func exchanges(
        codes: LockedValue<[String]>,
        answer: @escaping @Sendable (Int) throws -> ExchangeAnswer
    ) -> StubTransport.Handler {
        { _, body, operation in
            guard operation == exchangeOperation else {
                return Stub.json(Stub.exchange(token: "memos_pat_device"))
            }
            let sent = try await Stub.body(body)
            codes.set(codes.get() + [sent["code"] as? String ?? "<none>"])
            switch try answer(codes.get().count) {
            case .signedIn: return Stub.json(Stub.exchange(token: "memos_pat_device"))
            case .refused(let detail): return Stub.exchangeFailure(detail)
            }
        }
    }

    enum ExchangeAnswer {
        case signedIn
        case refused(String)
    }

    private func signIn(_ session: SessionStore, pkce: PKCE) async -> Bool {
        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: StubPresenter(behaviour: .callback(callbackURL)),
            pkce: pkce
        )
    }

    @Test("the denial is retried once, with the same code, and the sign-in completes")
    func denialThenSuccess() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { attempt in
                if attempt == 1 { throw localNetworkDenial() }
                return .signedIn
            }
        )
        let pkce = PKCE()

        let signedIn = await signIn(session, pkce: pkce)

        #expect(signedIn)
        #expect(session.state.user?.subject == "fabian")
        #expect(codes.get() == ["handoff-123", "handoff-123"], "the retry sends the SAME code")
        #expect(
            sleeps.get() == [.milliseconds(1500)],
            "the retry waits, so the permission prompt has a chance to be answered"
        )
        #expect(session.lastFailure == nil)
        #expect(pkce.verifier == nil)
    }

    @Test("two denials end as a readable local-network failure that offers Settings")
    func denialTwice() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { _ in throw localNetworkDenial() }
        )
        let pkce = PKCE()
        let verifier = pkce.verifier

        let signedIn = await signIn(session, pkce: pkce)

        #expect(!signedIn)
        #expect(session.state == .signedOut)
        #expect(codes.get().count == 2, "the denial is retried exactly once")
        #expect(session.lastFailure == .transport(.localNetworkDenied))
        #expect(session.lastError?.contains("Local Network") == true)
        #expect(credentials.isEmpty)
        #expect(pkce.verifier == nil)
        // Positive control above: the message IS there to be read, so the absences below are
        // absences of a leak and not of a message.
        #expect(session.lastError?.contains("handoff-123") == false)
        #expect(session.lastError?.contains(verifier ?? "unset") == false)
        #expect(session.lastError?.contains("operationInput") == false)
    }

    @Test("a retry that fails differently is reported as what it was, not as another denial")
    func denialThenTimeout() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { attempt in
                if attempt == 1 { throw localNetworkDenial() }
                throw URLError(.timedOut)
            }
        )

        let signedIn = await signIn(session, pkce: PKCE())

        #expect(!signedIn)
        #expect(codes.get().count == 2)
        #expect(session.lastFailure == .transport(.other("NSURLErrorDomain -1001")))
        #expect(
            session.lastError?.contains("Local Network") == false,
            "a timeout must not be answered with the local-network instruction"
        )
    }

    @Test("a timeout is not retried, and is reported by domain and code only")
    func timeoutIsNotRetried() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { _ in throw URLError(.timedOut) }
        )

        let signedIn = await signIn(session, pkce: PKCE())

        #expect(!signedIn)
        #expect(codes.get().count == 1, "a failure that may have been delivered is never resent")
        #expect(sleeps.get().isEmpty)
        #expect(session.lastFailure == .transport(.other("NSURLErrorDomain -1001")))
        #expect(session.lastError?.contains("-1001") == true)
    }

    @Test("a -1009 without the stream code is offline, and is not retried")
    func offlineIsNotRetried() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { _ in throw URLError(.notConnectedToInternet) }
        )

        let signedIn = await signIn(session, pkce: PKCE())

        #expect(!signedIn)
        #expect(codes.get().count == 1)
        #expect(sleeps.get().isEmpty)
        #expect(session.lastFailure == .transport(.offline))
        #expect(session.lastError?.contains("offline") == true)
    }

    @Test("an exchange that works is made exactly once")
    func successIsNotRepeated() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { _ in .signedIn }
        )

        let signedIn = await signIn(session, pkce: PKCE())

        #expect(signedIn)
        #expect(codes.get().count == 1)
        #expect(sleeps.get().isEmpty)
        #expect(session.lastFailure == nil)
    }

    @Test("a retry that finds the code spent says the answer was lost, and signs nothing in")
    func retryFindsTheCodeConsumed() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { attempt in
                if attempt == 1 { throw localNetworkDenial() }
                return .refused("code_consumed")
            }
        )
        let pkce = PKCE()

        let signedIn = await signIn(session, pkce: pkce)

        #expect(!signedIn)
        #expect(session.state == .signedOut)
        #expect(codes.get().count == 2)
        #expect(session.lastFailure == .answerLost)
        #expect(session.lastError == NativeLoginError.answerLost.message)
        #expect(credentials.isEmpty)
        #expect(pkce.verifier == nil)
    }

    @Test("a refusal the server actually answered is never retried")
    func serverRefusalIsNotRetried() async {
        let credentials = InMemoryCredentials()
        let codes = LockedValue<[String]>([])
        let sleeps = LockedValue<[Duration]>([])
        let session = store(
            credentials: credentials,
            sleeps: sleeps,
            handler: exchanges(codes: codes) { _ in .refused("code_expired") }
        )

        let signedIn = await signIn(session, pkce: PKCE())

        #expect(!signedIn)
        #expect(codes.get().count == 1)
        #expect(sleeps.get().isEmpty)
        #expect(session.lastFailure == .exchangeRejected(.codeExpired))
    }
}
