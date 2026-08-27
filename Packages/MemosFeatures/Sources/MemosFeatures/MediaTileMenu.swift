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
    /// The system share sheet, over the file's own URL.
    case share(URL)

    var id: String {
        switch self {
        case .showMemo(let uid): "show-memo:\(uid)"
        case .share(let url): "share:\(url.absoluteString)"
        }
    }

    /// Photos says "Show in All Photos" for the same move — from a picture, to where that picture
    /// lives. Here the place a picture lives is the memo somebody wrote it into.
    var title: String {
        switch self {
        case .showMemo: "Show Memo"
        case .share: "Share"
        }
    }

    var symbol: String {
        switch self {
        case .showMemo: "note.text"
        case .share: "square.and.arrow.up"
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
    /// Two files get fewer than two: an ORPHAN (an upload no memo references — a row this library
    /// deliberately includes) has no memo to be shown, and a file whose canonical URL never
    /// resolved has nothing to share. Neither is an error, and neither gets an action that would
    /// do nothing.
    static func actions(for attachment: MemoAttachment) -> [MediaTileAction] {
        var actions: [MediaTileAction] = []
        if let uid = attachment.memoUID {
            actions.append(.showMemo(uid: uid))
        }
        if let url = attachment.webURL {
            actions.append(.share(url))
        }
        return actions
    }
}
