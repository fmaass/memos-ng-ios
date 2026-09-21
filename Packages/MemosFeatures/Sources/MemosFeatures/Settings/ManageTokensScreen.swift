import MemosCore
import SwiftUI

/// Token management itself: everything the screen can show, as a function of what it is given.
///
/// Nothing here reaches for a store, a session or a clock. The screen has four quite different
/// things to draw — a prompt to sign in, a list, a secret shown once, and a server that does not
/// offer this yet — and every one of them is a state a test can hand it, which is the only way the
/// honest-degradation cases can be checked at all: a server without these routes cannot be
/// arranged by rendering a real screen against a real server.
struct ManageTokensScreen: View {
    let state: ManageTokensState
    /// What the APP's own account is called, which is the only half of the comparison this screen
    /// can make: the list it draws was read with a grant the browser issued, and nothing in that
    /// answer says which account it belongs to.
    let appAccountName: String
    /// The token just created, with the one look anybody gets at its text.
    let minted: MintedToken?
    /// A text that went away without being read. Says so rather than showing one panel fewer.
    let secretLost: Bool
    let notice: String?
    let isBusy: Bool
    /// Passed in rather than read from the clock, so what the rows say is a function of the
    /// screen's inputs and a test does not have to wait for time to pass.
    let now: Date
    @Binding var draft: String
    /// The token a revoke has been asked about and not yet answered for. Held by the view above
    /// rather than here, because this screen is what it is given and reaches for nothing.
    @Binding var pendingRevoke: ManagedToken?
    let signOn: () -> Void
    /// Asks for the list again, under the grant this screen already holds.
    let reread: () -> Void
    let create: (String) -> Void
    let revoke: (Int) -> Void
    /// Carries no plaintext of its own: what is copied is read where the copying happens, from the
    /// store, so a secret the screen drew can never be what a press hands over.
    let copySecret: () -> Void
    let dismissSecret: () -> Void

    var body: some View {
        List {
            if let minted {
                Section { secret(minted) }
            }
            if secretLost {
                Section {
                    NoticeCard(text: ManageTokensPresentation.secretLost, tone: .warning)
                        .cardRow()
                }
            }
            if let notice {
                Section {
                    NoticeCard(text: notice, tone: .warning).cardRow()
                }
            }
            Section { main }
        }
        .listStyle(.plain)
        .listRowSpacing(DesignTokens.Space.regular)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(ManageTokensPresentation.title)
        .navigationBarTitleDisplayMode(.inline)
        .revokeConfirmation(item: $pendingRevoke, confirm: revoke)
    }

    @ViewBuilder
    private var main: some View {
        card {
            switch state {
            case .unsupported:
                Text(ManageTokensPresentation.unsupported)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .locked(let lock):
                Text(ManageTokensPresentation.lockLine(lock))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CardButton(ManageTokensPresentation.signOnTitle, action: signOn)
                    .accessibilityLabel(ManageTokensPresentation.signOnLabel)
                    .disabled(isBusy)
            case .authenticating:
                HStack(spacing: DesignTokens.Space.snug) {
                    ProgressView().controlSize(.small)
                    Text(ManageTokensPresentation.signingOn)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .unlisted:
                Text(ManageTokensPresentation.unlisted)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                CardButton(ManageTokensPresentation.rereadTitle, action: reread)
                    .accessibilityLabel(ManageTokensPresentation.rereadLabel)
                    .disabled(isBusy)
            case .listed(let tokens):
                // First, above the list and above every control that could change it: read after
                // a token has been created or revoked, it would be an explanation of something
                // that already happened. In the screen's own text colour rather than the
                // secondary one the captions take, for the same reason.
                Text(ManageTokensPresentation.listedAccountLine(signedInAs: appAccountName))
                    .font(.footnote)
                creation
                Divider()
                if tokens.isEmpty {
                    Text(ManageTokensPresentation.empty)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tokens) { token in
                        row(token)
                        if token.id != tokens.last?.id { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var creation: some View {
        SettingsCaption(ManageTokensPresentation.createCaption)
        TextField(ManageTokensPresentation.nameFieldTitle, text: $draft)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        HStack(spacing: DesignTokens.Space.roomy) {
            // Handed over as typed. What may be sent is the session's decision, made once where
            // the request is built — a second copy of the rule here would be a second answer.
            CardButton(ManageTokensPresentation.createTitle) { create(draft) }
                .accessibilityLabel(ManageTokensPresentation.createLabel)
                .disabled(
                    ManageTokensPresentation.createIsDisabled(
                        isBusy: isBusy,
                        secretShowing: minted != nil,
                        draft: draft
                    )
                )
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func row(_ token: ManagedToken) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.regular) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                Text(token.name)
                Text(ManageTokensPresentation.detail(token, now: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Names the token rather than revoking it: what is sent is decided by the answer to
            // the question this raises, about the token the question itself names.
            CardButton(ManageTokensPresentation.revokeTitle, tone: .removing) {
                pendingRevoke = token
            }
            .accessibilityLabel(ManageTokensPresentation.revokeLabel(for: token.name))
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func secret(_ minted: MintedToken) -> some View {
        card {
            Text(ManageTokensPresentation.secretHeading)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(minted.token.name)
            // Not pickable by hand. The system's own copy of a dragged-over run of characters
            // would put a token on the clipboard that nothing here has any say over — no deadline,
            // and half a secret if the drag stopped short. Copy below is the one way out of this
            // panel, and it takes the whole thing.
            Text(minted.secret)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ManageTokensPresentation.secretCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Space.roomy) {
                // Copy first and prominent, Done quiet beside it: the panel is up so that the
                // text can be got out of it, and the control that ends it is not the one the eye
                // should land on.
                CardButton(
                    ManageTokensPresentation.copyTitle,
                    tone: .prominent,
                    action: copySecret
                )
                .accessibilityLabel(ManageTokensPresentation.copyLabel)
                CardButton(
                    ManageTokensPresentation.doneTitle,
                    tone: .secondary,
                    action: dismissSecret
                )
                .accessibilityLabel(ManageTokensPresentation.doneLabel)
            }
        }
    }

    /// The same card chrome the Settings screen is built from, so the two read as one app rather
    /// than as a screen and a sheet that were drawn by different hands.
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            content()
        }
        .padding(DesignTokens.Space.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .cardRow()
    }
}
