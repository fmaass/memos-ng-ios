import SwiftUI

/// The row on the account sheet that opens token management.
///
/// A view of its own taking a closure, for the reason `DeviceTokenSection` is one: pressing this
/// row inside `AccountSheet` means standing up that sheet's `SessionStore` and, behind the tap,
/// the whole token flow — a sign-on in a browser sheet, a grant, a keychain — for a case whose
/// subject is one row and where it leads. Extracted, the row is pressed as itself and the closure
/// says what the tap reached. That the sheet's row opens the management sheet over it is held
/// once, end to end, by `AccountSheetRenderTests`.
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
