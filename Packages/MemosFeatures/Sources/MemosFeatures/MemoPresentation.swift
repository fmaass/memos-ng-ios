import Foundation
import MemosCore

/// The tier of a derived rendition to ask the server for.
public enum MediaTier: String, Sendable, Equatable {
    case thumb
    case mobile
}

/// Decisions a view needs, kept out of the view.
///
/// A SwiftUI body is the worst place to unit-test anything, so everything here is a pure function
/// with its own vectors and the views just call them.
public enum MemoPresentation {
    /// Which rendition a slot of this size needs. `thumb` is the grid tier; anything wider is the
    /// one-up tier. Deliberately conservative — asking for `mobile` in a grid is how a timeline
    /// starts pulling megabytes per row.
    public static func tier(forPointWidth width: Double, scale: Double = 2) -> MediaTier {
        width * scale <= 320 ? .thumb : .mobile
    }

    public static func url(for attachment: MemoAttachment, tier: MediaTier) -> URL? {
        // A video has no image tiers — its still is the poster (the same hero frame the mail
        // digests use). Asking a video for `thumb` is how the timeline got warning triangles.
        if attachment.isVideo {
            return attachment.posterURL ?? attachment.thumbnailURL
        }
        switch tier {
        case .thumb: return attachment.thumbnailURL
        case .mobile: return attachment.previewURL
        }
    }

    /// What actually plays on tap: the derived, streamable rendition — never the original
    /// (ADR-0008: originals are the archive master, screens get the light copies).
    public static func playbackURL(for attachment: MemoAttachment) -> URL? {
        guard attachment.isVideo else { return nil }
        return attachment.webURL
    }

    /// A memo with no rendered body is not blank on screen — the tags still describe it.
    public static func hasRenderableBody(_ content: String) -> Bool {
        !MemoMarkdownSource.prepare(content).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The read-only task rows of a memo, in rendered order — the same enumeration the toggle
    /// indexes into, so row N on screen is task N in the source.
    public static func tasks(in content: String) -> [(text: String, checked: Bool)] {
        taskCheckboxItems(content)
    }
}
