import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Attaches the device's personal access token to every outgoing request, and refuses to let a
/// refusal of a REPLACED token be mistaken for a refusal of the one in hand.
///
/// The contract declares a `bearerAuth` security scheme, but swift-openapi-generator deliberately
/// does not generate security handling, so authentication is a client middleware — one place that
/// decides what credential a request carries.
///
/// The token is read per request rather than captured by value: it is stored in the Keychain and
/// can be revoked or RENEWED mid-session, and a middleware holding a stale copy would keep
/// presenting a dead token.
///
/// When it is built from a `PresentedCredential` it also fences the 401. A renewal destroys the
/// presenting token as it mints the successor, so every request already in the air comes back 401 —
/// correctly, about a token that no longer exists. Deciding that here is what keeps the rest of the
/// app simple: `APIError.unauthorized` remains the one signal that ends a session, and it can only
/// ever mean the credential this device is holding NOW was refused. Every caller, in the stores and
/// in the screens, gets that guarantee without a line of its own.
public struct BearerAuthMiddleware: ClientMiddleware {
    private let token: @Sendable () async -> String?
    /// Nil for a client built from a bare token closure — the share extension's, and the tests
    /// that are about the header rather than about renewal. With no generations there is nothing
    /// to supersede, so such a client fences nothing and behaves exactly as it always did.
    private let credential: PresentedCredential?

    public init(token: @escaping @Sendable () async -> String?) {
        self.token = token
        self.credential = nil
    }

    public init(credential: PresentedCredential) {
        self.credential = credential
        self.token = { () -> String? in credential.current }
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        let presented = await authorization()
        if let presented {
            request.headerFields[.authorization] = presented.header
        }
        let (response, responseBody) = try await next(request, body, baseURL)
        if response.status == .unauthorized, let credential, let epoch = presented?.epoch,
            !credential.isCurrent(epoch)
        {
            throw CredentialSuperseded()
        }
        return (response, responseBody)
    }

    /// The header to send and, when there is one to remember, the generation it belongs to.
    private func authorization() async -> (header: String, epoch: UInt64?)? {
        if let credential {
            let snapshot = credential.presented()
            guard !snapshot.token.isEmpty else { return nil }
            return ("Bearer \(snapshot.token)", snapshot.epoch)
        }
        guard let token = await token(), !token.isEmpty else { return nil }
        return ("Bearer \(token)", nil)
    }
}
