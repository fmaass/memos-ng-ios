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

    public init(
        id: UUID = UUID(),
        relativePath: String,
        filename: String,
        mime: String,
        byteSize: Int64,
        lastModified: Date? = nil,
        uploadUID: String? = nil,
        bytesConfirmed: Int64 = 0,
        chunkSize: Int = OutboxDefaults.chunkSize
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
    }

    public var isComplete: Bool { uploadUID != nil && bytesConfirmed >= byteSize }
}

/// A capture waiting for the server: the note, the originals, and everything needed to finish the
/// job from a cold start.
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
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastError: String?

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
        attemptCount: Int = 0,
        nextAttemptAt: Date = .distantPast,
        lastError: String? = nil
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
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
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
    public var uploadUIDs: [String] { files.compactMap(\.uploadUID) }
}

public enum OutboxDefaults {
    /// What the server asks for today (`UPLOAD_CHUNK_SIZE`). Only ever a starting value: the size
    /// the session answers with wins, because the server is allowed to change its mind.
    public static let chunkSize = 5 * 1024 * 1024
    public static let appGroup = "group.live.discomarder.memosng"
}
