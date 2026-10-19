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
/// It carries no position and no total, and that is a decision rather than an omission (MEMNG-189).
/// The library's viewer pages over a list that GROWS as it is swiped, so any count printed on a
/// page would be a count of what happened to be loaded — "3 of 60" over a library of 1,314 files.
/// Photos, Google Photos and Immich all show nothing at all for the same reason, and none of them
/// is worse for it: the swipe itself is what says where you are.
public struct MediaPage: Identifiable, Equatable, Sendable {
    public let attachment: MemoAttachment
    public let kind: MediaKind
    /// The tier `stillURL` was taken at.
    ///
    /// Carried rather than recomputed where it is needed, because the decoded picture is filed
    /// under `(uid, tier)` and nothing else: a key naming a tier the bytes did not come from
    /// would file one rendition under another's name, and the two are only provably the same
    /// tier if one value produces both.
    public let stillTier: MediaTier
    /// The still to show: the full-screen tier for a picture, the poster for a video.
    public let stillURL: URL?
    /// The streamable rendition, for a video page only — never the original (ADR-0008).
    public let playbackURL: URL?
    /// The DISPLAY date the list this page came from answered for it — the library's and the
    /// map's `takenAt`: when the picture was taken if the file says so, else its memo's date, else
    /// its upload. Nil for a memo's own page, whose list answers no such thing.
    ///
    /// Never capture metadata, and never read as such: the Info sheet's Taken row reads the
    /// attachment's capture fields alone. It is the first answer the date capsule takes.
    public var takenAt: Date? = nil

    public var id: String { attachment.uid }
    /// The memo this page's file belongs to, when there is one — what puts "Show Memo" in the
    /// viewer's overlay, and what leaves it off an orphan.
    public var memoUID: String? { attachment.memoUID }
    public var blurhash: String? { attachment.blurhash }

    /// What the decoded still is filed under — the same `(uid, tier)` key the timeline tiles use,
    /// so a photo opened full screen at a tier the feed has already loaded is painted out of
    /// memory rather than fetched a second time.
    public var stillKey: MediaImageKey {
        MediaImageKey(uid: attachment.uid, tier: stillTier.rawValue)
    }

    /// The proportions to lay the picture out in before it arrives — the same measured-or-4:3
    /// decision the detail view makes, so a photo does not change shape on its way to full screen.
    public var aspectRatio: Double { MemoPresentation.detailSlot(for: attachment).aspectRatio }

    /// What the page says out loud. The KIND and nothing else: a count read from a list that is
    /// still being paged would be read out wrong, and hearing "photo 3 of 60" in a library of
    /// thousands is worse than hearing "photo".
    public var accessibilityLabel: String {
        kind == .video ? "Video" : "Photo"
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
    /// Whether these pictures may be REMOVED from where they are being looked at.
    ///
    /// It rides on the selection rather than on the viewer because the answer is a fact about where
    /// the pages came from, and the viewer serves two places that differ in exactly that: a memo of
    /// mine, whose attachments the server will let me delete, and the media library, which is a
    /// read surface over files that may belong to anybody. Defaulted to false so the capability is
    /// something a caller has to ASK for — a new surface that forgets to think about it gets the
    /// safe answer.
    public let deletable: Bool

    /// Non-empty pages and an in-range start index are the invariant; the only way to build one is
    /// `MediaViewerPresentation.viewer(for:startingAt:)`, which enforces both.
    init(pages: [MediaPage], startIndex: Int, deletable: Bool = false) {
        self.pages = pages
        self.startIndex = min(max(0, startIndex), max(0, pages.count - 1))
        self.deletable = deletable
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
    public static func pages(
        for attachments: [MemoAttachment],
        takenAt: (MemoAttachment) -> Date? = { _ in nil }
    ) -> [MediaPage] {
        attachments.filter { isViewable($0) }.map { attachment in
            let tier = MemoPresentation.fullScreenTier(for: attachment)
            return MediaPage(
                attachment: attachment,
                kind: attachment.isVideo ? .video : .image,
                stillTier: tier,
                stillURL: MemoPresentation.url(for: attachment, tier: tier),
                playbackURL: MemoPresentation.playbackURL(for: attachment),
                takenAt: takenAt(attachment)
            )
        }
    }

    /// The viewer for a memo, opened at the attachment that was tapped.
    ///
    /// `nil` means "there is nothing to open" — a tapped attachment that is not viewable, or a
    /// memo with no viewable media at all. The caller decides what to do instead; silently opening
    /// page 1 of something else would be worse than doing nothing.
    /// A memo's own viewer, which carries the delete capability when the memo is mine — the same
    /// `mine` gate every other own-memo affordance is nil-gated on, because the server refuses the
    /// delete on somebody else's file.
    public static func viewer(for memo: Memo, startingAt uid: String) -> MediaViewerSelection? {
        viewer(for: memo.attachments, startingAt: uid, deletable: memo.mine)
    }

    /// The list overload, which the media library uses. It defaults to NOT deletable: a row there
    /// is an upload with no memo in hand, so nothing on that screen knows whose it is.
    public static func viewer(
        for attachments: [MemoAttachment],
        startingAt uid: String,
        deletable: Bool = false,
        takenAt: (MemoAttachment) -> Date? = { _ in nil }
    ) -> MediaViewerSelection? {
        let pages = pages(for: attachments, takenAt: takenAt)
        guard let index = pages.firstIndex(where: { $0.id == uid }) else { return nil }
        return MediaViewerSelection(pages: pages, startIndex: index, deletable: deletable)
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

extension MediaViewerPresentation {
    /// The library's rows as pages: each row's own `takenAt` rides on its page, and its
    /// attachment keeps its capture fields exactly as the list sent them.
    static func pages(for rows: [LibraryRow]) -> [MediaPage] {
        let taken = Dictionary(
            rows.map { ($0.attachment.uid, $0.takenAt) }, uniquingKeysWith: { first, _ in first })
        return pages(for: rows.map(\.attachment), takenAt: { taken[$0.uid] ?? nil })
    }
}
