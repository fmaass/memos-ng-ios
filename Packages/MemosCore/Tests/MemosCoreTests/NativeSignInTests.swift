import Foundation
import MemosAPI
import MemosCore
import Testing

private let exchangeOperation = "native_exchange_api_auth_native_exchange_post"

/// The browser-brokered device login, end to end through the real generated client.
///
/// Every branch is here because every branch is reachable in a hand: the sheet can fail to open,
/// the person can close it, the identity provider can refuse, the redirect can arrive truncated,
/// and the server has four separate ways to refuse the code. The one thing common to all of them
/// is that the verifier must not survive — it is checked on every path.
@MainActor
@Suite("Native sign-in")
struct NativeSignInTests {
    private let callbackURL = "https://memos.example.invalid/ios/auth/callback?code=handoff-123"

    private func store(
        credentials: InMemoryCredentials,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
    }

    @Test("the login is started against the server's own ios-mode route")
    func startsIosModeLogin() async throws {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let session = store(credentials: credentials) { _, _, _ in
            Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()
        let challenge = pkce.challenge

        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "Fabian's iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(signedIn)
        let authorizeURL = try #require(presenter.seenAuthorizeURL.get())
        let items = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems
        let query = Dictionary(
            uniqueKeysWithValues: (items ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(authorizeURL.path() == "/api/auth/login")
        #expect(query["client"] == "ios")
        #expect(query["code_challenge"] == challenge)
        #expect(query["device"] == "Fabian's iPhone")
        // The callback the session waits for is the server's own HTTPS URL, not a scheme.
        #expect(presenter.seenHost.get() == "memos.example.invalid")
        #expect(presenter.seenPath.get() == "/ios/auth/callback")
    }

    @Test("the exchange sends the code with the verifier of that challenge, and no credential")
    func exchangeCarriesTheVerifier() async throws {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let sentBody = LockedValue<[String: Any]>([:])
        let authorization = LockedValue<String?>("unset")
        let session = store(credentials: credentials) { request, body, operation in
            if operation == exchangeOperation {
                sentBody.set(try await Stub.body(body))
                authorization.set(request.headerFields[.authorization])
            }
            return Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()
        let challenge = pkce.challenge

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        let sent = sentBody.get()
        #expect(sent["code"] as? String == "handoff-123")
        let verifier = try #require(sent["code_verifier"] as? String)
        #expect(
            PKCE.s256Challenge(for: verifier) == challenge,
            "the verifier sent must be the one the challenge in the login URL was made from"
        )
        #expect(
            authorization.get() == nil,
            "the exchange is anonymous by construction — it is how a device gets its first token"
        )
    }

    @Test("a successful exchange stores the token and the server, and signs the app in")
    func storesTheDeviceToken() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let session = store(credentials: credentials) { _, _, _ in
            Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(session.state.user?.subject == "fabian")
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_device")
        #expect(
            credentials.snapshot()[SessionStore.serverAccount] == "https://memos.example.invalid"
        )
        #expect(pkce.verifier == nil, "the verifier has no purpose after the exchange")
        #expect(session.lastError == nil)
    }

    /// It used to be silent, on the reasoning that a cancel is a decision rather than a failure.
    /// It is not silent any more: the app cannot tell a deliberate close apart from a finished
    /// login whose callback never came back, and the second one is exactly what happens when the
    /// return link goes untapped. Both looked like a button that did nothing.
    @Test("closing the sign-in view says so rather than leaving the screen blank")
    func userCancel() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .failure(.cancelled))
        let exchanges = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            exchanges.increment()
            return Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()

        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(!signedIn)
        #expect(session.state == .signedOut)
        #expect(
            session.lastError?.contains("tap Sign in to try again") == true,
            "a closed sign-in view left nothing on screen to read"
        )
        #expect(exchanges.count == 0)
        #expect(credentials.isEmpty)
        #expect(pkce.verifier == nil)
    }

    @Test("a sheet that cannot be presented says so")
    func presentationFailure() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .failure(.presentationFailed("no window")))
        let session = store(credentials: credentials) { _, _, _ in Stub.empty(.internalServerError)
        }
        let pkce = PKCE()

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(session.state == .signedOut)
        #expect(session.lastError?.contains("no window") == true)
        #expect(pkce.verifier == nil)
    }

    @Test("a refusal arrives on the callback, because an app cannot read an HTTP status")
    func refusedByTheIdentityProvider() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(
            behaviour: .callback(
                "https://memos.example.invalid/ios/auth/callback?error=access_denied"
            )
        )
        let exchanges = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            exchanges.increment()
            return Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(session.state == .signedOut)
        #expect(session.lastError?.contains("access_denied") == true)
        #expect(exchanges.count == 0, "there is no code to exchange")
        #expect(pkce.verifier == nil)
    }

    /// The lane that actually carries this deployment's sign-ins. The server builds the
    /// custom-scheme URL from the https one by construction — same query, different scheme — so a
    /// login that came back this way must reach the same place as one that came back the other.
    @Test("a sign-in that came back on the tap-to-return lane completes exactly as the other")
    func signsInFromTheCustomSchemeLane() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(
            behaviour: .callback("memosng://auth-callback?code=handoff-123")
        )
        let session = store(credentials: credentials) { _, _, _ in
            Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()

        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(signedIn)
        #expect(session.state.user?.subject == "fabian")
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_device")
        #expect(session.lastError == nil)
        #expect(pkce.verifier == nil)
    }

    /// The BFF sends refusals to the same callback page, so the tap-to-return link can carry an
    /// `error` where a successful login carries a `code`. Read as "malformed", it would tell
    /// somebody their sign-in came back incomplete when in fact it was turned down — and read as
    /// nothing at all, it would be the silent dead button again.
    @Test("a refusal that came back on the tap-to-return lane is surfaced as a refusal")
    func refusalOnTheCustomSchemeLane() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(
            behaviour: .callback("memosng://auth-callback?error=access_denied")
        )
        let exchanges = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            exchanges.increment()
            return Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(session.state == .signedOut)
        #expect(session.lastError?.contains("access_denied") == true)
        #expect(
            session.lastError?.contains("incomplete") == false,
            "a refusal must not be reported as a truncated callback"
        )
        #expect(exchanges.count == 0, "there is no code to exchange")
        #expect(credentials.isEmpty)
        #expect(pkce.verifier == nil)
    }

    @Test("a callback with no code is a failure, not a silent success")
    func malformedCallback() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(
            behaviour: .callback("https://memos.example.invalid/ios/auth/callback")
        )
        let exchanges = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            exchanges.increment()
            return Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        let pkce = PKCE()

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(session.state == .signedOut)
        #expect(session.lastError != nil)
        #expect(exchanges.count == 0)
        #expect(pkce.verifier == nil)
    }

    @Test(
        "each of the four exchange refusals is reported as itself and destroys the verifier",
        arguments: [
            ("code_invalid", NativeExchangeFailure.codeInvalid),
            ("code_expired", NativeExchangeFailure.codeExpired),
            ("code_consumed", NativeExchangeFailure.codeConsumed),
            ("verifier_mismatch", NativeExchangeFailure.verifierMismatch),
        ]
    )
    func exchangeRefusals(_ detail: String, _ expected: NativeExchangeFailure) async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let session = store(credentials: credentials) { _, _, _ in Stub.exchangeFailure(detail) }
        let pkce = PKCE()

        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter,
            pkce: pkce
        )

        #expect(!signedIn)
        #expect(session.state == .signedOut)
        #expect(session.lastError == expected.message)
        #expect(credentials.isEmpty, "a refused exchange must leave no credential behind")
        #expect(pkce.verifier == nil)
    }

    @Test("a 500 from the exchange is reported as a server failure, not as a bad code")
    func exchangeServerError() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let session = store(credentials: credentials) { _, _, _ in
            Stub.empty(.internalServerError)
        }

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter
        )

        #expect(session.state == .signedOut)
        #expect(session.lastError?.contains("500") == true)
    }

    @Test("a request the server would refuse never opens a browser at all")
    func refusesUnusableRequestBeforePresenting() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let session = store(credentials: credentials) { _, _, _ in
            Stub.json(Stub.exchange(token: "memos_pat_device"))
        }

        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "   ",
            presenter: presenter
        )

        #expect(!signedIn)
        #expect(presenter.calls.count == 0)
        #expect(session.lastError != nil)
    }

    @Test("a plain-http server address is refused before a browser opens")
    func refusesInsecureServer() async {
        let credentials = InMemoryCredentials()
        let presenter = StubPresenter(behaviour: .callback(callbackURL))
        let session = store(credentials: credentials) { _, _, _ in
            Stub.json(Stub.exchange(token: "memos_pat_device"))
        }

        let signedIn = await session.signInNatively(
            serverAddress: "http://memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter
        )

        #expect(!signedIn)
        #expect(presenter.calls.count == 0)
        #expect(session.state == .signedOut)
    }
}

/// The claim a presenter can be handed is the management sign-on's, which races a deadline. The
/// sign-in lane has no rival for its answer, and it must go on asking the browser step exactly as
/// it always has: the plain call, with nothing claimed anywhere.
extension NativeSignInTests {
    @Test("the sign-in lane asks the plain browser step, with no claim")
    func theSignInLaneAsksNoClaim() async {
        let credentials = InMemoryCredentials()
        let presenter = EntryPointPresenter(callback: callbackURL)
        let session = store(credentials: credentials) { _, _, _ in
            Stub.json(Stub.exchange(token: "memos_pat_device"))
        }

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: presenter
        )

        #expect(presenter.plainCalls == 1, "the sign-in lane did not ask the plain browser step")
        #expect(presenter.claimingCalls == 0, "the sign-in lane handed the browser step a claim")
        #expect(session.state.user?.subject == "fabian")
    }
}

/// Answers with one callback and remembers which of the two entry points it was asked through.
@MainActor
private final class EntryPointPresenter: NativeLoginPresenter {
    private let callback: String
    private(set) var plainCalls = 0
    private(set) var claimingCalls = 0

    init(callback: String) { self.callback = callback }

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        plainCalls += 1
        return try url()
    }

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String,
        claimingAnswer claim: @escaping @MainActor () -> Bool
    ) async throws -> URL {
        claimingCalls += 1
        return try url()
    }

    private func url() throws -> URL {
        guard let url = URL(string: callback) else { throw NativeLoginError.malformedCallback }
        return url
    }
}
