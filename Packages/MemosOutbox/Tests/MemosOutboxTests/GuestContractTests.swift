import Foundation
import Testing

@testable import MemosOutbox

/// A test bundle built by Xcode has no `Bundle.module`, and Swift Testing has no `XCTestCase` for
/// `Bundle(for:)`, so this token supplies one.
private final class GuestBundleToken {}

/// What the guest lane's hand-rolled wire is held to: the guest door's own document,
/// `openapi-guest.json`, vendored verbatim from the same memos-ng commit as `openapi.json`.
///
/// `GuestWire` carries `OutboxWire`'s licence (the package's dependency rule makes the generated
/// client unreachable from here), and that licence holds only behind a test that pins every
/// semantic the mirrors consume. So every mirrored field is checked by what the MIRROR does with
/// it, never by a key spelled again in this file: a body is encoded and its keys looked up in the
/// schema, and an answer is synthesised from the schema itself and decoded, each consumed field
/// read back. A coding key that drifts from the document, or a document that renames a field the
/// mirror reads, fails here instead of on a guest's phone mid-trip.
@Suite("The vendored guest contract")
struct GuestContractTests {
    private let document: [String: Any]

    init() throws {
        let bundle = Bundle(for: GuestBundleToken.self)
        let url = try #require(bundle.url(forResource: "openapi-guest", withExtension: "json"))
        let data = try Data(contentsOf: url)
        document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Reading the document

    private func schema(_ name: String) throws -> [String: Any] {
        let components = try #require(document["components"] as? [String: Any])
        let schemas = try #require(components["schemas"] as? [String: Any])
        return try #require(schemas[name] as? [String: Any], "no schema \(name)")
    }

    private func properties(_ name: String) throws -> [String: Any] {
        try #require(try schema(name)["properties"] as? [String: Any])
    }

    private func requiredKeys(_ name: String) throws -> Set<String> {
        Set(try schema(name)["required"] as? [String] ?? [])
    }

    private func operation(_ path: String, _ method: String) throws -> [String: Any] {
        let paths = try #require(document["paths"] as? [String: Any])
        let item = try #require(paths[path] as? [String: Any], "no path \(path)")
        return try #require(item[method] as? [String: Any], "no \(method) on \(path)")
    }

    private func response(_ operation: [String: Any], _ status: String) throws -> [String: Any] {
        let responses = try #require(operation["responses"] as? [String: Any])
        return try #require(responses[status] as? [String: Any], "no \(status) declared")
    }

    private func statuses(_ operation: [String: Any]) throws -> Set<String> {
        Set(try #require(operation["responses"] as? [String: Any]).keys)
    }

    private func hasBody(_ operation: [String: Any], _ status: String) -> Bool {
        let content = (try? response(operation, status))?["content"] as? [String: Any]
        return !(content ?? [:]).isEmpty
    }

    /// The JSON schema node a status answers with.
    private func answer(_ operation: [String: Any], _ status: String) throws -> [String: Any] {
        let content = try #require(try response(operation, status)["content"] as? [String: Any])
        let json = try #require(content["application/json"] as? [String: Any])
        return try #require(json["schema"] as? [String: Any])
    }

    /// The schema name a status answers with (`$ref`), or nil for an inline schema.
    private func answerName(_ operation: [String: Any], _ status: String) throws -> String? {
        (try answer(operation, status)["$ref"] as? String).map(Self.name(of:))
    }

    private static func name(of ref: String) -> String {
        String(ref.split(separator: "/").last ?? "")
    }

    /// `type` is one string, or a list of them for a nullable field — read as a set either way.
    private func declaredTypes(_ node: [String: Any]) throws -> Set<String> {
        if let single = node["type"] as? String { return [single] }
        return Set(try #require(node["type"] as? [String], "no type in \(node)"))
    }

    private func expectType(_ name: String, _ key: String, is expected: Set<String>) throws {
        let node = try #require(try properties(name)[key] as? [String: Any], "\(name).\(key)")
        let actual = try declaredTypes(node)
        #expect(actual == expected, "\(name).\(key) is declared \(actual), used as \(expected)")
    }

    private func responseHeaderTypes(
        _ operation: [String: Any], _ status: String, _ header: String
    ) throws -> Set<String> {
        let headers = try #require(
            try response(operation, status)["headers"] as? [String: Any], "\(status) headers")
        let node = try #require(headers[header] as? [String: Any], "\(status) has no \(header)")
        return try declaredTypes(try #require(node["schema"] as? [String: Any]))
    }

    /// The document path whose template a built request's path fills.
    private func template(of url: URL?) throws -> String {
        let path = try #require(url?.path())
        let parts = path.split(separator: "/")
        let paths = try #require(document["paths"] as? [String: Any])
        let matches = paths.keys.filter { candidate in
            let slots = candidate.split(separator: "/")
            return slots.count == parts.count
                && zip(slots, parts).allSatisfy { $0.hasPrefix("{") || $0 == $1 }
        }
        return try #require(matches.count == 1 ? matches.first : nil, "\(path) -> \(matches)")
    }

    /// The keys a built request actually puts on the wire.
    private func sentKeys(_ body: Data?) throws -> [String: Any] {
        let body = try #require(body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// Every key sent is declared, and everything the schema requires is sent.
    private func expectBody(_ sent: [String: Any], fits name: String) throws {
        let declared = try properties(name)
        for key in sent.keys {
            #expect(declared[key] != nil, "\(name) has no '\(key)'")
        }
        let mandatory = try requiredKeys(name)
        #expect(
            mandatory.isSubset(of: Set(sent.keys)),
            "required but never sent: \(mandatory.subtracting(Set(sent.keys)))")
    }

    // MARK: - Answers synthesised from the document

    /// Every date the samples carry, in the server's own spelling.
    private static let instantText = "2026-10-30T09:15:42Z"
    private static var instant: Date {
        ISO8601DateFormatter().date(from: instantText)!
    }

    /// A distinct integer per field name, so a mirror that reads one field into another's slot
    /// cannot pass by coincidence.
    private static func number(for key: String) -> Int {
        key.unicodeScalars.reduce(17) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 } + 1000
    }

    /// A value of the shape `node` declares, every property present and nothing defaulted: booleans
    /// are true (their default is false), integers distinct, strings named after their field.
    private func sample(_ node: [String: Any], key: String = "") throws -> Any {
        if let ref = node["$ref"] as? String {
            return try sample(try schema(Self.name(of: ref)), key: key)
        }
        if let fields = node["properties"] as? [String: Any] {
            var object: [String: Any] = [:]
            for (name, child) in fields {
                object[name] = try sample(try #require(child as? [String: Any]), key: name)
            }
            return object
        }
        let types = try declaredTypes(node)
        if types.contains("array") {
            return [try sample(try #require(node["items"] as? [String: Any]), key: key)]
        }
        if let values = node["enum"] as? [String], let last = values.last { return last }
        if types.contains("boolean") { return true }
        if types.contains("integer") { return Self.number(for: key) }
        if types.contains("string") {
            if node["format"] as? String == "date-time" { return Self.instantText }
            return "\(key)-sample"
        }
        Issue.record("no sample for '\(key)' typed \(types)")
        return NSNull()
    }

    private func sampleObject(_ name: String) throws -> [String: Any] {
        try #require(try sample(try schema(name)) as? [String: Any])
    }

    private static func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    // MARK: - The routes

    private static let redeem = "POST /api/pass/redeem"
    private static let authed: Set<String> = [
        "GET /api/guest/me",
        "POST /api/guest/uploads",
        "HEAD /api/guest/uploads/{upload_uid}",
        "PATCH /api/guest/uploads/{upload_uid}",
        "POST /api/guest/memos",
        "GET /api/guest/batches",
    ]

    private func routes() throws -> [String: [String: Any]] {
        let methods: Set<String> = ["get", "put", "post", "delete", "head", "patch", "options"]
        var found: [String: [String: Any]] = [:]
        for (path, item) in try #require(document["paths"] as? [String: Any]) {
            let operations = try #require(item as? [String: Any])
            for (method, op) in operations where methods.contains(method) {
                found["\(method.uppercased()) \(path)"] = try #require(op as? [String: Any])
            }
        }
        return found
    }

    @Test("the door offers exactly the routes the guest lane mirrors", .tags(.contract))
    func routeSet() throws {
        // A route added upstream arrives as a decision here (mirror it, or say why not), never as
        // an operation nobody noticed was vendored.
        #expect(Set(try routes().keys) == Self.authed.union([Self.redeem]))
    }

    @Test("every authed route answers 401 and 410, and only redeem is open", .tags(.contract))
    func refusalsOnEveryAuthedRoute() throws {
        for (route, op) in try routes() {
            let security = op["security"] as? [[String: Any]] ?? []
            if route == Self.redeem {
                #expect(security.isEmpty, "redeem must take no credential")
                continue
            }
            #expect(!security.isEmpty, "\(route) declares no credential")
            let declared = try statuses(op)
            #expect(declared.isSuperset(of: ["401", "410"]), "\(route) declares \(declared)")
            // A HEAD answer has no body to describe; every other refusal is the door's error.
            for status in ["401", "410"] where declared.contains(status) && hasBody(op, status) {
                #expect(try answerName(op, status) == "GuestError", "\(route) \(status)")
            }
        }
    }

    // MARK: - Redeem and me

    @Test("redeem's body is RedeemIn and its 201 decodes into Redeemed", .tags(.contract))
    func redeem() throws {
        let op = try operation("/api/pass/redeem", "post")
        let body = try sentKeys(
            try GuestWire.encode(
                GuestWire.Redeem(secret: "s3cret", displayName: "Ana", deviceHint: "iPhone")))
        try expectBody(body, fits: "RedeemIn")
        #expect(body.count == 4, "a mirrored field went unsent: \(body.keys.sorted())")
        let platform = try #require(try properties("RedeemIn")["platform"] as? [String: Any])
        let platforms = try #require(platform["enum"] as? [String])
        #expect(platforms.contains(try #require(body["platform"] as? String)))
        try expectType("RedeemIn", "secret", is: ["string"])
        try expectType("RedeemIn", "display_name", is: ["string"])
        try expectType("RedeemIn", "platform", is: ["string"])
        try expectType("RedeemIn", "device_hint", is: ["string", "null"])

        #expect(try statuses(op).isSuperset(of: ["201", "404", "410", "429"]))
        #expect(try answerName(op, "201") == "RedeemOut")
        for status in ["404", "410", "429"] {
            #expect(try answerName(op, status) == "GuestError")
        }
        #expect(try responseHeaderTypes(op, "429", "Retry-After") == ["integer"])

        #expect(
            try requiredKeys("RedeemOut").isSuperset(
                of: ["device_token", "device_id", "pass", "limits"]))
        try expectType("RedeemOut", "device_token", is: ["string"])
        try expectType("RedeemOut", "device_id", is: ["string"])
        let sample = try sampleObject("RedeemOut")
        let redeemed = try #require(
            GuestWire.decode(GuestWire.Redeemed.self, from: try Self.data(sample)))
        #expect(redeemed.deviceToken == sample["device_token"] as? String)
        #expect(redeemed.deviceID == sample["device_id"] as? String)
        try expectPass(redeemed.pass, sample["pass"])
        try expectLimits(redeemed.limits, sample["limits"])
    }

    @Test("me's 200 decodes into Me", .tags(.contract))
    func me() throws {
        let op = try operation("/api/guest/me", "get")
        #expect(try answerName(op, "200") == "MeOut")
        #expect(try requiredKeys("MeOut").isSuperset(of: ["device_id", "pass", "limits"]))
        try expectType("MeOut", "device_id", is: ["string"])
        let sample = try sampleObject("MeOut")
        let me = try #require(GuestWire.decode(GuestWire.Me.self, from: try Self.data(sample)))
        #expect(me.deviceID == sample["device_id"] as? String)
        try expectPass(me.pass, sample["pass"])
        try expectLimits(me.limits, sample["limits"])
    }

    private func expectPass(_ pass: GuestWire.Pass, _ raw: Any?) throws {
        let sample = try #require(raw as? [String: Any])
        #expect(try requiredKeys("PassOut").isSuperset(of: ["label", "expires_at"]))
        try expectType("PassOut", "label", is: ["string"])
        try expectType("PassOut", "expires_at", is: ["string"])
        let expires = try #require(try properties("PassOut")["expires_at"] as? [String: Any])
        #expect(expires["format"] as? String == "date-time")
        #expect(pass.label == sample["label"] as? String)
        #expect(pass.expiresAt == Self.instant)
    }

    private func expectLimits(_ limits: GuestWire.Limits, _ raw: Any?) throws {
        let sample = try #require(raw as? [String: Any])
        try expectType("GuestLimits", "max_patch_bytes", is: ["integer"])
        #expect(limits.maxPatchBytes == (sample["max_patch_bytes"] as? Int).map(Int64.init))
    }

    // MARK: - Uploads

    @Test("the upload create sends GuestUploadIn and decodes 200 and 201", .tags(.contract))
    func uploadCreate() throws {
        var file = Fixture.file()
        file.lastModified = Date(timeIntervalSince1970: 1_761_800_000)
        let digest = String(repeating: "a1", count: 32)
        let request = try OutboxRequests.startUpload(
            baseURL: GuestDoor.baseURL, token: "trip_dev_x", file: file, kind: .guest,
            sha256: digest)
        #expect(request.httpMethod == "POST")
        let route = try template(of: request.url)
        let op = try operation(route, "post")
        #expect(op["operationId"] as? String == "guestCreateUpload")

        let body = try sentKeys(request.httpBody)
        try expectBody(body, fits: "GuestUploadIn")
        #expect(body.count == 5, "a mirrored field went unsent: \(body.keys.sorted())")
        // The digest is what earns "already received"; under a renamed key the door would open a
        // session for bytes it holds.
        let sent = try #require(body.first(where: { ($0.value as? String) == digest })?.key)
        let sha = try #require(try properties("GuestUploadIn")[sent] as? [String: Any])
        let pattern = try #require(sha["pattern"] as? String)
        #expect(digest.range(of: pattern, options: .regularExpression) != nil)
        try expectType("GuestUploadIn", "filename", is: ["string"])
        try expectType("GuestUploadIn", "mime", is: ["string"])
        try expectType("GuestUploadIn", "size", is: ["integer"])
        try expectType("GuestUploadIn", "last_modified", is: ["integer", "null"])
        try expectType("GuestUploadIn", "sha256", is: ["string", "null"])

        // 200 is "already received or resumed", 201 a new session: the same shape either way.
        #expect(try answerName(op, "200") == "GuestUploadOut")
        #expect(try answerName(op, "201") == "GuestUploadOut")
        for status in ["413", "415", "507"] {
            #expect(try answerName(op, status) == "GuestError")
        }
        try expectUploadAnswer()
    }

    /// Every field of the answer the create and each PATCH share, as both mirrors read it.
    private func expectUploadAnswer() throws {
        try expectType("GuestUploadOut", "already_received", is: ["boolean"])
        try expectType("GuestUploadOut", "upload_uid", is: ["string", "null"])
        try expectType("GuestUploadOut", "bytes_received", is: ["integer"])
        try expectType("GuestUploadOut", "chunk_size", is: ["integer"])
        try expectType("GuestUploadOut", "max_patch_bytes", is: ["integer"])
        let sample = try sampleObject("GuestUploadOut")
        let answer = try #require(
            GuestWire.decode(GuestWire.UploadAnswer.self, from: try Self.data(sample)))
        #expect(answer.alreadyReceived == sample["already_received"] as? Bool)
        #expect(answer.uploadUID == sample["upload_uid"] as? String)
        #expect(answer.bytesReceived == (sample["bytes_received"] as? Int).map(Int64.init))
        #expect(answer.chunkSize == sample["chunk_size"] as? Int)
        #expect(answer.maxPatchBytes == (sample["max_patch_bytes"] as? Int).map(Int64.init))

        // Every field is optional on the wire; what the mirror assumes for an absent one is the
        // document's own default, or a door that omits a field means something else here.
        let fields = try properties("GuestUploadOut")
        func defaultValue(_ key: String) -> Any? { (fields[key] as? [String: Any])?["default"] }
        let empty = try #require(
            GuestWire.decode(GuestWire.UploadAnswer.self, from: Data("{}".utf8)))
        #expect(empty.alreadyReceived == defaultValue("already_received") as? Bool)
        #expect(Int(empty.bytesReceived) == defaultValue("bytes_received") as? Int)
        #expect(empty.chunkSize == defaultValue("chunk_size") as? Int)
        #expect(Int(empty.maxPatchBytes) == defaultValue("max_patch_bytes") as? Int)

        // The PATCH answer is read by the shared session mirror (the chunk lane decodes every
        // append with it), so its three keys are held to this schema too.
        let session = try #require(OutboxWire.decodeSession(try Self.data(sample)))
        #expect(session.uploadUID == sample["upload_uid"] as? String)
        #expect(session.chunkSize == sample["chunk_size"] as? Int)
        #expect(session.bytesReceived == (sample["bytes_received"] as? Int).map(Int64.init))
    }

    @Test("the offset HEAD answers Upload-Offset, and 404 for an unknown upload", .tags(.contract))
    func offsetHead() throws {
        let request = OutboxRequests.offset(
            baseURL: GuestDoor.baseURL, token: "trip_dev_x", uploadUID: "u-1", kind: .guest)
        #expect(request.httpMethod == "HEAD")
        let op = try operation(try template(of: request.url), "head")
        #expect(op["operationId"] as? String == "guestUploadOffset")
        #expect(try responseHeaderTypes(op, "200", OutboxRequests.offsetHeader) == ["integer"])
        #expect(try statuses(op).contains("404"))
    }

    @Test("the append PATCH sends what the door declares and is answered so", .tags(.contract))
    func appendPatch() throws {
        let request = OutboxRequests.chunk(
            baseURL: GuestDoor.baseURL, token: "trip_dev_x", uploadUID: "u-1", offset: 4096,
            kind: .guest)
        #expect(request.httpMethod == "PATCH")
        let op = try operation(try template(of: request.url), "patch")
        #expect(op["operationId"] as? String == "guestAppendUpload")

        let requestBody = try #require(op["requestBody"] as? [String: Any])
        let content = try #require(requestBody["content"] as? [String: Any])
        let sentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(content[sentType] != nil, "sent \(sentType), declared \(content.keys.sorted())")

        // The offset travels as a header parameter the door reads, under the name the request uses.
        let parameters = try #require(op["parameters"] as? [[String: Any]])
        let offset = try #require(
            parameters.first {
                ($0["name"] as? String)?.caseInsensitiveCompare(OutboxRequests.offsetHeader)
                    == .orderedSame
            })
        #expect(offset["in"] as? String == "header")
        #expect(
            try declaredTypes(try #require(offset["schema"] as? [String: Any])) == ["integer"])
        #expect(request.value(forHTTPHeaderField: OutboxRequests.offsetHeader) == "4096")

        #expect(try answerName(op, "200") == "GuestUploadOut")
        #expect(try responseHeaderTypes(op, "200", OutboxRequests.offsetHeader) == ["integer"])
        for status in ["404", "409", "413", "429", "507"] {
            #expect(try answerName(op, status) == "GuestError")
        }
        #expect(try responseHeaderTypes(op, "429", "Retry-After") == ["integer"])
        try expectUploadAnswer()
    }

    // MARK: - Completion and receipts

    @Test("the completion sends CompleteIn and its Receipt names the batch", .tags(.contract))
    func completion() throws {
        let request = try OutboxRequests.guestComplete(
            baseURL: GuestDoor.baseURL, token: "trip_dev_x", uploadUIDs: ["u-1", "u-2"],
            caption: "the pier")
        #expect(request.httpMethod == "POST")
        let op = try operation(try template(of: request.url), "post")
        #expect(op["operationId"] as? String == "guestComplete")
        let body = try sentKeys(request.httpBody)
        try expectBody(body, fits: "CompleteIn")
        #expect(body.count == 2, "a mirrored field went unsent: \(body.keys.sorted())")
        let uids = try #require(try properties("CompleteIn")["upload_uids"] as? [String: Any])
        #expect(try declaredTypes(uids) == ["array"])
        let item = try #require(uids["items"] as? [String: Any])
        #expect(try declaredTypes(item) == ["string"])
        try expectType("CompleteIn", "caption", is: ["string", "null"])

        #expect(try answerName(op, "200") == "Receipt")
        let sample = try sampleObject("Receipt")
        let unused = ScriptedHTTP { _ in OutboxHTTPResponse(statusCode: 500) }
        let endpoint = GuestCompletionEndpoint(http: unused)
        let outcome = endpoint.outcome(
            for: OutboxHTTPResponse(statusCode: 200, body: try Self.data(sample)),
            refusal: OutboxRefusal(statusCode: 200, issuedUnder: 1, what: "x", kind: .guest))
        #expect(outcome == .created(uid: try #require(sample["batch_id"] as? String)))
        try expectReceipt(
            try #require(GuestWire.decode(GuestWire.Receipt.self, from: try Self.data(sample))),
            sample)
    }

    @Test("the batches list is an array of Receipt", .tags(.contract))
    func batches() throws {
        let op = try operation("/api/guest/batches", "get")
        let node = try answer(op, "200")
        #expect(try declaredTypes(node) == ["array"])
        let items = try #require(node["items"] as? [String: Any])
        #expect((items["$ref"] as? String).map(Self.name(of:)) == "Receipt")
        let rows = try #require(try sample(node) as? [[String: Any]])
        let receipts = try #require(
            GuestWire.decode([GuestWire.Receipt].self, from: try Self.data(rows)))
        #expect(receipts.count == rows.count)
        for (receipt, raw) in zip(receipts, rows) {
            try expectReceipt(receipt, raw)
        }
    }

    private func expectReceipt(_ receipt: GuestWire.Receipt, _ sample: [String: Any]) throws {
        let consumed: Set<String> = ["batch_id", "status", "file_count", "files"]
        #expect(try requiredKeys("Receipt").isSuperset(of: consumed))
        try expectType("Receipt", "batch_id", is: ["string"])
        try expectType("Receipt", "status", is: ["string"])
        try expectType("Receipt", "file_count", is: ["integer"])
        try expectType("Receipt", "completed_at", is: ["string", "null"])
        try expectType("Receipt", "files", is: ["array"])
        // The mirror tells the guest "received" from "held"; a third state would be shown as
        // neither.
        let status = try #require(try properties("Receipt")["status"] as? [String: Any])
        #expect(Set(status["enum"] as? [String] ?? []) == ["received", "held"])
        #expect(receipt.batchID == sample["batch_id"] as? String)
        #expect(receipt.status == sample["status"] as? String)
        #expect(receipt.fileCount == sample["file_count"] as? Int)
        #expect(receipt.completedAt == Self.instant)

        #expect(try requiredKeys("ReceiptFile").isSuperset(of: ["filename", "sha256", "size"]))
        try expectType("ReceiptFile", "filename", is: ["string"])
        try expectType("ReceiptFile", "sha256", is: ["string"])
        try expectType("ReceiptFile", "size", is: ["integer"])
        let files = try #require(sample["files"] as? [[String: Any]])
        #expect(receipt.files.count == files.count)
        for (file, raw) in zip(receipt.files, files) {
            #expect(file.filename == raw["filename"] as? String)
            #expect(file.sha256 == raw["sha256"] as? String)
            #expect(file.size == (raw["size"] as? Int).map(Int64.init))
        }
    }
}
