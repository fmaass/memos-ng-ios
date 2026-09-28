import MemosCore
import SwiftUI

/// The Library's header (plan page 3929 decision 10): a large bold title with a small subtitle
/// line under it, and on the right a round glass options button, then a glass "Select" capsule.
/// In select mode (MEMNG-588, the mockup's section 7) the two become a round "select all of mine
/// in view" toggle and a round close button.
///
/// Drawn by the screen rather than by the navigation bar, so the two controls are two pieces of
/// glass side by side, as the Photos app draws them, and not items a toolbar may group into one.
struct LibraryHeader<MenuContent: View>: View {
    let subtitle: String
    /// The Select capsule's action, or nil where there is nothing to select — Years and Months,
    /// whose tiles are days and years rather than files.
    var select: (() -> Void)?
    /// Whether the grid is in select mode, which swaps the controls on the right.
    var selecting = false
    /// Whether every own picture in view is chosen: the toggle is drawn filled, and its next tap
    /// clears.
    var allMineSelected = false
    var toggleAll: () -> Void = {}
    var close: () -> Void = {}
    @ViewBuilder let menu: () -> MenuContent

    /// The smallest target a finger is promised, which the round button and the capsule share so
    /// they read as one row of controls.
    private static var control: CGFloat { 44 }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.snug) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                Text("Library")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Space.snug)
            if selecting {
                selectModeControls
            } else {
                browsingControls
            }
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
    }

    @ViewBuilder
    private var browsingControls: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.control, height: Self.control)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Options")
        // Live only where there are files to choose (All); on Years and Months it is still drawn,
        // so the header keeps its shape, and disabled, so it promises nothing it cannot do.
        Button("Select") { select?() }
            .font(.body.weight(.semibold))
            .padding(.horizontal, DesignTokens.Space.roomy)
            .frame(height: Self.control)
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(select == nil)
    }

    @ViewBuilder
    private var selectModeControls: some View {
        Button(action: toggleAll) {
            Image(systemName: allMineSelected ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.control, height: Self.control)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(allMineSelected ? "Deselect All" : "Select All")
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: Self.control, height: Self.control)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
    }
}

/// The rows of the Library's options menu, in the order page 3929 gives them (decisions 5, 10
/// and 12): the sort, the kind, then "All tags" and every tag with its picture count. Each group is
/// an inline Picker, which is what draws the checkmark on the chosen row — one selection each, so
/// choosing a row un-chooses the others in its group and leaves the other groups alone.
struct LibraryOptionsMenuContent: View {
    @Binding var order: MediaLibraryOrder
    @Binding var filter: MediaLibraryFilter
    @Binding var tag: String?
    let tagRows: [LibraryTagRow]

    var body: some View {
        Picker("Sort", selection: $order) {
            ForEach(MediaLibraryOrder.allCases) { order in
                Text(MediaLibraryPresentation.sortLabel(for: order)).tag(order)
            }
        }
        .pickerStyle(.inline)
        Picker("Kind", selection: $filter) {
            ForEach(MediaLibraryFilter.allCases) { filter in
                Text(MediaLibraryPresentation.label(for: filter)).tag(filter)
            }
        }
        .pickerStyle(.inline)
        Picker("Tags", selection: $tag) {
            ForEach(tagRows) { row in
                Text(row.label).tag(row.selection)
            }
        }
        .pickerStyle(.inline)
    }
}
