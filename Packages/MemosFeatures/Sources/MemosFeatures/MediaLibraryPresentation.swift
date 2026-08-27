import CoreGraphics
import Foundation
import MemosCore

/// What a tile in the library grid draws, and whether it opens.
///
/// The grid is not a memo's gallery: it shows the household's WHOLE library, which contains files
/// that are neither a picture nor a clip. Those get a tile of their own rather than a warning
/// triangle (nothing is wrong with them) and they do not open, because the full-screen viewer has
/// no page for a file it can neither show nor play — `MediaViewerPresentation.pages` drops exactly
/// these, and a tile that swallows a tap is worse than one that never offered.
public enum LibraryTileKind: Equatable, Sendable {
    case image
    case video
    case document
}

/// The library's empty state, as the three parts a `ContentUnavailableView` is made of. Carried
/// as a value so what each tab says when it has nothing is a thing a test can read back.
public struct LibraryEmptyState: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let message: String
}

/// Decisions the library screen needs, kept out of the view — the same split `MemoPresentation`
/// makes, and for the same reason: a SwiftUI body is the worst place to unit-test anything.
public enum MediaLibraryPresentation {
    /// The narrowest a tile may be, which is what decides how many fit across.
    ///
    /// A grid of squares this size gives four columns on the phones this app targets and more on
    /// an iPad, without the count being written down anywhere — the grid adapts, so a rotation or
    /// a split view is not a layout this code has to know about.
    public static let minimumTileWidth: CGFloat = 104

    /// What the tile at this file draws. Derived from the KIND rather than from the status: what
    /// a file still being processed looks like is `AttachmentThumbnail`'s decision (it has the
    /// readiness projection and the veil), and duplicating it here would be two answers to one
    /// question.
    public static func tileKind(for attachment: MemoAttachment) -> LibraryTileKind {
        switch attachment.mediaKind {
        case .image: .image
        case .video: .video
        case .other: .document
        }
    }

    /// Whether tapping this tile opens the full-screen viewer.
    public static func isOpenable(_ kind: LibraryTileKind) -> Bool {
        kind != .document
    }

    /// The glyph a non-media file wears. Broad strokes on purpose: the point is that the tile
    /// reads as "a file, not a photo", not that it identifies the format.
    public static func documentSymbol(for mime: String) -> String {
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    /// The name of a tab of the filter control. The SPA's own three, so the two clients offer the
    /// same choice under the same words (`frontend/src/views/ResourcesView.vue`).
    public static func label(for filter: MediaLibraryFilter) -> String {
        switch filter {
        case .all: "All"
        case .images: "Images"
        case .videos: "Videos"
        }
    }

    /// What a tab says when it holds nothing.
    ///
    /// One message per tab rather than one for the screen: "No attachments yet" under Videos, on a
    /// library full of photographs, reads as the library being empty when what is empty is the
    /// filter. The tab that is open is the only thing that makes the sentence true.
    public static func emptyState(for filter: MediaLibraryFilter) -> LibraryEmptyState {
        switch filter {
        case .all:
            LibraryEmptyState(
                title: "No media yet",
                symbol: "photo.on.rectangle.angled",
                message: "Photos and videos posted to your memos appear here."
            )
        case .images:
            LibraryEmptyState(
                title: "No photos yet",
                symbol: "photo",
                message: "Photos posted to your memos appear here."
            )
        case .videos:
            LibraryEmptyState(
                title: "No videos yet",
                symbol: "video",
                message: "Videos posted to your memos appear here."
            )
        }
    }

    /// How wide the picture a long press lifts off the grid is drawn.
    ///
    /// Wider than a tile by a large factor, which is the whole point of a context-menu preview: it
    /// is the moment the grid stops being a grid of thumbnails and the file is looked AT. The
    /// height follows the picture's own proportions, so a portrait and a landscape both get their
    /// shape rather than a common box.
    public static let previewWidth: CGFloat = 320

    /// What a tile says out loud. A grid of unlabelled images is a grid VoiceOver cannot describe,
    /// and the kind is the only thing about a file that is knowable without opening it — the list
    /// payload carries no caption, no filename and no duration.
    public static func accessibilityLabel(for kind: LibraryTileKind) -> String {
        switch kind {
        case .image: "Photo"
        case .video: "Video"
        case .document: "File"
        }
    }
}
