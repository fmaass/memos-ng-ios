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
        switch tier {
        case .thumb: attachment.thumbnailURL
        case .mobile: attachment.previewURL
        }
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
