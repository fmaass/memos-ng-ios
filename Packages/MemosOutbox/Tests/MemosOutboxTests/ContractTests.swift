import Foundation
import MemosOutbox
import Testing

/// A test bundle built by Xcode has no `Bundle.module`, and Swift Testing has no `XCTestCase` for
/// `Bundle(for:)`, so this token supplies one.
private final class BundleToken {}

/// What the hand-rolled transport is held to.
///
/// A hand-rolled wire type is allowed only where the generated type is unreachable from the layer
/// that needs it — because generation is impossible, or because the layer's dependency rule forbids
/// importing the generated client — and only behind this test. So the vendored document is read
/// here and every operation semantic the hand-written transport consumes is pinned against it: the
/// response headers it reads, the exact required set of every body it sends, the declared type of
/// every field it sends or decodes, and the statuses and refusal codes it branches on. The outbox
/// has no retry limit, so drift nothing catches does not fail — it queues captures forever.
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

    /// The `$ref`ed schema names of a response, so a response is checked by its shape and not by
    /// the sentence describing it. One status may declare ALTERNATIVES (`anyOf`) — the memo patch
    /// answers 409 with either refusal — so this reports every name the status can carry.
    private func responseSchemas(
        _ operation: [String: Any],
        status: String
    ) throws -> Set<String> {
        let responses = try #require(operation["responses"] as? [String: Any])
        let response = try #require(responses[status] as? [String: Any])
        let content = try #require(response["content"] as? [String: Any])
        let json = try #require(content["application/json"] as? [String: Any])
        let schema = try #require(json["schema"] as? [String: Any])
        if let ref = schema["$ref"] as? String { return [Self.name(of: ref)] }
        let alternatives = try #require(schema["anyOf"] as? [[String: Any]])
        return Set(
            try alternatives.map { Self.name(of: try #require($0["$ref"] as? String)) }
        )
    }

    /// The one name a response carries, for a status that declares no alternatives.
    private func responseSchema(_ operation: [String: Any], status: String) throws -> String {
        let names = try responseSchemas(operation, status: status)
        #expect(names.count == 1, "\(status) declares alternatives: \(names.sorted())")
        return names.first ?? ""
    }

    private static func name(of ref: String) -> String {
        String(ref.split(separator: "/").last ?? "")
    }

    private func property(_ name: String, _ key: String) throws -> [String: Any] {
        try #require(try properties(name)[key] as? [String: Any])
    }

    private func requiredKeys(_ name: String) throws -> Set<String> {
        Set(try #require(try schema(name)["required"] as? [String]))
    }

    /// `type` is one string, or a list of them for a nullable field — read as a set either way.
    private func declaredTypes(_ node: [String: Any]) throws -> Set<String> {
        if let single = node["type"] as? String { return [single] }
        return Set(try #require(node["type"] as? [String]))
    }

    /// Asserts the declared type of a field one of the mirrored types sends or decodes.
    private func expectType(_ name: String, _ key: String, is expected: Set<String>) throws {
        let actual = try declaredTypes(try property(name, key))
        #expect(actual == expected, "\(name).\(key) is declared \(actual), used as \(expected)")
    }

    private func responseHeader(
        _ operation: [String: Any], status: String, name: String
    ) throws -> [String: Any] {
        let responses = try #require(operation["responses"] as? [String: Any])
        let response = try #require(responses[status] as? [String: Any])
        let headers = try #require(response["headers"] as? [String: Any])
        return try #require(headers[name] as? [String: Any])
    }

    /// The keys a built request actually puts on the wire.
    private func sentKeys(_ request: URLRequest) throws -> Set<String> {
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return Set(json.keys)
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

        // The other direction, which key existence alone cannot see: a field the server newly
        // requires and the outbox never sends fails here, not on every create with the capture
        // already taken and no retry limit to stop it being tried again.
        let mandatory = try requiredKeys("MemoCreate")
        #expect(
            mandatory.isSubset(of: Set(sent.keys)),
            "required but never sent: \(mandatory.subtracting(Set(sent.keys)))")

        // With a visibility chosen, the key it travels under is pinned too — under a renamed one
        // the server would quietly store the account default instead of what was asked for.
        var chosen = job
        chosen.visibility = "PRIVATE"
        let withVisibility = try sentKeys(
            try OutboxRequests.createMemo(baseURL: Fixture.server, token: "pat-token", job: chosen))
        #expect(withVisibility == Set(sent.keys).union(["visibility"]))
        #expect(withVisibility.isSubset(of: Set(declared.keys)))
    }

    @Test("every key the outbox sends on a memo edit exists in MemoPatch", .tags(.contract))
    func memoPatchKeys() throws {
        var job = Fixture.job(files: [Fixture.file(uploadUID: "u1")])
        job.visibility = "PRIVATE"
        job.resolvedMemoUID = "m1"
        job.editKey = UUID().uuidString
        job.files[0].attachmentUID = "att-u1"
        job.pendingEdit = PendingEdit(
            content: "the pier, the day after",
            visibility: "PUBLIC",
            capturedAt: Date(timeIntervalSince1970: 1_751_111_111),
            fileIDs: job.files.map(\.id)
        )
        let request = try OutboxRequests.patchMemo(
            baseURL: Fixture.server, token: "pat-token", job: job
        )
        let sent = try sentKeys(request)
        let declared = try properties("MemoPatch")
        for key in sent {
            #expect(declared[key] != nil, "MemoPatch has no '\(key)'")
        }

        // The four fields a compose screen lets a create change, plus the key the server answers a
        // second transmission from: an edit missing any of them is a silent loss of what the
        // person changed, and one missing the key is a second edit rather than a replay.
        #expect(sent.isSuperset(of: ["content", "created_at", "visibility", "edit_key"]))
        #expect(sent.contains("attachment_uids"))

        // The other direction, which key existence alone cannot see: a field the server newly
        // requires and the outbox never sends fails here rather than on every restored draft.
        // Read leniently, unlike the create's: `MemoPatch` declares no `required` at all today —
        // every field is optional, which is what makes a partial edit legal — and the day one
        // appears this is what fails.
        let mandatory = Set(try schema("MemoPatch")["required"] as? [String] ?? [])
        #expect(
            mandatory.isSubset(of: sent),
            "required but never sent: \(mandatory.subtracting(sent))")

        // An edit that chose nothing of its own still travels under the visibility the capture was
        // made with: an omitted key means "leave it", which is how an edit loses what it changed.
        var inherited = job
        inherited.pendingEdit?.visibility = nil
        let request2 = try OutboxRequests.patchMemo(
            baseURL: Fixture.server, token: "pat-token", job: inherited)
        #expect(try sentKeys(request2).contains("visibility"))
        let sentBody = try #require(request2.httpBody)
        let body = try #require(
            try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(body["visibility"] as? String == "PRIVATE")
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
        // The patch also answers 409 with `EditKeyConflictError` (MEMNG-124), which the outbox
        // never sends an edit key for — what it needs is that the refusal it DOES act on is still
        // one of the shapes the status can carry.
        for (path, method) in [("/api/memos", "post"), ("/api/memos/{uid}", "patch")] {
            #expect(
                try responseSchemas(try operation(path, method), status: "409")
                    .contains("UploadsUnlinkableError"),
                "\(method.uppercased()) \(path)"
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

        // The two calls the generated client does not drive; their full shape is pinned below.
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

    @Test(
        "Upload-Offset is declared where the outbox reads the server's own byte count",
        .tags(.contract))
    func offsetHeaderDeclared() throws {
        // `resync` resumes from this header and from nothing else, on the HEAD it asks for it with
        // and on the PATCH answer it also reads. Renamed, every resumed upload would stall on a
        // count it cannot find — quietly, and forever, because there is no retry limit.
        for method in ["head", "patch"] {
            let header = try responseHeader(
                try operation("/api/uploads/{upload_uid}", method),
                status: "200",
                name: OutboxRequests.offsetHeader
            )
            let schema = try #require(header["schema"] as? [String: Any])
            // Parsed with `Int64(_:)`: anything but an integer fails that parse and stalls resume.
            let types = try declaredTypes(schema)
            #expect(types == ["integer"], "\(method) declares Upload-Offset as \(types)")
        }
    }

    @Test(
        "the chunk PATCH declares the raw body and the offset header the outbox sends",
        .tags(.contract))
    func chunkRequestDeclared() throws {
        let patch = try operation("/api/uploads/{upload_uid}", "patch")
        let body = try #require(patch["requestBody"] as? [String: Any])
        #expect(body["required"] as? Bool == true)

        // The transport sets exactly this Content-Type and hands the chunk to the background
        // session as a file, so the body is raw bytes and never a modelled JSON shape.
        let content = try #require(body["content"] as? [String: Any])
        let octets = try #require(content["application/octet-stream"] as? [String: Any])
        let schema = try #require(octets["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "string")
        #expect(schema["format"] as? String == "binary")

        // The offset the chunk starts at travels as a request header, not in the body.
        let parameters = try #require(patch["parameters"] as? [[String: Any]])
        let offset = try #require(
            parameters.first { $0["name"] as? String == OutboxRequests.offsetHeader })
        #expect(offset["in"] as? String == "header")
        let offsetSchema = try #require(offset["schema"] as? [String: Any])
        #expect(offsetSchema["type"] as? String == "integer")
    }

    @Test(
        "starting an upload sends exactly what UploadCreate declares, in both directions",
        .tags(.contract))
    func uploadStartRequiredSet() throws {
        let declared = Set(try properties("UploadCreate").keys)
        let mandatory = try requiredKeys("UploadCreate")

        // Built with the optional field absent, because it is what the outbox ALWAYS sends that
        // has to cover what the server requires.
        let bare = try OutboxRequests.startUpload(
            baseURL: Fixture.server, token: "pat-token", file: Fixture.file())
        let always = try sentKeys(bare)
        #expect(
            always.isSubset(of: declared), "UploadCreate has no \(always.subtracting(declared))")
        #expect(
            mandatory.isSubset(of: always),
            "required but never sent: \(mandatory.subtracting(always))")

        // ...and again with it, so the optional key is checked against the document under the name
        // it is actually sent under.
        let dated = try OutboxRequests.startUpload(
            baseURL: Fixture.server,
            token: "pat-token",
            file: OutboxFile(
                relativePath: "file.bin",
                filename: "IMG_0001.HEIC",
                mime: "image/heic",
                byteSize: 1024,
                lastModified: Date(timeIntervalSince1970: 1_750_000_000)
            )
        )
        let full = try sentKeys(dated)
        #expect(full == always.union(["last_modified"]))
        #expect(full.isSubset(of: declared))
    }

    @Test(
        "every field the mirrors send or decode is declared as the type they use", .tags(.contract))
    func mirroredFieldTypes() throws {
        // What starting an upload sends. `last_modified` is epoch MILLISECONDS as an Int64; a
        // string here would be a 422 on a capture that is already on disk.
        try expectType("UploadCreate", "filename", is: ["string"])
        try expectType("UploadCreate", "mime", is: ["string"])
        try expectType("UploadCreate", "size", is: ["integer"])
        try expectType("UploadCreate", "last_modified", is: ["integer", "null"])

        // What every upload call answers with, decoded into `OutboxWire.UploadSession`.
        try expectType("UploadOut", "upload_uid", is: ["string"])
        try expectType("UploadOut", "chunk_size", is: ["integer"])
        try expectType("UploadOut", "bytes_received", is: ["integer"])

        // What creating the memo sends. `created_at` is written as an ISO-8601 string.
        try expectType("MemoCreate", "content", is: ["string"])
        try expectType("MemoCreate", "created_at", is: ["string", "null"])
        #expect(try property("MemoCreate", "created_at")["format"] as? String == "date-time")
        try expectType("MemoCreate", "idempotency_key", is: ["string", "null"])
        let uids = try property("MemoCreate", "upload_uids")
        #expect(try declaredTypes(uids) == ["array"])
        #expect((uids["items"] as? [String: Any])?["type"] as? String == "string")

        // The one field of the create response that is read — and the only proof, anywhere in this
        // package, that a memo was stored and the originals may be deleted.
        let created = try requiredKeys("MemoOut")
        #expect(created.contains("uid"))
        try expectType("MemoOut", "uid", is: ["string"])

        // The refusal's two lists, decoded as `[String]` and acted on per file.
        for key in ["missing_upload_uids", "incomplete_upload_uids"] {
            let node = try property("UploadsUnlinkableDetail", key)
            let types = try declaredTypes(node)
            #expect(types == ["array"], "\(key) is declared \(types)")
            #expect((node["items"] as? [String: Any])?["type"] as? String == "string")
        }
    }

    @Test("the responses the transport branches on are the declared ones", .tags(.contract))
    func branchedResponses() throws {
        // Both calls that hand back a session decode the SAME schema: the start and every chunk.
        let started = try responseSchema(try operation("/api/uploads", "post"), status: "201")
        #expect(started == "UploadOut")
        let chunked = try responseSchema(
            try operation("/api/uploads/{upload_uid}", "patch"), status: "200")
        #expect(chunked == "UploadOut")
        let memo = try responseSchema(try operation("/api/memos", "post"), status: "201")
        #expect(memo == "MemoOut")

        // An offset gap. The outbox does not resend blind on this: it re-syncs with the HEAD and
        // carries on from the server's count, so the branch needs the status to stay declared.
        let patch = try operation("/api/uploads/{upload_uid}", "patch")
        let responses = try #require(patch["responses"] as? [String: Any])
        #expect(responses["409"] != nil, "the chunk PATCH no longer declares an offset gap")
    }

    @Test("the calls that carry a bearer token are the ones that declare it", .tags(.contract))
    func bearerAuthDeclared() throws {
        let components = try #require(document["components"] as? [String: Any])
        let schemes = try #require(components["securitySchemes"] as? [String: Any])
        let bearer = try #require(schemes["bearerAuth"] as? [String: Any])
        #expect(bearer["type"] as? String == "http")
        #expect(bearer["scheme"] as? String == "bearer")

        // Every request the outbox makes but one attaches `Authorization: Bearer <pat>`.
        for (path, method) in [
            ("/api/uploads", "post"),
            ("/api/uploads/{upload_uid}", "patch"),
            ("/api/uploads/{upload_uid}", "head"),
            ("/api/memos", "post"),
        ] {
            let security = try #require(try operation(path, method)["security"] as? [[String: Any]])
            #expect(
                security.contains { $0["bearerAuth"] != nil },
                "\(method) \(path) declares no bearer auth")
        }

        // The health probe is the one request that deliberately carries no token, asked before a
        // video is put on the wire — and the document agrees it needs none.
        let probe = try operation("/health", "get")
        #expect(probe["security"] == nil)
        let url = try #require(OutboxRequests.health(baseURL: Fixture.server).url)
        #expect(url.path() == "/health")
    }
}
