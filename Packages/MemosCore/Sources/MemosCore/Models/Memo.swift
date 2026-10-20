import Foundation
import MemosAPI

public enum MemoVisibility: String, Sendable, Equatable, Codable, CaseIterable {
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

/// What a tile should SAY about an attachment, as three states rather than two.
///
/// The server produces the derived tiers after the memo exists, so a memo posted a moment ago
/// carries attachments that are real, intact and simply not rendered yet. The app used to know
/// only "there is a picture" and "there is no picture", so those attachments got the same warning
/// triangle a genuinely broken upload gets — the first real post showed a card of "!" marks.
///
/// Waiting and failed are different facts about the world and they are projected apart here, once,
/// so the view and the refresh that ends the waiting cannot disagree about which is which.
public enum AttachmentReadiness: String, Sendable, Equatable {
    /// The tiers exist; the tile can fetch a picture.
    case ready
    /// The server has not finished with it. Nothing is wrong.
    case waiting
    /// The server gave up on this file. Nothing more is coming.
    case failed
}

/// A media file hanging off a memo, with the derived tiers the server already produced.
public struct MemoAttachment: Sendable, Equatable, Identifiable, Codable {
    public var uid: String
    public var mime: String
    public var status: AttachmentStatus
    public var blurhash: String?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    /// When the picture was TAKEN, as the server read it from the file's own metadata.
    ///
    /// Distinct from the memo's `createdAt`, which is the memo's DATE — the one the compose sheet
    /// chose or defaulted to, and which may be backdated — while this is when THIS picture was
    /// taken: a roll of holiday photos filed under one evening's date all differ only here. `nil`
    /// is the ordinary case for anything the camera did not date — a screenshot, a drawing, a file
    /// stripped of its metadata — so nothing may treat it as an ordering key on its own.
    public var captureInstant: Date?
    public var thumbnailURL: URL?
    public var previewURL: URL?
    public var webURL: URL?
    public var posterURL: URL?
    /// The file as it was uploaded — the archive master, not a tier derived from it.
    ///
    /// It is the odd one out among these URLs and it is worth saying why. The four above are
    /// DERIVED tiers and the server signs them, so anything holding the URL can fetch them; this
    /// one is served unsigned and behind authentication (memos-ng `app/routers/assets.py`, the
    /// "UNSIGNED / AUTH PATH" branch — original and print take a token or a session, never a
    /// signature). So it is not a link that can be handed to anything: fetching it means presenting
    /// the device credential, which is why `SessionStore.download` is the only thing that
    /// does.
    public var downloadURL: URL?
    /// The memo this file hangs on, when the payload it came from says so (MEMNG-171).
    ///
    /// `nil` means two different things and deliberately reads as one: the file is an ORPHAN — the
    /// library list includes uploads no memo references — or it arrived on a payload that carries
    /// no owner at all. Either way there is no memo to open, which is the only question anything
    /// asks this field.
    public var memoUID: String?
    /// The wall-clock time the picture was taken, as the camera wrote it — `2026-01-01T13:00:00`,
    /// no offset — when the file carried one.
    ///
    /// Capture metadata in the same sense as `captureInstant`, and kept apart from every DISPLAY
    /// date for the same reason: nothing derived from the memo or the upload may be written here.
    /// A clock with no offset is what a camera records, so it is read as written, in whatever zone
    /// the reader is in, rather than converted from anywhere.
    public var captureCivil: String?
    /// Where the server read the capture fields from (`exif`, `quicktime`, …), or `nil` when it
    /// read none.
    public var captureSource: String?
    /// Whether this FILE is the reader's own — the attachment owner's flag the payload carries.
    ///
    /// Not the memo's `mine`: a picture of somebody else's can hang on a memo of mine, and the
    /// other way round. `nil` where the payload this was built from says nothing about it.
    public var mine: Bool?
    /// The picture's OWN tags (MEMNG-867), sorted by name as the server sends them — never its
    /// memo's tags, which are `Memo.tags` and live on the text. A favorite is one of these
    /// (`FavoriteTag.name`), so this is what the viewer's heart reads.
    ///
    /// Part of the timeline snapshot's shape: adding it took `currentFormatVersion` past 2
    /// (`TimelineSnapshot.currentFormatVersion` names the version that carries it).
    public var tags: [String]

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
        captureInstant: Date? = nil,
        captureCivil: String? = nil,
        captureSource: String? = nil,
        mine: Bool? = nil,
        thumbnailURL: URL? = nil,
        previewURL: URL? = nil,
        webURL: URL? = nil,
        posterURL: URL? = nil,
        downloadURL: URL? = nil,
        memoUID: String? = nil,
        tags: [String] = []
    ) {
        self.uid = uid
        self.mime = mime
        self.status = status
        self.blurhash = blurhash
        self.width = width
        self.height = height
        self.duration = duration
        self.captureInstant = captureInstant
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.webURL = webURL
        self.posterURL = posterURL
        self.downloadURL = downloadURL
        self.memoUID = memoUID
        self.captureCivil = captureCivil
        self.captureSource = captureSource
        self.mine = mine
        self.tags = tags
    }

    public var id: String { uid }
    public var isVideo: Bool { mime.hasPrefix("video/") }
    /// The proportions the SERVER measured, or `nil` when it did not say.
    ///
    /// A screen that reserves space for a picture before the picture arrives has to know the
    /// difference between "this is square" and "nobody knows yet" — the two want different
    /// fallbacks, and the caller is the only one that knows which.
    public var measuredAspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    /// Aspect ratio for layout; a missing dimension means "assume a square" rather than "crash".
    public var aspectRatio: Double { measuredAspectRatio ?? 1 }

    /// The three-way projection every surface reads. `uploading` is grouped with the server-side
    /// stages deliberately: from a reader's point of view a file still on its way and a file the
    /// worker has not reached yet are the same thing — something is coming, nothing is broken.
    public var readiness: AttachmentReadiness {
        switch status {
        case .ready: .ready
        case .failed: .failed
        case .uploading, .pending, .processing: .waiting
        }
    }
}

/// One memo, as every screen in the app reads it.
///
/// `Codable` because the timeline snapshot on disk is made of these (`TimelineSnapshotStore`).
/// That carries an obligation: changing the SHAPE of this type — or of `MemoAttachment` under it —
/// bumps `TimelineSnapshot.currentFormatVersion` in the same change, so a file written by the
/// previous version reads as absent instead of decoding into a memo that is missing half of itself.
public struct Memo: Sendable, Equatable, Identifiable, Codable {
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

    /// Whether anything on this memo is still being derived — the condition the tier-ready refresh
    /// runs under, and the condition it stops on.
    public var isAwaitingTiers: Bool { attachments.contains { $0.readiness == .waiting } }
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

extension MemoVisibility {
    /// The write direction of the same mapping. It exists as its own function so the pair can be
    /// asserted to round-trip: a request that says PUBLIC when the reader chose PROTECTED is the
    /// one mistake in this file that would publish someone's memo.
    var generated: Components.Schemas.Visibility {
        switch self {
        case .private: ._private
        case .protected: .protected
        case .public: ._public
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
    ///
    /// `memoUID` stays nil even though the memo being decoded around it is right there. The field
    /// is what puts "Show Memo" on a tile and in the viewer overlay, and every attachment reached
    /// through this initialiser was reached FROM the memo it belongs to — an action that navigates
    /// to the screen it was invoked from is an action that does nothing anybody can see. The
    /// library list is the payload that genuinely knows something the surface does not.
    public init(_ generated: Components.Schemas.AttachmentRef, baseURL: URL) {
        self.init(
            uid: generated.uid,
            mime: generated.mime,
            status: AttachmentStatus(generated.status),
            blurhash: generated.blurhash,
            width: generated.width,
            height: generated.height,
            duration: generated.duration,
            captureInstant: generated.captureInstant,
            captureCivil: generated.captureCivil,
            captureSource: generated.captureSource,
            mine: generated.mine,
            thumbnailURL: URL(string: generated.thumbnailUrl, relativeTo: baseURL)?.absoluteURL,
            previewURL: URL(string: generated.previewUrl, relativeTo: baseURL)?.absoluteURL,
            webURL: URL(string: generated.webUrl, relativeTo: baseURL)?.absoluteURL,
            posterURL: URL(string: generated.posterUrl, relativeTo: baseURL)?.absoluteURL,
            downloadURL: URL(string: generated.downloadUrl, relativeTo: baseURL)?.absoluteURL,
            tags: generated.tags ?? []
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
