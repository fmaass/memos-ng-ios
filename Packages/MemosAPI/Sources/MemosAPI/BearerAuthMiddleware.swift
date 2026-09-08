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
/// When it is built from a `PresentedCredential` the device has ADOPTED, it also stamps the 401. A
/// renewal destroys the presenting token as it mints the successor, so every request already in the
/// air comes back 401 — correctly, about a token that no longer exists. Which of the two a given
/// refusal is about cannot be answered here, because the effect it triggers happens hops later and
/// the answer changes in between. So this layer records rather than decides: it throws a
/// `CredentialRefusal` carrying the generation the request PRESENTED, and every effect asks the one
/// question of that value at the instant it acts (MEMNG-270).
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
        // EVERY refusal of an INSTALLED credential, not only the ones this instant can already
        // call stale. Whether it is stale is not this middleware's question — it is the question
        // the EFFECT asks, one or more hops later; the only thing knowable here is which
        // credential earned it, and that is what travels.
        //
        // The epoch's presence is half the test, and it is exact: `authorization()` returns nil
        // for an empty token, so the ANONYMOUS credential the login exchange presents never
        // reaches here — its 401 stays a `.undocumented(401)`. A client built from a bare token
        // closure has no generation at all, so the share extension's lane is untouched.
        //
        // INSTALLED is the other half: a pasted token being validated before anything adopts it
        // is a candidate, not this device's credential. Nothing can renew it, so wrapping its
        // refusal would only cost its owner the sentence that says the server refused it.
        if response.status == .unauthorized, let epoch = presented?.epoch,
            credential?.isInstalled == true
        {
            throw CredentialRefusal(issuedUnder: epoch)
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
