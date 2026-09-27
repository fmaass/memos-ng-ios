import Foundation
import MemosAPI

/// What a file in the library IS, as far as anything that shows it is concerned.
///
/// Three cases, not two. The library list is every attachment the household can see, and the
/// server accepts uploads that are neither a picture nor a clip — a PDF, a voice memo, a zip. A
/// two-way split would have to call one of those an image, and a grid of "image" tiles that can
/// never load a picture is the same failure the timeline had before `AttachmentReadiness` existed.
///
/// Derived from the mime prefix, which is the same rule the server filters by
/// (`?type=image` is `mime LIKE 'image/%'`), so the client and the server cannot disagree about
/// which tab a file belongs under.
public enum AttachmentMediaKind: String, Sendable, Equatable, CaseIterable {
    case image
    case video
    /// Neither. It has no still to show and nothing to play.
    case other

    public static func of(mime: String) -> AttachmentMediaKind {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        return .other
    }
}

extension MemoAttachment {
    /// Which of the three this attachment is. `isVideo` answers half of the same question and is
    /// kept — this is the whole of it, for the surface that has to place a file in a tab.
    public var mediaKind: AttachmentMediaKind { AttachmentMediaKind.of(mime: mime) }
}

/// Which slice of the library is being looked at — the SPA's own three (`ResourcesView.vue`), so
/// the two clients offer the same choice under the same names.
public enum MediaLibraryFilter: String, Sendable, Equatable, CaseIterable, Identifiable {
    case all
    case images
    case videos

    public var id: String { rawValue }

    /// What rides in `?type=`. `nil` for `all`, which is the parameter being ABSENT rather than
    /// empty: `?type=` would be a filter matching nothing on a server that compares it to a mime
    /// prefix.
    public var apiType: String? {
        switch self {
        case .all: nil
        case .images: "image"
        case .videos: "video"
        }
    }

    /// Whether a file of this kind belongs in this tab.
    ///
    /// The tab a row appears under is decided HERE rather than taken on trust from the response.
    /// `?type=` and this function are two statements of one rule, on either side of the wire, and
    /// the only way a client can hold the server to it is to apply it again to what came back —
    /// exactly as the page merge re-applies identity with its own dedup rather than trusting a
    /// keyset not to overlap. A video under Images is a row in the wrong tab, which is worse than
    /// a row missing from it.
    public func includes(_ kind: AttachmentMediaKind) -> Bool {
        switch self {
        case .all: true
        case .images: kind == .image
        case .videos: kind == .video
        }
    }
}

/// Which end of the library the grid starts at.
///
/// One key, two directions — which is the whole of what the server offers (`?order=desc|asc` on
/// `GET /api/attachments`) and the whole of what a photo library needs. Photos calls the same pair
/// "Newest First" and "Oldest First" on an album, and this is that control.
public enum MediaLibraryOrder: String, Sendable, Equatable, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    public var id: String { rawValue }

    /// What rides in `?order=`. It is the server's own vocabulary rather than this enum's, because
    /// the two are answers to different questions: the reader chooses a direction in words, the
    /// request names the sort the database does.
    public var apiOrder: String {
        switch self {
        case .newestFirst: "desc"
        case .oldestFirst: "asc"
        }
    }

    /// The row a menu draws. Photos' words, so the two libraries read the same.
    public var label: String {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        }
    }
}

extension MemoAttachment {
    /// A row of the library list.
    ///
    /// It maps onto the SAME model a memo's attachments do, deliberately: the tile, the image
    /// loader, its cache key and the full-screen viewer are all written against `MemoAttachment`,
    /// and a second model for the same file would be a second image-loading path.
    ///
    /// `duration` is nil because `AttachmentListItem` does not carry one — the list payload is the
    /// memo payload minus `duration` and `captured_at`, plus `orphan`/`mine`/`hasPrint`/`memoUid`.
    /// So a library tile cannot print a clip's length; it says "video" with the play glyph the
    /// timeline tiles already use. Inventing a zero here would put "0:00" under every clip.
    public init(_ generated: Components.Schemas.AttachmentListItem, baseURL: URL) {
        self.init(
            uid: generated.uid,
            mime: generated.mime,
            status: AttachmentStatus(generated.status),
            blurhash: generated.blurhash,
            width: generated.width,
            height: generated.height,
            duration: nil,
            thumbnailURL: URL(string: generated.thumbnailUrl, relativeTo: baseURL)?.absoluteURL,
            previewURL: URL(string: generated.previewUrl, relativeTo: baseURL)?.absoluteURL,
            webURL: URL(string: generated.webUrl, relativeTo: baseURL)?.absoluteURL,
            posterURL: URL(string: generated.posterUrl, relativeTo: baseURL)?.absoluteURL,
            downloadURL: URL(string: generated.downloadUrl, relativeTo: baseURL)?.absoluteURL,
            // The one thing this payload knows that a memo's own attachment list cannot: which
            // memo a file in the WHOLE library belongs to. Null for an orphan, and an orphan is a
            // row this list deliberately includes (MEMNG-171).
            memoUID: generated.memoUid
        )
    }
}

/// A row of the library list: the file, and the three things the list knows about it that a memo's
/// attachment list does not.
///
/// It WRAPS `MemoAttachment` rather than widening it. The tile, the image loader, its cache key and
/// the viewer keep their one model, and `MemoAttachment` is part of the timeline snapshot on disk,
/// whose shape is versioned — these fields belong to the list, not to the file.
///
/// `takenAt` is not `MemoAttachment.captureInstant`: that is camera metadata and nil for an undated
/// file, while the list answers `takenAt` for every row. It is optional here although the wire
/// field is required, so that a row can also stand for a date that could not be read rather than
/// inventing one.
public struct LibraryRow: Sendable, Equatable, Identifiable {
    public var attachment: MemoAttachment
    public var takenAt: Date?
    public var mine: Bool
    public var filename: String

    public var id: String { attachment.uid }

    public init(attachment: MemoAttachment, takenAt: Date?, mine: Bool, filename: String) {
        self.attachment = attachment
        self.takenAt = takenAt
        self.mine = mine
        self.filename = filename
    }

    public init(_ generated: Components.Schemas.AttachmentListItem, baseURL: URL) {
        self.init(
            attachment: MemoAttachment(generated, baseURL: baseURL),
            takenAt: generated.takenAt,
            mine: generated.mine,
            filename: generated.filename
        )
    }
}
