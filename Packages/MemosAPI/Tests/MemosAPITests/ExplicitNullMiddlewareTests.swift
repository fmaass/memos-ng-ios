import Foundation
import HTTPTypes
import MemosAPI
import OpenAPIRuntime
import Testing

/// The one place an explicit JSON `null` is written: the trip PATCH, only for the fields the task
/// names, and nothing else the client sends.
@Suite("Explicit nulls")
struct ExplicitNullMiddlewareTests {
    static let patch = "update_collection_api_collections__uid__patch"
    static let create = "create_collection_api_collections_post"
    static let base = URL(string: "https://memos.example.invalid")!

    static func request(length: Int) -> HTTPRequest {
        var request = HTTPRequest(method: .patch, scheme: "https", authority: nil, path: "/x")
        request.headerFields[.contentType] = "application/json; charset=utf-8"
        request.headerFields[.contentLength] = String(length)
        return request
    }

    /// What reached the transport: the request and its body bytes.
    static func send(
        _ operation: String, _ text: String, fields: Set<String>
    ) async throws -> (request: HTTPRequest, body: Data, original: HTTPRequest) {
        let original = request(length: Data(text.utf8).count)
        var seen: (HTTPRequest, Data)?
        try await ExplicitNulls.$fields.withValue(fields) {
            _ = try await ExplicitNullMiddleware().intercept(
                original, body: HTTPBody(text), baseURL: base, operationID: operation
            ) { request, body, _ in
                var data = Data()
                if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
                seen = (request, data)
                return (HTTPResponse(status: .ok), nil)
            }
        }
        let reached = try #require(seen, "nothing reached the transport")
        return (reached.0, reached.1, original)
    }

    @Test("a different operation passes through byte-identical inside a withValue")
    func otherOperationUntouched() async throws {
        let text = "{\n  \"tag\" : \"porto\",\n  \"title\" : \"Porto\"\n}"
        let sent = try await Self.send(Self.create, text, fields: ["tag", "tz", "title"])
        #expect(sent.request == sent.original)
        #expect(sent.body == Data(text.utf8))
    }

    @Test("the trip PATCH gains a null per named absent field, keeps a present one, and its length")
    func patchGainsNulls() async throws {
        let text = #"{"tag":"keep","title":"T"}"#
        let sent = try await Self.send(Self.patch, text, fields: ["tag", "tz", "spanStart"])
        let expected = #"{"spanStart":null,"tag":"keep","title":"T","tz":null}"#
        #expect(String(decoding: sent.body, as: UTF8.self) == expected)
        #expect(sent.request.headerFields[.contentLength] == String(Data(expected.utf8).count))
        #expect(sent.request.path == sent.original.path)
        #expect(sent.request.method == .patch)
    }

    @Test("a named field that appears only inside a string value still gains its null")
    func fieldNameInsideAValueIsNotTheField() async throws {
        let text = #"{"title":"tz"}"#
        let sent = try await Self.send(Self.patch, text, fields: ["tz"])
        let parsed = try JSONSerialization.jsonObject(with: sent.body)
        let object = try #require(parsed as? [String: Any])
        #expect(object["tz"] is NSNull, "the name inside the title stood in for the field")
        #expect(object["title"] as? String == "tz")
    }

    @Test("the trip PATCH with nothing named passes through byte-identical")
    func patchWithNothingNamedUntouched() async throws {
        let text = "{\n  \"title\" : \"T\"\n}"
        let sent = try await Self.send(Self.patch, text, fields: [])
        #expect(sent.request == sent.original)
        #expect(sent.body == Data(text.utf8))
    }

    @Test("a PATCH body that is not a JSON object is refused, never sent without its null")
    func nonObjectRefused() async throws {
        await #expect(throws: ExplicitNullMiddleware.Refusal.notAnObject) {
            _ = try await Self.send(Self.patch, "[1]", fields: ["tag"])
        }
    }
}
