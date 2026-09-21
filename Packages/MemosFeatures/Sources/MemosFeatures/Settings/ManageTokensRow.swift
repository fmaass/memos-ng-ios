import SwiftUI

/// The row in Settings that opens token management.
///
/// A view of its own taking a closure, for the reason `DeviceTokenSection` is one: pressing this
/// row inside `SettingsView` means standing up that screen's `SessionStore` and, behind the tap,
/// the whole token flow — a sign-on in a browser sheet, a grant, a keychain — for a case whose
/// subject is one row and where it leads. Extracted, the row is pressed as itself and the closure
/// says what the tap reached.
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
