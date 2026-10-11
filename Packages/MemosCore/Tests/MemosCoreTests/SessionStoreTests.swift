import Foundation
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime
import Testing

// The transport is handed the contract's own operationId, not the generated Swift method name.
private let whoamiOperation = "whoami_api_auth_user_get"
private let nativeLogoutOperation = "native_logout_api_auth_native_logout_post"
private let settingsOperation = "get_settings_api_settings_get"

@MainActor
@Suite("SessionStore")
struct SessionStoreTests {
    private func store(
        credentials: InMemoryCredentials,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        store(anyCredentials: credentials, handler: handler)
    }

    /// The same session over a store that is not the in-memory one — a namespace that will not
    /// read, or one that will not let go of what it holds.
    private func store(
        anyCredentials credentials: any CredentialStore,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
    }

    @Test("a valid token is validated against /api/auth/user and then stored")
    func signInStoresValidatedToken() async {
        let credentials = InMemoryCredentials()
        let seenAuthorization = LockedValue<String?>(nil)
        let session = store(credentials: credentials) { request, _, _ in
            seenAuthorization.set(request.headerFields[.authorization])
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(session.state.user?.subject == "fabian")
        #expect(seenAuthorization.get() == "Bearer memos_pat_good")
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_good")
        #expect(
            credentials.snapshot()[SessionStore.serverAccount] == "https://memos.example.invalid"
        )
    }

    @Test("a rejected token is never stored and leaves the app signed out")
    func signInRejects401() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, _ in Stub.empty(.unauthorized) }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_revoked")

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
        #expect(session.lastError != nil)
    }

    @Test("a plain-http address is refused before anything is sent")
    func refusesInsecureServer() async {
        let credentials = InMemoryCredentials()
        let calls = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            calls.increment()
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "http://memos.example.invalid", token: "memos_pat_x")

        #expect(calls.count == 0)
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("an empty token is refused before anything is sent")
    func refusesEmptyToken() async {
        let credentials = InMemoryCredentials()
        let calls = Counter()
        let session = store(credentials: credentials) { _, _, _ in
            calls.increment()
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "   ")

        #expect(calls.count == 0)
        #expect(session.state == .signedOut)
    }

    @Test("sign-out revokes the presenting token and wipes the credential")
    func signOutRevokes() async {
        let credentials = InMemoryCredentials()
        let operations = LockedValue<[String]>([])
        let session = store(credentials: credentials) { _, _, operation in
            operations.set(operations.get() + [operation])
            return operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        await session.signOut()

        #expect(operations.get().contains(nativeLogoutOperation))
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("a failed revoke keeps the credential and says so")
    func signOutKeepsCredentialWhenRevokeFails() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation
                ? Stub.json(Stub.user)
                : Stub.empty(.internalServerError)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let outcome = await session.signOut()

        // The revoke never reached the server, so the token is still live out there — wiping the
        // only copy the app tracks would abandon it, signed out in appearance only.
        #expect(outcome.failureDescription != nil)
        #expect(session.state != .signedOut)
        #expect(!credentials.isEmpty, "a live token must stay tracked until its fate is settled")

        // The person can still decide otherwise, in the open.
        await session.signOutWithoutRevoking()
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("a revoke that never left the device also keeps the credential")
    func signOutKeepsCredentialWhenTransportThrows() async {
        struct Offline: Error {}
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            guard operation == whoamiOperation else { throw Offline() }
            return Stub.json(Stub.user)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let outcome = await session.signOut()

        // Same rule as the 5xx case, different road there: the request THREW before any server
        // verdict existed, which says even less about the token than a 500 does.
        #expect(outcome.failureDescription != nil)
        #expect(session.state != .signedOut)
        #expect(!credentials.isEmpty)
    }

    @Test("a stored credential is re-validated at launch, not trusted")
    func restoreRevalidates() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stale", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)

        let session = store(credentials: credentials) { _, _, _ in Stub.empty(.unauthorized) }
        await session.restore()

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    @Test("a stored credential that still works signs the app back in")
    func restoreSucceeds() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)

        let session = store(credentials: credentials) { _, _, _ in Stub.json(Stub.user) }
        await session.restore()

        #expect(session.state.user?.subject == "fabian")
    }

    @Test("an unauthorized error anywhere ends the session")
    func unauthorizedSignsOut() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(session.state.user != nil)

        await session.handle(CredentialRefusal(issuedUnder: nil))

        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty)
    }

    /// A stored credential that will not READ is not an absent one. Storage said something, and
    /// what it said could not be turned into a token — which is a complaint, not evidence that
    /// nobody is signed in. Nothing is deleted on the strength of it: the token may be perfectly
    /// good and unreachable only because the device has not been unlocked since it booted.
    @Test("a credential that cannot be read is a storage complaint, not a silent sign-out")
    func restoreSurfacesUnreadableStorage() async {
        let credentials = UnreadableCredentials()
        let calls = Counter()
        let session = store(anyCredentials: credentials) { _, _, _ in
            calls.increment()
            return Stub.json(Stub.user)
        }

        await session.restore()

        #expect(session.state == .signedOut)
        #expect(session.lastError == SessionStore.storageUnreadable)
        #expect(credentials.removalCount == 0, "a read that failed must not delete anything")
        #expect(calls.count == 0, "and nothing was sent anywhere on the strength of it")
    }

    /// The licence is what lets the share extension enqueue a capture, and it is revoked when a
    /// launch finds no credential. A launch that could not READ the credential has found nothing
    /// of the sort: it has found storage that will not answer, and revoking on that evidence takes
    /// the share sheet away from somebody who is still signed in.
    @Test("a launch that cannot read storage leaves the extension's licence alone")
    func unreadableStorageKeepsTheLicence() async {
        let licence = SpyAccountStore()
        licence.publish(
            AccountBinding(serverBaseURL: Stub.baseURL, ownerSubject: "fabian")
        )
        // A vault whose namespaces all refuse to read — which is what a device with a broken
        // keychain hands the session, and what a device that lost an entitlement hands it too.
        let vault = CredentialVault(
            CredentialNamespaces(
                primary: CredentialNamespace(InMemoryCredentials(), reach: .appOnly),
                legacies: [
                    CredentialNamespace(UnreadableCredentials(), reach: .sharedWithExtensions),
                    CredentialNamespace(UnreadableCredentials(), reach: .appOnly),
                ]
            )
        )
        let session = SessionStore(
            credentials: vault,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, _ in Stub.json(Stub.user) }
            },
            account: licence
        )

        await session.restore()

        #expect(licence.clearCount == 0, "the licence was revoked on a read that never answered")
        #expect(licence.published != nil)
        #expect(session.lastError == SessionStore.storageUnreadable)
    }

    /// A sign-out that could not clear the device must not look like one that did. The token is
    /// revoked server-side either way, so the sign-out stands — but the person is told, because
    /// until the next launch reconciles it there is a credential on a device that says there is
    /// not.
    @Test("a sign-out that could not remove the credential says so")
    func signOutReportsACredentialItCouldNotRemove() async {
        let credentials = UnwipeableCredentials()
        let session = store(anyCredentials: credentials) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        let outcome = await session.signOut()

        #expect(outcome == .revoked)
        #expect(session.state == .signedOut)
        #expect(session.lastError == SessionStore.credentialWipeWarning)
        #expect(
            credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_good",
            "the double is only interesting while it really is holding the token"
        )
    }
}

/// A tiny box so a `@Sendable` closure can record what it saw.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

extension SessionStoreTests {
    @Test("an unreachable server parks the session instead of inviting a second sign-in")
    func restoreParksWhenUnreachable() async {
        struct Offline: Error {}
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)

        let session = store(credentials: credentials) { _, _, _ in throw Offline() }
        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
        #expect(!credentials.isEmpty, "an unconfirmed token is kept for the retry")
    }
}

/// The token and the address the launch cases restore from, so a leak has something recognisable
/// to be found by.
private let storedToken = "memos_pat_stored_secret"
private let storedHost = "memos.example.invalid"
private let retryHint = "Join your home wifi (or turn on NetBird) and tap Try again."
private let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
/// ENETDOWN at connect: what iOS fails the first connection to a LAN host with while the Local
/// Network permission sheet is up.
private let networkIsDown = 50

/// A coding key, so a decoding failure can be built here rather than borrowed from the store.
private struct StubKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

/// The decoding failure the generated client raises for a body missing a required property, built
/// independently of any store, wrapped the way the client wraps it.
///
/// It is the shape observed from the real decoder against `{"nope":1}` and `UserOut`:
/// `DecodingError.keyNotFound` on `auth_kind`.
private let rawDecodeFailure = ClientError(
    operationID: "whoami_api_auth_user_get",
    operationInput: "",
    causeDescription: "Unknown",
    underlyingError: DecodingError.keyNotFound(
        StubKey("auth_kind"),
        DecodingError.Context(
            codingPath: [],
            debugDescription: "No value associated with key auth_kind"
        )
    )
)

/// What the classifier renders for that failure — the domain and the code, nothing else.
///
/// Derived from the fixture above rather than from the store, so a store that leaked the decoder's
/// own words into its descriptor could not make its own expectation move with it. The assertions
/// that this really is sanitized, and that the raw error really did carry the decoder's words,
/// live in the tests that use it.
private var classifiedDecodeDetail: String {
    guard case .other(let detail) = NativeLoginTransportFailure.classify(rawDecodeFailure) else {
        return "<not classified as other>"
    }
    return detail
}

/// One launch failure: what the transport threw, the sentence it has to become, and the value the
/// screen decides its Settings button from.
struct LaunchFailureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let thrown: URLError
    let sentence: String
    let failure: SessionRestoreFailure

    var testDescription: String { name }
}

let launchFailureCases = [
    LaunchFailureCase(
        name: "a DNS failure",
        thrown: URLError(.cannotFindHost),
        sentence: "Can't reach \(storedHost) (NSURLErrorDomain -1003). \(retryHint)",
        failure: .unreachable(host: storedHost, detail: "NSURLErrorDomain -1003")
    ),
    LaunchFailureCase(
        name: "a refused connection",
        thrown: URLError(.cannotConnectToHost),
        sentence: "Can't reach \(storedHost) (NSURLErrorDomain -1004). \(retryHint)",
        failure: .unreachable(host: storedHost, detail: "NSURLErrorDomain -1004")
    ),
    LaunchFailureCase(
        name: "a timeout",
        thrown: URLError(.timedOut),
        sentence: "Can't reach \(storedHost) (NSURLErrorDomain -1001). \(retryHint)",
        failure: .unreachable(host: storedHost, detail: "NSURLErrorDomain -1001")
    ),
    LaunchFailureCase(
        name: "a TLS failure",
        thrown: URLError(.secureConnectionFailed),
        sentence: "Can't reach \(storedHost) (NSURLErrorDomain -1200). \(retryHint)",
        failure: .unreachable(host: storedHost, detail: "NSURLErrorDomain -1200")
    ),
    LaunchFailureCase(
        name: "an offline phone",
        thrown: URLError(.notConnectedToInternet),
        sentence: "Can't reach \(storedHost). This phone looks offline. \(retryHint)",
        failure: .offline(host: storedHost)
    ),
    LaunchFailureCase(
        name: "the Local Network denial",
        thrown: URLError(
            .notConnectedToInternet,
            userInfo: [streamErrorCodeKey: networkIsDown]
        ),
        sentence: "This phone is not letting the app reach your home network. Allow Local "
            + "Network for memosng in Settings, then tap Try again.",
        failure: .localNetworkDenied
    ),
]

/// What a launch that could not confirm its stored credential puts on screen.
///
/// Every case here runs through the REAL generated client over `StubTransport`, so what the store
/// classifies is the `ClientError` the client actually builds — the one whose description is the
/// operation, its `operationInput` and the request that presented the bearer token. Substituting
/// the store, or the client, would leave that error out of the test and prove nothing about the
/// defect these cases exist for.
@MainActor
@Suite("The launch failure's sentence")
struct SessionRestoreClassificationTests {
    private func restored(
        diagnostics: @escaping @Sendable (String) -> Void = { _ in },
        handler: @escaping StubTransport.Handler
    ) async -> (session: SessionStore, credentials: InMemoryCredentials) {
        let credentials = InMemoryCredentials()
        try? credentials.set(storedToken, for: SessionStore.tokenAccount)
        try? credentials.set("https://\(storedHost)", for: SessionStore.serverAccount)
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            diagnostics: diagnostics
        )
        await session.restore()
        return (session, credentials)
    }

    private func sentence(of session: SessionStore) -> String {
        guard case .unreachable(let message) = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return ""
        }
        return message
    }

    @Test("each transport failure becomes its own sentence", arguments: launchFailureCases)
    func transportFailureBecomesASentence(_ scenario: LaunchFailureCase) async {
        let (session, credentials) = await restored { _, _, _ in throw scenario.thrown }

        #expect(sentence(of: session) == scenario.sentence)
        #expect(session.restoreFailure == scenario.failure)
        #expect(!credentials.isEmpty, "an unconfirmed token is kept for the retry")
    }

    /// A preserved-behaviour regression pin, not a red-first case: `main` already produced this
    /// sentence for a 5xx, because `whoami` throws an `APIError` there and the pre-fix catch used
    /// `APIError.errorDescription` too. What is new is the VALUE beside it, which is what the
    /// screen decides its affordance from, and that is what a mutation of the catch site removes.
    @Test("a server that answered keeps its own sentence")
    func serverErrorKeepsItsSentence() async {
        let (session, credentials) = await restored { _, _, _ in
            Stub.empty(.internalServerError)
        }

        #expect(sentence(of: session) == "The server returned an error (HTTP 500).")
        #expect(session.restoreFailure == .server(.server(status: 500)))
        #expect(!credentials.isEmpty)
    }

    @Test("a body the client cannot decode reads as the host being unreachable")
    func decodeFailureNamesTheHost() async {
        // Control: the decoder's own words — the missing key and the case — really are in the
        // error the client throws, so their absence below is a fact about the descriptor.
        let rawText = String(describing: rawDecodeFailure)
        #expect(rawText.contains("auth_kind"))
        #expect(rawText.contains("keyNotFound"))
        // And the classifier's answer for that same error, computed here rather than read back
        // from the store, is a domain and a code and nothing else.
        let expected = classifiedDecodeDetail
        #expect(!expected.contains("auth_kind"))
        #expect(!expected.contains("keyNotFound"))
        #expect(expected.split(separator: " ").count == 2, "a descriptor is a domain and a code")

        let (session, _) = await restored { _, _, _ in Stub.json(#"{"nope":1}"#) }

        #expect(sentence(of: session) == "Can't reach \(storedHost) (\(expected)). \(retryHint)")
        #expect(session.restoreFailure == .unreachable(host: storedHost, detail: expected))
    }

    @Test("nothing the launch shows or logs carries the request or the token")
    func nothingProducedCarriesTheRequest() async {
        let leaks = [
            "operationInput", "requestBody", "Client encountered an error invoking",
            "whoami_api_auth_user_get", storedToken,
        ]
        // A real `ClientError`, built the way swift-openapi-runtime builds one, with every field
        // it prints populated.
        let raw = ClientError(
            operationID: "whoami_api_auth_user_get",
            operationInput: storedToken,
            requestBody: HTTPBody(storedToken),
            baseURL: URL(string: "https://\(storedHost)")!,
            causeDescription: "Transport threw an error.",
            underlyingError: URLError(.timedOut)
        )
        // Positive control: between the two texts that type produces, every marker below is
        // present — so an assertion that finds none of them downstream is looking for something
        // this test could actually see. `description` spells out the input and the body;
        // `localizedDescription` is the "Client encountered an error invoking …" line that reached
        // the owner's screen (runtime 1.12.0; the same phrase is quoted at StoreFailure.swift:12).
        let control = String(describing: raw) + " " + raw.localizedDescription
        for marker in leaks {
            #expect(control.contains(marker), "the control error must carry \(marker)")
        }

        // The log is WATCHED, not re-derived: this is the line the store actually handed its
        // logger, so a `logWhoamiFailure` that interpolated the error itself would be seen here.
        let logged = LockedValue<[String]>([])
        let (session, _) = await restored(
            diagnostics: { line in logged.set(logged.get() + [line]) }
        ) { _, _, _ in throw URLError(.timedOut) }

        // What the screen gets, and what the log gets, are the two things that leave the store.
        let written = logged.get()
        #expect(written.count == 1, "the failure is written down once")
        let produced = [sentence(of: session)] + written
        // Second control: both were produced, are not empty, and were read.
        #expect(produced[0].contains(storedHost))
        #expect(
            written.first == "GET /api/auth/user did not arrive: other (NSURLErrorDomain -1001)"
        )
        for text in produced {
            #expect(!text.isEmpty)
            for marker in leaks {
                #expect(!text.contains(marker), "\(text) carries \(marker)")
            }
        }
    }
}

/// One pasted-token sign-in failure: what the transport threw and the sentence the sign-in screen
/// has to show for it.
struct SignInFailureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let thrown: URLError
    let sentence: String
    let failure: NativeLoginError

    var testDescription: String { name }
}

private let signInDetail = "The sign-in could not reach the server: NSURLErrorDomain "
private let signInFailureCases = [
    SignInFailureCase(
        name: "a DNS failure",
        thrown: URLError(.cannotFindHost),
        sentence: "\(signInDetail)-1003",
        failure: .transport(.other("NSURLErrorDomain -1003"))
    ),
    SignInFailureCase(
        name: "a refused connection",
        thrown: URLError(.cannotConnectToHost),
        sentence: "\(signInDetail)-1004",
        failure: .transport(.other("NSURLErrorDomain -1004"))
    ),
    SignInFailureCase(
        name: "a timeout",
        thrown: URLError(.timedOut),
        sentence: "\(signInDetail)-1001",
        failure: .transport(.other("NSURLErrorDomain -1001"))
    ),
    SignInFailureCase(
        name: "a TLS failure",
        thrown: URLError(.secureConnectionFailed),
        sentence: "\(signInDetail)-1200",
        failure: .transport(.other("NSURLErrorDomain -1200"))
    ),
    SignInFailureCase(
        name: "an offline phone",
        thrown: URLError(.notConnectedToInternet),
        sentence: "This phone looks offline. Join your home wifi (or turn on NetBird) and try "
            + "again.",
        failure: .transport(.offline)
    ),
    SignInFailureCase(
        name: "the Local Network denial",
        thrown: URLError(
            .notConnectedToInternet,
            userInfo: [streamErrorCodeKey: networkIsDown]
        ),
        sentence: "This phone is not letting the app reach your home network. Allow Local Network "
            + "for memosng in Settings, then tap Sign in again.",
        failure: .transport(.localNetworkDenied)
    ),
]

/// What a PASTED-TOKEN sign-in says when the check it runs first does not arrive.
///
/// The same defect as the launch screen's, in the same file: this catch stored the `ClientError`'s
/// own text. It is answered with the classification the NATIVE sign-in leg already applies, so the
/// two ways into this app cannot say different things about one failure — and so the Local Network
/// denial keeps the Settings button `SignInView` already draws from `lastFailure`.
@MainActor
@Suite("The pasted-token sign-in's sentence")
struct SignInFailureClassificationTests {
    private func attempted(
        diagnostics: @escaping @Sendable (String) -> Void = { _ in },
        handler: @escaping StubTransport.Handler
    ) async -> (session: SessionStore, credentials: InMemoryCredentials) {
        let credentials = InMemoryCredentials()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            diagnostics: diagnostics
        )
        await session.signIn(serverAddress: storedHost, token: storedToken)
        return (session, credentials)
    }

    @Test("each transport failure becomes its own sentence", arguments: signInFailureCases)
    func transportFailureBecomesASentence(_ scenario: SignInFailureCase) async {
        let (session, credentials) = await attempted { _, _, _ in throw scenario.thrown }

        #expect(session.lastError == scenario.sentence)
        #expect(session.lastFailure == scenario.failure)
        #expect(session.state == .signedOut)
        #expect(credentials.isEmpty, "a token that was never confirmed is never stored")
    }

    /// A preserved-behaviour regression pin, not a red-first case: `main` already produced this
    /// sentence for a 5xx, because `whoami` throws an `APIError` and the pre-fix catch read
    /// `APIError.errorDescription`. What is new is the value beside it.
    @Test("a server that answered keeps its own sentence")
    func serverErrorKeepsItsSentence() async {
        let (session, _) = await attempted { _, _, _ in Stub.empty(.internalServerError) }

        #expect(session.lastError == "The server returned an error (HTTP 500).")
        #expect(session.lastFailure == .api(.server(status: 500)))
    }

    @Test("a body the client cannot decode is reported as a transport failure, not as its text")
    func decodeFailureIsNamedByDomainAndCode() async {
        // Same two controls as the launch case: the decoder's words are in the raw error, and the
        // classifier's answer for that same error — computed here, not read back — has none.
        let rawText = String(describing: rawDecodeFailure)
        #expect(rawText.contains("auth_kind"))
        #expect(rawText.contains("keyNotFound"))
        let expected = classifiedDecodeDetail
        #expect(!expected.contains("auth_kind"))
        #expect(!expected.contains("keyNotFound"))
        #expect(expected.split(separator: " ").count == 2, "a descriptor is a domain and a code")

        let (session, _) = await attempted { _, _, _ in Stub.json(#"{"nope":1}"#) }

        #expect(session.lastFailure == .transport(.other(expected)))
        #expect(session.lastError == "The sign-in could not reach the server: \(expected)")
    }

    @Test("nothing the sign-in shows or logs carries the request or the token")
    func nothingProducedCarriesTheRequest() async {
        let leaks = [
            "operationInput", "requestBody", "Client encountered an error invoking",
            "whoami_api_auth_user_get", storedToken,
        ]
        let raw = ClientError(
            operationID: "whoami_api_auth_user_get",
            operationInput: storedToken,
            requestBody: HTTPBody(storedToken),
            baseURL: URL(string: "https://\(storedHost)")!,
            causeDescription: "Transport threw an error.",
            underlyingError: URLError(.timedOut)
        )
        // Positive control: between them, the two texts a real `ClientError` produces carry every
        // marker below — so finding none of them downstream is a fact, not an empty grep.
        let control = String(describing: raw) + " " + raw.localizedDescription
        for marker in leaks {
            #expect(control.contains(marker), "the control error must carry \(marker)")
        }

        // The log is WATCHED, not re-derived — see the launch case.
        let logged = LockedValue<[String]>([])
        let (session, _) = await attempted(
            diagnostics: { line in logged.set(logged.get() + [line]) }
        ) { _, _, _ in throw URLError(.timedOut) }

        let written = logged.get()
        #expect(written.count == 1, "the failure is written down once")
        let produced = [session.lastError ?? ""] + written
        #expect(produced[0].contains("NSURLErrorDomain -1001"))
        #expect(
            written.first == "GET /api/auth/user did not arrive: other (NSURLErrorDomain -1001)"
        )
        for text in produced {
            #expect(!text.isEmpty)
            for marker in leaks {
                #expect(!text.contains(marker), "\(text) carries \(marker)")
            }
        }
    }
}

/// The order two stores were written in, which is the only thing that says what an interruption
/// between them would have left behind.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ event: String) { lock.withLock { entries.append(event) } }
    func reset() { lock.withLock { entries = [] } }
    var events: [String] { lock.withLock { entries } }
}

/// What the app published about the signed-in account — which is everything a share extension
/// will ever know about it, since it has no session and no credential of its own.
final class SpyAccountStore: OutboxAccountPublishing, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var value: AccountBinding?
    private var clears = 0
    private var refusals: Int
    private let log: EventLog?

    /// - Parameter refusingClears: how many revocations fail before one succeeds — a file that
    ///   will not delete, which is the failure the session has to survive without going silent.
    init(log: EventLog? = nil, refusingClears: Int = 0) {
        self.log = log
        self.refusals = refusingClears
    }

    func current() -> AccountBinding? { lock.withLock { value } }

    func publish(_ binding: AccountBinding) {
        lock.withLock { value = binding }
        log?.record("licence.publish")
    }

    func clear() throws {
        let refuse: Bool = lock.withLock {
            guard refusals > 0 else { return false }
            refusals -= 1
            return true
        }
        if refuse {
            log?.record("licence.clear.failed")
            throw Refused()
        }
        lock.withLock {
            value = nil
            clears += 1
        }
        log?.record("licence.clear")
    }

    /// Aims the refusal at a particular moment — signing IN revokes the outgoing licence too, so
    /// a count fixed at construction would fail the wrong one.
    func refuseNextClears(_ count: Int) { lock.withLock { refusals = count } }

    var published: AccountBinding? { lock.withLock { value } }
    var clearCount: Int { lock.withLock { clears } }
}

/// The credential store, with every write it is asked for written down in the same log as the
/// licence's — so a test can assert which of the two went first.
final class RecordingCredentials: CredentialStore, @unchecked Sendable {
    private let inner = InMemoryCredentials()
    private let log: EventLog

    init(log: EventLog) { self.log = log }

    func set(_ value: String, for account: String) throws {
        try inner.set(value, for: account)
        log.record("credential.set")
    }

    func add(_ value: String, for account: String) throws -> Bool {
        let stored = try inner.add(value, for: account)
        if stored { log.record("credential.set") }
        return stored
    }

    func string(for account: String) throws -> String? { try inner.string(for: account) }

    func remove(_ account: String) throws {
        try inner.remove(account)
        log.record("credential.remove")
    }

    func snapshot() -> [String: String] { inner.snapshot() }
    var isEmpty: Bool { inner.isEmpty }
}

/// The account the share extension binds a capture to is published by the session, because the
/// owner's subject exists nowhere else on the device: the keychain holds a token and a server
/// address, and the subject comes back from the server.
extension SessionStoreTests {
    private func store(
        credentials: InMemoryCredentials,
        account: SpyAccountStore,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            account: account
        )
    }

    @Test("signing in publishes the server and the owner a shared capture is bound to")
    func signInPublishesTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.user) }
        #expect(account.published == nil)

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")

        #expect(
            account.published
                == AccountBinding(
                    serverBaseURL: URL(string: "https://memos.example.invalid")!,
                    ownerSubject: "fabian"
                )
        )
    }

    @Test("a restored session publishes it too, so an update does not silence the extension")
    func restorePublishesTheAccount() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_good", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }

        await session.restore()

        #expect(account.published?.ownerSubject == "fabian")
    }

    @Test("the browser-brokered sign-in publishes the same account as a pasted token")
    func nativeSignInPublishesTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.exchange(token: "memos_pat_device")) }

        await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: StubPresenter(
                behaviour: .callback(
                    "https://memos.example.invalid/ios/auth/callback?code=handoff-123"
                )
            ),
            pkce: PKCE()
        )

        #expect(session.state.user?.subject == "fabian")
        #expect(session.serverBaseURL?.absoluteString == "https://memos.example.invalid")
        #expect(account.published?.ownerSubject == "fabian")
    }

    @Test("signing out revokes the extension's account in the same breath as the token")
    func signOutClearsTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(account.published != nil)

        await session.signOut()

        #expect(account.published == nil)
        #expect(
            account.clearCount == 2,
            "signing in revokes the outgoing licence and signing out revokes this one"
        )
    }

    @Test("a 401 anywhere clears it as well — the extension must not queue for a dead account")
    func unauthorizedClearsTheAccount() async {
        let account = SpyAccountStore()
        let session = store(
            credentials: InMemoryCredentials(), account: account
        ) { _, _, _ in Stub.json(Stub.user) }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        #expect(account.published != nil)

        await session.handle(CredentialRefusal(issuedUnder: nil))

        #expect(account.published == nil)
    }
}

/// The licence and the credential are two writes to two places, and a phone can die between any
/// two writes. What matters is not that the pair is always consistent — it cannot be — but that
/// every interruption leaves the state where the share extension REFUSES, never one where it
/// enqueues under an identity that has been revoked or replaced.
@MainActor
@Suite("The account licence, interrupted")
struct AccountLicenceOrderTests {
    private func store(
        credentials: any CredentialStore,
        account: SpyAccountStore,
        handler: @escaping StubTransport.Handler
    ) -> SessionStore {
        SessionStore(
            credentials: credentials,
            makeClient: { _, token in Stub.client(token: token, handler: handler) },
            account: account
        )
    }

    @Test("signing out revokes the licence BEFORE the credential it belongs to")
    func revokesLicenceFirst() async {
        let log = EventLog()
        let credentials = RecordingCredentials(log: log)
        let account = SpyAccountStore(log: log)
        let session = store(credentials: credentials, account: account) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        log.reset()

        await session.signOut()

        let events = log.events
        #expect(events.first == "licence.clear")
        #expect(
            events == ["licence.clear", "credential.remove", "credential.remove"],
            "credential-then-licence would leave a revoked identity still able to queue"
        )
        #expect(account.published == nil)
        #expect(credentials.isEmpty)
    }

    @Test("switching accounts revokes the old licence, stores the credential, then publishes")
    func replacementOrderDeniesRatherThanMisleads() async {
        let log = EventLog()
        let credentials = RecordingCredentials(log: log)
        let account = SpyAccountStore(log: log)
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")
        log.reset()

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        #expect(
            log.events == [
                "licence.clear", "credential.set", "credential.set", "licence.publish",
            ],
            "every prefix of this sequence is a state with NO licence, which denies the extension"
        )
    }

    @Test("a licence that will not delete is said out loud, not swallowed")
    func revocationFailureIsVisible() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        account.refuseNextClears(1)

        let outcome = await session.signOut()

        #expect(outcome == .revoked, "a file that will not delete must not keep a live token")
        #expect(credentials.isEmpty)
        #expect(account.published != nil, "the licence really is still there")
        #expect(
            session.lastError?.contains("could not be removed") == true,
            "silence here is a revoked identity that can still queue captures"
        )
    }

    @Test("the next launch retries a revocation that failed, because the credential is gone")
    func restoreRetriesAFailedRevocation() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let signingOut = store(credentials: credentials, account: account) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.empty(.noContent)
        }
        await signingOut.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        account.refuseNextClears(1)
        await signingOut.signOut()
        #expect(account.published != nil)

        // A fresh process over the same two stores: the credential is gone, the licence is not.
        let relaunched = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await relaunched.restore()

        #expect(
            account.published == nil,
            "a licence with no credential behind it belongs to nobody"
        )
    }

    @Test("a licence naming another server is revoked before the credential is even validated")
    func restoreDeniesAMismatchedLicence() async {
        struct Offline: Error {}
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        account.publish(
            AccountBinding(
                serverBaseURL: URL(string: "https://other.example.invalid")!,
                ownerSubject: "someone"
            )
        )

        let session = store(credentials: credentials, account: account) { _, _, _ in
            throw Offline()
        }
        await session.restore()

        guard case .unreachable = session.state else {
            Issue.record("expected .unreachable, got \(session.state)")
            return
        }
        #expect(
            account.published == nil,
            "an unreachable server is no reason to keep licensing the account being replaced"
        )
        #expect(!credentials.isEmpty, "the credential itself is still not evidence of anything")
    }

    @Test("a credential with no licence gets one again as soon as the server says whose it is")
    func restoreHealsAMissingLicence() async {
        let credentials = InMemoryCredentials()
        try? credentials.set("memos_pat_stored", for: SessionStore.tokenAccount)
        try? credentials.set("https://memos.example.invalid", for: SessionStore.serverAccount)
        let account = SpyAccountStore()
        #expect(account.published == nil)

        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.restore()

        #expect(
            account.published
                == AccountBinding(
                    serverBaseURL: URL(string: "https://memos.example.invalid")!,
                    ownerSubject: "fabian"
                )
        )
    }
}

extension AccountLicenceOrderTests {
    /// Swapping accounts on the SAME server is the case nothing downstream can catch: `restore`
    /// compares server addresses, and only the server knows whose a credential is. So a refused
    /// revocation has to stop the sign-in where it stands rather than carry on and hope.
    @Test("a licence that will not go stops the sign-in and changes nothing at all")
    func refusedRevocationAbortsSignIn() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")
        let credentialsBefore = credentials.snapshot()
        let licenceBefore = account.published
        #expect(licenceBefore != nil)

        account.refuseNextClears(1)
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        #expect(
            credentials.snapshot() == credentialsBefore,
            "the new credential must not be stored while the old licence is still standing"
        )
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_a")
        #expect(
            account.published == licenceBefore,
            "and the old licence is untouched, not half-replaced"
        )
        #expect(session.state.user != nil, "the session is left exactly as the sign-in found it")
        #expect(
            session.lastError?.contains("Try signing in again") == true,
            "a sign-in that changed nothing has to say so, or it looks like it worked"
        )
    }

    @Test("the browser-brokered sign-in aborts on the same refusal, and reports it")
    func refusedRevocationAbortsNativeSignIn() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, operation in
            // Two operations, two answers: the first sign-in is what establishes the account this
            // test then proves untouched, so its whoami cannot be answered with an exchange.
            operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.json(Stub.exchange(token: "memos_pat_device"))
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")
        let credentialsBefore = credentials.snapshot()
        let licenceBefore = account.published
        #expect(credentialsBefore[SessionStore.tokenAccount] == "memos_pat_a")
        #expect(licenceBefore != nil)

        account.refuseNextClears(1)
        let signedIn = await session.signInNatively(
            serverAddress: "memos.example.invalid",
            deviceName: "iPhone",
            presenter: StubPresenter(
                behaviour: .callback(
                    "https://memos.example.invalid/ios/auth/callback?code=handoff-123"
                )
            ),
            pkce: PKCE()
        )

        #expect(!signedIn, "the caller has to learn that nothing happened")
        #expect(credentials.snapshot() == credentialsBefore)
        #expect(account.published == licenceBefore)
        #expect(session.lastError?.contains("Try signing in again") == true)
    }

    @Test("a sign-in whose licence WAS revoked still goes through")
    func revocationThatWorksDoesNotBlockASignIn() async {
        let credentials = InMemoryCredentials()
        let account = SpyAccountStore()
        let session = store(credentials: credentials, account: account) { _, _, _ in
            Stub.json(Stub.user)
        }
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_a")

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_b")

        #expect(credentials.snapshot()[SessionStore.tokenAccount] == "memos_pat_b")
        #expect(account.published?.ownerSubject == "fabian")
        #expect(session.lastError == nil)
    }
}

/// What "Default" means in the compose sheet is the ACCOUNT's setting, and until this the app
/// never asked for it — the pill said "Default" and left the reader to guess whether that meant
/// their memo would be private or public.
@MainActor
@Suite("The account's default visibility")
struct SessionSettingsTests {
    private func signedIn(
        handler: @escaping StubTransport.Handler
    ) async -> SessionStore {
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in Stub.client(token: token, handler: handler) }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        return session
    }

    @Test("the default is read from /api/settings and kept")
    func settingsAreRead() async {
        let asked = LockedValue<Bool>(false)
        let session = await signedIn { _, _, operation in
            if operation == settingsOperation {
                asked.set(true)
                return Stub.json(
                    """
                    {"default_visibility":"PROTECTED","theme":"dark","avatar":null}
                    """
                )
            }
            return Stub.json(Stub.user)
        }
        // Nothing is assumed before the server has answered.
        #expect(session.defaultVisibility == nil)

        await session.loadSettings()

        #expect(asked.get())
        #expect(session.defaultVisibility == .protected)
    }

    @Test("each visibility the server can name round-trips")
    func everyVisibilityIsUnderstood() async {
        for (wire, expected) in [
            ("PRIVATE", MemoVisibility.private),
            ("PROTECTED", .protected),
            ("PUBLIC", .public),
        ] {
            let session = await signedIn { _, _, operation in
                operation == settingsOperation
                    ? Stub.json(
                        "{\"default_visibility\":\"\(wire)\",\"theme\":\"d\",\"avatar\":null}"
                    )
                    : Stub.json(Stub.user)
            }
            await session.loadSettings()
            #expect(session.defaultVisibility == expected)
        }
    }

    /// The pill is allowed to say less. It is not allowed to say something wrong, and it is not
    /// allowed to take the screen down with it: this call sits on the timeline's appearance path.
    @Test("a server that will not answer leaves the default unnamed, not invented")
    func aFailedFetchIsSurvivable() async {
        let session = await signedIn { _, _, operation in
            operation == settingsOperation ? Stub.empty(.internalServerError) : Stub.json(Stub.user)
        }
        await session.loadSettings()
        #expect(session.defaultVisibility == nil)
        // The session itself is untouched — a settings failure is not a sign-out.
        #expect(session.state.user?.subject == "fabian")
        #expect(session.lastError == nil)
    }

    /// A reply can outlive the question it answered.
    ///
    /// Dropping the client does not reliably cancel a request already on the wire, so the settings
    /// call started for account A can resolve after somebody has signed in as B. Without the
    /// generation check it assigns A's answer into B's session, and the compose sheet then tells B
    /// their memos default to whatever A had chosen — a wrong promise about who can read something.
    @Test("an answer that arrives after the account changed is discarded")
    func aLateAnswerCannotCrossAccounts() async {
        let entered = Gate()
        let release = Gate()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    guard operation == settingsOperation else { return Stub.json(Stub.user) }
                    entered.open()
                    await release.wait()
                    return Stub.json(
                        """
                        {"default_visibility":"PUBLIC","theme":"d","avatar":null}
                        """
                    )
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "token_for_a")

        let inFlight = Task { await session.loadSettings() }
        // Not "probably started": the stub says so before anything is allowed to change.
        await entered.wait()

        await session.signOutWithoutRevoking()
        await session.signIn(serverAddress: "memos.example.invalid", token: "token_for_b")

        release.open()
        await inFlight.value

        #expect(session.defaultVisibility == nil)
        #expect(session.state.user?.subject == "fabian")
    }

    /// The control for the test above. The same slow call, with nobody signing in behind it, still
    /// lands — so what that test proves is about the account changing, not about slowness.
    @Test("an answer for the session that asked for it is still assigned")
    func aSlowAnswerForTheSameSessionLands() async {
        let entered = Gate()
        let release = Gate()
        let session = SessionStore(
            credentials: InMemoryCredentials(),
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    guard operation == settingsOperation else { return Stub.json(Stub.user) }
                    entered.open()
                    await release.wait()
                    return Stub.json(
                        """
                        {"default_visibility":"PUBLIC","theme":"d","avatar":null}
                        """
                    )
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "token_for_a")

        let inFlight = Task { await session.loadSettings() }
        await entered.wait()
        release.open()
        await inFlight.value

        #expect(session.defaultVisibility == .public)
    }

    /// A 401 here is not "the setting could not be read", it is the server saying this credential
    /// is dead — which is the one error this codebase never treats as best-effort, wherever it
    /// turns up. A token revoked between opening the timeline and reading the settings is still a
    /// revoked token.
    @Test("a 401 from the settings call ends the session like any other")
    func anUnauthorisedSettingsCallEndsTheSession() async {
        let credentials = InMemoryCredentials()
        let session = SessionStore(
            credentials: credentials,
            makeClient: { _, token in
                Stub.client(token: token) { _, _, operation in
                    operation == settingsOperation
                        ? Stub.empty(.unauthorized) : Stub.json(Stub.user)
                }
            }
        )
        await session.signIn(serverAddress: "memos.example.invalid", token: "token_for_a")
        #expect(session.state.user != nil)

        await session.loadSettings()

        #expect(session.state.user == nil)
        #expect(session.defaultVisibility == nil)
        #expect(session.lastError != nil)
        // The dead credential is gone from the device, not merely from memory.
        #expect(credentials.snapshot()[SessionStore.tokenAccount] == nil)
    }

    /// One account's setting must never be shown to the next one.
    @Test("signing out forgets the account's default")
    func theDefaultDoesNotOutliveTheAccount() async {
        let session = await signedIn { _, _, operation in
            operation == settingsOperation
                ? Stub.json("{\"default_visibility\":\"PUBLIC\",\"theme\":\"d\",\"avatar\":null}")
                : Stub.json(Stub.user)
        }
        await session.loadSettings()
        #expect(session.defaultVisibility == .public)

        await session.signOutWithoutRevoking()

        #expect(session.defaultVisibility == nil)
    }
}

/// A place a stubbed request can stop, so a test can say exactly when a call is in flight and
/// exactly when it is allowed to finish. Without it "start a slow load, then switch accounts" is
/// a race the test would sometimes win by accident.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen: Bool = lock.withLock {
                if isOpen { return true }
                waiter = continuation
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            isOpen = true
            let held = waiter
            waiter = nil
            return held
        }
        waiting?.resume()
    }
}

// MARK: - a newly documented 503 is answered as its undocumented self was

extension SessionStoreTests {
    /// The server failed to revoke: the credential stays, and the outcome names the 503 exactly as
    /// the undocumented status did before v2.1.0.
    @Test("a 503 to the revoke keeps the credential and names HTTP 503, as before v2.1.0")
    func signOutUnavailable() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation ? Stub.json(Stub.user) : Stub.databaseBusy()
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let outcome = await session.signOut()

        #expect(outcome == .revokeFailed(.server(status: 503)))
        #expect(session.state != .signedOut)
        #expect(!credentials.isEmpty, "a live token must stay tracked until its fate is settled")
    }
}

extension SessionStoreTests {
    @Test("a proxy's HTML 503 to the revoke keeps the credential and names HTTP 503")
    func signOutProxyPage() async {
        let credentials = InMemoryCredentials()
        let session = store(credentials: credentials) { _, _, operation in
            operation == whoamiOperation
                ? Stub.json(Stub.user) : Stub.proxyPage(.serviceUnavailable)
        }

        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_good")
        let outcome = await session.signOut()

        #expect(outcome == .revokeFailed(.server(status: 503)))
        #expect(!credentials.isEmpty)
    }
}
