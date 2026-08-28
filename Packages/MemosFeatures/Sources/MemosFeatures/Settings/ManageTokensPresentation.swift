import Foundation
import MemosCore

/// What the token-management screen says, decided in pure functions the screen only reads.
///
/// Every sentence here is load-bearing in a way most UI copy is not. This screen hands somebody a
/// secret they will only ever see once, ends its own session after a few minutes, and can be
/// opened against a server that does not offer it yet — and each of those has to arrive as a
/// sentence that is TRUE, because the alternative is a person who thinks they still have a token
/// they do not have, or who is looking at a spinner that is never going to stop.
enum ManageTokensPresentation {
    static let title = "Manage tokens"

    // MARK: - the Settings row that opens it

    static let rowTitle = "Manage tokens"
    /// Says the price up front. Opening this costs a sign-in, and a row that did not say so would
    /// be a tap that unexpectedly throws somebody into the household sign-on.
    static let rowCaption =
        "See, create and revoke this account's access tokens. It needs a fresh sign-in."
    /// Says the price too, and it has to: a button replaces its children's accessibility, so the
    /// caption below the title reaches nobody using a screen reader. A hint would not do — a hint
    /// is optional and can be switched off, and "this throws you into the household sign-on" is
    /// not optional information about a row somebody is deciding whether to press.
    static let rowLabel =
        "Manage this account's access tokens. It needs a fresh sign-in."

    // MARK: - buying a management session

    static let signOnTitle = "Sign in to manage"
    static let signOnLabel = "Sign in again to manage this account's tokens"
    static let signingOn = "Signing in…"

    /// Why the screen is asking for a sign-on rather than showing a list.
    ///
    /// Four different sentences for four different reasons, because they are not the same thing to
    /// the person reading them: one is how the screen opens, one is a deadline that passed, one is
    /// the app having been put away, and one is something that actually went wrong.
    static func lockLine(_ lock: ManageTokensLock) -> String {
        switch lock {
        case .never:
            "Managing tokens needs a fresh sign-in. It lasts a few minutes and nothing is kept on "
                + "this phone."
        case .expired:
            "That management session has ended - they last a few minutes by design. Sign in again "
                + "to carry on."
        case .discarded:
            "The app was put away, so the management session went with it. Sign in again to carry "
                + "on."
        // Falls back to the opening line rather than to silence: `alreadySigningIn` is the one
        // outcome with nothing to say, and it means a sign-on is on screen right now.
        case .refused(let error): error.message ?? lockLine(.never)
        }
    }

    /// A server that has not caught up with this build. Not an error, and deliberately not worded
    /// as one — the app can ship before the deploy, and this screen must never be what breaks.
    static let unsupported =
        "This server does not offer token management to the app yet. Nothing is wrong with your "
        + "sign-in; the account's tokens can still be managed in the web app."

    static let empty = "This account has no access tokens."

    // MARK: - the one look anybody gets at a new token

    static let secretHeading = "New token"
    /// The sentence this whole panel exists for. The plaintext is in exactly one response from the
    /// server and is stored nowhere afterwards, so somebody who closes this without copying it has
    /// a token they can use from nothing but this screen — which is gone.
    static let secretCaption =
        "This is the only time this token is shown. Copy it now - it cannot be shown again."
    static let copyTitle = "Copy"
    static let copyLabel = "Copy the new token"
    static let doneTitle = "Done"
    static let doneLabel = "Hide the new token"

    /// What is said when the text went away without anybody putting it away — the app was
    /// backgrounded, or the management session ran out while the panel was still up. The token is
    /// recoverable and its text is not, and both halves of that are said.
    static let secretLost =
        "The new token's text is gone - it is shown once and only once. The token itself still "
        + "works: sign in again to find it in the list, and revoke it if you did not copy it."

    // MARK: - creating and revoking

    static let nameFieldTitle = "Name"
    static let createTitle = "Create token"
    static let createLabel = "Create a token with this name"
    static let createCaption =
        "A new token never expires and can do everything this account can. Revoke it here when it "
        + "is no longer needed."

    /// Named, because a screen reader reaching a row of identical "Revoke" buttons cannot tell
    /// which token it is about to destroy.
    static func revokeLabel(for name: String) -> String { "Revoke \(name)" }
    static let revokeTitle = "Revoke"

    /// The two lines under a token's name. The same arithmetic the device row uses, because it is
    /// the same question about the same kind of row — two answers to "when does this expire" would
    /// be two answers to the same question.
    static func detail(_ token: ManagedToken, now: Date) -> String {
        DeviceTokenPresentation.expiryLine(token.expiresAt, now: now)
            + " · " + DeviceTokenPresentation.lastUsedLine(token.lastUsed, now: now)
    }
}
