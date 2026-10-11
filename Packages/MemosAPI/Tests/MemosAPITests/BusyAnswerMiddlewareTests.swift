import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

/// Which answers the middleware rewrites, and that a rewrite keeps everything but the body.
@Suite("BusyAnswerMiddleware")
struct BusyAnswerMiddlewareTests {
    private let baseURL = URL(string: "https://memos.example.invalid")!
    private static let page = "<html><body>Service Unavailable</body></html>"

    /// What comes back from the middleware for one answer from the network.
    private func answer(
        _ status: HTTPResponse.Status,
        to operationID: String,
        method: HTTPRequest.Method = .get
    ) async throws -> (response: HTTPResponse, body: String) {
        var sent = HTTPResponse(status: status)
        sent.headerFields[.contentType] = "text/html"
        sent.headerFields[.retryAfter] = "7"
        let network = sent
        let request = HTTPRequest(
            method: method, scheme: "https", authority: "memos.example.invalid", path: "/"
        )
        let (response, body) = try await BusyAnswerMiddleware().intercept(
            request,
            body: nil,
            baseURL: baseURL,
            operationID: operationID,
            next: { _, _, _ in (network, HTTPBody(Self.page)) }
        )
        var text = ""
        if let body { text = try await String(collecting: body, upTo: 4096) }
        return (response, text)
    }

    @Test("a 503 is given an empty JSON body, its other headers kept")
    func rewritesAndKeepsHeaders() async throws {
        let (response, body) = try await answer(.serviceUnavailable, to: "list_pats_api_pats_get")

        #expect(response.status == .serviceUnavailable)
        #expect(body == "{}")
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(response.headerFields[.retryAfter] == "7")
    }

    @Test("a 429 to the chunk append is given an empty JSON body")
    func rewritesTheChunk429() async throws {
        let (response, body) = try await answer(
            .tooManyRequests, to: "append_chunk_api_uploads__upload_uid__patch", method: .patch
        )

        #expect(response.status == .tooManyRequests)
        #expect(body == "{}")
        #expect(response.headerFields[.retryAfter] == "7")
    }

    /// The contract documents a 429 on the chunk append only; anywhere else it stays undocumented.
    @Test("a 429 on any other route passes through untouched")
    func otherRoute429IsUntouched() async throws {
        let (response, body) = try await answer(.tooManyRequests, to: "list_pats_api_pats_get")

        #expect(body == Self.page)
        #expect(response.headerFields[.contentType] == "text/html")
    }

    /// The keyed create and patch documented their 503 before v2.1.0, as the race that stored
    /// nothing; an unreadable 503 there must not be turned into that answer.
    @Test(
        "an unreadable 503 to the keyed create or patch passes through untouched",
        arguments: ["create_memo_api_memos_post", "patch_memo_api_memos__uid__patch"]
    )
    func keyedWritesAreUntouched(_ operationID: String) async throws {
        let (response, body) = try await answer(.serviceUnavailable, to: operationID, method: .post)

        #expect(body == Self.page)
        #expect(response.headerFields[.contentType] == "text/html")
    }

    @Test("a 503 to a HEAD passes through untouched")
    func headIsUntouched() async throws {
        let (response, body) = try await answer(
            .serviceUnavailable, to: "upload_offset_api_uploads__upload_uid__head", method: .head
        )

        #expect(body == Self.page)
        #expect(response.headerFields[.contentType] == "text/html")
    }

    @Test("any other status passes through untouched")
    func otherStatusIsUntouched() async throws {
        let (response, body) = try await answer(.internalServerError, to: "list_pats_api_pats_get")

        #expect(body == Self.page)
        #expect(response.headerFields[.contentType] == "text/html")
    }
}
