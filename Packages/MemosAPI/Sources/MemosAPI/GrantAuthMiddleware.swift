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
/// Answers, at the instant a request is about to leave, whether the identity the grant was bought
/// under is still the app's identity.
///
/// The question is asked through a closure rather than a type of this layer's own, because the
/// identity it consults lives above this layer and this layer imports nothing above itself. The
/// closure is wrapped in a value for the reason `SendAuthority` is one: a bare function type
/// travelling through a `makeClient` seam is a non-escaping parameter at every site it passes
/// through, and none of those sites could store it.
public struct GrantSendLicence: Sendable {
    private let stillCurrent: @Sendable () -> Bool

    public init(_ stillCurrent: @escaping @Sendable () -> Bool) {
        self.stillCurrent = stillCurrent
    }

    public func holds() -> Bool { stillCurrent() }
}

/// Thrown instead of sending, when the licence refuses.
///
/// Its own type, so a caller can tell a withdrawn identity from anything the server said: there is
/// nobody left to read a notice about it, and the answer must not be mistaken for one.
public struct ManagementIdentityWithdrawn: Error, Equatable {
    public init() {}
}

public struct GrantAuthMiddleware: ClientMiddleware {
    private let grant: ManagementGrant
    private let licence: GrantSendLicence

    public init(grant: ManagementGrant, licence: GrantSendLicence) {
        self.grant = grant
        self.licence = licence
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // Here and not where the work was started: this is the last instant before the request
        // leaves, and nothing is awaited between the answer and the forward. A check made on the
        // main actor can only speak for a moment that has already passed by the time the transport
        // sends.
        guard licence.holds() else { throw ManagementIdentityWithdrawn() }
        var request = request
        if let value = grant.current, !value.isEmpty {
            request.headerFields[.authorization] = "Grant \(value)"
        }
        return try await next(request, body, baseURL)
    }
}
