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
    /// still holds. Letting that 401 out would make it indistinguishable from a revoked session.
    @Test("a 401 for a token the credential has since replaced is not a 401 to anyone else")
    func supersededRefusalIsFenced() async {
        let credential = PresentedCredential("first")
        let middleware = BearerAuthMiddleware(credential: credential)

        await #expect(throws: CredentialSuperseded.self) {
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

    /// The control, and the reason the fence is a fence rather than a hole: the same 401, with no
    /// replacement in between, is passed straight through to be read as the end of the session.
    @Test("a 401 for the token the credential still holds passes through untouched")
    func currentRefusalPassesThrough() async throws {
        let credential = PresentedCredential("first")
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
