import SwiftUI

/// Signing out, at the bottom of the account sheet and nowhere else.
///
/// MEMNG-185. It sat in the Account section at the TOP and in the toolbar's account menu, so the
/// first thing the screen offered — and one of the two things the menu did — was the one action
/// that ends the session. It is a rare, deliberate act and it now reads as one: last on the
/// screen, a plain word rather than a labelled button, and no heading over it.
///
/// A view of its own, holding the conversation and the session rather than a closure handed down
/// from the sheet, so the tap and what the tap does are both inside something a test can put on a
/// screen and press without a session (`SignOutSectionTests`). Moved here from the Settings screen
/// when the chrome trim (2026-10-10) deleted it; the account sheet draws it last.
///
/// The red is stated rather than left to the destructive role: these cards are hand-built rather
/// than system list rows, and inside them a button takes the app's accent — the green the whole
/// app is drawn in. The one control here that takes something away must not read like the rest.
struct SignOutSection: View {
    let conversation: SignOutConversation
    let session: any SignOutRevoking

    var body: some View {
        Button(role: .destructive) {
            conversation.send(.requested, to: session)
        } label: {
            Text("Sign out")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
