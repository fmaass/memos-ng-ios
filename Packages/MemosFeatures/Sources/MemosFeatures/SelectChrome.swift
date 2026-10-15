import SwiftUI

/// One row of select mode's actions menu (MEMNG-779): a title, its symbol, and what it does.
struct SelectAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    /// Drawn but taking no press: nothing chosen, or a share or a delete is out (MEMNG-780).
    var disabled = false
    let action: () -> Void
}

/// Select mode's actions menu's rows, in order: the Library's header menu and the trip's system
/// bar menu (MEMNG-780) draw the same rows from the same values.
struct SelectActionRows: View {
    let rows: [SelectAction]

    var body: some View {
        ForEach(rows) { row in
            Button(row.title, systemImage: row.systemImage, role: row.role) {
                row.action()
            }
            .disabled(row.disabled)
        }
    }
}

/// Select mode's trailing control in a header (MEMNG-779, WPN-12 phase 1): one piece of glass.
/// While the actions menu has no rows — the Library's case until WPN-14 gives it some — it is the
/// close button alone, a round one; with rows it is a capsule of two, the actions menu (…) and the
/// close button (✕).
struct SelectChrome: View {
    let menuRows: [SelectAction]
    let close: () -> Void

    /// The actions menu's name, read by VoiceOver.
    static let moreLabel = "More"

    var body: some View {
        if menuRows.isEmpty {
            HeaderGlassCircle(systemName: "xmark", label: "Close", action: close)
        } else {
            HStack(spacing: 0) {
                Menu {
                    SelectActionRows(rows: menuRows)
                } label: {
                    HeaderGlassCircle.symbol("ellipsis")
                }
                .accessibilityLabel(Self.moreLabel)
                Button(action: close) {
                    HeaderGlassCircle.symbol("xmark")
                }
                .accessibilityLabel("Close")
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}
