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
