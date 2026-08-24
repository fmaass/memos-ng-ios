import Foundation
import MemosOutbox
import Testing

extension Tag {
    /// Asserts the memo-create wire contract (`idempotency_key` on create, the strict
    /// `409 uploads_unlinkable` refusal). Tagged so every assertion that depends on that contract
    /// can be found and re-checked against the schema the day it merges.
    @Tag static var contract: Self
}

@Suite("Completing a memo")
struct CompletionTests {
    let capture = Date(timeIntervalSince1970: 1_750_000_000)

    private func job(uids: [String]) -> UploadJob {
        var files: [OutboxFile] = []
        for uid in uids {
            files.append(Fixture.file(uploadUID: uid, byteSize: 10, bytesConfirmed: 10))
        }
        return UploadJob(
            content: "on the beach",
            visibility: "PRIVATE",
            capturedAt: capture,
            files: files,
            binding: Fixture.binding()
        )
    }

    @Test(
        "the create carries the capture time, every uid and the job's idempotency key",
        .tags(.contract))
    func requestBody() async throws {
        let job = job(uids: ["u1", "u2"])
        let http = ScriptedHTTP { _ in
            ScriptedHTTP.json(["uid": "m1"], status: 201)
        }
        let outcome = await MemoCompletionEndpoint(http: http).create(
            job: job, credentials: Fixture.credentials()
        )
        #expect(outcome == .created(uid: "m1"))

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://memos.example.invalid/api/memos")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pat-token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["content"] as? String == "on the beach")
        #expect(json["visibility"] as? String == "PRIVATE")
        #expect(json["created_at"] as? String == "2025-06-15T15:06:40Z")
        #expect(json["upload_uids"] as? [String] == ["u1", "u2"])
        #expect(json["idempotency_key"] as? String == job.idempotencyKey.uuidString)
    }

    @Test("a memo with no visibility lets the account's own default apply", .tags(.contract))
    func visibilityIsOmitted() async throws {
        var job = job(uids: [])
        job.visibility = nil
        let http = ScriptedHTTP { _ in ScriptedHTTP.json(["uid": "m1"], status: 201) }
        _ = await MemoCompletionEndpoint(http: http).create(
            job: job, credentials: Fixture.credentials()
        )
        let body = try #require(http.requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["visibility"] == nil)
    }

    @Test("409 uploads_unlinkable is per-file recovery; anything else 4xx is not", .tags(.contract))
    func statusMapping() {
        let endpoint = MemoCompletionEndpoint(http: ScriptedHTTP { _ in .init(statusCode: 500) })
        let unlinkable = Data(
            """
            {"detail":{"code":"uploads_unlinkable","missing_upload_uids":["u1"],\
            "incomplete_upload_uids":["u2"]}}
            """.utf8)

        #expect(
            endpoint.outcome(for: OutboxHTTPResponse(statusCode: 409, body: unlinkable))
                == .unlinkable(
                    UploadsUnlinkableFailure(
                        missingUploadUIDs: ["u1"], incompleteUploadUIDs: ["u2"]
                    )
                )
        )
        // A validation error stays a validation error: it must never start a re-upload.
        let validation = Data(#"{"detail":[{"loc":["body"],"msg":"required"}]}"#.utf8)
        if case .refused = endpoint.outcome(
            for: OutboxHTTPResponse(statusCode: 422, body: validation)
        ) {
        } else {
            Issue.record("a 422 must be refused, not read as upload loss")
        }
        if case .refused = endpoint.outcome(
            for: OutboxHTTPResponse(statusCode: 409, body: Data("{}".utf8))
        ) {
        } else {
            Issue.record("a 409 that is not the structured refusal must be refused")
        }
    }

    @Test("what is worth retrying with the same key, and what is not", .tags(.contract))
    func retryMapping() {
        let endpoint = MemoCompletionEndpoint(http: ScriptedHTTP { _ in .init(statusCode: 500) })
        for status in [500, 502, 503, 429, 408] {
            if case .retry = endpoint.outcome(for: OutboxHTTPResponse(statusCode: status)) {
            } else {
                Issue.record("\(status) should be retried with the same idempotency key")
            }
        }
        for status in [400, 401, 403, 404, 422] {
            if case .refused = endpoint.outcome(for: OutboxHTTPResponse(statusCode: status)) {
            } else {
                Issue.record("\(status) should hold the job rather than loop")
            }
        }
    }

    @Test("a connection that failed is retried, never refused", .tags(.contract))
    func transportFailureIsRetried() async {
        struct Offline: Error {}
        let http = ScriptedHTTP { _ in throw Offline() }
        let outcome = await MemoCompletionEndpoint(http: http).create(
            job: job(uids: []), credentials: Fixture.credentials()
        )
        if case .retry = outcome {
        } else {
            Issue.record("a transport failure must be retried with the same key")
        }
    }
}
