import Foundation
import MemosOutbox
import Testing
@Suite("Wire encoding")
struct WireTests {
    let capture = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("created_at is ISO-8601 in UTC")
    func iso8601() {
        #expect(OutboxEncoding.iso8601(capture) == "2025-06-15T15:06:40Z")
        #expect(OutboxEncoding.iso8601(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }

    @Test("last_modified is epoch MILLISECONDS, as the server's field documents")
    func epochMilliseconds() {
        #expect(OutboxEncoding.epochMilliseconds(capture) == 1_750_000_000_000)
        #expect(
            OutboxEncoding.epochMilliseconds(Date(timeIntervalSince1970: 1_724_500_000.25))
                == 1_724_500_000_250
        )
    }

    @Test("starting an upload sends the four fields the server declares")
    func startUpload() throws {
        var file = Fixture.file(byteSize: 42)
        file.lastModified = capture
        let request = try OutboxRequests.startUpload(
            baseURL: Fixture.server, token: "pat-token", file: file
        )
        #expect(request.url?.absoluteString == "https://memos.example.invalid/api/uploads")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pat-token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["filename"] as? String == "IMG_0001.HEIC")
        #expect(json["mime"] as? String == "image/heic")
        #expect(json["size"] as? Int == 42)
        #expect(json["last_modified"] as? Int == 1_750_000_000_000)
    }

    @Test("a chunk PATCH carries the offset in the header and no body")
    func chunkRequest() {
        let request = OutboxRequests.chunk(
            baseURL: Fixture.server, token: "pat-token", uploadUID: "u1", offset: 5_242_880
        )
        #expect(request.httpMethod == "PATCH")
        #expect(
            request.url?.absoluteString == "https://memos.example.invalid/api/uploads/u1"
        )
        #expect(request.value(forHTTPHeaderField: "Upload-Offset") == "5242880")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        // The bytes are a FILE handed to the background session, never an in-memory body.
        #expect(request.httpBody == nil)
    }

    @Test("the offset HEAD asks the server what it holds")
    func offsetRequest() {
        let request = OutboxRequests.offset(
            baseURL: Fixture.server, token: "pat-token", uploadUID: "u1"
        )
        #expect(request.httpMethod == "HEAD")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer pat-token")
    }

    @Test("the health probe is unauthenticated and short-fused")
    func healthRequest() {
        let request = OutboxRequests.health(baseURL: Fixture.server)
        #expect(request.url?.absoluteString == "https://memos.example.invalid/health")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 5)
    }

    @Test("a credential never prints its token")
    func credentialsAreNotPrintable() {
        let credentials = Fixture.credentials(token: "super-secret-token")
        #expect(!"\(credentials)".contains("super-secret-token"))
        #expect(!String(reflecting: credentials).contains("super-secret-token"))
    }
}
