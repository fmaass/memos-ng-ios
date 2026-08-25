import SwiftUI

/// The account menu's contents, as a view of its own.
///
/// Separate from the `Menu` that presents it for one reason: a system popover cannot be rendered,
/// so a capture of "the menu open" can only ever be a capture of this. Having one view means the
/// picture is of the rows the app actually builds, rather than of a second hand-written copy of
/// them that could drift.
///
/// It draws whatever `AccountMenu.rows` hands it, in the order it hands them — the order is a
/// safety property (see `AccountMenu`), and a view that re-decided it here would be deciding it
/// twice.
struct AccountMenuRows: View {
    let rows: [AccountMenu.Row]
    let openSettings: () -> Void
    let signOut: () -> Void

    var body: some View {
        ForEach(rows, id: \.self) { row in
            switch row {
            case .heading(let title):
                // A Section header with nothing in it: the heading IS the row, and what it is for
                // is occupying the position under the anchor.
                Section(title) { EmptyView() }
            case .settings:
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
            case .signOut:
                Button(role: .destructive, action: signOut) {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                // The destructive role reddens the WORDS; the glyph beside them is drawn in the
                // inherited tint, which is the app's green — so the one row that should read as
                // dangerous had a friendly icon on it.
                .tint(.red)
            }
        }
    }
}
