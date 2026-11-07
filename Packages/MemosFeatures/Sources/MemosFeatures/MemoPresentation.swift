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

    /// A memo with ONE photo on the timeline: the picture's own shape, whole.
    ///
    /// A lone photo reads as a photo rather than as a tile, so nothing is cut off it — the card
    /// takes the shape the server measured and the card's own height cap is what stops a very tall
    /// one from taking the whole screen (it narrows instead of losing its top and bottom).
    ///
    /// An UNMEASURED one is the exception, and the same exception the web app makes: there is no
    /// shape to take, so it goes in a 4:3 box and crops into it. Guessing "square" for a photo
    /// nobody measured would be a shape invented by the client.
    public static func soloSlot(for attachment: MemoAttachment) -> AttachmentSlot {
        guard let ratio = attachment.measuredAspectRatio else {
            return AttachmentSlot(aspectRatio: fallbackAspectRatio, contentMode: .fill)
        }
        return AttachmentSlot(aspectRatio: ratio, contentMode: .fit)
    }

    /// A photo in a justified row: its own proportions, because that is what the row solver
    /// allotted it. `fill` rather than `fit` only so a rounded fraction of a point cannot leave a
    /// hairline of blur down one edge — the box IS the picture's shape, so nothing is cropped.
    public static func justifiedSlot(for attachment: MemoAttachment) -> AttachmentSlot {
        AttachmentSlot(aspectRatio: attachment.aspectRatio, contentMode: .fill)
    }

    /// A tile in a row of tiles. Square and cropped, because a row that does not line up is not
    /// a row. This is the two-up, which is the one arrangement that still crops.
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

/// What the memo's screen offers on ONE of its pictures.
///
/// A list rather than a Boolean, and rendered from rather than mirrored by the view: an affordance
/// that exists only inside a `contextMenu` body is one no test can miss the absence of. It is also
/// where a "Move Left"/"Move Right" would join if reordering is ever funded, which is why the
/// shape is a list of one and not a lone `canDelete`.
public enum AttachmentAction: String, Equatable, Sendable, Identifiable, CaseIterable {
    case delete

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .delete: "trash"
        }
    }

    /// Whether the row is drawn as dangerous — and, with it, whether it belongs at the END of the
    /// menu (HIG: a destructive action is last, away from the finger's resting place).
    public var isDestructive: Bool {
        switch self {
        case .delete: true
        }
    }

    /// What the row says, which depends on what the file IS: "Delete Photo" over a picture and
    /// "Delete Video" over a clip. The wording lives with the flow that owns the whole
    /// conversation, so the row and the alert cannot come to call one file two things.
    public func title(for attachment: MemoAttachment) -> String {
        switch self {
        case .delete: AttachmentDeleteFlow.title(for: attachment)
        }
    }
}

/// What the memo DETAIL screen offers on a memo, decided outside the view.
///
/// Editing used to live only in the timeline card's context menu — a long press on a card, with
/// nothing on the memo's own screen to say it was possible. People opened a memo to change it and
/// found no way to, which is not a discoverability nicety: it is the feature being missing for
/// anyone who did not already know the gesture.
public enum MemoDetailPresentation {
    /// The compose mode the Edit affordance opens, or nil when this memo is not mine.
    ///
    /// Returning the MODE rather than a Bool is what keeps the gate and the payload together: a
    /// view that asked "may I edit?" and then built the mode itself could answer yes and open the
    /// wrong memo. It is nil-gated on `mine` for the same reason every other own-memo action is —
    /// the server would refuse the write, and an affordance that leads to a 403 is worse than none.
    ///
    /// A guest memo opens for every signed-in member (MEMNG-1264): the pass's issuer owns it, but a
    /// guest has no account, so the household edits it in their stead and the server allows that.
    public static func editMode(for memo: Memo) -> ComposeView.Mode? {
        guard memo.mine || memo.guest != nil else { return nil }
        return .edit(
            uid: memo.uid,
            content: memo.content,
            createdAt: memo.createdAt,
            attachments: memo.attachments,
            visibility: memo.visibility
        )
    }

    /// What is left of the memo's own screen once its editor has closed.
    public enum EditorExit: Equatable, Sendable {
        /// The memo is gone from the server, so the screen it was open on goes with it. A detail
        /// view of a memo that no longer exists is a screen showing a lie.
        case popToOverview
        /// Every other way an editor closes — saved, cancelled, a delete that failed — leaves
        /// the memo where it was, and its screen with it.
        case stay
    }

    /// Whether the memo's screen goes now. BOTH halves, because either one alone is a bug that
    /// has actually happened.
    ///
    /// On `memoDeleted` alone, the pop is asked for while the sheet is still on its way out, and a
    /// `dismiss()` issued by a view that is still presenting a sheet is spent on the sheet — the
    /// editor closed and the detail view of the deleted memo stayed (build 4). On `sheetClosed`
    /// alone, somebody who swipes the editor away while the delete is still in flight is never
    /// asked again: the server answers to a closed sheet, and the screen stays on the memo it has
    /// just deleted. So the screen goes on whichever of the two arrives second, and only then.
    public static func popDecision(memoDeleted: Bool, sheetClosed: Bool) -> EditorExit {
        memoDeleted && sheetClosed ? .popToOverview : .stay
    }

    /// The archive affordance a memo's screen offers: what it will ask the server for, and what it
    /// says.
    ///
    /// One action with a direction rather than two, because on the wire it IS one call — `archived`
    /// is a boolean on the patch. The direction is derived from the memo, so a screen cannot offer
    /// "Archive" on something already archived.
    public struct MemoArchiveAction: Equatable, Sendable {
        /// The state being asked for, which is always the opposite of the memo's own.
        public let archived: Bool
        public let title: String
        public let symbol: String
    }

    /// What the archive control on this memo's screen does, or nil when there is no such control.
    ///
    /// Nil-gated on `mine` exactly as `editMode` is, and for the same reason: the server refuses
    /// the write on somebody else's memo, and an affordance that leads to a 403 is worse than
    /// none at all.
    public static func archiveAction(for memo: Memo) -> MemoArchiveAction? {
        guard memo.mine else { return nil }
        return memo.isArchived
            ? MemoArchiveAction(
                archived: false, title: "Restore memo", symbol: "arrow.uturn.backward"
            )
            : MemoArchiveAction(archived: true, title: "Archive memo", symbol: "archivebox")
    }

    /// What can be done to one of this memo's pictures from the screen it is on.
    ///
    /// Nil-gated on `mine` exactly as `editMode` and `archiveAction` are, and for the same reason:
    /// the server refuses the delete on somebody else's attachment, and an affordance that leads to
    /// a 403 is worse than none at all. `MemoAttachment` carries no ownership of its own — the memo
    /// is what owns the file — so the memo is what the gate reads.
    ///
    /// Destructive last, always. It is the only entry today, so the ORDER is what a test can hold
    /// before there is a second one to hold it against.
    /// A guest memo's pictures are removable by every member, as `editMode` says why.
    public static func attachmentActions(for memo: Memo) -> [AttachmentAction] {
        guard memo.mine || memo.guest != nil else { return [] }
        return AttachmentAction.allCases.filter { !$0.isDestructive }
            + AttachmentAction.allCases.filter(\.isDestructive)
    }

    /// Whether a memo's edit offers to add pictures: never to a guest memo, whose pictures are the
    /// guest's to send (owner, 2026-11-06, MEMNG-1264); removing them stays.
    public static func addsMedia(to memo: Memo) -> Bool {
        memo.guest == nil
    }

    /// The date an edit actually SENDS: only one the editor moved.
    ///
    /// An untouched date would be a rewrite of the memo's own value dressed up as an edit. It is a
    /// function rather than a line inside a submit closure because there are now two screens that
    /// submit an edit, and the rule has to be the same one on both.
    public static func editedDate(chosen: Date?, original: Date) -> Date? {
        chosen == original ? nil : chosen
    }
}
