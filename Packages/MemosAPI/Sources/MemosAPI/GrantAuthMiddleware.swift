import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Attaches the step-up management grant — and nothing else, under any circumstances.
///
/// `Grant` is its own scheme in the contract (`grantAuth`) and its own middleware here, and both
/// halves of that are the point. The server refuses a PAT presented as a grant and a grant
/// presented as a bearer, neither is ever reinterpreted as the other, and on this side the
/// separation is structural rather than careful: a client built with this middleware is built with
/// this middleware ONLY, so it holds no reference to a `PresentedCredential` and there is no code
/// path — not a fallback, not an "if the grant is missing" branch — by which the device's token
/// could travel to `/api/pats`. A leaked device token must not be able to mint successors that
/// outlive its own revocation (ADR-0015, Decision 5), and the way to keep that true is for the
/// management client to have never been able to see one.
///
/// Nothing is attached when there is no grant, which is not an edge case: the request that BUYS a
/// grant is made by this same client before it holds one, and that request has to be anonymous or
/// it could not be the way a device gets its first management credential.
///
/// The value is read per request rather than captured, so a re-authentication mid-screen reaches a
/// client that was already built — the same reason `BearerAuthMiddleware` reads its credential.
public struct GrantAuthMiddleware: ClientMiddleware {
    private let grant: ManagementGrant

    public init(grant: ManagementGrant) {
        self.grant = grant
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let value = grant.current, !value.isEmpty {
            request.headerFields[.authorization] = "Grant \(value)"
        }
        return try await next(request, body, baseURL)
    }
}
