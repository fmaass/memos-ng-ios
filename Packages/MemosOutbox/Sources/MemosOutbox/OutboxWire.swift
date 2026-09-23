import Foundation

/// The handful of wire fields the outbox reads and writes, mirrored locally.
///
/// Hand-rolling a wire type is allowed only where the generated one is UNREACHABLE from the layer
/// that needs it — generation is impossible, or the layer's dependency rule forbids importing the
/// generated client — and only behind a contract test that pins the semantics of every operation
/// consumed. Here exactly ONE ground carries it: the dependency rule. This package takes no
/// package dependencies, so the generated client cannot be imported from it at all. The shape of
/// the calls is NOT a second ground — the vendored document does model them — and convenience was
/// never one.
///
/// The condition is the vendored-document contract test in `MemosOutboxTests`: it must pin every
/// semantic these mirrors consume, so a re-sync that moves the contract fails there instead of on
/// a device. These types mirror ONLY the fields consumed; anything else the server sends is
/// ignored rather than mapped.
public enum OutboxWire {
    /// What starting an upload session sends.
    public struct UploadStart: Encodable, Sendable {
        public var filename: String
        public var mime: String
        public var size: Int64
        public var lastModified: Int64?

        public init(filename: String, mime: String, size: Int64, lastModified: Int64?) {
            self.filename = filename
            self.mime = mime
            self.size = size
            self.lastModified = lastModified
        }

        public enum CodingKeys: String, CodingKey {
            case filename
            case mime
            case size
            case lastModified = "last_modified"
        }
    }

    /// What every upload call answers with.
    public struct UploadSession: Decodable, Equatable, Sendable {
        public var uploadUID: String
        public var chunkSize: Int
        public var bytesReceived: Int64

        public init(uploadUID: String, chunkSize: Int, bytesReceived: Int64) {
            self.uploadUID = uploadUID
            self.chunkSize = chunkSize
            self.bytesReceived = bytesReceived
        }

        public enum CodingKeys: String, CodingKey {
            case uploadUID = "upload_uid"
            case chunkSize = "chunk_size"
            case bytesReceived = "bytes_received"
        }
    }

    /// What creating the memo sends. `upload_uids` is what links the originals: the server
    /// finalises the pending uploads itself, so there is no separate finalize call from here.
    public struct MemoCreate: Encodable, Sendable {
        public var content: String
        public var visibility: String?
        public var createdAt: String
        public var uploadUIDs: [String]
        public var idempotencyKey: String

        public init(
            content: String,
            visibility: String?,
            createdAt: String,
            uploadUIDs: [String],
            idempotencyKey: String
        ) {
            self.content = content
            self.visibility = visibility
            self.createdAt = createdAt
            self.uploadUIDs = uploadUIDs
            self.idempotencyKey = idempotencyKey
        }

        public enum CodingKeys: String, CodingKey {
            case content
            case visibility
            case createdAt = "created_at"
            case uploadUIDs = "upload_uids"
            case idempotencyKey = "idempotency_key"
        }
    }

    /// What editing the memo sends. Every field a compose screen lets a create set, so an edit
    /// that carried only the text would be a silent loss of the rest, plus `edit_key`: the key the
    /// server answers a second transmission of the SAME edit from, with the memo's current state
    /// and no second apply.
    ///
    /// `attachment_uids` is the memo's complete picture list in the order the editor left it. An
    /// entry is either an attachment uid the memo already holds or an upload uid named in THIS
    /// request's `upload_uids`; anything else fails the whole request.
    public struct MemoPatch: Encodable, Sendable {
        public var content: String
        public var visibility: String?
        public var createdAt: String
        public var editKey: String
        public var uploadUIDs: [String]
        /// Absent where the edit cannot name the memo's pictures: the synthesized encoder leaves
        /// the key out, and the server leaves the memo's own list alone.
        public var attachmentUIDs: [String]?

        public init(
            content: String,
            visibility: String?,
            createdAt: String,
            editKey: String,
            uploadUIDs: [String],
            attachmentUIDs: [String]?
        ) {
            self.content = content
            self.visibility = visibility
            self.createdAt = createdAt
            self.editKey = editKey
            self.uploadUIDs = uploadUIDs
            self.attachmentUIDs = attachmentUIDs
        }

        public enum CodingKeys: String, CodingKey {
            case content
            case visibility
            case createdAt = "created_at"
            case editKey = "edit_key"
            case uploadUIDs = "upload_uids"
            case attachmentUIDs = "attachment_uids"
        }
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decodeSession(_ data: Data) -> UploadSession? {
        try? JSONDecoder().decode(UploadSession.self, from: data)
    }

    /// The machine-readable `code` of a structured refusal, when the body carries one.
    ///
    /// The server distinguishes its refusals by this string rather than by status alone, and the
    /// difference decides whether an outbox re-uploads, waits, or stops — so it is read, not
    /// inferred from the status code.
    public static func detailCode(_ data: Data) -> String? {
        struct Coded: Decodable {
            struct Detail: Decodable {
                var code: String
            }

            var detail: Detail
        }
        return (try? JSONDecoder().decode(Coded.self, from: data))?.detail.code
    }
}

/// Date shapes the server expects, in one place because each one is a different unit.
public enum OutboxEncoding {
    /// `created_at`: ISO-8601 in UTC, seconds resolution, `Z` suffix.
    static let utc = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year().month().day()
        .dateTimeSeparator(.standard)
        .time(includingFractionalSeconds: false)
        .timeZone(separator: .omitted)

    public static func iso8601(_ date: Date) -> String {
        utc.format(date)
    }

    /// `last_modified`: the same epoch MILLISECONDS a browser's `File.lastModified` carries, which
    /// is what the server's field documents. Seconds here would date every original to 1970.
    public static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// The server's structured refusal to link a memo's uploads.
///
/// It is decoded strictly: a body that is not this exact shape — an ordinary validation error, for
/// one — must NOT be read as upload loss, because the recovery for upload loss is re-uploading
/// files that were never lost.
public struct UploadsUnlinkableFailure: Sendable, Equatable {
    public static let code = "uploads_unlinkable"

    /// Uids the server has no record of: the session expired or was reaped. These need a fresh
    /// upload from the original, which the outbox still holds.
    public var missingUploadUIDs: [String]
    /// Uids the server has but has not received every byte for. These need an offset HEAD and a
    /// resumed upload, not a restart.
    public var incompleteUploadUIDs: [String]

    public init(missingUploadUIDs: [String], incompleteUploadUIDs: [String]) {
        self.missingUploadUIDs = missingUploadUIDs
        self.incompleteUploadUIDs = incompleteUploadUIDs
    }

    private struct Envelope: Decodable {
        struct Detail: Decodable {
            var code: String
            // Both arrays are REQUIRED by the contract. Decoding them as optional would let a
            // body that is merely shaped like the refusal be treated as one, and "no uids named"
            // is not a recovery instruction.
            var missingUploadUIDs: [String]
            var incompleteUploadUIDs: [String]

            enum CodingKeys: String, CodingKey {
                case code
                case missingUploadUIDs = "missing_upload_uids"
                case incompleteUploadUIDs = "incomplete_upload_uids"
            }
        }

        var detail: Detail
    }

    /// Returns nil unless the body is the structured refusal, code included.
    public static func decode(_ data: Data) -> UploadsUnlinkableFailure? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.detail.code == code
        else { return nil }
        return UploadsUnlinkableFailure(
            missingUploadUIDs: envelope.detail.missingUploadUIDs,
            incompleteUploadUIDs: envelope.detail.incompleteUploadUIDs
        )
    }
}
