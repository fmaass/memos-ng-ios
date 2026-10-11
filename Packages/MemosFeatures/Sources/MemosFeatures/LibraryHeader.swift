import MemosCore
import SwiftUI

/// The Library's header (plan page 3929 decision 10): a large bold title with a small subtitle
/// line under it, and on the right a round glass options button, then a glass "Select" capsule.
/// In select mode (MEMNG-588, the mockup's section 7) the two become a round "select all of mine
/// in view" toggle and a round close button.
///
/// Drawn by the screen rather than by the navigation bar, so the two controls are two pieces of
/// glass side by side, as the Photos app draws them, and not items a toolbar may group into one.
/// The layout is `ScreenHeader`'s, which Collections wears too (MEMNG-757).
struct LibraryHeader<MenuContent: View>: View {
    let subtitle: String
    /// The Select capsule's action, or nil where there is nothing to select — Years and Months,
    /// whose tiles are days and years rather than files.
    var select: (() -> Void)?
    /// Whether the grid is in select mode, which swaps the controls on the right.
    var selecting = false
    /// Whether every picture in view is chosen: the toggle is drawn filled, and its next tap
    /// clears.
    var allSelected = false
    var toggleAll: () -> Void = {}
    var close: () -> Void = {}
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        ScreenHeader(title: "Library", subtitle: subtitle) {
            if selecting {
                selectModeControls
            } else {
                browsingControls
            }
        }
    }

    @ViewBuilder
    private var browsingControls: some View {
        Menu {
            menu()
        } label: {
            HeaderGlassCircle.symbol("ellipsis")
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Options")
        // Live only where there are files to choose (All); on Years and Months it is still drawn,
        // so the header keeps its shape, and disabled, so it promises nothing it cannot do. The
        // padding and the height are the label's, so the button is the whole capsule of glass and
        // its frame is the capsule's: the edge Collections' + is held to (MEMNG-757).
        Button {
            select?()
        } label: {
            Text("Select")
                .padding(.horizontal, DesignTokens.Space.roomy)
                .frame(height: HeaderGlassCircle.control)
        }
        .font(.body.weight(.semibold))
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(select == nil)
    }

    @ViewBuilder
    private var selectModeControls: some View {
        HeaderGlassCircle(
            systemName: allSelected ? "checkmark.circle.fill" : "checkmark.circle",
            label: allSelected ? "Deselect All" : "Select All",
            action: toggleAll
        )
        HeaderGlassCircle(systemName: "xmark", label: "Close", action: close)
    }
}

/// A tab root's header, drawn by the screen with the navigation bar hidden (plan page 3929
/// decision 10, MEMNG-757): a large bold title with a small subtitle line under it, and the
/// screen's controls on the right. The Library and Collections both wear it, so the two tabs'
/// titles stand at one edge and their controls at one height.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Space.snug) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
                Text(title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Space.snug)
            trailing()
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.vertical, DesignTokens.Space.snug)
    }
}

/// A header's round glass button: a symbol on a circle of glass, the Library's options and select
/// mode's controls and Collections' + alike, so they read as one row of controls at one height.
struct HeaderGlassCircle: View {
    let systemName: String
    let label: String
    let action: () -> Void

    /// The smallest target a finger is promised, which the circle and the Select capsule share.
    static let control: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Self.symbol(systemName)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// The symbol at the circle's size, for the one round control that is a menu, not a button.
    static func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: control, height: control)
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
