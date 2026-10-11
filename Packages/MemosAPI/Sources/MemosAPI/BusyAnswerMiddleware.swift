import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Keeps a 503 or a 429 arriving as the status it is, whatever its body.
///
/// memos-ng v2.1.0 documents a JSON 503 on almost every route, and a JSON 429 on the chunk append.
/// The generated client decodes a documented answer's body INSIDE the call, so a 503 whose body is
/// not a JSON object — a reverse proxy's HTML page, an empty body — would throw from the call
/// rather than reach the caller's switch, and every caller reads a throw differently from a
/// status: a compose failure classifies it as a rejection instead of a server failure, a sign-out
/// takes its catch instead of keeping the credential with an HTTP 503. Until v2.1.0 that same
/// answer arrived as `.undocumented(503)`, decided by its status alone. So the body of one of
/// those answers is replaced, unread, by an empty JSON object, which the contract's
/// `{detail?: string}` accepts and every switch throws `APIError.fromStatus` for. Unread matters:
/// waiting for a body that a proxy stalls or trickles would hold the caller — and any mutation
/// gate it occupies — until the body ends, where the status alone used to answer at once. Nothing
/// reads these bodies, so nothing is lost; the other headers, `Retry-After` among them, stay.
///
/// The keyed memo create and patch are left alone: their 503 was documented before v2.1.0, as the
/// race that stored nothing, and an unreadable 503 there never was that answer and must not become
/// it. A HEAD carries no body, and its 503 is documented without one.
public struct BusyAnswerMiddleware: ClientMiddleware {
    /// The routes whose 503 is the keyed-write race, documented since before v2.1.0.
    static let racedWriteOperations: Set<String> = [
        "create_memo_api_memos_post", "patch_memo_api_memos__uid__patch",
    ]

    /// The one route whose 429 the contract documents.
    static let chunkAppendOperation = "append_chunk_api_uploads__upload_uid__patch"

    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard request.method != .head, Self.covers(response.status.code, operationID) else {
            return (response, responseBody)
        }
        var readable = response
        readable.headerFields[.contentType] = "application/json"
        readable.headerFields[.contentLength] = nil
        return (readable, HTTPBody("{}"))
    }

    /// The statuses v2.1.0 newly documents with a body, on the routes it documents them for.
    static func covers(_ status: Int, _ operationID: String) -> Bool {
        switch status {
        case 503: !racedWriteOperations.contains(operationID)
        case 429: operationID == chunkAppendOperation
        default: false
        }
    }
}
