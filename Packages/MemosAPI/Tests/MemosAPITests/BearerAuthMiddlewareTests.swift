import Foundation
import HTTPTypes
import MemosAPI
import Testing

@Suite("BearerAuthMiddleware")
struct BearerAuthMiddlewareTests {
    private func request() -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "https", authority: "example.invalid", path: "/api/memos")
    }

    private let baseURL = URL(string: "https://example.invalid")!

    @Test("attaches the token as a bearer credential")
    func attachesBearerHeader() async throws {
        let middleware = BearerAuthMiddleware(token: { "memos_pat_abc" })
        var seen: HTTPRequest?
        let (response, _) = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { forwarded, body, _ in
                seen = forwarded
                _ = body
                return (HTTPResponse(status: .ok), nil)
            }
        )
        #expect(response.status == .ok)
        #expect(seen?.headerFields[.authorization] == "Bearer memos_pat_abc")
    }

    @Test("sends no Authorization header when there is no token")
    func omitsHeaderWhenSignedOut() async throws {
        let middleware = BearerAuthMiddleware(token: { nil })
        var seen: HTTPRequest?
        _ = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { forwarded, _, _ in
                seen = forwarded
                return (HTTPResponse(status: .ok), nil)
            }
        )
        #expect(seen?.headerFields[.authorization] == nil)
    }

    @Test("sends no Authorization header for an empty token")
    func omitsHeaderForEmptyToken() async throws {
        let middleware = BearerAuthMiddleware(token: { "" })
        var seen: HTTPRequest?
        _ = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { forwarded, _, _ in
                seen = forwarded
                return (HTTPResponse(status: .ok), nil)
            }
        )
        #expect(seen?.headerFields[.authorization] == nil)
    }

    @Test("reads the token again for every request")
    func readsTokenPerRequest() async throws {
        let tokens = TokenSequence(["first", "second"])
        let middleware = BearerAuthMiddleware(token: { await tokens.next() })
        var headers: [String?] = []
        for _ in 0..<2 {
            _ = try await middleware.intercept(
                request(),
                body: nil,
                baseURL: baseURL,
                operationID: "listMemos",
                next: { forwarded, _, _ in
                    headers.append(forwarded.headerFields[.authorization])
                    return (HTTPResponse(status: .ok), nil)
                }
            )
        }
        #expect(headers == ["Bearer first", "Bearer second"])
    }

    // MARK: - the credential that moved underneath a request

    @Test("a credential presents whatever it holds now, without the client being rebuilt")
    func presentsTheCurrentValue() async throws {
        let credential = PresentedCredential("first")
        let middleware = BearerAuthMiddleware(credential: credential)
        var headers: [String?] = []
        for _ in 0..<2 {
            _ = try await middleware.intercept(
                request(),
                body: nil,
                baseURL: baseURL,
                operationID: "listMemos",
                next: { forwarded, _, _ in
                    headers.append(forwarded.headerFields[.authorization])
                    return (HTTPResponse(status: .ok), nil)
                }
            )
            credential.replace(with: "second")
        }
        #expect(headers == ["Bearer first", "Bearer second"])
    }

    /// The renewal's window, at the layer that can see it: the request left carrying the token the
    /// renewal then destroyed, so the server refuses it — correctly, and about nothing this device
    /// still holds. What travels out is the epoch the request PRESENTED; whether that is still the
    /// device's credential is the question the effect asks, hops later, and not this one's.
    @Test("a 401 carries the generation the refused request presented")
    func supersededRefusalCarriesItsEpoch() async {
        let credential = PresentedCredential("first")
        credential.install()
        let middleware = BearerAuthMiddleware(credential: credential)

        await #expect(throws: CredentialRefusal(issuedUnder: 0)) {
            try await middleware.intercept(
                request(),
                body: nil,
                baseURL: baseURL,
                operationID: "listMemos",
                next: { _, _, _ in
                    // The swap lands while this request is in the air.
                    credential.replace(with: "second")
                    return (HTTPResponse(status: .unauthorized), nil)
                }
            )
        }
    }

    /// The same value for the un-raced 401, and that is the point: the middleware records, it does
    /// not decide. A verdict taken here is a verdict about the instant the answer arrived, which is
    /// never the instant the wipe runs.
    @Test("a 401 for the token the credential still holds is thrown as a refusal too")
    func currentRefusalIsThrownAsARefusal() async {
        let credential = PresentedCredential("first")
        credential.install()
        let middleware = BearerAuthMiddleware(credential: credential)

        await #expect(throws: CredentialRefusal(issuedUnder: 0)) {
            try await middleware.intercept(
                request(),
                body: nil,
                baseURL: baseURL,
                operationID: "listMemos",
                next: { _, _, _ in (HTTPResponse(status: .unauthorized), nil) }
            )
        }
    }

    /// A credential nothing has adopted is a CANDIDATE — the pasted token being validated before
    /// anything installs it. Nothing can renew it underneath its own check, so its 401 is the
    /// server's plain answer about what was typed in, and it keeps the `.undocumented(401)` path
    /// that turns into the sentence its owner needs.
    @Test("a 401 for a credential nothing installed passes through untouched")
    func uninstalledCredentialRefusalPassesThrough() async throws {
        let credential = PresentedCredential("candidate")
        let middleware = BearerAuthMiddleware(credential: credential)

        let (response, _) = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { _, _, _ in (HTTPResponse(status: .unauthorized), nil) }
        )

        #expect(response.status == .unauthorized)
    }

    /// A success is never fenced, however much the credential moved while it was in flight: the
    /// server answered the request, and the answer is the answer.
    @Test("a replacement mid-flight does not disturb a response that succeeded")
    func supersededSuccessIsUntouched() async throws {
        let credential = PresentedCredential("first")
        let middleware = BearerAuthMiddleware(credential: credential)

        let (response, _) = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { _, _, _ in
                credential.replace(with: "second")
                return (HTTPResponse(status: .ok), nil)
            }
        )

        #expect(response.status == .ok)
    }

    /// A client built from a bare token closure has no generations, so it fences nothing — the
    /// share extension's client, and every suite here that is about the header itself.
    @Test("a client with no credential behind it still reports its 401")
    func tokenClosureClientDoesNotFence() async throws {
        let middleware = BearerAuthMiddleware(token: { "memos_pat_abc" })

        let (response, _) = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { _, _, _ in (HTTPResponse(status: .unauthorized), nil) }
        )

        #expect(response.status == .unauthorized)
    }

    @Test("an anonymous credential attaches nothing")
    func anonymousAttachesNothing() async throws {
        let middleware = BearerAuthMiddleware(credential: .anonymous)
        var seen: HTTPRequest?
        _ = try await middleware.intercept(
            request(),
            body: nil,
            baseURL: baseURL,
            operationID: "listMemos",
            next: { forwarded, _, _ in
                seen = forwarded
                return (HTTPResponse(status: .ok), nil)
            }
        )
        #expect(seen?.headerFields[.authorization] == nil)
    }
}

private actor TokenSequence {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String? {
        values.isEmpty ? nil : values.removeFirst()
    }
}
