import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The body fields a trip change sends as an explicit JSON `null`, for the task it is set on.
///
/// The server clears a trip's field only when the PATCH body names it with `null`; a field that is
/// absent is kept. The generated client cannot write that `null`: its synthesized encoding leaves
/// every nil property out, and no generator option says otherwise. So the caller names the fields
/// to clear here, around the one generated call, and `ExplicitNullMiddleware` adds them to the
/// body on the way out. The names are the body's wire names (`tag`, `spanStart`, …).
public enum ExplicitNulls {
    @TaskLocal public static var fields: Set<String> = []
}

/// Writes `ExplicitNulls.fields` into the trip PATCH's JSON body as `null`.
///
/// Only the trip PATCH, and only while the task-local names a field: every other request — any
/// other operation, or the PATCH with nothing to clear — passes through untouched, the same
/// request and the same body. A field the body already carries keeps its value. A body that is not
/// a JSON object is refused rather than sent without the clear it was asked to carry.
public struct ExplicitNullMiddleware: ClientMiddleware {
    /// The one operation whose body may carry an explicit null.
    static let patchOperation = "update_collection_api_collections__uid__patch"
    /// More than any trip change the client writes.
    static let readLimit = 64 * 1024

    public enum Refusal: Error, Equatable {
        /// The body to add the nulls to was not a JSON object.
        case notAnObject
    }

    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let fields = ExplicitNulls.fields
        guard operationID == Self.patchOperation, !fields.isEmpty else {
            return try await next(request, body, baseURL)
        }
        var data = Data("{}".utf8)
        if let body { data = try await Data(collecting: body, upTo: Self.readLimit) }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Refusal.notAnObject
        }
        for field in fields where object[field] == nil { object[field] = NSNull() }
        let written = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        var sent = request
        if sent.headerFields[.contentLength] != nil {
            sent.headerFields[.contentLength] = String(written.count)
        }
        if sent.headerFields[.contentType] == nil {
            sent.headerFields[.contentType] = "application/json; charset=utf-8"
        }
        return try await next(sent, HTTPBody(written), baseURL)
    }
}
