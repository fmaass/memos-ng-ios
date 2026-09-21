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
    /// be a tap that unexpectedly throws somebody into the household sign-on. It names whose
    /// tokens those turn out to be as well, because that is decided in the browser and the app has
    /// no way to check it against the account it is itself signed in as.
    static let rowCaption =
        "See, create and revoke access tokens. It goes through the browser's sign-in, and it "
        + "manages the account signed in there."
    /// Says the price too, and it has to: a button replaces its children's accessibility, so the
    /// caption below the title reaches nobody using a screen reader. A hint would not do — a hint
    /// is optional and can be switched off, and "this throws you into the household sign-on" is
    /// not optional information about a row somebody is deciding whether to press.
    static let rowLabel =
        "Manage access tokens. It goes through the browser's sign-in, and it manages the account "
        + "signed in there."

    // MARK: - buying a management session

    static let signOnTitle = "Sign in to manage"
    static let signOnLabel = "Sign in again to manage tokens"
    static let signingOn = "Signing in…"

    /// Why the screen is asking for a sign-on rather than showing a list.
    ///
    /// Five different sentences for five different reasons, because they are not the same thing to
    /// the person reading them: one is how the screen opens, one is a deadline that passed, one is
    /// the app having been put away, one is a browser step that never came back, and one is
    /// something that actually went wrong.
    static func lockLine(_ lock: ManageTokensLock) -> String {
        switch lock {
        case .never:
            "Managing tokens goes through the browser's sign-in. What you see and change here "
                + "belongs to the account signed in there, and the app cannot verify that it is "
                + "the same account as its own. It lasts a few minutes and nothing is kept on "
                + "this phone."
        case .expired:
            "That management session has ended - they last a few minutes by design. Sign in again "
                + "to carry on."
        case .discarded:
            "The app was put away, so the management session went with it. Sign in again to carry "
                + "on."
        // Nothing was bought, so nothing is said to have been lost: what ran out is the waiting.
        case .unanswered:
            "That sign-in did not come back within a few minutes, so the app stopped waiting for "
                + "it. Sign in again to carry on."
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

    // MARK: - whose tokens are on the screen

    /// Said above the list and above everything that could change it, because it is a warning
    /// before it is an explanation: the grant this list was read with was bought in the browser,
    /// where a session that is already open answers the sign-in without anybody typing anything,
    /// so the account these tokens belong to is one the app cannot hold against its own.
    static func listedAccountLine(signedInAs name: String) -> String {
        "These tokens belong to the account signed in through the browser. The app is signed in "
            + "as \(name), but cannot verify that these are the same account. If you are unsure "
            + "which account the browser used, close this screen before creating or revoking "
            + "tokens."
    }

    static let empty = "The account signed in through the browser has no access tokens."

    // MARK: - a live session whose list did not arrive

    /// Said when the grant is live and the list is not. What went wrong is in the notice above this
    /// card; what this adds is that the sign-in was not wasted — the other reading, that it was, is
    /// the one that makes somebody close the screen and buy another one.
    static let unlisted =
        "The tokens could not be read. The management session is still live, so the list can be "
        + "asked for again."
    static let rereadTitle = "Try again"
    static let rereadLabel = "Read the tokens again"

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
        "A new token never expires and opens the memos and files of the account signed in "
        + "through the browser to whoever holds it. Creating tokens and managing other tokens "
        + "require a sign-in in the browser. Revoke it here when it is no longer needed."

    /// Whether Create is there to be pressed, decided from what the screen was given.
    ///
    /// The plaintext panel is part of the answer and not only the store's: while it is up, the
    /// store refuses a create outright, and a control that looked pressable would spend somebody's
    /// tap to be told why it did nothing. The store keeps its own refusal — this is the same rule
    /// said in the one place the screen can say it, not a second copy of the decision.
    static func createIsDisabled(isBusy: Bool, secretShowing: Bool, draft: String) -> Bool {
        isBusy || secretShowing || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Named, because a screen reader reaching a row of identical "Revoke" buttons cannot tell
    /// which token it is about to destroy.
    static func revokeLabel(for name: String) -> String { "Revoke \(name)" }
    static let revokeTitle = "Revoke"
    static let cancelTitle = "Cancel"

    /// Asked before a token goes, and it names the token: the press that answers it is often not
    /// the press that was meant, and this is the last moment at which that can still be said.
    static func revokeQuestion(for name: String) -> String { "Revoke \(name)?" }
    /// Both halves of what a revoke costs, because neither of them is obvious from a list of
    /// names: what the token was doing stops, and nothing brings it back.
    static let revokeWarning =
        "Anything still using this token stops working straight away, and it cannot be undone. A "
        + "device signed in with it has to be signed in again."

    /// The two lines under a token's name. The same arithmetic the device row uses, because it is
    /// the same question about the same kind of row — two answers to "when does this expire" would
    /// be two answers to the same question.
    static func detail(_ token: ManagedToken, now: Date) -> String {
        DeviceTokenPresentation.expiryLine(token.expiresAt, now: now)
            + " · " + DeviceTokenPresentation.lastUsedLine(token.lastUsed, now: now)
    }
}
