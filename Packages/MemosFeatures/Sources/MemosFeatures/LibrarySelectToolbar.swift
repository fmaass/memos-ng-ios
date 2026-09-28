import MemosCore
import SwiftUI

/// What select mode draws, as values a test can hold without a screen (MEMNG-588).
enum LibrarySelectionPresentation {
    /// How one tile of the All grid takes part in select mode.
    enum Tile: Equatable {
        /// Not in select mode: a tap opens the picture.
        case browsing
        /// An own picture, chosen or not. Unchosen it keeps its brightness, as in the Photos app.
        case selectable(selected: Bool)
        /// Another member's picture, or a tile whose row is not the one it was drawn for: dimmed,
        /// and a tap does nothing.
        case inert
    }

    static func tile(for row: LibraryRow?, in selection: LibrarySelection) -> Tile {
        guard selection.isActive else { return .browsing }
        guard let row, row.mine else { return .inert }
        return .selectable(selected: selection.contains(row.id))
    }

    /// The toolbar's middle line, "N Items Selected" as the design of record writes it — "0 Items
    /// Selected" before anything is chosen — and "1 Item Selected" for one.
    static func countText(_ count: Int) -> String {
        count == 1 ? "1 Item Selected" : "\(count) Items Selected"
    }

    /// The row a placed picture was drawn from: the list entry at its index, when that entry is
    /// still the same file. A grid drawn between two lists must not let a tap choose the wrong one.
    static func row(at index: Int, uid: String, in items: [LibraryRow]) -> LibraryRow? {
        guard items.indices.contains(index), items[index].id == uid else { return nil }
        return items[index]
    }

    /// What VoiceOver says a tile's tap does: open or play it while browsing, choose it in select
    /// mode, where the tap no longer opens anything.
    static func tileHint(for kind: LibraryTileKind, selecting: Bool) -> String {
        if selecting { return "Selects or deselects" }
        return kind == .video ? "Plays full screen" : "Opens full screen"
    }

    /// How far another member's picture is dimmed in select mode.
    static let inertOpacity = 0.4
}

/// Select mode on a tile: other members' pictures dimmed and inert, and a small blue checkmark in
/// the bottom-right corner of a chosen one (the mockup's section 7).
struct SelectableTile: ViewModifier {
    let state: LibrarySelectionPresentation.Tile

    func body(content: Content) -> some View {
        content
            .opacity(state == .inert ? LibrarySelectionPresentation.inertOpacity : 1)
            .allowsHitTesting(state != .inert)
            .overlay(alignment: .bottomTrailing) {
                if state == .selectable(selected: true) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                        .padding(DesignTokens.Space.tight)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(state == .selectable(selected: true) ? .isSelected : [])
    }
}

/// Select mode's bottom bar, in the dock's place (plan page 3929 decision 6): a flat toolbar, as
/// in the Photos app, with a round glass share button on the left, the count in the middle and a
/// round glass delete button on the right.
struct LibrarySelectToolbar: View {
    let count: Int
    /// A share batch is fetching: the share button shows a spinner and takes no second tap.
    let isSharing: Bool
    let share: () -> Void

    /// The smallest target a finger is promised, the header's round controls' size.
    private static var control: CGFloat { 44 }

    var body: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            Button(action: share) {
                Group {
                    if isSharing {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(width: Self.control, height: Self.control)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(count == 0 || isSharing)
            .accessibilityLabel("Share")
            Spacer(minLength: DesignTokens.Space.snug)
            Text(LibrarySelectionPresentation.countText(count))
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: DesignTokens.Space.snug)
            // Drawn so the bar has its final shape; what it does is MEMNG-589 (confirm, then delete
            // one at a time through the single-picture endpoint), so until then it promises nothing.
            Button(action: {}) {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .frame(width: Self.control, height: Self.control)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(true)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(.bar)
    }
}
