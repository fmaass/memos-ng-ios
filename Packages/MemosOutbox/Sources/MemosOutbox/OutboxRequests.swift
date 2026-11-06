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

    /// The upload create. A guest create also carries the original's SHA-256 (`sha256`), which is
    /// what lets the door answer "already received" instead of opening a session for bytes the
    /// pass already holds; the member body is exactly what it always was.
    public static func startUpload(
        baseURL: URL,
        token: String,
        file: OutboxFile,
        kind: CredentialKind = .member,
        sha256: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: uploadsURL(baseURL: baseURL, kind: kind))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if kind == .guest {
            request.httpBody = try GuestWire.encode(
                GuestWire.UploadStart(
                    filename: file.filename,
                    mime: file.mime,
                    size: file.byteSize,
                    lastModified: file.lastModified.map(OutboxEncoding.epochMilliseconds),
                    sha256: sha256
                )
            )
            return request
        }
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

    /// The batch upload create (`POST /api/uploads/batch`): one request opening a session per
    /// file, each entry exactly the body `startUpload` sends for that file alone. Member only — the
    /// guest door has no batch, and its create carries a digest this body does not.
    public static func startUploadBatch(
        baseURL: URL,
        token: String,
        files: [OutboxFile]
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/uploads/batch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try OutboxWire.encode(
            OutboxWire.UploadBatchStart(
                entries: files.map { file in
                    OutboxWire.UploadStart(
                        filename: file.filename,
                        mime: file.mime,
                        size: file.byteSize,
                        lastModified: file.lastModified.map(OutboxEncoding.epochMilliseconds)
                    )
                }
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
        offset: Int64,
        kind: CredentialKind = .member
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL(baseURL: baseURL, uploadUID: uploadUID, kind: kind))
        request.httpMethod = "PATCH"
        // The guest door declares its append body as `application/offset+octet-stream` (its own
        // web client's type); the member server declares plain octets. Each gets its own document's.
        request.setValue(
            kind == .guest ? "application/offset+octet-stream" : "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        return request
    }

    /// The whole-file PATCH: one request carrying every byte from `offset` to the end — the entire
    /// original at 0, or the rest of a resumed one at the offset its HEAD reported — which the
    /// contract allows ("any length from 1 byte to the bytes remaining"). Like the chunk, its body
    /// is a file handed to the background session, never set here.
    ///
    /// The networks it may use travel on the REQUEST, not the session: the session's configuration
    /// is fixed for the life of the process, while the person's choice is not, and the request is
    /// what the system keeps with the task — so the choice a task was sent under can be read back
    /// after a relaunch and the task replaced when it no longer matches.
    public static func wholeUpload(
        baseURL: URL,
        token: String,
        uploadUID: String,
        allowsMobileData: Bool,
        offset: Int64 = 0
    ) -> URLRequest {
        var request = chunk(baseURL: baseURL, token: token, uploadUID: uploadUID, offset: offset)
        let access = WholeTaskNetworkAccess.policy(allowsMobileData: allowsMobileData)
        request.allowsCellularAccess = access.allowsCellular
        request.allowsExpensiveNetworkAccess = access.allowsExpensive
        request.allowsConstrainedNetworkAccess = access.allowsConstrained
        return request
    }

    /// The offset HEAD: the server's own count of what it holds, which is the only number the
    /// outbox resumes from.
    public static func offset(
        baseURL: URL, token: String, uploadUID: String, kind: CredentialKind = .member
    ) -> URLRequest {
        var request = URLRequest(url: uploadURL(baseURL: baseURL, uploadUID: uploadUID, kind: kind))
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public static func createMemo(
        baseURL: URL,
        token: String,
        job: UploadJob
    ) throws -> URLRequest {
        // An edit job names a memo that already exists; posted, its files would be a second memo.
        guard job.memoEdit == nil else { throw Failure.editIsNotACreate }
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
        if let memoEdit = job.memoEdit {
            return try patchExistingMemo(
                baseURL: baseURL, token: token, job: job, uid: uid, editKey: editKey, edit: edit,
                memoEdit: memoEdit
            )
        }
        let staged = Set(job.files.filter { $0.stagedForEdit == true }.map(\.id))
        // A kept picture may be named only by the attachment uid the create's answer was matched
        // to; a picture picked in the editor is named by its upload uid, which the memo has not
        // seen yet and which the job must therefore be holding. The list travels whole or not at
        // all: an omitted key leaves the memo's pictures as they are, while a list missing one
        // entry DELETES that picture, so an original that could not be named takes the whole list
        // out of the request ENTIRELY, as `incompleteEdit`: the job holds, whole, and nothing
        // partial is ever sent. A retained original the create's answer did not name is made
        // nameable before the edit is claimed, so this is the net under that recovery, not a path
        // the ordinary sequence takes.
        let attachmentUIDs = try edit.fileIDs.map { id -> String in
            if staged.contains(id) {
                guard let uid = job.file(id)?.uploadUID else { throw Failure.incompleteEdit }
                return uid
            }
            guard let uid = job.file(id)?.attachmentUID else { throw Failure.incompleteEdit }
            return uid
        }
        var request = URLRequest(url: baseURL.appending(path: "api/memos").appending(path: uid))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try OutboxWire.encode(
            OutboxWire.MemoPatch(
                content: edit.content,
                // Visibility travels on EVERY edit that has one to send. The server reads an
                // omitted key as "leave it", so an edit that meant PRIVATE and said nothing would
                // leave the memo public; the contract declares no null for this field, so a value
                // is what goes. Both nil is the one honest omission: the create sent no visibility
                // either, so the memo already carries the account's own answer.
                visibility: edit.visibility ?? job.visibility,
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

    /// The PATCH an edit job sends to a memo that already existed (MEMNG-954): the edit's words,
    /// its audience and date only where it states them, every added file's upload uid, and the
    /// picture list only where the sheet stated one — kept pictures by attachment uid, added ones by
    /// upload uid. Built from the manifest alone, like the owed edit above, so a relaunch's second
    /// transmission is the same request under the same key and the server answers it as a replay.
    static func patchExistingMemo(
        baseURL: URL, token: String, job: UploadJob, uid: String, editKey: String,
        edit: PendingEdit, memoEdit: MemoEdit
    ) throws -> URLRequest {
        let added = try edit.fileIDs.map { id -> String in
            guard let upload = job.file(id)?.uploadUID else { throw Failure.incompleteEdit }
            return upload
        }
        let listed = try memoEdit.pictures?.map { picture -> String in
            switch picture {
            case .kept(let attachment):
                return attachment
            case .added(let id):
                guard let upload = job.file(id)?.uploadUID else { throw Failure.incompleteEdit }
                return upload
            }
        }
        var request = URLRequest(url: baseURL.appending(path: "api/memos").appending(path: uid))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try OutboxWire.encode(
            OutboxWire.MemoPatch(
                content: edit.content,
                // Nil leaves the audience: the job never carries a create's visibility to fall
                // back on, so an untouched pill says nothing to the server.
                visibility: edit.visibility,
                createdAt: memoEdit.statesDate ? OutboxEncoding.iso8601(edit.capturedAt) : nil,
                editKey: editKey,
                uploadUIDs: added,
                attachmentUIDs: listed
            )
        )
        return request
    }

    /// A request this device cannot build from what it holds.
    public enum Failure: Error, Sendable, Equatable {
        /// The job is not carrying everything an edit names — the memo it resolved to, the key it
        /// is applied under, or the upload session of a picture the editor added. Nothing is sent
        /// on a guess.
        case incompleteEdit
        /// The job is an edit of a memo already posted (MEMNG-954): it is never sent as a create.
        case editIsNotACreate
    }

    /// The header the offset HEAD answers with, read case-insensitively because header names are.
    public static let offsetHeader = "Upload-Offset"

    /// The guest door's guest-scoped completion: the received uploads become one batch, under the
    /// caption when there is one. The door derives its idempotency from the device and the uid
    /// list, so the same list sent again answers the batch the first one made.
    public static func guestComplete(
        baseURL: URL, token: String, uploadUIDs: [String], caption: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "api/guest/memos"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try GuestWire.encode(
            GuestWire.Complete(uploadUIDs: uploadUIDs, caption: caption)
        )
        return request
    }

    /// Where uploads live for this credential: the member server's `api/uploads`, or the guest
    /// door's `api/guest/uploads`. Written once, so no request can pair one kind's token with the
    /// other kind's route.
    static func uploadsURL(baseURL: URL, kind: CredentialKind) -> URL {
        switch kind {
        case .member: baseURL.appending(path: "api/uploads")
        case .guest: baseURL.appending(path: "api/guest/uploads")
        }
    }

    static func uploadURL(baseURL: URL, uploadUID: String, kind: CredentialKind = .member) -> URL {
        uploadsURL(baseURL: baseURL, kind: kind).appending(path: uploadUID)
    }
}
