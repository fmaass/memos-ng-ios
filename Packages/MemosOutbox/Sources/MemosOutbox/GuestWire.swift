import Foundation

/// The guest door's wire fields, mirrored locally — the guest twin of `OutboxWire`.
///
/// The licence is `OutboxWire`'s: this package's dependency rule makes a generated client
/// unreachable from here. The condition is the guest door's own document, `openapi-guest.json`,
/// vendored verbatim beside `openapi.json` and never generated from, and `GuestContractTests`,
/// which pins every field named here against it (`RedeemIn`, `RedeemOut`, `PassOut`, `MeOut`,
/// `GuestLimits`, `GuestUploadIn`, `GuestUploadOut`, `CompleteIn`, `Receipt`, `ReceiptFile`).
/// These mirrors map ONLY the fields consumed; anything else the server sends is ignored.
public enum GuestWire {
    /// `POST /api/pass/redeem`'s body.
    public struct Redeem: Encodable, Sendable, Equatable {
        public var secret: String
        public var displayName: String
        /// Always `app` from here: the server records which surface enrolled the device.
        public var platform: String
        public var deviceHint: String?

        public init(secret: String, displayName: String, deviceHint: String? = nil) {
            self.secret = secret
            self.displayName = displayName
            self.platform = "app"
            self.deviceHint = deviceHint
        }

        public enum CodingKeys: String, CodingKey {
            case secret
            case displayName = "display_name"
            case platform
            case deviceHint = "device_hint"
        }
    }

    /// The pass as the guest may see it: its label and when it closes.
    public struct Pass: Decodable, Sendable, Equatable {
        public var label: String
        public var expiresAt: Date

        public init(label: String, expiresAt: Date) {
            self.label = label
            self.expiresAt = expiresAt
        }

        public enum CodingKeys: String, CodingKey {
            case label
            case expiresAt = "expires_at"
        }
    }

    /// The door's limits. Only the PATCH ceiling is consumed: it bounds every body the outbox sends
    /// (`GuestPatchPlan`). Absent is legal — the server sends a plain mapping — and reads as "use
    /// the documented ceiling".
    public struct Limits: Decodable, Sendable, Equatable {
        public var maxPatchBytes: Int64?

        public init(maxPatchBytes: Int64?) {
            self.maxPatchBytes = maxPatchBytes
        }

        public enum CodingKeys: String, CodingKey {
            case maxPatchBytes = "max_patch_bytes"
        }
    }

    /// `POST /api/pass/redeem`'s answer (201).
    public struct Redeemed: Decodable, Sendable, Equatable {
        public var deviceToken: String
        public var deviceID: String
        public var pass: Pass
        public var limits: Limits

        public enum CodingKeys: String, CodingKey {
            case deviceToken = "device_token"
            case deviceID = "device_id"
            case pass
            case limits
        }
    }

    /// `GET /api/guest/me`'s answer: the same pass and limits, read again under the device token.
    public struct Me: Decodable, Sendable, Equatable {
        public var deviceID: String
        public var pass: Pass
        public var limits: Limits

        public enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case pass
            case limits
        }
    }

    /// `PATCH /api/guest/device`'s body: the name the door credits this device's pictures to.
    ///
    /// Not yet pinned by `GuestContractTests`: the vendored `openapi-guest.json` predates the
    /// route. The next contract sync adds it there, and `routeSet` fails until it is mirrored.
    public struct Rename: Encodable, Sendable, Equatable {
        public var displayName: String

        public init(displayName: String) {
            self.displayName = displayName
        }

        public enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    /// `PATCH /api/guest/device`'s answer (200): the name as the door stored it.
    public struct Renamed: Decodable, Sendable, Equatable {
        public var displayName: String

        public enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    /// `POST /api/guest/uploads`'s body. `sha256` is what lets the door answer "already received"
    /// for bytes this pass already holds, so a re-share costs no upload.
    public struct UploadStart: Encodable, Sendable, Equatable {
        public var filename: String
        public var mime: String
        public var size: Int64
        public var lastModified: Int64?
        public var sha256: String?

        public init(
            filename: String, mime: String, size: Int64, lastModified: Int64?, sha256: String?
        ) {
            self.filename = filename
            self.mime = mime
            self.size = size
            self.lastModified = lastModified
            self.sha256 = sha256
        }

        public enum CodingKeys: String, CodingKey {
            case filename
            case mime
            case size
            case lastModified = "last_modified"
            case sha256
        }
    }

    /// What the upload create and every PATCH answer with. The server defaults every field, so
    /// each one decodes absent as that default.
    public struct UploadAnswer: Decodable, Sendable, Equatable {
        public var alreadyReceived: Bool
        public var uploadUID: String?
        public var bytesReceived: Int64
        public var chunkSize: Int
        public var maxPatchBytes: Int64

        public init(
            alreadyReceived: Bool = false, uploadUID: String? = nil, bytesReceived: Int64 = 0,
            chunkSize: Int = 0, maxPatchBytes: Int64 = 0
        ) {
            self.alreadyReceived = alreadyReceived
            self.uploadUID = uploadUID
            self.bytesReceived = bytesReceived
            self.chunkSize = chunkSize
            self.maxPatchBytes = maxPatchBytes
        }

        public enum CodingKeys: String, CodingKey {
            case alreadyReceived = "already_received"
            case uploadUID = "upload_uid"
            case bytesReceived = "bytes_received"
            case chunkSize = "chunk_size"
            case maxPatchBytes = "max_patch_bytes"
        }

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            alreadyReceived =
                try fields.decodeIfPresent(Bool.self, forKey: .alreadyReceived) ?? false
            uploadUID = try fields.decodeIfPresent(String.self, forKey: .uploadUID)
            bytesReceived = try fields.decodeIfPresent(Int64.self, forKey: .bytesReceived) ?? 0
            chunkSize = try fields.decodeIfPresent(Int.self, forKey: .chunkSize) ?? 0
            maxPatchBytes = try fields.decodeIfPresent(Int64.self, forKey: .maxPatchBytes) ?? 0
        }

        /// What the outbox does with this answer.
        ///
        /// An answer that is neither a received file nor a session is no answer: a decoder that
        /// filled a session from defaults would PATCH an upload uid nobody issued.
        public var start: GuestStart? {
            if alreadyReceived { return .alreadyReceived }
            guard let uploadUID, !uploadUID.isEmpty else { return nil }
            // The session's slice is bounded by the door's PATCH ceiling here, at the one place a
            // session enters the queue, so a door that asked for slices larger than it accepts
            // can never have its own number sent back to it.
            let ceiling = GuestPatchPlan.limit(reported: maxPatchBytes)
            let slice = chunkSize > 0 ? Swift.min(Int64(chunkSize), ceiling) : ceiling
            return .session(
                OutboxWire.UploadSession(
                    uploadUID: uploadUID, chunkSize: Int(slice), bytesReceived: bytesReceived
                )
            )
        }
    }

    /// `POST /api/guest/memos`'s body: the completion that turns received uploads into one batch.
    /// The server derives its idempotency from the device and the upload uids, so a replay of the
    /// same list answers the batch the first one made.
    public struct Complete: Encodable, Sendable, Equatable {
        public var uploadUIDs: [String]
        public var caption: String?

        public init(uploadUIDs: [String], caption: String?) {
            self.uploadUIDs = uploadUIDs
            self.caption = caption
        }

        public enum CodingKeys: String, CodingKey {
            case uploadUIDs = "upload_uids"
            case caption
        }
    }

    /// One receipt (`POST /api/guest/memos`, `GET /api/guest/batches`): what the guest is shown.
    public struct Receipt: Decodable, Sendable, Equatable, Identifiable {
        public struct File: Decodable, Sendable, Equatable {
            public var filename: String
            public var sha256: String
            public var size: Int64
        }

        public var batchID: String
        /// `received` or `held`; held is the owner's moderation, and the guest sees that it is.
        public var status: String
        public var fileCount: Int
        public var completedAt: Date?
        public var files: [File]

        public var id: String { batchID }

        public enum CodingKeys: String, CodingKey {
            case batchID = "batch_id"
            case status
            case fileCount = "file_count"
            case completedAt = "completed_at"
            case files
        }
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// The server's datetimes are pydantic's ISO 8601, with fractional seconds and an offset, or
    /// without either; each spelling is tried rather than one assumed.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date")
            )
        }
        return try? decoder.decode(type, from: data)
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: raw) { return date }
        // A naive timestamp is UTC on this server (it stores timezone-aware values, but a
        // serializer that dropped the offset must not shift every expiry by the phone's zone).
        return whole.date(from: raw + "Z") ?? fractional.date(from: raw + "Z")
    }
}

/// What a guest upload create resolved to.
public enum GuestStart: Sendable, Equatable {
    /// The pass already holds these bytes: nothing is PATCHed, and the file is in no completion.
    case alreadyReceived
    /// A session to PATCH into, its slice already bounded by the door's ceiling.
    case session(OutboxWire.UploadSession)
}

/// Where the guest door is, and the one bound every guest PATCH body is held to.
public enum GuestDoor {
    /// The guest door's public origin. Fixed, never derived from a pass link a person opened: a
    /// guest token goes to this host and no other.
    public static let baseURL = URL(string: "https://trip.discomarder.live")!

    /// Whether a URL is a trip pass link for this door, and its secret when it is.
    ///
    /// The scanner and an opened link both arrive here, so the one rule about what a pass looks
    /// like is written once. Anything not `https://trip.discomarder.live/p/<secret>` is refused.
    public static func secret(fromPassLink url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
            url.host()?.lowercased() == baseURL.host()?.lowercased(),
            url.port == nil
        else { return nil }
        let parts = url.path().split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "p" else { return nil }
        let secret = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        guard !secret.isEmpty, secret.count <= 256 else { return nil }
        return secret
    }
}

/// How every guest PATCH body is bounded.
///
/// The guest door refuses any single body over 64 MiB (`INGEST_PATCH_MAX_BYTES`), whether it is a
/// fresh upload or the tail of one resumed after the offset HEAD. Pure, so the vectors that matter
/// — the empty file, one byte, exactly the ceiling, one past it, a large video, an odd resume
/// offset — are asserted without a network.
public enum GuestPatchPlan {
    /// The documented ceiling. A larger number reported by a server is never trusted past it.
    public static let ceiling: Int64 = 64 * 1024 * 1024

    /// The bound to use: the door's reported `max_patch_bytes` when it is a size, never above the
    /// ceiling.
    public static func limit(reported: Int64?) -> Int64 {
        guard let reported, reported > 0 else { return ceiling }
        return Swift.min(reported, ceiling)
    }

    /// The body that starts at `offset`, or nil when nothing is left to send.
    public static func body(atOffset offset: Int64, byteSize: Int64, limit: Int64) -> Range<Int64>?
    {
        guard limit > 0, offset >= 0, offset < byteSize else { return nil }
        return offset..<Swift.min(byteSize, offset + Swift.min(limit, ceiling))
    }

    /// Every body from `offset` to the end, in order.
    public static func bodies(from offset: Int64, byteSize: Int64, limit: Int64) -> [Range<Int64>] {
        var result: [Range<Int64>] = []
        var cursor = offset
        while let next = body(atOffset: cursor, byteSize: byteSize, limit: limit) {
            result.append(next)
            cursor = next.upperBound
        }
        return result
    }

    /// A resumed offset is the server's count — unless it claims more bytes than this file has, which
    /// no honest resume can: that upload is not this file, and sending its "tail" would corrupt
    /// whatever it is.
    public enum ResumeRefusal: Error, Sendable, Equatable {
        case offsetBeyondFile(reported: Int64, byteSize: Int64)
    }

    public static func resumeOffset(reported: Int64, byteSize: Int64) throws(ResumeRefusal) -> Int64
    {
        guard reported >= 0, reported <= byteSize else {
            throw .offsetBeyondFile(reported: reported, byteSize: byteSize)
        }
        return reported
    }
}
