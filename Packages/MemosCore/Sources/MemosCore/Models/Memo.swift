import Foundation
import MemosAPI

public enum MemoVisibility: String, Sendable, Equatable, Codable {
    case `private` = "PRIVATE"
    case protected = "PROTECTED"
    case `public` = "PUBLIC"
}

public enum AttachmentStatus: String, Sendable, Equatable, Codable {
    case uploading
    case pending
    case processing
    case ready
    case failed
}

/// A media file hanging off a memo, with the derived tiers the server already produced.
public struct MemoAttachment: Sendable, Equatable, Identifiable {
    public var uid: String
    public var mime: String
    public var status: AttachmentStatus
    public var blurhash: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var thumbnailURL: URL?
    public var previewURL: URL?
    public var webURL: URL?
    public var posterURL: URL?

    // A public memberwise initialiser, so previews and tests in other modules can build one
    // without a server. Structs only synthesise an internal one.
    public init(
        uid: String,
        mime: String,
        status: AttachmentStatus,
        blurhash: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        thumbnailURL: URL? = nil,
        previewURL: URL? = nil,
        webURL: URL? = nil,
        posterURL: URL? = nil
    ) {
        self.uid = uid
        self.mime = mime
        self.status = status
        self.blurhash = blurhash
        self.width = width
        self.height = height
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.webURL = webURL
        self.posterURL = posterURL
    }

    public var id: String { uid }
    public var isVideo: Bool { mime.hasPrefix("video/") }
    /// Aspect ratio for layout; a missing dimension means "assume a square" rather than "crash".
    public var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

public struct Memo: Sendable, Equatable, Identifiable {
    public var uid: String
    public var owner: String
    public var mine: Bool
    public var content: String
    public var visibility: MemoVisibility
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?
    public var tags: [String]
    public var attachments: [MemoAttachment]

    public init(
        uid: String,
        owner: String,
        mine: Bool,
        content: String,
        visibility: MemoVisibility,
        pinned: Bool,
        createdAt: Date,
        updatedAt: Date,
        archivedAt: Date? = nil,
        tags: [String] = [],
        attachments: [MemoAttachment] = []
    ) {
        self.uid = uid
        self.owner = owner
        self.mine = mine
        self.content = content
        self.visibility = visibility
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.tags = tags
        self.attachments = attachments
    }

    public var id: String { uid }
    public var isArchived: Bool { archivedAt != nil }
}

// MARK: - mapping from the generated types

extension MemoVisibility {
    init(_ generated: Components.Schemas.Visibility) {
        switch generated {
        case ._private: self = .private
        case .protected: self = .protected
        case ._public: self = .public
        }
    }
}

extension AttachmentStatus {
    init(_ generated: Components.Schemas.AttachmentStatus) {
        switch generated {
        case .uploading: self = .uploading
        case .pending: self = .pending
        case .processing: self = .processing
        case .ready: self = .ready
        case .failed: self = .failed
        }
    }
}

extension MemoAttachment {
    /// Derived-tier URLs arrive relative to the server, so they are resolved against the base URL
    /// the session is talking to rather than assumed absolute.
    public init(_ generated: Components.Schemas.AttachmentRef, baseURL: URL) {
        self.init(
            uid: generated.uid,
            mime: generated.mime,
            status: AttachmentStatus(generated.status),
            blurhash: generated.blurhash,
            width: generated.width,
            height: generated.height,
            duration: generated.duration,
            thumbnailURL: URL(string: generated.thumbnailUrl, relativeTo: baseURL)?.absoluteURL,
            previewURL: URL(string: generated.previewUrl, relativeTo: baseURL)?.absoluteURL,
            webURL: URL(string: generated.webUrl, relativeTo: baseURL)?.absoluteURL,
            posterURL: URL(string: generated.posterUrl, relativeTo: baseURL)?.absoluteURL
        )
    }
}

extension Memo {
    public init(_ generated: Components.Schemas.MemoOut, baseURL: URL) {
        self.init(
            uid: generated.uid,
            owner: generated.owner,
            mine: generated.mine,
            content: generated.content,
            visibility: MemoVisibility(generated.visibility),
            pinned: generated.pinned,
            createdAt: generated.createdAt,
            updatedAt: generated.updatedAt,
            archivedAt: generated.archivedAt,
            tags: generated.tags,
            attachments: (generated.attachments ?? []).map {
                MemoAttachment($0, baseURL: baseURL)
            }
        )
    }
}
