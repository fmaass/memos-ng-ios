import CoreGraphics
import Foundation
import MemosCore

/// What a page of the viewer is showing. A video page shows its poster and plays on tap; an image
/// page is the picture itself. The distinction is a decision the projection makes once, rather
/// than a `mime.hasPrefix` scattered through a view body.
public enum MediaKind: Equatable, Sendable {
    case image
    case video
}

/// One swipeable page of the full-screen viewer.
///
/// `position`/`total` are carried rather than derived at the call site because they are what the
/// page SAYS to a screen reader ("Photo 2 of 5"), and a label that counts differently from the
/// order the pages are in is worse than no label.
public struct MediaPage: Identifiable, Equatable, Sendable {
    public let attachment: MemoAttachment
    public let kind: MediaKind
    /// The still to show: the full-screen tier for a picture, the poster for a video.
    public let stillURL: URL?
    /// The streamable rendition, for a video page only — never the original (ADR-0008).
    public let playbackURL: URL?
    /// 1-based, for what the page says out loud.
    public let position: Int
    public let total: Int

    public var id: String { attachment.uid }
    public var blurhash: String? { attachment.blurhash }

    /// The proportions to lay the picture out in before it arrives — the same measured-or-4:3
    /// decision the detail view makes, so a photo does not change shape on its way to full screen.
    public var aspectRatio: Double { MemoPresentation.detailSlot(for: attachment).aspectRatio }

    public var accessibilityLabel: String {
        let noun = kind == .video ? "Video" : "Photo"
        return "\(noun) \(position) of \(total)"
    }
}

/// A viewer opened at one page of a memo's media.
///
/// The start index is part of the value rather than something the view figures out: the page that
/// was TAPPED is what the zoom transition animates from, and a viewer that opens on a different
/// picture than the one under the finger is the bug this type exists to make impossible.
public struct MediaViewerSelection: Identifiable, Equatable, Sendable {
    public let pages: [MediaPage]
    public let startIndex: Int

    /// Non-empty pages and an in-range start index are the invariant; the only way to build one is
    /// `MediaViewerPresentation.viewer(for:startingAt:)`, which enforces both.
    init(pages: [MediaPage], startIndex: Int) {
        self.pages = pages
        self.startIndex = min(max(0, startIndex), max(0, pages.count - 1))
    }

    public var startPage: MediaPage { pages[startIndex] }
    /// Identity for `fullScreenCover(item:)` AND the id the zoom transition matches on.
    public var id: String { startPage.id }
}

/// Which of a memo's attachments the viewer can show, in what order, and at which rendition.
///
/// All of it is pure so the two surfaces that open the viewer (a timeline tile, a picture on the
/// detail view) provably open the SAME thing, and so "never the original" is an assertion rather
/// than a habit.
public enum MediaViewerPresentation {
    /// The memo's media, as pages.
    ///
    /// Only pictures and videos are pages: a memo can carry any upload the server accepted, and a
    /// PDF in the swipe order is a black rectangle nobody can leave. An attachment with neither a
    /// still nor a stream is dropped for the same reason — a page that can render nothing at all
    /// is a gap in the count, not a picture.
    public static func pages(for attachments: [MemoAttachment]) -> [MediaPage] {
        let viewable = attachments.filter { isViewable($0) }
        return viewable.enumerated().map { index, attachment in
            MediaPage(
                attachment: attachment,
                kind: attachment.isVideo ? .video : .image,
                stillURL: fullScreenStillURL(for: attachment),
                playbackURL: MemoPresentation.playbackURL(for: attachment),
                position: index + 1,
                total: viewable.count
            )
        }
    }

    /// The viewer for a memo, opened at the attachment that was tapped.
    ///
    /// `nil` means "there is nothing to open" — a tapped attachment that is not viewable, or a
    /// memo with no viewable media at all. The caller decides what to do instead; silently opening
    /// page 1 of something else would be worse than doing nothing.
    public static func viewer(for memo: Memo, startingAt uid: String) -> MediaViewerSelection? {
        viewer(for: memo.attachments, startingAt: uid)
    }

    public static func viewer(
        for attachments: [MemoAttachment],
        startingAt uid: String
    ) -> MediaViewerSelection? {
        let pages = pages(for: attachments)
        guard let index = pages.firstIndex(where: { $0.id == uid }) else { return nil }
        return MediaViewerSelection(pages: pages, startIndex: index)
    }

    /// A picture or a video with something to render.
    static func isViewable(_ attachment: MemoAttachment) -> Bool {
        guard attachment.isVideo || attachment.mime.hasPrefix("image/") else { return false }
        return fullScreenStillURL(for: attachment) != nil
            || MemoPresentation.playbackURL(for: attachment) != nil
    }

    static func fullScreenStillURL(for attachment: MemoAttachment) -> URL? {
        let tier = MemoPresentation.fullScreenTier(for: attachment)
        return MemoPresentation.url(for: attachment, tier: tier)
    }
}
