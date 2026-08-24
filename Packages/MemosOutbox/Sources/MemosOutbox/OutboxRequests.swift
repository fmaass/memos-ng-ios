import Foundation

/// Every request the outbox makes, built in one place and testable without a server.
///
/// The bearer token is attached here and nowhere else, and the health probe is the one request
/// that deliberately carries none — it is the cheap "am I on the network that can reach the
/// server" question, asked before a video is put on the wire.
public enum OutboxRequests {
    /// Unauthenticated, short-fused reachability check. On a foreign wifi this is what a drain
    /// costs: one small request that fails fast, instead of a large upload that hangs.
    public static func health(baseURL: URL, timeout: TimeInterval = 5) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    public static func startUpload(
        baseURL: URL,
        token: String,
        file: OutboxFile
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/uploads"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try OutboxWire.encode(
            OutboxWire.UploadStart(
                filename: file.filename,
                mime: file.mime,
                size: file.byteSize,
                lastModified: file.lastModified.map(OutboxEncoding.epochMilliseconds)
            )
        )
        return request
    }

    /// The chunk PATCH. The body is NOT set here: it is a file, handed to the background session
    /// as an upload task, so that a chunk in flight survives the app being suspended.
    public static func chunk(
        baseURL: URL,
        token: String,
        uploadUID: String,
        offset: Int64
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL(baseURL: baseURL, uploadUID: uploadUID))
        request.httpMethod = "PATCH"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        return request
    }

    /// The offset HEAD: the server's own count of what it holds, which is the only number the
    /// outbox resumes from.
    public static func offset(baseURL: URL, token: String, uploadUID: String) -> URLRequest {
        var request = URLRequest(url: uploadURL(baseURL: baseURL, uploadUID: uploadUID))
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func createMemo(
        baseURL: URL,
        token: String,
        job: UploadJob
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/memos"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try OutboxWire.encode(
            OutboxWire.MemoCreate(
                content: job.content,
                visibility: job.visibility,
                createdAt: OutboxEncoding.iso8601(job.capturedAt),
                uploadUIDs: job.uploadUIDs,
                idempotencyKey: job.idempotencyKey.uuidString
            )
        )
        return request
    }

    /// The header the offset HEAD answers with, read case-insensitively because header names are.
    public static let offsetHeader = "Upload-Offset"

    static func uploadURL(baseURL: URL, uploadUID: String) -> URL {
        baseURL.appending(path: "api/uploads").appending(path: uploadUID)
    }
}
