import Foundation
import MemosOutbox
import Testing

/// A test bundle built by Xcode has no `Bundle.module`, and Swift Testing has no `XCTestCase` for
/// `Bundle(for:)`, so this token supplies one.
private final class BundleToken {}

/// What the hand-rolled transport is held to.
///
/// This package mirrors a handful of wire fields instead of using the generated client, because
/// two of its four calls cannot be generated at all. The risk that buys is drift: a schema
/// re-sync could move a field and nothing would notice until an upload silently stopped working.
/// So the vendored document is read here and the outbox's own encoding is checked against it —
/// every key it sends, every key it decodes, and the two refusal codes it acts on.
@Suite("The vendored contract")
struct ContractTests {
    private let document: [String: Any]

    init() throws {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: "openapi", withExtension: "json"))
        let data = try Data(contentsOf: url)
        document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func schema(_ name: String) throws -> [String: Any] {
        let components = try #require(document["components"] as? [String: Any])
        let schemas = try #require(components["schemas"] as? [String: Any])
        return try #require(schemas[name] as? [String: Any])
    }

    private func properties(_ name: String) throws -> [String: Any] {
        try #require(try schema(name)["properties"] as? [String: Any])
    }

    private func operation(_ path: String, _ method: String) throws -> [String: Any] {
        let paths = try #require(document["paths"] as? [String: Any])
        let item = try #require(paths[path] as? [String: Any])
        return try #require(item[method] as? [String: Any])
    }

    /// The `$ref`ed schema name of a response, so a response is checked by its shape and not by
    /// the sentence describing it.
    private func responseSchema(_ operation: [String: Any], status: String) throws -> String {
        let responses = try #require(operation["responses"] as? [String: Any])
        let response = try #require(responses[status] as? [String: Any])
        let content = try #require(response["content"] as? [String: Any])
        let json = try #require(content["application/json"] as? [String: Any])
        let schema = try #require(json["schema"] as? [String: Any])
        let ref = try #require(schema["$ref"] as? String)
        return String(ref.split(separator: "/").last ?? "")
    }

    @Test("every key the outbox sends on a memo create exists in MemoCreate", .tags(.contract))
    func memoCreateKeys() throws {
        let job = Fixture.job(files: [Fixture.file(uploadUID: "u1")])
        let request = try OutboxRequests.createMemo(
            baseURL: Fixture.server, token: "pat-token", job: job
        )
        let body = try #require(request.httpBody)
        let sent = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let declared = try properties("MemoCreate")
        for key in sent.keys {
            #expect(declared[key] != nil, "MemoCreate has no '\(key)'")
        }
        #expect(sent["idempotency_key"] != nil)
        #expect(sent["upload_uids"] as? [String] == ["u1"])
    }

    @Test("a UUID satisfies the idempotency key's own rules", .tags(.contract))
    func idempotencyKeyShape() throws {
        let key = try #require(try properties("MemoCreate")["idempotency_key"] as? [String: Any])
        let pattern = try #require(key["pattern"] as? String)
        let minimum = try #require(key["minLength"] as? Int)
        let maximum = try #require(key["maxLength"] as? Int)

        // The outbox sends `UUID.uuidString`; if that ever stopped satisfying the server's own
        // constraint, every create would fail validation with the memo already captured.
        let sent = UUID().uuidString
        #expect(sent.count >= minimum)
        #expect(sent.count <= maximum)
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(sent.startIndex..., in: sent)
        #expect(expression.firstMatch(in: sent, range: range) != nil)
    }

    @Test(
        "the strict refusal is declared on create AND patch, with the fields the outbox reads",
        .tags(.contract))
    func unlinkableRefusal() throws {
        for (path, method) in [("/api/memos", "post"), ("/api/memos/{uid}", "patch")] {
            #expect(
                try responseSchema(try operation(path, method), status: "409")
                    == "UploadsUnlinkableError"
            )
        }
        let detail = try schema("UploadsUnlinkableDetail")
        let declared = try #require(detail["properties"] as? [String: Any])
        let required = try #require(detail["required"] as? [String])
        #expect(Set(required) == ["code", "missing_upload_uids", "incomplete_upload_uids"])
        let code = try #require(declared["code"] as? [String: Any])
        #expect(code["const"] as? String == UploadsUnlinkableFailure.code)

        // Built from the declared names, decoded by the outbox's own decoder.
        let body = Data(
            """
            {"detail":{"code":"\(UploadsUnlinkableFailure.code)",\
            "missing_upload_uids":["a"],"incomplete_upload_uids":["b"]}}
            """.utf8)
        let failure = try #require(UploadsUnlinkableFailure.decode(body))
        #expect(failure.missingUploadUIDs == ["a"])
        #expect(failure.incompleteUploadUIDs == ["b"])
    }

    @Test(
        "a raced keyed create is declared, and is the code the outbox retries on", .tags(.contract))
    func racedCreate() throws {
        #expect(
            try responseSchema(try operation("/api/memos", "post"), status: "503")
                == "CreateRacedError"
        )
        let detail = try schema("CreateRacedDetail")
        let declared = try #require(detail["properties"] as? [String: Any])
        let code = try #require(declared["code"] as? [String: Any])
        #expect(code["const"] as? String == MemoCompletionEndpoint.racedCode)
    }

    @Test("the upload calls the outbox drives by hand still say what it expects", .tags(.contract))
    func uploadCalls() throws {
        let start = try properties("UploadCreate")
        for key in ["filename", "mime", "size", "last_modified"] {
            #expect(start[key] != nil, "UploadCreate has no '\(key)'")
        }
        let out = try schema("UploadOut")
        let required = try #require(out["required"] as? [String])
        #expect(Set(required) == ["upload_uid", "chunk_size", "bytes_received"])

        // The two the generated client cannot drive, which is why this package exists at all.
        let paths = try #require(document["paths"] as? [String: Any])
        let session = try #require(paths["/api/uploads/{upload_uid}"] as? [String: Any])
        #expect(session["patch"] != nil)
        #expect(session["head"] != nil)
    }

    @Test(
        "the visibility strings the outbox passes through are the declared ones", .tags(.contract))
    func visibilityValues() throws {
        let values = try #require(try schema("Visibility")["enum"] as? [String])
        #expect(Set(values) == ["PRIVATE", "PROTECTED", "PUBLIC"])
    }
}
