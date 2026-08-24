import Foundation
import MemosCore

/// The tier of a derived rendition to ask the server for.
public enum MediaTier: String, Sendable, Equatable {
    case thumb
    case mobile
}

/// How much of a picture a slot shows, and in what proportions.
///
/// The two surfaces want opposite things and both are right. A timeline is a browse surface: the
/// tiles line up, so they crop. A detail view is the picture itself: nothing may be cut off, so
/// the slot takes the picture's own proportions and the whole frame is shown inside it.
public enum TileContentMode: Equatable, Sendable {
    /// Fill the slot and crop whatever overflows.
    case fill
    /// Show the whole picture inside the slot.
    case fit
}

public struct AttachmentSlot: Equatable, Sendable {
    public var aspectRatio: Double
    public var contentMode: TileContentMode

    public init(aspectRatio: Double, contentMode: TileContentMode) {
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
    }
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

    /// What the full-screen viewer asks for: the largest rendition of this picture that exists.
    ///
    /// The server derives exactly two image tiers — `thumb` (800 px) and `mobile` (2048 px) — and
    /// they are the only ones a client can fetch over a signed URL. `web` is the video mp4, and
    /// the ORIGINAL is never fetched at all: it is the archive master (ADR-0008), a 60 MP HEIC
    /// over a household connection, and nothing on a phone screen is better for having it.
    ///
    /// So the answer is `mobile` wherever a mobile rendition exists, and `thumb` where one does
    /// not — a picture whose 2048 px tier is missing still opens, at the tier it has, rather than
    /// showing a warning triangle in a full-screen black frame.
    public static func fullScreenTier(for attachment: MemoAttachment) -> MediaTier {
        attachment.previewURL == nil ? .thumb : .mobile
    }

    /// The detail view: the whole picture, at the proportions the server measured.
    ///
    /// The ratio comes from the metadata rather than from the decoded image so the container is
    /// the right shape BEFORE anything loads — which is what stops the page jumping as photos
    /// arrive, and what gives the blurhash underneath the identical frame.
    ///
    /// Without measurements there is nothing to derive, and a ratio of zero would be a
    /// zero-height container that renders as nothing at all. 4:3 is the fallback: the commonest
    /// photographic shape, and wrong in a way that letterboxes rather than crops.
    public static func detailSlot(for attachment: MemoAttachment) -> AttachmentSlot {
        AttachmentSlot(
            aspectRatio: attachment.measuredAspectRatio ?? fallbackAspectRatio,
            contentMode: .fit
        )
    }

    /// A memo with one photo on the timeline: the picture's own shape, cropped to fill it.
    public static func timelineSlot(for attachment: MemoAttachment) -> AttachmentSlot {
        AttachmentSlot(aspectRatio: attachment.aspectRatio, contentMode: .fill)
    }

    /// A tile in a row of tiles. Square and cropped, because a row that does not line up is not
    /// a row.
    public static let gridSlot = AttachmentSlot(aspectRatio: 1, contentMode: .fill)

    static let fallbackAspectRatio = 4.0 / 3.0

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
