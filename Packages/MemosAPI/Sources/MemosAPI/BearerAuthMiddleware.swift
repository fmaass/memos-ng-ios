import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Attaches the device's personal access token to every outgoing request.
///
/// The contract declares a `bearerAuth` security scheme, but swift-openapi-generator deliberately
/// does not generate security handling, so authentication is a client middleware — one place that
/// decides what credential a request carries.
///
/// The token is read through a closure rather than captured by value: it is stored in the Keychain
/// and can be revoked mid-session, and a middleware holding a stale copy would keep presenting a
/// dead token.
public struct BearerAuthMiddleware: ClientMiddleware {
    private let token: @Sendable () async -> String?

    public init(token: @escaping @Sendable () async -> String?) {
        self.token = token
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = await token(), !token.isEmpty {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}
