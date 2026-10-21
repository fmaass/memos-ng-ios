import MemosCore
import SwiftUI

/// One row of select mode's actions menu (MEMNG-779): a title, its symbol, and what it does.
struct SelectAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    /// Drawn but taking no press: nothing chosen, or a share or a delete is out (MEMNG-780).
    var disabled = false
    /// A submenu's rows (MEMNG-788): drawn as a nested menu under the title, whose own press does
    /// nothing; empty for an ordinary row.
    var children: [SelectAction] = []
    var action: () -> Void = {}
}

extension SelectAction {
    /// Select mode's Use as Cover row (MEMNG-842): offered wherever the viewer offers it,
    /// pressable only with exactly one picture chosen and nothing else out.
    static func useAsCover(count: Int, free: Bool, perform: @escaping () -> Void) -> SelectAction {
        SelectAction(
            id: "cover", title: TripView.useAsCoverButton, systemImage: "photo.badge.checkmark",
            disabled: !(free && count == 1), action: perform)
    }

    /// The one picture the Use as Cover row makes the cover, or nil unless exactly one picture on
    /// screen is chosen.
    static func coverPick(_ selection: LibrarySelection, in members: [LibraryRow])
        -> MemoAttachment?
    {
        let chosen = selection.rows(in: members)
        guard selection.count == 1, chosen.count == 1 else { return nil }
        return chosen.first?.attachment
    }
}

/// Select mode's actions menu's rows, in order: the Library's header menu and the trip's system
/// bar menu (MEMNG-780) draw the same rows from the same values.
struct SelectActionRows: View {
    let rows: [SelectAction]

    var body: some View {
        ForEach(rows) { row in
            if row.children.isEmpty {
                Button(row.title, systemImage: row.systemImage, role: row.role) {
                    row.action()
                }
                .disabled(row.disabled)
            } else {
                Menu(row.title, systemImage: row.systemImage) {
                    SelectActionRows(rows: row.children)
                }
                .disabled(row.disabled)
            }
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
