import MemosCore
import SwiftUI

/// What select mode draws, as values a test can hold without a screen (MEMNG-588).
enum LibrarySelectionPresentation {
    /// How one tile of the All grid takes part in select mode.
    enum Tile: Equatable {
        /// Not in select mode: a tap opens the picture.
        case browsing
        /// A loaded picture, mine or another member's (MEMNG-684), chosen or not. Unchosen it keeps
        /// its brightness, as in the Photos app.
        case selectable(selected: Bool)
        /// A tile whose row is not the one it was drawn for — the list moved under it: dimmed, and
        /// a tap does nothing, because there is no row for the tap to choose.
        case unloaded
    }

    static func tile(for row: LibraryRow?, in selection: LibrarySelection) -> Tile {
        guard selection.isActive else { return .browsing }
        guard let row else { return .unloaded }
        return .selectable(selected: selection.contains(row.id))
    }

    /// The toolbar's middle line over a trip, "N Items Selected" as the design of record writes it —
    /// "0 Items Selected" before anything is chosen — and "1 Item Selected" for one.
    static func countText(_ count: Int) -> String {
        count == 1 ? "1 Item Selected" : "\(count) Items Selected"
    }

    /// The Library's centre button (MEMNG-779): "Select Items", drawn disabled, before anything is
    /// chosen, and "Show Selected (N)" after — the Photos app's words.
    static func showSelectedText(_ count: Int) -> String {
        count == 0 ? "Select Items" : "Show Selected (\(count))"
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

    /// How far a tile with no row is dimmed in select mode.
    static let unloadedOpacity = 0.4

    /// Whether the toolbar's share and delete take a tap: something is chosen, and neither a share
    /// batch nor a delete run is out. One run at a time across both — a share fetching a file a
    /// delete is removing, or a delete of a file a share is still fetching, is a race nobody asked
    /// for.
    static func actionsEnabled(count: Int, isSharing: Bool, isDeleting: Bool) -> Bool {
        count > 0 && !isSharing && !isDeleting
    }

    /// Whether Delete takes a tap: the same gate, counted over the chosen pictures that are mine
    /// (`LibrarySelection.deletable`). A selection of only other members' pictures has nothing
    /// for it to delete. This is about permission, not about one run at a time: that is the
    /// delete flow's and the store's (`LibraryDeleteFlow.next`, `MediaLibraryStore.delete`).
    static func deleteEnabled(ownCount: Int, isSharing: Bool, isDeleting: Bool) -> Bool {
        actionsEnabled(count: ownCount, isSharing: isSharing, isDeleting: isDeleting)
    }
}

/// Select mode on a tile: a tile with no row dimmed and inert, and a small blue checkmark in the
/// bottom-right corner of a chosen one (the mockup's section 7).
struct SelectableTile: ViewModifier {
    let state: LibrarySelectionPresentation.Tile

    func body(content: Content) -> some View {
        content
            .opacity(state == .unloaded ? LibrarySelectionPresentation.unloadedOpacity : 1)
            .allowsHitTesting(state != .unloaded)
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
/// round glass delete button on the right — over a trip, with a round glass remove button before
/// it. On the Library the middle is a button, "Show Selected (N)", that narrows the grid to the
/// chosen pictures and back (MEMNG-779); over a trip it stays the count until the trip's chrome
/// follows (WPN-12 phase 2).
struct LibrarySelectToolbar: View {
    let count: Int
    /// How many of the chosen pictures are mine, the only ones Delete may take (MEMNG-684).
    let ownCount: Int
    /// A share batch is fetching: the share button shows a spinner and takes no second tap.
    let isSharing: Bool
    /// A delete run is out: the delete button shows a spinner, and neither button takes a tap.
    let isDeleting: Bool
    let share: () -> Void
    let delete: () -> Void
    /// Remove from Trip (MEMNG-722): drawn beside Delete only where the toolbar stands over a
    /// trip. The Library passes nil and has no such button.
    var remove: (() -> Void)? = nil
    /// "Show Selected (N)" (MEMNG-779): the Library passes it and draws the middle as that button;
    /// nil draws the count line, as over a trip.
    var showSelected: (() -> Void)? = nil
    /// Whether the grid is narrowed to the selection: the button is drawn tinted, and selected.
    var narrowed = false

    /// Remove from Trip's name, read by VoiceOver.
    static let removeLabel = "Remove from Trip"

    /// The smallest target a finger is promised, the header's round controls' size.
    private static var control: CGFloat { 44 }

    private var enabled: Bool {
        LibrarySelectionPresentation.actionsEnabled(
            count: count,
            isSharing: isSharing,
            isDeleting: isDeleting
        )
    }

    private var deletable: Bool {
        LibrarySelectionPresentation.deleteEnabled(
            ownCount: ownCount,
            isSharing: isSharing,
            isDeleting: isDeleting
        )
    }

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
            .disabled(!enabled)
            .accessibilityLabel("Share")
            Spacer(minLength: DesignTokens.Space.snug)
            centre
            Spacer(minLength: DesignTokens.Space.snug)
            // Asks nothing: what it takes is only this trip's on this device, and the trip's Show
            // Removed gives it back.
            if let remove {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                        .font(.body.weight(.semibold))
                        .frame(width: Self.control, height: Self.control)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(!enabled)
                .accessibilityLabel(Self.removeLabel)
            }
            // Asks first (`LibraryDeleteFlow`); only the alert's yes deletes, one picture at a time
            // through the single-picture endpoint (MEMNG-589), and only the chosen pictures that
            // are mine (MEMNG-684).
            Button(action: delete) {
                Group {
                    if isDeleting {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(width: Self.control, height: Self.control)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(!deletable)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(.bar)
    }
}

extension LibrarySelectToolbar {
    /// The middle: the Library's Show Selected button, or the count line over a trip.
    @ViewBuilder
    private var centre: some View {
        if let showSelected {
            Button(action: showSelected) {
                Text(LibrarySelectionPresentation.showSelectedText(count))
                    .font(.headline)
                    .lineLimit(1)
            }
            // Tinted while narrowed; the system's disabled look before anything is chosen.
            .foregroundStyle(
                narrowed
                    ? AnyShapeStyle(.tint)
                    : count == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
            )
            .disabled(count == 0)
            .accessibilityAddTraits(narrowed ? .isSelected : [])
        } else {
            Text(LibrarySelectionPresentation.countText(count))
                .font(.headline)
                .lineLimit(1)
        }
    }
}

/// What a delete run that did not delete everything says, above select mode's toolbar
/// (`LibraryDeleteFlow.resultText`). It goes by itself after a few seconds, or on a tap.
struct LibraryDeleteToast: View {
    let text: String
    let dismiss: () -> Void

    /// Long enough to read "3 deleted, 7 failed" twice.
    static let lifetime: Duration = .seconds(4)

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, DesignTokens.Space.roomy)
            .padding(.vertical, DesignTokens.Space.snug)
            .glassEffect(.regular, in: .capsule)
            .onTapGesture(perform: dismiss)
            // Keyed on the text, so a second report restarts the clock rather than inheriting the
            // first one's remaining seconds.
            .task(id: text) {
                try? await Task.sleep(for: Self.lifetime)
                guard !Task.isCancelled else { return }
                dismiss()
            }
    }
}
