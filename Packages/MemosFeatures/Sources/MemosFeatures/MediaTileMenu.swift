import Foundation
import MemosCore

/// One thing a long press on a library tile — or the viewer's overlay over the same file — offers.
///
/// A value rather than a `Button` written inline in two view bodies, because the two surfaces have
/// to offer the SAME things about the same file: a menu that knows which memo a photo belongs to
/// while the viewer over it does not is the drift this type exists to make impossible. It also
/// makes the one rule that matters assertable — an orphan has no memo to show, so it is offered
/// nothing that pretends otherwise.
enum MediaTileAction: Equatable, Sendable, Identifiable {
    /// Take me to the memo this file was posted on.
    case showMemo(uid: String)
    /// Fetch the file and hand it to the share sheet.
    ///
    /// It carries the attachment rather than a URL, and that is the whole of MEMNG-207 rather than
    /// a tidy-up. This used to carry the file's `webUrl` and give it to SwiftUI's built-in
    /// share-link control, so what a recipient was sent was a signed link into the household
    /// server: good for about two hours, resolvable only from inside the house, and naming that
    /// server out loud. What goes now is the file (`AttachmentRendition.shared`).
    case share(MemoAttachment)
    /// Fetch the file as it was uploaded and hand it to the share sheet.
    ///
    /// It carries the whole attachment rather than a URL because the download needs three things
    /// from it — where the original is, what it is, and what to call it — and a case that carried
    /// only the URL would have the two surfaces reassembling the other two for themselves.
    case saveOriginal(MemoAttachment)
    /// Open the album picker for this picture (MEMNG-805). The viewer's alone: a tile's long press
    /// does not offer it.
    case addToAlbum(uid: String)

    var id: String {
        switch self {
        case .showMemo(let uid): "show-memo:\(uid)"
        case .share(let attachment): "share:\(attachment.uid)"
        case .saveOriginal(let attachment): "save-original:\(attachment.uid)"
        case .addToAlbum(let uid): "add-to-album:\(uid)"
        }
    }

    /// Photos says "Show in All Photos" for the same move — from a picture, to where that picture
    /// lives. Here the place a picture lives is the memo somebody wrote it into.
    var title: String {
        switch self {
        case .showMemo: "Show Memo"
        case .share: "Share"
        // Named for what arrives, not for the sheet that follows it. It is only ever shown beside
        // a Share that sends something else — a clip's derived mp4 — so this name is the whole
        // difference between the two rows.
        case .saveOriginal: "Save Original"
        case .addToAlbum: AlbumPicker.title
        }
    }

    var symbol: String {
        switch self {
        case .showMemo: "note.text"
        case .share: "square.and.arrow.up"
        case .saveOriginal: "square.and.arrow.down"
        case .addToAlbum: "rectangle.stack.badge.plus"
        }
    }
}

/// The SHAPE of the control a surface draws over one file's actions.
///
/// A three-dots menu is an indirection, and an indirection over a single row buys nothing: it hides
/// that row's name behind a glyph meaning "something", and charges a tap to find out what. So the
/// control follows the list — one action is drawn as ITSELF, with its own icon and its own tap, and
/// the menu comes back the moment there is a choice to make (MEMNG-213). Settings made the same
/// move when its menu of one became a gear.
///
/// A value rather than a count read in a view body, for the reason `MediaTileAction` is one: the
/// surfaces that offer these actions must agree about them, and "how many is one" is exactly the
/// kind of decision that gets written twice and then diverges.
enum MediaActionControl: Equatable, Sendable {
    /// Nothing can be done with this file: no control at all. A button that opens an empty menu is
    /// worse than no button.
    case hidden
    /// Exactly one thing can be done: that action IS the control.
    case direct(MediaTileAction)
    /// Two or more, in the order `actions(for:)` returned them.
    case menu([MediaTileAction])
}

/// What the menu over a library file contains.
enum MediaTileMenu {
    /// The actions for one file, in the order they are shown.
    ///
    /// SHORT on purpose. A context menu that lists everything is a menu nobody reads, and a
    /// context menu is never the only way to do any of this — the tap opens the file, the viewer
    /// carries the same two actions, and neither of them is hidden behind a gesture nobody is told
    /// about. Nothing here is destructive, so nothing here is last for that reason.
    ///
    /// Files get fewer than three, and none of the absences is an error. An ORPHAN (an upload no
    /// memo references — a row this library deliberately includes) has no memo to be shown. A
    /// payload naming no original names nothing this app can hand anybody, so it is offered no
    /// Share either: since MEMNG-207 that action fetches a file, and an action that would download
    /// nothing is worse than no action.
    ///
    /// `Save Original` appears only where it is a DIFFERENT file from the one Share sends. A
    /// document IS shared as its own original (`MemoAttachment.file(_:)`), so there the two rows
    /// would fetch the same bytes under two names — a menu that offers the same thing twice is one
    /// nobody can choose from. A picture and a clip are where they genuinely part: Share hands on
    /// the mobile JPEG or the mp4 (MEMNG-874), this fetches the master beside it, and it is the
    /// only way to that master.
    ///
    /// It is also LAST because it is the slow one, and the archive master is the reason: it is
    /// megabytes to gigabytes over a household connection.
    ///
    /// Naming a file is not the same as having one, which is the other absence here: a row is
    /// offered only for a file the server is already holding (`heldFile(_:of:)`). So a clip still
    /// being transcoded is offered its master and no Share, and nothing here decides that by
    /// disabling a row — an action that cannot work is not shown, exactly as an action with
    /// nothing to fetch is not (MEMNG-209).
    static func actions(for attachment: MemoAttachment) -> [MediaTileAction] {
        var actions: [MediaTileAction] = []
        if let uid = attachment.memoUID {
            actions.append(.showMemo(uid: uid))
        }
        if heldFile(.shared, of: attachment) != nil {
            actions.append(.share(attachment))
        }
        // Compared against the file Share NAMES rather than the one it can hand over: a clip whose
        // mp4 is still being made offers no Share, and its master is still a different file — and
        // then the only thing left that can be done with it.
        if let master = heldFile(.original, of: attachment), master != attachment.file(.shared) {
            actions.append(.saveOriginal(attachment))
        }
        return actions
    }

    /// How this file's actions are offered: as nothing, as the one action itself, or as the menu.
    ///
    /// The list and its shape are decided in one place so a surface cannot draw a menu over a list
    /// this rule calls single, or the reverse.
    static func control(for attachment: MemoAttachment) -> MediaActionControl {
        control(of: actions(for: attachment))
    }

    /// The same rule over a list already in hand, which is what makes it assertable without an
    /// attachment standing behind every case.
    static func control(of actions: [MediaTileAction]) -> MediaActionControl {
        switch actions.count {
        case 0: .hidden
        case 1: .direct(actions[0])
        default: .menu(actions)
        }
    }

    /// The file a row would hand over, but only when the server is actually HOLDING it.
    ///
    /// Every payload names all four derived tiers whether the file behind one exists or not
    /// (memos-ng `app/services/asset_urls.py` signs the set from the uid alone), so a derived URL
    /// is a promise about a file the worker may not have made yet. Since MEMNG-207 Share fetches
    /// that file, so a clip still being transcoded offered a download that 404s into the error
    /// alert — beside a tile that was visibly still waiting (MEMNG-209).
    ///
    /// The two kinds of file become real at different moments, which is why this is not one
    /// question. A DERIVED tier exists only once the server says it is finished, so it is gated on
    /// `readiness`. The ARCHIVE MASTER is written by the upload itself, before the worker starts —
    /// memos-ng leaves an attachment `uploading` until its bytes land and moves it to
    /// `pending`/`processing` afterwards (`app/services/uploads.py`) — so it is gated on the one
    /// status that means no bytes at all. Gating the master on readiness too would take an action
    /// away from a file sitting right there: a photograph is handed on as its own master, and its
    /// Share has to survive the seconds its tiers are being made.
    ///
    /// It is what the menu is built from, not what makes the fetch safe: a tap that somehow
    /// arrives anyway fails the way it always did, in `OriginalMedia.fetch`, into the message the
    /// sheet already shows. This decides what is OFFERED.
    static func heldFile(
        _ rendition: AttachmentRendition,
        of attachment: MemoAttachment
    ) -> AttachmentFile? {
        guard let file = attachment.file(rendition) else { return nil }
        // The master, whichever rendition asked for it: `shared` IS the original for a document
        // and for a clip whose mp4 is not made yet.
        if file == attachment.file(.original) {
            return attachment.status == .uploading ? nil : file
        }
        return attachment.readiness == .ready ? file : nil
    }
}

extension MediaTileMenu {
    /// The viewer's ⋯ rows: the tile's list less Share, which the viewer's bar holds instead
    /// (`MediaViewerBar`), and Add to Album after Show Memo where the viewer can add (`albums`) and
    /// the picture hangs on a memo — one on none cannot be an album's member (MEMNG-805). The
    /// tile's own list is unchanged.
    ///
    /// A memo's own pictures name no memo (`MemoAttachment(_:baseURL:)`), which is what keeps Show
    /// Memo off the screen it would only lead back to; `inMemo` is the viewer saying it was opened
    /// over the memo that holds this picture, so it hangs on one all the same (MEMNG-930).
    ///
    /// `showsMemo` false takes Show Memo off a page that names its memo all the same: a guest
    /// memo's, which the Timeline the jump lands on never holds (MEMNG-1263).
    static func viewerActions(
        for attachment: MemoAttachment, albums: Bool = false, inMemo: Bool = false,
        showsMemo: Bool = true
    ) -> [MediaTileAction] {
        var rows = actions(for: attachment).filter { action in
            switch action {
            case .share: return false
            case .showMemo: return showsMemo
            default: return true
            }
        }
        if albums, inMemo || attachment.memoUID != nil {
            let after = rows.firstIndex { if case .showMemo = $0 { true } else { false } }
            rows.insert(.addToAlbum(uid: attachment.uid), at: after.map { $0 + 1 } ?? 0)
        }
        return rows
    }

    /// The viewer's top-right control: ALWAYS the ⋯ menu when there is anything in it, even one
    /// row — the viewer's top row is close, date, ⋯, and a lone action drawn as its own glyph would
    /// break that row's shape. The tile's direct-versus-menu rule (`control(of:)`, MEMNG-213) is
    /// the tile's and stays as it is.
    static func viewerControl(
        for attachment: MemoAttachment, albums: Bool = false, inMemo: Bool = false,
        showsMemo: Bool = true
    ) -> MediaActionControl {
        let actions = viewerActions(
            for: attachment, albums: albums, inMemo: inMemo, showsMemo: showsMemo)
        return actions.isEmpty ? .hidden : .menu(actions)
    }

    /// Whether the bar's Share has a file to hand over — the same rule the tile's Share row is
    /// offered under.
    static func canShare(_ attachment: MemoAttachment) -> Bool {
        heldFile(.shared, of: attachment) != nil
    }
}
