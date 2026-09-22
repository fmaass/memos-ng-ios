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

    /// The edit owed to the memo an uncertain create resolved to.
    ///
    /// Every byte of it is built from the MANIFEST and nothing else, so the same job builds the
    /// same request in a process that has never seen the first one — which is what makes a
    /// relaunch's second transmission a replay the server answers from the key rather than a
    /// second edit. What the job cannot name, it refuses to send: a picture list assembled from
    /// half a mapping would silently drop a picture from the memo.
    public static func patchMemo(
        baseURL: URL,
        token: String,
        job: UploadJob
    ) throws -> URLRequest {
        guard let uid = job.resolvedMemoUID, let editKey = job.editKey,
            let edit = job.pendingEdit
        else { throw Failure.incompleteEdit }
        let staged = Set(job.files.filter { $0.stagedForEdit == true }.map(\.id))
        let originals = job.files.filter { $0.stagedForEdit != true }
        let resolved = job.resolvedAttachmentUIDs ?? []
        // Positional, and refused unless the two counts agree: the answer lists the memo's
        // attachments in the order the create sent its uploads, so the nth original is the nth
        // attachment — and a count that does not match means that correspondence is broken, which
        // is a request that must not be guessed at.
        guard originals.count == resolved.count else { throw Failure.incompleteEdit }
        var attachmentByFile: [UUID: String] = [:]
        for (index, file) in originals.enumerated() { attachmentByFile[file.id] = resolved[index] }
        let attachmentUIDs = try edit.fileIDs.map { id -> String in
            if staged.contains(id) {
                guard let uid = job.file(id)?.uploadUID else { throw Failure.incompleteEdit }
                return uid
            }
            guard let uid = attachmentByFile[id] else { throw Failure.incompleteEdit }
            return uid
        }
        var request = URLRequest(url: baseURL.appending(path: "api/memos").appending(path: uid))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try OutboxWire.encode(
            OutboxWire.MemoPatch(
                content: edit.content,
                visibility: edit.visibility,
                createdAt: OutboxEncoding.iso8601(edit.capturedAt),
                editKey: editKey,
                uploadUIDs: edit.fileIDs.compactMap {
                    staged.contains($0) ? job.file($0)?.uploadUID : nil
                },
                attachmentUIDs: attachmentUIDs
            )
        )
        return request
    }

    /// A request this device cannot build from what it holds.
    public enum Failure: Error, Sendable, Equatable {
        /// The job is not carrying everything an edit names — the memo it resolved to, the key it
        /// is applied under, or a picture list that maps. Nothing is sent on a guess.
        case incompleteEdit
    }

    /// The header the offset HEAD answers with, read case-insensitively because header names are.
    public static let offsetHeader = "Upload-Offset"

    static func uploadURL(baseURL: URL, uploadUID: String) -> URL {
        baseURL.appending(path: "api/uploads").appending(path: uploadUID)
    }
}
