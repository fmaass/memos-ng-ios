import MemosCore
import SwiftUI

/// The Library's header (plan page 3929 decision 10): a large bold title with a small subtitle
/// line under it, and on the right a round glass filter button, then a glass "Select" capsule.
/// In select mode (MEMNG-588; MEMNG-779) the two give way to `SelectChrome`: the close button
/// alone while select mode's actions menu has no rows, as on the Library. There is no Select All.
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
    /// Select mode's actions menu: none on the Library yet (WPN-14 adds them).
    var menuRows: [SelectAction] = []
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
            HeaderGlassCircle.symbol(LibraryFilterMenuContent.symbol)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Filter")
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

    private var selectModeControls: some View {
        SelectChrome(menuRows: menuRows, close: close)
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

/// The round filter button's menu, in the Photos app's shape (MEMNG-779, WPN-12 phase 1): the
/// shared filter rows (`MediaFilterRows` — the kinds, "Captured by me" and Visibility); a
/// divider; then a nested "Sort By" menu whose label says the order in force, and a nested
/// "View Options" menu holding Group by Day (MEMNG-818) and the tile layout (MEMNG-821).
///
/// The tags are not here — they are reached from Collections — and neither is clearing the media
/// cache, which is the Settings app's Storage group (MEMNG-781).
struct LibraryFilterMenuContent: View {
    /// The round button's glyph: Photos' filter symbol.
    static let symbol = "line.3.horizontal.decrease"

    @Binding var filter: MediaLibraryFilter
    @Binding var mine: Bool
    @Binding var visibility: MediaVisibilityFilter
    @Binding var order: MediaLibraryOrder
    @Binding var groupByDay: Bool
    @Binding var tileLayout: LibraryTileLayout

    var body: some View {
        MediaFilterRows(filter: $filter, mine: $mine, visibility: $visibility)
        Divider()
        SortByMenu(order: $order)
        ViewOptionsMenu(groupByDay: $groupByDay, tileLayout: $tileLayout)
    }
}

/// The filter rows the Library's menu and a trip's share (MEMNG-787), one copy for both: the
/// kinds as an inline Picker under "Filter"; "Captured by me" as a Toggle — its own row with a
/// checkmark, because it combines with whichever kind is chosen; then the nested Visibility menu.
struct MediaFilterRows: View {
    /// The toggle row's words and glyph.
    static let capturedByMe = "Captured by me"
    static let capturedByMeSymbol = "person.crop.circle"

    @Binding var filter: MediaLibraryFilter
    @Binding var mine: Bool
    @Binding var visibility: MediaVisibilityFilter

    var body: some View {
        Picker("Filter", selection: $filter) {
            ForEach(MediaLibraryFilter.allCases) { filter in
                Text(MediaLibraryPresentation.label(for: filter)).tag(filter)
            }
        }
        .pickerStyle(.inline)
        Toggle(Self.capturedByMe, systemImage: Self.capturedByMeSymbol, isOn: $mine)
        VisibilityMenu(visibility: $visibility)
    }
}

/// The nested "Visibility" menu: its label carries the choice in force as a second line, as Sort
/// By's does, and opening it shows Any, Public and Just us with a checkmark on the current one.
struct VisibilityMenu: View {
    @Binding var visibility: MediaVisibilityFilter

    var body: some View {
        Menu {
            Picker("Visibility", selection: $visibility) {
                ForEach(MediaVisibilityFilter.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("Visibility")
            Text(visibility.label)
                .font(.caption)
        }
        .accessibilityLabel("Visibility")
        .accessibilityValue(visibility.label)
    }
}

extension MediaVisibilityFilter {
    /// The row a menu draws: the memo visibilities' own words (`MemoVisibility.label`), and "Any".
    var label: String {
        switch self {
        case .any: "Any"
        case .public: MemoVisibility.public.label
        case .justUs: MemoVisibility.protected.label
        }
    }
}

/// The filter menu's nested "Sort By" menu: its label carries the order in force as a second,
/// smaller line, and opening it shows the two orders with a checkmark on the current one.
struct SortByMenu: View {
    @Binding var order: MediaLibraryOrder

    var body: some View {
        Menu {
            SortByMenuContent(order: $order)
        } label: {
            SortByMenuLabel(order: order)
        }
        // One element for VoiceOver, "Sort By, Newest First": the two lines read as the menu's
        // name and its value rather than as two things to visit.
        .accessibilityLabel("Sort By")
        .accessibilityValue(order.label)
    }
}

/// "Sort By", and under it the order in force — the menu's title and subtitle.
struct SortByMenuLabel: View {
    let order: MediaLibraryOrder

    var body: some View {
        Text("Sort By")
        Text(order.label)
            .font(.caption)
    }
}

/// The Sort By menu's rows, Oldest First then Newest First: an inline Picker, so the order in force
/// carries the checkmark and choosing the other un-chooses it.
struct SortByMenuContent: View {
    @Binding var order: MediaLibraryOrder

    /// The rows' order, as the design of record lists them.
    static let orders: [MediaLibraryOrder] = [.oldestFirst, .newestFirst]

    var body: some View {
        Picker("Sort By", selection: $order) {
            ForEach(Self.orders) { order in
                Text(order.label).tag(order)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The filter menu's nested "View Options" menu, as Photos names it: Group by Day (MEMNG-818),
/// then the tile layout (MEMNG-821). Two options only: a third is a decision of its own, not a row
/// to add here.
struct ViewOptionsMenu: View {
    @Binding var groupByDay: Bool
    @Binding var tileLayout: LibraryTileLayout

    var body: some View {
        Menu("View Options") {
            ViewOptionsMenuContent(groupByDay: $groupByDay, tileLayout: $tileLayout)
        }
    }
}

/// View Options' two groups: a toggle, which a menu draws as a row with a checkmark while it is
/// on; a divider; then Mixed Sizes and Square Grid as an inline Picker, the one in force ticked.
struct ViewOptionsMenuContent: View {
    @Binding var groupByDay: Bool
    @Binding var tileLayout: LibraryTileLayout

    var body: some View {
        Toggle("Group by Day", isOn: $groupByDay)
        Divider()
        Picker("Tile Layout", selection: $tileLayout) {
            ForEach(LibraryTileLayout.allCases) { layout in
                Text(layout.label).tag(layout)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
