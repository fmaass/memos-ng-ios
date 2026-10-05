import MemosCore
import SwiftUI

/// The app-drawn main bar of the `leading` bar style (MEMNG-690): ONE Liquid Glass capsule holding
/// the three tabs, anchored at the leading edge where the system's minimised icon lands, so that
/// folding it changes its width and nothing else — "it looks like the bar is not moving".
///
/// Its three shapes are one glass in one container, so iOS morphs between them rather than cutting:
/// the capsule, the selected tab's icon alone (`folded`, the Timeline scrolled down), and on the
/// Library the scope row — the Library icon and Years | Months | All, at the place and size the
/// system's bottom toolbar draws them under the `system` style. The capsule and the Library icon
/// share one glass identity, so the capsule flows into the icon and the scope's glass grows out of
/// it, and back. The system toolbar cannot do this: its glass belongs to UIKit and no container of
/// the app's can hold it, which is why the scope row is drawn here under this style — and, since
/// build 39, under the `system` style too, alone, in that toolbar's place
/// (`MediaLibraryView.systemRow`).
struct LeadingMainBar: View {
    enum BarShape: Equatable {
        case tabs
        case folded
        case scope
    }

    /// Nil under the system style wherever its own tab bar or a claim's bar stands: the container
    /// stays and draws nothing, so the scope's glass materialises inside it (MEMNG-690, build 39).
    let shape: BarShape?
    let selection: MainTab
    /// A press on a tab: the same binding the system bar writes (`MainTabs.pressing`), so the dock
    /// hears it before the selection moves.
    let press: (MainTab) -> Void
    /// A press on the scope row's Library icon (`DockEvent.pressedLibraryIcon`).
    let pressLibraryIcon: () -> Void
    let scope: LibraryScopeChoice
    @Namespace private var glass

    /// The capsule's leading edge from the leading safe-area edge, in every shape. UIKit publishes
    /// no value for where its minimised tab bar lands; 21 pt is where iOS 26 drew its own
    /// leading-anchored bar in a render of the system's search-role layout (63 px at 3x), and the
    /// system bar's own foot stands the same 21 pt above the screen's edge.
    static let leadingInset: CGFloat = 21
    /// How far the bar is drawn below the bottom safe-area edge, so its foot stands where the
    /// system bar's does, 21 pt above the screen's edge on a 34 pt home-indicator inset.
    static let bottomDrop: CGFloat = 13
    /// The bar's height in every shape, so a fold or a swap to the scope changes no inset under it
    /// and the scroll view above is not reframed.
    static let height: CGFloat = 62
    /// The scope row's Library icon: a 48 pt glass circle 7 pt in from the capsule's edge, as the
    /// system toolbar draws it (measured under the `system` style: x 28, 48 x 48).
    static let scopeIconInset: CGFloat = 7
    static let scopeIconSide: CGFloat = 48
    /// Between the icon's glass and the scope control's, as the toolbar's fixed spacer leaves it.
    static let scopeGap: CGFloat = 12

    var body: some View {
        GlassEffectContainer(spacing: Self.scopeGap) {
            HStack(spacing: Self.scopeGap) {
                switch shape {
                case .tabs?: capsule
                case .folded?: foldedIcon
                case .scope?: scopeRow
                case nil: EmptyView()
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: shape)
        // Outside the animation: the inset under the scroll view changes at once, as the tab
        // bar's does, while the glass inside appears and goes in the container's animation.
        .frame(height: shape == nil ? 0 : Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Self.leadingInset)
        .offset(y: Self.bottomDrop)
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                item(tab, titled: true)
            }
        }
        .padding(.horizontal, DesignTokens.Space.snug)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(GlassID.main, in: glass)
        .modifier(MainGlassMarker(shape: .tabs))
    }

    private var foldedIcon: some View {
        item(selection, titled: false)
            .padding(.horizontal, DesignTokens.Space.tight)
            .frame(height: Self.height)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID(GlassID.main, in: glass)
            .modifier(MainGlassMarker(shape: .folded))
    }

    @ViewBuilder
    private var scopeRow: some View {
        Button(action: pressLibraryIcon) {
            Image(systemName: MainTab.library.symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: Self.scopeIconSide, height: Self.scopeIconSide)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // On the button itself: said after the marker, they would name the marker's leaf too.
        .accessibilityLabel(MainTab.library.title)
        .accessibilityIdentifier(MediaLibraryView.tabsButton)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(GlassID.main, in: glass)
        .modifier(MainGlassMarker(shape: .scope))
        .padding(.leading, Self.scopeIconInset)
        // The control at the toolbar's size: on its own iOS draws it 32 pt tall, in the bottom
        // toolbar 48 (measured under each style).
        LibraryScopePicker(scope: scope)
            .controlSize(.extraLarge)
            .padding(5)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID(GlassID.scope, in: glass)
    }

    private func item(_ tab: MainTab, titled: Bool) -> some View {
        Button {
            press(tab)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 23, weight: .medium))
                    .frame(height: 28)
                if titled {
                    Text(tab.title)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(tab == selection ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            // The system's tab buttons: 86 pt apart and 54 pt tall, the selection's pill as wide
            // as the button (read from the system bar's own layout in a render test).
            .frame(width: titled ? 86 : 54, height: 54)
            .background {
                if titled, tab == selection {
                    Capsule().fill(Color.primary.opacity(0.08)).padding(.horizontal, -4)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }

    /// What the main glass is found by in each shape (`MainGlassMarker`).
    static func identifier(of shape: BarShape) -> String {
        switch shape {
        case .tabs: "main-bar-tabs"
        case .folded: "main-bar-folded"
        case .scope: "main-bar-scope-icon"
        }
    }

    private enum GlassID {
        static let main = "main-bar"
        static let scope = "main-bar-scope"
    }
}

/// A leaf behind the leading bar's main glass — the capsule, the folded icon or the scope row's
/// Library icon — that reports its frame by an identifier naming the shape, the way the Places
/// root reports its own (`PlacesView.rootIdentifier`): what a render test measures the glass by.
private struct MainGlassMarker: ViewModifier {
    let shape: LeadingMainBar.BarShape

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Tab bar")
                .accessibilityIdentifier(LeadingMainBar.identifier(of: shape))
        }
    }
}
