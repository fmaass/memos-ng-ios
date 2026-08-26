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

extension MemoAttachment {
    /// A row of the library list.
    ///
    /// It maps onto the SAME model a memo's attachments do, deliberately: the tile, the image
    /// loader, its cache key and the full-screen viewer are all written against `MemoAttachment`,
    /// and a second model for the same file would be a second image-loading path.
    ///
    /// `duration` is nil because `AttachmentListItem` does not carry one — the list payload is the
    /// memo payload minus `duration` and `captured_at`, plus `orphan`/`mine`/`hasPrint`. So a
    /// library tile cannot print a clip's length; it says "video" with the play glyph the timeline
    /// tiles already use. Inventing a zero here would put "0:00" under every clip.
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
            posterURL: URL(string: generated.posterUrl, relativeTo: baseURL)?.absoluteURL
        )
    }
}
