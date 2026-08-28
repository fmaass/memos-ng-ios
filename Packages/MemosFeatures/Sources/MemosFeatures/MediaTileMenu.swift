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

    var id: String {
        switch self {
        case .showMemo(let uid): "show-memo:\(uid)"
        case .share(let attachment): "share:\(attachment.uid)"
        case .saveOriginal(let attachment): "save-original:\(attachment.uid)"
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
        }
    }

    var symbol: String {
        switch self {
        case .showMemo: "note.text"
        case .share: "square.and.arrow.up"
        case .saveOriginal: "square.and.arrow.down"
        }
    }
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
    /// picture and a document ARE shared as their own original (`MemoAttachment.file(_:)`), so on
    /// those two rows would fetch the same bytes under two names — a menu that offers the same
    /// thing twice is one nobody can choose from. A clip is where they genuinely part: Share hands
    /// on the derived mp4, this fetches the master beside it.
    ///
    /// It is also LAST because it is the slow one, and the archive master is the reason: it is
    /// megabytes to gigabytes over a household connection.
    static func actions(for attachment: MemoAttachment) -> [MediaTileAction] {
        var actions: [MediaTileAction] = []
        if let uid = attachment.memoUID {
            actions.append(.showMemo(uid: uid))
        }
        let shared = attachment.file(.shared)
        if shared != nil {
            actions.append(.share(attachment))
        }
        let original = attachment.file(.original)
        if original != nil, original != shared {
            actions.append(.saveOriginal(attachment))
        }
        return actions
    }
}
