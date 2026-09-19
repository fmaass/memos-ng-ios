import Foundation
import UIKit
import UniformTypeIdentifiers

/// How the one look at a new token's plaintext leaves this screen.
///
/// The Copy button is the only way out of the panel, so this is the one write to answer for. What
/// it puts on the clipboard has a deadline: a full-access token that stays there is pasted into
/// whatever comes next hours later, by somebody who has long forgotten it is still holding one.
///
/// It is deliberately NOT local-only. These tokens are mostly going to a Mac, and a clipboard that
/// stopped at the phone would send people back to reading a token off a screen and typing it in —
/// which is how a secret ends up in a note, a chat message or a screenshot instead.
enum ManageTokensClipboard {
    /// How long a copied token stays on the clipboard: long enough to reach the app or the Mac it
    /// was copied for, short enough that a phone put down on a table is not still holding it.
    static let lifetime: TimeInterval = 180

    /// Hands one secret to the pasteboard write it is given — the system's in the app, a test's in
    /// a test, which is the only place what is written can be read back at all.
    static func copy(
        _ secret: String,
        now: Date = .now,
        write: ([[String: Any]], [UIPasteboard.OptionsKey: Any]) -> Void = {
            UIPasteboard.general.setItems($0, options: $1)
        }
    ) {
        write(
            [[UTType.utf8PlainText.identifier: secret]],
            [.expirationDate: now.addingTimeInterval(lifetime)]
        )
    }
}
