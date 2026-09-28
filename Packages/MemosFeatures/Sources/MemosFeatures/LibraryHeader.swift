import MemosCore
import SwiftUI

/// The Library's header (plan page 3929 decision 10): a large bold title with a small subtitle
/// line under it, and on the right a round glass options button, then a glass "Select" capsule.
///
/// Drawn by the screen rather than by the navigation bar, so the two controls are two pieces of
/// glass side by side, as the Photos app draws them, and not items a toolbar may group into one.
struct LibraryHeader<MenuContent: View>: View {
    let subtitle: String
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
            // Inert until select mode exists (MEMNG-588): drawn, so the header already has its
            // final shape, and disabled, so it promises nothing it cannot do.
            Button("Select") {}
                .font(.body.weight(.semibold))
                .padding(.horizontal, DesignTokens.Space.roomy)
                .frame(height: Self.control)
                .glassEffect(.regular, in: .capsule)
                .disabled(true)
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
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
