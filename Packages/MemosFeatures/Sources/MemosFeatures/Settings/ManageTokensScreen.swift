import MemosCore
import SwiftUI

/// The row in Settings that opens token management.
///
/// A view of its own taking a closure, for the reason `DeviceTokenSection` is one: `SettingsView`
/// reads a `SessionStore` and so cannot be hosted in the Features test bundle, and a row written
/// inline in that body would be the app's only way to reach this screen with no test able to press
/// it.
struct ManageTokensRow: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                Text(ManageTokensPresentation.rowTitle)
                Text(ManageTokensPresentation.rowCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ManageTokensPresentation.rowLabel)
    }
}

/// Token management itself: everything the screen can show, as a function of what it is given.
///
/// Nothing here reaches for a store, a session or a clock. The screen has four quite different
/// things to draw — a prompt to sign in, a list, a secret shown once, and a server that does not
/// offer this yet — and every one of them is a state a test can hand it, which is the only way the
/// honest-degradation cases can be checked at all: a server without these routes cannot be
/// arranged by rendering a real screen against a real server.
struct ManageTokensScreen: View {
    let state: ManageTokensState
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
    let signOn: () -> Void
    let create: (String) -> Void
    let revoke: (Int) -> Void
    let copySecret: (String) -> Void
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
                Button(ManageTokensPresentation.signOnTitle, action: signOn)
                    .accessibilityLabel(ManageTokensPresentation.signOnLabel)
                    .disabled(isBusy)
            case .authenticating:
                HStack(spacing: DesignTokens.Space.snug) {
                    ProgressView().controlSize(.small)
                    Text(ManageTokensPresentation.signingOn)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .listed(let tokens):
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
            Button(ManageTokensPresentation.createTitle) { create(draft) }
                .accessibilityLabel(ManageTokensPresentation.createLabel)
                .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            // Stated red rather than left to the destructive role: inside these hand-built cards a
            // button takes the app's accent, and the control that takes something away must not
            // read like the rest of the screen.
            Button(ManageTokensPresentation.revokeTitle) { revoke(token.id) }
                .foregroundStyle(.red)
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
            Text(minted.secret)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ManageTokensPresentation.secretCaption)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: DesignTokens.Space.roomy) {
                Button(ManageTokensPresentation.copyTitle) { copySecret(minted.secret) }
                    .accessibilityLabel(ManageTokensPresentation.copyLabel)
                Button(ManageTokensPresentation.doneTitle, action: dismissSecret)
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
