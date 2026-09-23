import Foundation

/// Which server, and whose account, a capture was made under.
///
/// It is persisted with the job because the phone outlives the session: a memo written offline
/// under one account must never be posted later under whoever happens to be signed in when the
/// wifi comes back. The token is deliberately NOT part of this — a credential in a queue file is
/// a credential in a backup.
public struct AccountBinding: Codable, Sendable, Equatable {
    public var serverBaseURL: URL
    public var ownerSubject: String

    public init(serverBaseURL: URL, ownerSubject: String) {
        self.serverBaseURL = serverBaseURL
        self.ownerSubject = ownerSubject
    }

    public func matches(_ credentials: OutboxCredentials) -> Bool {
        serverBaseURL == credentials.serverBaseURL && ownerSubject == credentials.ownerSubject
    }
}

/// Where a queued capture is, as the person would describe it.
public enum JobState: String, Codable, Sendable, Equatable {
    /// Nothing is in flight: either the server has not been reachable yet, or the job is spacing
    /// out a retry.
    case waiting
    /// Bytes are moving, or a chunk is with the background session.
    case uploading
    /// Every byte is on the server; the memo itself is being created.
    case creating
    /// Stopped until a person does something. A held job is never retried on a timer — that is
    /// the difference between a queue and a loop.
    case held
}

/// Why a job stopped needing a person.
public enum HoldReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// Captured under a different account or a different server than the one signed in now.
    case accountMismatch
    /// The server refused in a way that repeating cannot fix.
    case serverRefused
    /// The capture's manifest on disk could not be read. Its originals and the manifest itself are
    /// both KEPT — the manifest set aside rather than deleted — and this is what the outbox says
    /// about it, because a capture that disappears without a word is the one failure this package
    /// exists to prevent.
    case unreadableManifest
    /// A change to this capture could not be written to disk, so as far as anything is concerned
    /// the change did not happen. The capture stops here rather than being carried on from a state
    /// only memory believes in.
    case storageFailed
}

/// Why a waiting job is waiting on an EVENT rather than on the clock.
///
/// A backoff spaces itself out and comes back by itself; this does not. It is nil for every job
/// that is simply between attempts, which is also how a manifest written before this existed
/// decodes — the field is optional so that a queue from an older build is read, never quarantined.
public enum WaitReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The phone is on a network this capture may not use: mobile data with the toggle off, or
    /// Low Data Mode, which waits whatever the toggle says.
    case homeNetwork
}

/// One captured file, and how much of it the SERVER says it has.
///
/// `bytesConfirmed` is only ever written from a server answer (the PATCH response body or the
/// offset HEAD). Local arithmetic about what "should" have arrived is how a resumed upload
/// corrupts a file.
public struct OutboxFile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Path of the copied original, relative to the job's media directory.
    public var relativePath: String
    public var filename: String
    public var mime: String
    public var byteSize: Int64
    /// The original's modification date, sent as the upload session's `last_modified`.
    public var lastModified: Date?
    /// The server's handle for this file's upload session, once one exists.
    public var uploadUID: String?
    public var bytesConfirmed: Int64
    /// The chunk size the server asked for when the session was created.
    public var chunkSize: Int
    /// Which retry of this file the current upload belongs to. Optional and last, so a manifest
    /// written before retries were counted decodes unchanged and reads as nil — which is what an
    /// equally attempt-less task description says, and the two have to agree to be adopted.
    public var uploadAttempt: Int?
    /// The uid the memo's own picture carries, once the create's answer has been matched to this
    /// original. It is the ONLY name an edit may use for a picture the memo already holds — an
    /// upload uid is not one — and it is written once, where that answer is applied. Optional and
    /// last, so a manifest written before this existed decodes unchanged and reads as unnamed,
    /// which is what an edit then treats as "leave the memo's pictures alone".
    public var attachmentUID: String?
    /// Set on a picture picked while the capture was back in the editor, and only there.
    ///
    /// It is what keeps that picture OUT of the create: the create is replayed exactly as it was
    /// first sent — that is what resolves an uncertain create to the memo it made rather than to a
    /// second one — and a picture the first send never named cannot appear in the replay. It
    /// reaches the memo through the edit instead. Optional and last, so a manifest written before
    /// this existed decodes unchanged and reads as "captured", which is what it is.
    public var stagedForEdit: Bool?

    public init(
        id: UUID = UUID(),
        relativePath: String,
        filename: String,
        mime: String,
        byteSize: Int64,
        lastModified: Date? = nil,
        uploadUID: String? = nil,
        bytesConfirmed: Int64 = 0,
        chunkSize: Int = OutboxDefaults.chunkSize,
        uploadAttempt: Int? = nil,
        attachmentUID: String? = nil,
        stagedForEdit: Bool? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.filename = filename
        self.mime = mime
        self.byteSize = byteSize
        self.lastModified = lastModified
        self.uploadUID = uploadUID
        self.bytesConfirmed = bytesConfirmed
        self.chunkSize = chunkSize
        self.uploadAttempt = uploadAttempt
        self.attachmentUID = attachmentUID
        self.stagedForEdit = stagedForEdit
    }

    public var isComplete: Bool { uploadUID != nil && bytesConfirmed >= byteSize }
}

/// A capture waiting for the server: the note, the originals, and everything needed to finish the
/// job from a cold start.
/// The edits a restored draft carries back, held beside the capture as it was FIRST SENT.
///
/// The create is replayed unchanged under the original key — that is what resolves a create whose
/// answer was lost to the memo it made — and these are what is then applied to that memo. A
/// manifest written before this existed carries no such value at all, which is what "nothing is
/// pending" decodes as.
public struct PendingEdit: Codable, Sendable, Equatable {
    public var content: String
    public var visibility: String?
    public var capturedAt: Date
    /// The pictures the memo keeps, in the order the editor left them.
    public var fileIDs: [UUID]

    public init(content: String, visibility: String?, capturedAt: Date, fileIDs: [UUID]) {
        self.content = content
        self.visibility = visibility
        self.capturedAt = capturedAt
        self.fileIDs = fileIDs
    }
}

public struct UploadJob: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Generated once, at capture, and sent on every create attempt for this job. It is what makes
    /// a retry after a lost response produce the same memo instead of a second one.
    public var idempotencyKey: UUID
    public var content: String
    /// The wire value (`PRIVATE`/`PROTECTED`/`PUBLIC`), or nil to let the account's default apply.
    public var visibility: String?
    /// When the person made the capture — sent as the memo's `created_at`, so a memo written on
    /// Monday and uploaded on Wednesday is still dated Monday.
    public var capturedAt: Date
    public var files: [OutboxFile]
    public var binding: AccountBinding
    public var state: JobState
    public var holdReason: HoldReason?
    /// What a waiting job is waiting FOR, when it is waiting for something a person can change.
    public var waitReason: WaitReason?
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    /// When a person took this capture back to the editor. Optional because a manifest written
    /// before this existed has no such field, and absent has to keep meaning "never cancelled"
    /// rather than making that manifest unreadable.
    public var cancelledAt: Date?
    /// The memo a create resolved to, once the server named it.
    public var resolvedMemoUID: String?
    /// The key the edit below is applied under, minted once per logical edit and kept across
    /// every transmission of that edit, so a replay is the same apply rather than a second one.
    /// It is not the create's idempotency key: a second edit of the same memo is a different edit
    /// and carries a different key.
    public var editKey: String?
    /// How often the pending edit has been put on the wire, moved through the fenced write. A
    /// relaunch deliberately claims the edit again — that is the recovery — and this counts those
    /// claims rather than preventing them; what makes the extra transmission harmless is the key
    /// above, which turns it into a replay of the same edit.
    public var patchAttempt: Int?
    /// What the editor changed while the create was in flight, still owed to the memo above.
    public var pendingEdit: PendingEdit?
    /// When the pending edit above was last put on the wire, cleared the moment an outcome says it
    /// is owed again. While it is set the edit is immutable: the capture cannot be taken back to
    /// the editor, because the body the server is answering about is the one on disk. Optional
    /// because a manifest written before this existed has none, and absent means "not in flight".
    public var editSentAt: Date?
    public init(
        id: UUID = UUID(),
        idempotencyKey: UUID = UUID(),
        content: String,
        visibility: String? = nil,
        capturedAt: Date,
        files: [OutboxFile],
        binding: AccountBinding,
        state: JobState = .waiting,
        holdReason: HoldReason? = nil,
        waitReason: WaitReason? = nil,
        attemptCount: Int = 0,
        nextAttemptAt: Date = .distantPast,
        lastError: String? = nil,
        cancelledAt: Date? = nil,
        resolvedMemoUID: String? = nil,
        editKey: String? = nil,
        patchAttempt: Int? = nil,
        pendingEdit: PendingEdit? = nil,
        editSentAt: Date? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.content = content
        self.visibility = visibility
        self.capturedAt = capturedAt
        self.files = files
        self.binding = binding
        self.state = state
        self.holdReason = holdReason
        self.waitReason = waitReason
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.cancelledAt = cancelledAt
        self.resolvedMemoUID = resolvedMemoUID
        self.editKey = editKey
        self.patchAttempt = patchAttempt
        self.pendingEdit = pendingEdit
        self.editSentAt = editSentAt
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteSize } }

    public var confirmedBytes: Int64 {
        files.reduce(0) { $0 + Swift.min($1.bytesConfirmed, $1.byteSize) }
    }

    /// 0...1, and 1 for a note with no media — a text-only capture is not stuck at 0 %.
    public var fractionUploaded: Double {
        guard totalBytes > 0 else { return 1 }
        return Double(confirmedBytes) / Double(totalBytes)
    }

    public func file(_ id: UUID) -> OutboxFile? { files.first { $0.id == id } }

    /// The uids the memo is created with, in capture order.
    ///
    /// A picture staged for the edit is not one of them: it was picked after this create was first
    /// sent, and a replay that named it would be a different request under the same key.
    public var uploadUIDs: [String] {
        files.filter { $0.stagedForEdit != true }.compactMap(\.uploadUID)
    }
}

public enum OutboxDefaults {
    /// What the server asks for today (`UPLOAD_CHUNK_SIZE`). Only ever a starting value: the size
    /// the session answers with wins, because the server is allowed to change its mind.
    public static let chunkSize = 5 * 1024 * 1024
    public static let appGroup = "group.live.discomarder.memosng"
}
