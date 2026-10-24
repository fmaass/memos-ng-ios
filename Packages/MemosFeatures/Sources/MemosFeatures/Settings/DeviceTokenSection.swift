import MemosCore
import SwiftUI

/// The device-token row on the account sheet: what this phone's credential is called, how long
/// it has, when it last spoke, and the two things a device may do to it.
///
/// A view of its own rather than a body inside `AccountSheet`, and for the reason `SignOutSection`
/// is one. The sheet reads a `SessionStore`; it is hosted in the Features test bundle, but only
/// over a session signed in through a scripted server, so every state of this row would have to
/// be staged as a server's answer before a Rename could be pressed. Everything here arrives as a
/// value or a closure, so the whole row is a thing a test puts on a screen by itself
/// (`DeviceTokenSectionTests`).
///
/// Renaming is an inline field rather than an alert, and that is the same decision: an alert's
/// text field is presented by UIKit outside the view under test, so a row that opened one would
/// take its only editable control off the screen a probe can see.
///
/// `draft` is the editing state, held OUTSIDE this view: `nil` while the row is only being read,
/// and the text being typed once renaming has started. It lives on the screen rather than here so
/// that a rename survives the row being redrawn when the session answers.
struct DeviceTokenSection: View {
    let token: DeviceToken?
    /// What the session has to say about the last read, rename or renewal — `nil` when it has
    /// nothing to say.
    let notice: String?
    /// Passed in rather than read from the clock, so that what the row says is a function of its
    /// inputs and a test does not have to wait for time to pass.
    let now: Date
    /// A call is on the wire. Both controls go quiet: a renewal destroys the presenting token, and
    /// two of them in flight is one successor orphaned on a device that thinks it is signed in.
    let isBusy: Bool
    @Binding var draft: String?
    let rename: (String) -> Void
    let renew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
            Text(DeviceTokenPresentation.heading)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            if let token {
                Text(token.name)
                Text(DeviceTokenPresentation.expiryLine(token.expiresAt, now: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(DeviceTokenPresentation.lastUsedLine(token.lastUsed, now: now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(DeviceTokenPresentation.unread)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let notice {
                NoticeCard(text: notice, tone: .warning)
            }
            if let editing = draft {
                editor(editing)
            } else {
                controls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func editor(_ editing: String) -> some View {
        TextField(
            DeviceTokenPresentation.nameFieldTitle,
            text: Binding(get: { editing }, set: { draft = $0 })
        )
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        HStack(spacing: DesignTokens.Space.roomy) {
            // The name is handed over as typed. What may be sent is `DeviceTokenName`'s decision,
            // made once, in the session that builds the request — a second copy of the rule here
            // would be a second answer to the same question.
            Button(DeviceTokenPresentation.saveTitle) {
                rename(editing)
                draft = nil
            }
            .accessibilityLabel(DeviceTokenPresentation.saveLabel)
            Button(DeviceTokenPresentation.cancelTitle) { draft = nil }
                .accessibilityLabel(DeviceTokenPresentation.cancelLabel)
        }
        .padding(.top, DesignTokens.Space.hair)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: DesignTokens.Space.roomy) {
            // Opened on the name the device is ALREADY called, so a rename starts from what is
            // there rather than from an empty field somebody has to retype.
            Button(DeviceTokenPresentation.renameTitle) { draft = token?.name ?? "" }
                .accessibilityLabel(DeviceTokenPresentation.renameLabel)
                .disabled(token == nil || isBusy)
            Button(DeviceTokenPresentation.renewTitle) { renew() }
                .accessibilityLabel(DeviceTokenPresentation.renewLabel)
                .disabled(isBusy)
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.top, DesignTokens.Space.hair)
    }
}
