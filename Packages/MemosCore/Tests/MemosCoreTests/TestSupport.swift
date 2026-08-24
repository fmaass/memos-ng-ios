import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
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

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        try await handler(request, body, operationID)
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

    static let user = """
        {"subject":"fabian","display_name":"Fabian","email":"f@example.invalid",\
        "role":"admin","auth_kind":"oidc"}
        """

    static func memo(
        uid: String,
        content: String = "hello",
        pinned: Bool = false,
        visibility: String = "PRIVATE",
        createdAt: String = "2026-08-23T09:00:00Z"
    ) -> String {
        """
        {"uid":"\(uid)","owner":"fabian","mine":true,"content":"\(jsonEscaped(content))",\
        "visibility":"\(visibility)","pinned":\(pinned),"created_at":"\(createdAt)",\
        "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],"attachments":[]}
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
final class InMemoryCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ value: String, for account: String) throws {
        lock.withLock { storage[account] = value }
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
final class RefusingCredentials: CredentialStore, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var reads = 0

    func set(_ value: String, for account: String) throws { throw Refused() }
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

/// The two keychain namespaces as the Security framework was OBSERVED to behave, which is the one
/// thing a pair of independent dictionaries cannot express: there is ONE item table, an item
/// carries the access group it was written under, and a `SecItemDelete` whose query names no
/// access group matches the account in EVERY group — while a `SecItemCopyMatching` that names
/// none sees only the ungrouped ones.
///
/// That asymmetry is not invented for the test. On a fresh sign-in the shipped app logged
/// `SecItemAdd -> 0`, then `SecItemCopyMatching -> 0` for the same query, and then
/// `SecItemCopyMatching -> -25300` a second later — with nothing in between but the ungrouped
/// delete that was supposed to clear the OTHER namespace.
final class KeychainNamespaces: @unchecked Sendable {
    private struct Key: Hashable {
        var group: String?
        var account: String
    }

    private let lock = NSLock()
    private var items: [Key: String] = [:]

    /// The namespace addressed WITH an access group: it reads, writes and deletes only its own.
    func grouped(_ group: String) -> any CredentialStore { Namespace(table: self, group: group) }

    /// The namespace addressed with no access group, as `Keychain(accessGroup: nil)` is.
    func ungrouped() -> any CredentialStore { Namespace(table: self, group: nil) }

    var isEmpty: Bool { lock.withLock { items.isEmpty } }

    fileprivate func write(_ value: String, group: String?, account: String) {
        lock.withLock { items[Key(group: group, account: account)] = value }
    }

    fileprivate func read(group: String?, account: String) -> String? {
        lock.withLock { items[Key(group: group, account: account)] }
    }

    /// A grouped delete takes its own item. An UNGROUPED one takes the account out of every group
    /// there is — the behaviour the shipped defect ran into.
    fileprivate func delete(group: String?, account: String) {
        lock.withLock {
            if let group {
                items[Key(group: group, account: account)] = nil
            } else {
                for key in items.keys where key.account == account { items[key] = nil }
            }
        }
    }

    private struct Namespace: CredentialStore {
        let table: KeychainNamespaces
        let group: String?

        func set(_ value: String, for account: String) throws {
            table.write(value, group: group, account: account)
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
final class ForgetfulCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    func set(_ value: String, for account: String) throws { lock.withLock { writes += 1 } }
    func string(for account: String) throws -> String? { nil }
    func remove(_ account: String) throws {}

    var writeCount: Int { lock.withLock { writes } }
}
