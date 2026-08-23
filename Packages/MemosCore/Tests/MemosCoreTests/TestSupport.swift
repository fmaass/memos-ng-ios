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

    static func memo(uid: String, content: String = "hello") -> String {
        """
        {"uid":"\(uid)","owner":"fabian","mine":true,"content":"\(content)",\
        "visibility":"PRIVATE","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
        "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],"attachments":[]}
        """
    }

    static func memoList(_ uids: [String], nextCursor: String?) -> String {
        let cursor = nextCursor.map { "\"\($0)\"" } ?? "null"
        return """
            {"items":[\(uids.map { memo(uid: $0) }.joined(separator: ","))],\
            "nextCursor":\(cursor),"totalCount":null}
            """
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

/// Counts calls from a `@Sendable` closure without tripping strict concurrency.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
