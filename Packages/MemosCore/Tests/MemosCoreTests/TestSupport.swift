import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import MemosOutbox
import OpenAPIRuntime

/// Substitutes the network, not the client.
///
/// The store's dependency is the generated `APIProtocol`, and the honest way to stand in for a
/// server is to give the REAL generated client a transport that answers from a script: the
/// request the store actually builds, the decoding the client actually does and the middleware
/// that actually attaches the token are all exercised. A hand-written stand-in for `APIProtocol`
/// would assert only that the test agrees with itself.
struct StubTransport: ClientTransport {
    typealias Handler =
        @Sendable (HTTPRequest, HTTPBody?, String) async throws -> (
            HTTPResponse, HTTPBody?
        )

    let handler: Handler
    /// Whether `/health` is answered here, as a server of the app's own major, instead of reaching
    /// the handler. Every sign-in launches the handshake as an unstructured task, so its request
    /// races whatever a test is counting; a handler written before the handshake existed counts it
    /// as one of its own. Only the handshake's own suite hands `/health` to its handler.
    var answersHealthItself = true

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if answersHealthItself, operationID == Stub.healthOperation {
            return Stub.json(Stub.healthOfThisMajor)
        }
        return try await handler(request, body, operationID)
    }
}

/// What a stubbed answer is, so a handler written as a `switch` can return one line per case.
///
/// The `Stub` helpers hand back a tuple, and a `switch` whose arms are tuples of an
/// `HTTPResponse` and an optional body is unreadable. This is the same answers with a name.
enum HTTPResponseLike: Sendable {
    case json(String)
    /// A 201 with a body — what a create answers, and the one status where the body matters as
    /// much as the code.
    case created(String)
    case status(HTTPResponse.Status)
    case detail(String, status: HTTPResponse.Status)
    case validation(String)

    var parts: (HTTPResponse, HTTPBody?) {
        switch self {
        case .json(let payload): Stub.json(payload)
        case .created(let payload): Stub.json(payload, status: .created)
        case .status(let status): Stub.empty(status)
        case .detail(let detail, let status): Stub.detail(detail, status: status)
        case .validation(let message): Stub.validationError(message)
        }
    }
}

extension APIProtocol {
    /// The store seam, for a client with no session behind it.
    ///
    /// Generation zero, and that is the honest value: these suites are about paging, merging and
    /// what a request carries, and none of them names a session — a store with no session has no
    /// incarnation to be wrong about (`TimelineStore.sessionStillCurrent`). The suites that ARE
    /// about the fence build their handles from a real `SessionStore`.
    var handle: SessionHandle { SessionHandle(client: self, generation: 0) }
}

/// Lands a renewal in the ONE instant nothing else can reach: after `BearerAuthMiddleware`
/// compared the epoch and THREW, and before the store's continuation resumes.
///
/// The hook is the CATCH, not the ordinary continuation. Once the bearer middleware throws on a
/// 401 its caller's post-`next` code never runs, so a hook placed there could only ever fire
/// BEFORE the fix — a test that passed for the wrong reason. `swift-openapi-runtime` applies the
/// first element of the middleware array outermost, so this one sees the throw last;
/// `PresentedCredential.replace(with:)` is synchronous and nonisolated, so landing it needs no hop
/// and there is no scheduling race at all.
struct RenewingOnRefusal: ClientMiddleware {
    typealias Answer = (HTTPResponse, HTTPBody?)
    /// `@concurrent` is not decoration. This target has MainActor default isolation, under which
    /// a `@Sendable` async function parameter is inferred `nonisolated(nonsending)`, which does
    /// not match `ClientMiddleware`'s requirement — the conformance simply fails.
    typealias Next = @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> Answer

    let install: @Sendable () -> Void

    nonisolated func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: Next
    ) async throws -> Answer {
        do {
            return try await next(request, body, baseURL)
        } catch {
            install()
            throw error
        }
    }
}

/// Lands a renewal on a request's way OUT: after everything the store did before it sent, and
/// before `BearerAuthMiddleware` reads the credential to attach it.
///
/// It sits in FRONT of the bearer middleware, so it runs first, inside the same call, with nothing
/// awaited between it and that read. `PresentedCredential.replace(with:)` is synchronous and
/// nonisolated, so the renewal is in place when the read happens by construction — not because a
/// task queued somewhere else happened to get its turn first.
struct RenewingBeforeSend: ClientMiddleware {
    typealias Answer = (HTTPResponse, HTTPBody?)
    /// `@concurrent` for the reason `RenewingOnRefusal` gives.
    typealias Next = @concurrent @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> Answer

    let renew: @Sendable () -> Void

    nonisolated func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: Next
    ) async throws -> Answer {
        renew()
        return try await next(request, body, baseURL)
    }
}

extension VisibilityChange {
    /// Any change, cleared to send through the real rule: a narrowing as it is proposed, a
    /// widening as the yes to its question. For tests whose subject is the request, not the asking.
    static func cleared(_ to: MemoVisibility, from: MemoVisibility? = nil) -> VisibilityChange {
        switch propose(to, from: from) {
        case .ready(let change): return change
        case .ask(let question): return question.confirmed()
        case .unchanged: fatalError("no change from \(String(describing: from)) to \(to)")
        }
    }
}

enum Stub {
    static let baseURL = URL(string: "https://memos.example.invalid")!

    static func json(_ payload: String, status: HTTPResponse.Status = .ok) -> (
        HTTPResponse, HTTPBody?
    ) {
        var response = HTTPResponse(status: status)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }

    static func empty(_ status: HTTPResponse.Status) -> (HTTPResponse, HTTPBody?) {
        (HTTPResponse(status: status), nil)
    }

    static func client(
        token: @escaping @Sendable () async -> String? = { nil },
        handler: @escaping StubTransport.Handler
    ) -> any APIProtocol {
        APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: baseURL),
            token: token,
            transport: StubTransport(handler: handler)
        )
    }

    /// The session's own client, which reads a credential that can MOVE underneath it. Overloaded
    /// on the same label so that every `makeClient: { _, token in Stub.client(token: token, …) }`
    /// in these suites keeps building the client the app actually builds — including the epoch
    /// fence, which a token closure has no way to carry.
    static func client(
        token: PresentedCredential,
        healthFromHandler: Bool = false,
        handler: @escaping StubTransport.Handler
    ) -> any APIProtocol {
        APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: baseURL),
            credential: token,
            transport: StubTransport(handler: handler, answersHealthItself: !healthFromHandler)
        )
    }

    /// The session's own client — the app's middleware chain, unchanged — with a renewal hook in
    /// front of it that runs on every request's way out, before the credential is read.
    static func client(
        token: PresentedCredential,
        beforeSend renew: @escaping @Sendable () -> Void,
        handler: @escaping StubTransport.Handler
    ) -> any APIProtocol {
        Client(
            serverURL: baseURL,
            configuration: APIClientFactory.runtimeConfiguration,
            transport: StubTransport(handler: handler),
            middlewares: [
                RenewingBeforeSend(renew: renew),
                BearerAuthMiddleware(credential: token),
                BusyAnswerMiddleware(),
                ExplicitNullMiddleware(),
            ]
        )
    }

    /// The contract's operationId for `/health`, which the sign-in handshake asks.
    static let healthOperation = "health_health_get"

    /// A server of exactly the major this build was generated from: the handshake says nothing.
    static let healthOfThisMajor =
        #"{"status":"ok","version":"test","apiMajor":\#(VendoredRelease.apiMajor)}"#

    /// The management screen's client: a real generated client whose ONLY middleware is the grant
    /// one, which is what the app builds. A test that reached for `client(token:)` here would be
    /// exercising a client the management lane never has.
    static func client(
        grant: ManagementGrant,
        licence: GrantSendLicence = GrantSendLicence { true },
        handler: @escaping StubTransport.Handler
    ) -> any APIProtocol {
        APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: baseURL),
            grant: grant,
            licence: licence,
            transport: StubTransport(handler: handler)
        )
    }

    /// The management client with a middleware in FRONT of the grant one, so a test can hold a
    /// request on its way OUT.
    ///
    /// Holding an answer exercises the store's fence; only holding the request itself reaches the
    /// instant the licence is asked, which is after every main-actor check the store can make.
    static func client(
        grant: ManagementGrant,
        licence: GrantSendLicence,
        ahead: any ClientMiddleware,
        handler: @escaping StubTransport.Handler
    ) -> any APIProtocol {
        Client(
            serverURL: baseURL,
            configuration: APIClientFactory.runtimeConfiguration,
            transport: StubTransport(handler: handler),
            middlewares: [ahead, GrantAuthMiddleware(grant: grant, licence: licence)]
        )
    }

    /// The error an upload against an INSTALLED credential actually throws for a 401.
    ///
    /// Made by performing the real request through `StubTransport` rather than by constructing a
    /// wrapper by hand: what a store meets is the generated client's envelope around a
    /// `CredentialRefusal` carrying the epoch the request presented, and a test that builds that
    /// value itself asserts only that the test agrees with itself. A bare-token client's plain
    /// `APIError.unauthorized` is a DIFFERENT shape and is asserted beside this one, never instead
    /// of it.
    ///
    /// - Returns: the thrown error, or nil if the call unexpectedly succeeded — which a caller
    ///   turns into a named failure rather than a silent pass.
    static func uploadRefusalFromAnInstalledClient() async -> (any Error)? {
        let credential = PresentedCredential("memos_pat_a")
        credential.install()
        let client = client(token: credential) { _, _, _ in Stub.empty(.unauthorized) }
        do {
            _ = try await MediaUpload.start(
                StagedSource(
                    url: URL(filePath: "/tmp/never-read.jpg"),
                    filename: "never-read.jpg",
                    mime: "image/jpeg"
                ),
                size: 1,
                using: client
            )
            return nil
        } catch {
            return error
        }
    }

    /// The session's own client with a renewal armed on the refusal path — the window every
    /// checkpoint-6 test is about.
    ///
    /// Built from the app's OWN runtime configuration rather than a second one, as CLAUDE.md
    /// requires: a client that quietly used the default date handling would pass here and fail on
    /// every memo in production.
    static func client(
        token: PresentedCredential,
        afterRefusal install: @escaping @Sendable () -> Void,
        handler: @escaping StubTransport.Handler
    ) -> any APIProtocol {
        Client(
            serverURL: baseURL,
            configuration: APIClientFactory.runtimeConfiguration,
            transport: StubTransport(handler: handler),
            middlewares: [
                RenewingOnRefusal(install: install),
                BearerAuthMiddleware(credential: token),
            ]
        )
    }

    static let user = """
        {"subject":"fabian","display_name":"Fabian","email":"f@example.invalid",\
        "role":"admin","auth_kind":"oidc"}
        """

    /// One row of `GET /api/pats`. Both nullable fields are written out as JSON `null` rather than
    /// omitted, which is what the server sends and what the generated decoder has to survive.
    static func pat(
        id: Int,
        name: String,
        createdAt: String = "2026-08-01T09:00:00Z",
        lastUsed: String? = "2026-08-27T09:00:00Z",
        expiresAt: String? = "2027-08-01T09:00:00Z"
    ) -> String {
        let used = lastUsed.map { "\"\($0)\"" } ?? "null"
        let expires = expiresAt.map { "\"\($0)\"" } ?? "null"
        return """
            {"id":\(id),"name":"\(jsonEscaped(name))","last_used":\(used),\
            "created_at":"\(createdAt)","expires_at":\(expires)}
            """
    }

    /// What `POST /api/pats` answers: the row, plus the plaintext that exists in this one response
    /// and nowhere else, ever.
    static func patCreated(
        id: Int,
        name: String,
        token: String,
        createdAt: String = "2026-08-28T09:00:00Z",
        expiresAt: String? = nil
    ) -> String {
        let expires = expiresAt.map { "\"\($0)\"" } ?? "null"
        return """
            {"id":\(id),"name":"\(jsonEscaped(name))","last_used":null,\
            "created_at":"\(createdAt)","expires_at":\(expires),"token":"\(token)"}
            """
    }

    /// What `POST /api/auth/native/manage-grant` answers on the one successful mint.
    static func manageGrant(
        _ grant: String,
        expiresAt: String = "2026-08-28T09:10:00Z"
    ) -> String {
        #"{"grant":"\#(grant)","expires_at":"\#(expiresAt)"}"#
    }

    static func memo(
        uid: String,
        content: String = "hello",
        pinned: Bool = false,
        visibility: String = "PRIVATE",
        createdAt: String = "2026-08-23T09:00:00Z",
        /// When the server says this memo was archived. `nil` is a memo in the ordinary timeline —
        /// which is every memo in every test that does not say otherwise.
        archivedAt: String? = nil,
        attachments: [String] = [],
        /// The server's write stamp. One fixed instant unless a test is about the ORDER of writes.
        updatedAt: String = "2026-08-23T09:00:00.443000Z"
    ) -> String {
        let archived = archivedAt.map { "\"\($0)\"" } ?? "null"
        return """
            {"uid":"\(uid)","owner":"fabian","mine":true,"content":"\(jsonEscaped(content))",\
            "visibility":"\(visibility)","pinned":\(pinned),"created_at":"\(createdAt)",\
            "updated_at":"\(updatedAt)","archived_at":\(archived),"tags":[],\
            "attachments":[\(attachments.joined(separator: ","))]}
            """
    }

    /// One attachment on a memo, at whatever stage of processing the test needs. The derived-tier
    /// URLs are present whatever the status — which is the whole point: they exist in the payload
    /// from the moment the attachment does, long before the worker has produced anything to serve
    /// from them.
    ///
    /// `position` and `captureInstant` are null unless a test asks for them, the way a row written
    /// before either was kept is. Both fields are REQUIRED on `AttachmentRef` (nullable, but
    /// required), as are `sha256`, `capture_civil` and `capture_source`, which nothing here has a
    /// use for and which are therefore spelled as the nulls they are rather than left out.
    ///
    /// `exp` and `sig` mint them the way the server does — `?exp=&scope=&sig=`, the shape
    /// `sign_asset_url` writes — for the tests that are about the SIGNATURE having a life of its
    /// own. Left off, the URLs carry no signature at all, which is what every other test wants:
    /// nothing then expires and no test accidentally depends on the clock it runs under.
    static func attachment(
        uid: String,
        status: String,
        mime: String = "image/jpeg",
        captureInstant: String? = nil,
        position: Int? = nil,
        exp: Int? = nil,
        sig: String = "aaaa"
    ) -> String {
        let query = exp.map { "?exp=\($0)&scope=1&sig=\(sig)" } ?? ""
        let capture = captureInstant.map { "\"\($0)\"" } ?? "null"
        let place = position.map(String.init) ?? "null"
        return """
            {"uid":"\(uid)","mime":"\(mime)","status":"\(status)","blurhash":null,\
            "width":1000,"height":1000,"duration":null,"mine":true,"hasPrint":false,\
            "hasLegacyPrint":false,"webReady":true,"renditions":[],"position":\(place),\
            "sha256":null,"capture_instant":\(capture),"capture_civil":null,\
            "capture_source":null,\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(uid)/mobile\(query)",\
            "webUrl":"/api/attachments/\(uid)/web\(query)",\
            "posterUrl":"/api/attachments/\(uid)/poster\(query)",\
            "downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    /// One row of `GET /api/attachments`: `AttachmentListItem`, NOT the memo's `AttachmentRef`
    /// above. It has no `duration`, `position` or capture fields, and requires `orphan`, `memoUid`,
    /// `takenAt` and `filename`, so a memo attachment served in its place is refused by the
    /// decoder and a test reading an empty library would be reading that refusal.
    ///
    /// The row is a ready JPEG hanging on no memo — an orphan, which the library deliberately
    /// lists.
    static func libraryItem(uid: String) -> String {
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":1000,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "webReady":true,\
            "renditions":[],"tags":[],"orphan":true,"memoUid":null,"visibility":null,\
            "takenAt":"2026-09-26T10:00:00Z","filename":"\(uid).jpg",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
            "previewUrl":"/api/attachments/\(uid)/mobile",\
            "webUrl":"/api/attachments/\(uid)/web",\
            "posterUrl":"/api/attachments/\(uid)/poster",\
            "downloadUrl":"/api/attachments/\(uid)/original",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    /// A memo's content is Markdown, so it carries newlines and quotes into these hand-built JSON
    /// bodies; unescaped they produce a body the real decoder rejects and a test that fails for
    /// the wrong reason.
    static func jsonEscaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// What `POST /api/auth/native/exchange` answers on the one and only successful exchange.
    static func exchange(token: String) -> String {
        """
        {"token":"\(token)","expires_at":"2027-08-23T09:00:00Z","user":\(user)}
        """
    }

    /// A 400 from the exchange, with one of the server's four stable detail codes.
    static func exchangeFailure(_ detail: String) -> (HTTPResponse, HTTPBody?) {
        json(#"{"detail":"\#(detail)"}"#, status: .badRequest)
    }

    /// A refusal in FastAPI's own shape — `{"detail": "<code>"}` — at whatever status sent it.
    /// The renewal's `token_not_renewable` arrives this way, and it is a different answer from
    /// every other 400, so a test has to be able to send exactly it.
    static func detail(
        _ detail: String,
        status: HTTPResponse.Status
    ) -> (HTTPResponse, HTTPBody?) {
        json(#"{"detail":"\#(detail)"}"#, status: status)
    }

    /// FastAPI's 422, in the shape `HTTPValidationError` declares — a LIST under `detail`, which
    /// is what makes it a different answer from every other refusal the app reads.
    static func validationError(_ message: String) -> (HTTPResponse, HTTPBody?) {
        json(
            #"{"detail":[{"loc":[],"msg":"\#(message)","type":"value_error"}]}"#,
            status: .unprocessableContent
        )
    }

    /// What `GET` and `PATCH /api/auth/native/token` answer: the presenting token's own row.
    ///
    /// There is no `id` in it, deliberately — the contract withholds one because a bearer has no
    /// sibling to act on. Both nullable fields are written out as JSON `null` rather than omitted,
    /// which is what the server sends and what the generated decoder has to survive.
    static func nativeToken(
        name: String,
        createdAt: String = "2026-08-01T09:00:00Z",
        lastUsed: String? = "2026-08-27T09:00:00Z",
        expiresAt: String? = "2027-08-01T09:00:00Z"
    ) -> String {
        let used = lastUsed.map { "\"\($0)\"" } ?? "null"
        let expires = expiresAt.map { "\"\($0)\"" } ?? "null"
        return """
            {"name":"\(jsonEscaped(name))","created_at":"\(createdAt)",\
            "last_used":\(used),"expires_at":\(expires)}
            """
    }

    /// The JSON body a store actually sent, so a test asserts the request rather than trusting it.
    static func body(_ body: HTTPBody?) async throws -> [String: Any] {
        guard let body else { return [:] }
        let data = try await Data(collecting: body, upTo: 64 * 1024)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The same bytes, kept whole. A body has to be collected inside the transport handler, but a
    /// test often wants to assert on it afterwards — above all that a key is ABSENT, which is
    /// only meaningful once the body it is missing from has been read.
    static func bytes(_ body: HTTPBody?) async throws -> Data {
        guard let body else { return Data() }
        return try await Data(collecting: body, upTo: 64 * 1024)
    }

    static func object(_ data: Data?) -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A page built from memo bodies the test wrote itself, for lists whose memos differ by more
    /// than their uid.
    static func page(_ memos: [String], nextCursor: String? = nil) -> String {
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        return """
            {"items":[\(memos.joined(separator: ","))],\
            "nextCursor":\(cursor),"totalCount":null}
            """
    }

    static func memoList(_ uids: [String], nextCursor: String?) -> String {
        page(uids.map { memo(uid: $0) }, nextCursor: nextCursor)
    }
}

/// Stands in for the browser sheet: it hands back whatever callback URL a test wants, or fails
/// the way a real authentication session fails, and records what it was asked to present.
@MainActor
struct StubPresenter: NativeLoginPresenter {
    enum Behaviour {
        case callback(String)
        case failure(NativeLoginError)
    }

    let behaviour: Behaviour
    let seenAuthorizeURL = LockedValue<URL?>(nil)
    let seenHost = LockedValue<String?>(nil)
    let seenPath = LockedValue<String?>(nil)
    let calls = Counter()

    func authenticate(
        authorizeURL: URL,
        callbackHost: String,
        callbackPath: String
    ) async throws -> URL {
        calls.increment()
        seenAuthorizeURL.set(authorizeURL)
        seenHost.set(callbackHost)
        seenPath.set(callbackPath)
        switch behaviour {
        case .callback(let raw):
            guard let url = URL(string: raw) else { throw NativeLoginError.malformedCallback }
            return url
        case .failure(let error):
            throw error
        }
    }
}

/// A credential store that behaves like the Keychain without needing one.
///
/// It conforms to BOTH seams: `KeychainNamespaceStore`, so it can be one namespace inside a
/// vault, and `CredentialStore`, so it can be the whole of what a session is given. A synchronous
/// method satisfies an asynchronous requirement, so there is one implementation, not two.
final class InMemoryCredentials: KeychainNamespaceStore, CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ value: String, for account: String) throws {
        lock.withLock { storage[account] = value }
    }

    func add(_ value: String, for account: String) throws -> Bool {
        lock.withLock {
            guard storage[account] == nil else { return false }
            storage[account] = value
            return true
        }
    }

    func string(for account: String) throws -> String? {
        lock.withLock { storage[account] }
    }

    func remove(_ account: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }

    var isEmpty: Bool { lock.withLock { storage.isEmpty } }

    func snapshot() -> [String: String] { lock.withLock { storage } }
}

/// A store that accepts nothing — how the app-group namespace behaves on a build whose
/// entitlement is missing, which is the case the migration has to survive without losing a token.
final class RefusingCredentials: KeychainNamespaceStore, CredentialStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var reads = 0

    func set(_ value: String, for account: String) throws { throw Refused() }
    func add(_ value: String, for account: String) throws -> Bool { throw Refused() }
    func string(for account: String) throws -> String? {
        lock.withLock { reads += 1 }
        return nil
    }
    func remove(_ account: String) throws {}

    var readCount: Int { lock.withLock { reads } }
}

/// Counts calls from a `@Sendable` closure without tripping strict concurrency.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// The two keychain namespaces, each addressed BY NAME, over one item table.
///
/// One table is the honest model: the Security framework has one keychain, and an item carries the
/// access group it was written under. What separates the namespaces is that every query names a
/// group — which is exactly the property the production code now has by type, and exactly the
/// property it lacked when the token was written to one namespace and deleted by a query that
/// named none.
final class KeychainNamespaces: @unchecked Sendable {
    /// The three groups a device actually has: the app-only one the token lives in now, the app
    /// group the extensions share, and the `<team id>.<bundle id>` one a pre-entitlement sign-in
    /// wrote to.
    static let credentials = "ABCDE12345.live.discomarder.memosng.credentials"
    static let shared = "group.live.discomarder.memosng"
    static let appDefault = "ABCDE12345.live.discomarder.memosng"

    private struct Key: Hashable {
        var group: String
        var account: String
    }

    private let lock = NSLock()
    private var items: [Key: String] = [:]

    func grouped(_ group: String) -> any KeychainNamespaceStore {
        Namespace(table: self, group: group)
    }

    func value(_ group: String, _ account: String) -> String? {
        lock.withLock { items[Key(group: group, account: account)] }
    }

    var isEmpty: Bool { lock.withLock { items.isEmpty } }

    fileprivate func write(_ value: String, group: String, account: String) {
        lock.withLock { items[Key(group: group, account: account)] = value }
    }

    fileprivate func add(_ value: String, group: String, account: String) -> Bool {
        lock.withLock {
            let key = Key(group: group, account: account)
            guard items[key] == nil else { return false }
            items[key] = value
            return true
        }
    }

    fileprivate func read(group: String, account: String) -> String? {
        lock.withLock { items[Key(group: group, account: account)] }
    }

    /// Scoped, because every query names its group. A delete in one namespace leaves the other
    /// alone — which is the whole of the fix, and what these tests are here to keep true.
    fileprivate func delete(group: String, account: String) {
        lock.withLock { items[Key(group: group, account: account)] = nil }
    }

    private struct Namespace: KeychainNamespaceStore {
        let table: KeychainNamespaces
        let group: String

        func set(_ value: String, for account: String) throws {
            table.write(value, group: group, account: account)
        }

        func add(_ value: String, for account: String) throws -> Bool {
            table.add(value, group: group, account: account)
        }

        func string(for account: String) throws -> String? {
            table.read(group: group, account: account)
        }

        func remove(_ account: String) throws {
            table.delete(group: group, account: account)
        }
    }
}

/// A namespace that accepts every write and then has nothing — `SecItemAdd` answering
/// `errSecSuccess` for an item the next `SecItemCopyMatching` cannot find. It is the only failure
/// here that a status code does not report, which is why the store has to read back.
final class ForgetfulCredentials: KeychainNamespaceStore, CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    func set(_ value: String, for account: String) throws { lock.withLock { writes += 1 } }
    func add(_ value: String, for account: String) throws -> Bool {
        lock.withLock { writes += 1 }
        return true
    }
    func string(for account: String) throws -> String? { nil }
    func remove(_ account: String) throws {}

    var writeCount: Int { lock.withLock { writes } }
}

/// Stops a store's FIRST read halfway, so another thread can be let past it.
///
/// The migration reads the old namespace and then acts on what it read, and the interesting
/// question is what happens when a sign-in lands in that gap. This holds the gap open: the reader
/// signals `entered` with the stale value already in hand and blocks on `proceed`.
final class GatedCredentialStore: KeychainNamespaceStore, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    private let wrapped: any KeychainNamespaceStore
    private let lock = NSLock()
    private var armed = true

    init(wrapping wrapped: any KeychainNamespaceStore) { self.wrapped = wrapped }

    func string(for account: String) throws -> String? {
        let value = try wrapped.string(for: account)
        if takeGate() {
            entered.signal()
            proceed.wait()
        }
        return value
    }

    func set(_ value: String, for account: String) throws { try wrapped.set(value, for: account) }
    func add(_ value: String, for account: String) throws -> Bool {
        try wrapped.add(value, for: account)
    }
    func remove(_ account: String) throws { try wrapped.remove(account) }

    private func takeGate() -> Bool {
        lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
    }
}

/// A namespace that holds what it was given and refuses every write — a build whose entitlement
/// for this group is missing, which is readable and unwritable. It is here to prove that a writer
/// whose own write failed deletes NOTHING: the delete works, so a wrongful one would show.
final class ReadOnlyCredentials: KeychainNamespaceStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var storage: [String: String]

    init(holding storage: [String: String]) { self.storage = storage }

    func set(_ value: String, for account: String) throws { throw Refused() }
    func add(_ value: String, for account: String) throws -> Bool { throw Refused() }
    func string(for account: String) throws -> String? { lock.withLock { storage[account] } }
    func remove(_ account: String) throws {
        _ = lock.withLock { storage.removeValue(forKey: account) }
    }

    func snapshot() -> [String: String] { lock.withLock { storage } }
}

/// A namespace whose reads FAIL: an item that is there and will not come back — bytes that are
/// not UTF-8, an item of the wrong class, a status the keychain would not explain. Absence and
/// corruption are different answers, and this is the second one. It counts its deletions, because
/// the thing being asserted is usually that there were none.
final class UnreadableCredentials: KeychainNamespaceStore, CredentialStore, @unchecked Sendable {
    struct Unreadable: Error {}

    private let lock = NSLock()
    private var removals = 0

    func set(_ value: String, for account: String) throws {}
    func add(_ value: String, for account: String) throws -> Bool { true }
    func string(for account: String) throws -> String? { throw Unreadable() }
    func remove(_ account: String) throws { lock.withLock { removals += 1 } }

    var removalCount: Int { lock.withLock { removals } }
}

/// A store that keeps what it is given and will not let go of it — the sign-out that cannot clear
/// the device.
final class UnwipeableCredentials: KeychainNamespaceStore, CredentialStore, @unchecked Sendable {
    struct Stuck: Error {}

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ value: String, for account: String) throws {
        lock.withLock { storage[account] = value }
    }
    func add(_ value: String, for account: String) throws -> Bool {
        lock.withLock {
            guard storage[account] == nil else { return false }
            storage[account] = value
            return true
        }
    }
    func string(for account: String) throws -> String? { lock.withLock { storage[account] } }
    func remove(_ account: String) throws { throw Stuck() }

    func snapshot() -> [String: String] { lock.withLock { storage } }
}

/// A namespace this build has lost the right to look in — `errSecMissingEntitlement`, which is
/// what a keychain group missing from the signed entitlements answers. It is the one status that
/// must never be read as "nothing here": the token may be sitting in exactly this namespace.
final class NotEntitledCredentials: KeychainNamespaceStore, CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var removals = 0

    func set(_ value: String, for account: String) throws { throw Keychain.Failure.notEntitled }
    func add(_ value: String, for account: String) throws -> Bool {
        throw Keychain.Failure.notEntitled
    }
    func string(for account: String) throws -> String? { throw Keychain.Failure.notEntitled }
    func remove(_ account: String) throws { lock.withLock { removals += 1 } }

    var removalCount: Int { lock.withLock { removals } }
}

/// Stops a namespace's FIRST write halfway, so another operation can be let at it.
///
/// The interesting question about a sign-in is what a sign-out arriving mid-way would leave
/// behind, and the only way to ask it is to hold the sign-in open between its two halves.
final class GatedWriteCredentials: KeychainNamespaceStore, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    private let wrapped: any KeychainNamespaceStore
    private let lock = NSLock()
    private var armed = true

    init(wrapping wrapped: any KeychainNamespaceStore) { self.wrapped = wrapped }

    func set(_ value: String, for account: String) throws {
        try wrapped.set(value, for: account)
        if takeGate() {
            entered.signal()
            proceed.wait()
        }
    }

    func add(_ value: String, for account: String) throws -> Bool {
        try wrapped.add(value, for: account)
    }
    func string(for account: String) throws -> String? { try wrapped.string(for: account) }
    func remove(_ account: String) throws { try wrapped.remove(account) }

    private func takeGate() -> Bool {
        lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
    }
}

/// One value written on one thread and read on another, without tripping strict concurrency.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
