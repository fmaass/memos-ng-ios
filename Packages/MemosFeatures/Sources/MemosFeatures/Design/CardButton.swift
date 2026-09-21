import MemosCore
import SwiftUI

/// How a control on a card is drawn.
///
/// The red is stated rather than taken from the system's destructive role: inside these hand-built
/// cards a control takes the app's accent, and the one that takes something away must not read
/// like the rest of the screen.
enum CardButtonTone {
    /// The app's accent, which is what a control on a card takes when nothing else is said.
    case regular
    /// The one control on a panel that is the reason the panel is up.
    case prominent
    /// A control that is there to be reached for, not looked at.
    case secondary
    /// A control that takes something away.
    case removing
}

/// A control inside one of the hand-built cards, confined to its own hit target.
///
/// A card is ONE row of a List, and SwiftUI presses a List row's default-styled buttons on a tap
/// anywhere in that row — with several of them in one row, not necessarily the one under the
/// finger. So a tap on a token's name pressed a Revoke that belonged to another token, and a tap
/// on a minted token's plaintext pressed Done and took the one look at it away. An explicit style
/// confines each control to what is drawn for it, whichever way that arbitration goes.
///
/// It is one component rather than a modifier repeated at each call site because six call sites
/// are six chances to forget, and because it gives the gate a single thing to count.
/// `.borderless` rather than `.plain` because `.plain` also drops the control's tint, and on these
/// cards the tint is most of what says what a control does.
struct CardButton: View {
    let title: String
    let tone: CardButtonTone
    let action: () -> Void

    init(_ title: String, tone: CardButtonTone = .regular, action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .tint(tint)
            .fontWeight(tone == .prominent ? .semibold : nil)
    }

    /// `nil` where the control keeps the accent it would have taken anyway, so a tone that says
    /// nothing about colour does not restate the default and freeze it.
    private var tint: Color? {
        switch tone {
        case .regular, .prominent: nil
        case .secondary: .secondary
        case .removing: .red
        }
    }
}

/// The two answers to the question a revoke asks, as a view of their own.
///
/// Standalone rather than written inline in the dialog so that a test can render them and press
/// one: a presented dialog is drawn by the system, outside the hosted view's own tree, and what it
/// does with a press is not something a test in this bundle can watch. Here the press and the
/// token it is about are one value apart, which is the whole of what the dialog adds.
///
/// They carry no style of their own: `.confirmationDialog` lays out and draws its own buttons, so
/// these are not a hit target anybody can miss.
struct RevokeConfirmationButtons: View {
    let token: ManagedToken
    let confirm: (Int) -> Void
    let cancel: () -> Void

    var body: some View {
        Button(ManageTokensPresentation.revokeTitle, role: .destructive) { confirm(token.id) }
        Button(ManageTokensPresentation.cancelTitle, role: .cancel, action: cancel)
    }
}

extension View {
    /// Asks before a token is taken away, and acts only on the token that was asked about.
    ///
    /// The token itself is what is pending, not a flag beside an index: the question, the sentence
    /// it asks and the id that is finally sent all read the same value, so there is no way for the
    /// answer to arrive about a different row than the one the question named.
    func revokeConfirmation(
        item: Binding<ManagedToken?>,
        confirm: @escaping (Int) -> Void
    ) -> some View {
        confirmationDialog(
            item.wrappedValue.map { Text(ManageTokensPresentation.revokeQuestion(for: $0.name)) }
                ?? Text(""),
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { asked in if !asked { item.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: item.wrappedValue
        ) { token in
            RevokeConfirmationButtons(
                token: token,
                confirm: { id in
                    item.wrappedValue = nil
                    confirm(id)
                },
                cancel: { item.wrappedValue = nil }
            )
        } message: { _ in
            Text(ManageTokensPresentation.revokeWarning)
        }
    }
}
