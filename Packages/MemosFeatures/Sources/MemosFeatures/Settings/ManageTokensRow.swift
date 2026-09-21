import SwiftUI

/// The row in Settings that opens token management.
///
/// A view of its own taking a closure, for the reason `DeviceTokenSection` is one: `SettingsView`
/// reads a `SessionStore`, and the one a case would get by asking for it reaches the device's
/// keychain (`DeviceCredentials.keychain()`) and the real sign-on behind it — which is not what a
/// case about this row is asking. A row written inline in that body would be the app's only way to
/// reach this screen with no test able to press it.
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
