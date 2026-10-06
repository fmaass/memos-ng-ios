import MemosCore
import SwiftUI

/// The app's main bar, the only one it has (MEMNG-690): ONE Liquid Glass capsule holding
/// the three tabs, anchored at the leading edge where the system's minimised icon lands, so that
/// folding it changes its width and nothing else — "it looks like the bar is not moving".
///
/// Its three shapes are one glass in one container: the capsule, the selected tab's icon alone
/// (`folded`, the Timeline scrolled down) — the same capsule narrowed, so the fold is a change of
/// width that animates, not a swap of glasses — and on the Library the scope row: the Library icon
/// and Years | Months | All, at the place and size the system's bottom toolbar drew them. The
/// capsule and the Library icon share one glass identity, so the capsule flows into the icon and
/// the scope's glass grows out of it, and back. The system toolbar cannot do this: its glass
/// belongs to UIKit and no container of the app's can hold it. There is one of it, the bottom bar
/// `MainTabs` keeps around every tab.
struct LeadingMainBar: View {
    enum BarShape: Equatable {
        case tabs
        case folded
        case scope
    }

    /// Nil on the Library under a claim, where select mode's toolbar stands: the container stays
    /// and draws nothing, so the bar's glass materialises inside it when the claim ends.
    let shape: BarShape?
    let selection: MainTab
    /// A press on a tab: the same binding the system bar writes (`MainTabs.pressing`), so the dock
    /// hears it before the selection moves.
    let press: (MainTab) -> Void
    /// A press on the scope row's Library icon (`DockEvent.pressedLibraryIcon`).
    let pressLibraryIcon: () -> Void
    let scope: LibraryScopeChoice
    @Namespace private var glass
    /// A press held on screen with no finger, for the simulator's screen recording; a person's
    /// press is the button's own.
    @Environment(\.leadingBarHeldPress) private var heldPress

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

    /// The bar's room at a stack's foot (`LeadingFootBar`): its height and nothing drawn. A room
    /// that draws, however faintly, moved the scroll edge effect 32 pt below the bar's (quick runs
    /// 5-7); a clear one draws none of its own (quick run 4), so the fade is the bar's.
    static var room: some View {
        Color.clear
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The scope row's Library icon: a 48 pt glass circle 7 pt in from the capsule's edge, as the
    /// system toolbar drew it (measured under the retired `system` style: x 28, 48 x 48).
    static let scopeIconInset: CGFloat = 7
    static let scopeIconSide: CGFloat = 48
    /// Between the icon's glass and the scope control's, as the toolbar's fixed spacer leaves it.
    static let scopeGap: CGFloat = 12
    /// A tab's width in the capsule, the system bar's 86 pt apart.
    static let itemWidth: CGFloat = 86
    /// The selection pill reaches 4 pt past its tab on either side, as the system bar's does (94 pt
    /// in its recording beside this bar's, MEMNG-690 phase 3); 40's was clipped to the tab.
    static let pillWidth: CGFloat = 94
    /// The selection pill's travel to a tapped tab: a spring that overshoots and settles, as the
    /// system bar's pill bounces into place.
    static let pillTravel = Spring(response: 0.35, dampingRatio: 0.7)
    /// A pressed tab swells under the finger, the system bar's glass bulge, and springs back.
    static let pressScale: CGFloat = 1.1
    static let pressSpring: Animation = .spring(response: 0.25, dampingFraction: 0.6)
    /// The selection pill's fill, and a pressed tab's.
    static let pillFill = Color.primary.opacity(0.08)

    /// Where the selection pill stands under `tab`: its leading edge from the first tab's, the
    /// pill centred on its tab and reaching past it on either side.
    static func pillOffset(for tab: MainTab) -> CGFloat {
        let index = MainTab.allCases.firstIndex(of: tab) ?? 0
        return CGFloat(index) * itemWidth - (pillWidth - itemWidth) / 2
    }

    var body: some View {
        GlassEffectContainer(spacing: Self.scopeGap) {
            HStack(spacing: Self.scopeGap) {
                switch shape {
                // One case, so one view: the fold narrows the capsule it is.
                case .tabs?, .folded?: capsule(folded: shape == .folded)
                case .scope?: scopeRow
                case nil: EmptyView()
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: shape)
        // Outside the animation: under a claim the bar has no height at once, so nothing of it
        // stands over the claimant's toolbar while the glass inside goes.
        .frame(height: shape == nil ? 0 : Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, Self.leadingInset)
        .offset(y: Self.bottomDrop)
    }

    /// The capsule, and folded the selected tab's icon alone in it. The fold is not a swap of
    /// two glasses: a swap inside the container cut from one to the other on the simulator's own
    /// screen recording, the bar alone on a plain background included (MEMNG-690 round 2). So the
    /// folded bar is the same capsule with the other tabs narrowed to nothing — the glass's width
    /// is layout, and the container's animation moves it like any other frame.
    private func capsule(folded: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                let shown = !folded || tab == selection
                item(tab, titled: !folded, width: shown ? (folded ? 54 : Self.itemWidth) : 0)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
        // ONE pill for the capsule, under every tab, moved to the selected one with its own
        // spring: the bar is one view across the tabs (`MainTabs`), so a press slides it there
        // from the tab left, first visit or not. Its offset carries the spring alone; the fold
        // and the morph keep the container's animation.
        .background(alignment: .leading) {
            if !folded {
                pill
                    .offset(x: Self.pillOffset(for: selection))
                    .animation(.spring(Self.pillTravel), value: selection)
            }
        }
        .padding(.horizontal, folded ? DesignTokens.Space.tight : DesignTokens.Space.snug)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(GlassID.main, in: glass)
        .modifier(MainGlassMarker(shape: folded ? .folded : .tabs))
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
        // toolbar 48 (measured under the retired `system` style).
        LibraryScopePicker(scope: scope)
            .controlSize(.extraLarge)
            .padding(5)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID(GlassID.scope, in: glass)
    }

    /// The selected tab's pill, the system bar's: 54 pt tall, a little wider than its tab.
    private var pill: some View {
        Capsule()
            .fill(Self.pillFill)
            .frame(width: Self.pillWidth, height: 54)
            .background {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Selection")
                    .accessibilityIdentifier(Self.pillIdentifier)
            }
    }

    /// What a render test finds the selection pill by.
    static let pillIdentifier = "main-bar-pill"

    private func item(_ tab: MainTab, titled: Bool, width: CGFloat) -> some View {
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
            .frame(width: titled ? Self.itemWidth : 54, height: 54)
            .contentShape(Capsule())
        }
        .buttonStyle(BarItemPress(width: width, held: heldPress == tab))
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

/// A tab in the capsule: pressed, it swells with a pill of its own under it and springs back on
/// release — the system bar's bulge under the finger, drawn on the one glass rather than as a
/// glass of its own, so the capsule stays one glass. It holds the tab's frame and clip: the clip
/// is the fold's, which narrows the tabs it hides to nothing, and gives a swollen tab room only
/// while it is pressed, so the fold and the unfold are drawn as before.
private struct BarItemPress: ButtonStyle {
    let width: CGFloat
    let held: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || held
        configuration.label
            .background {
                if pressed { Capsule().fill(LeadingMainBar.pillFill) }
            }
            .scaleEffect(pressed ? LeadingMainBar.pressScale : 1)
            .frame(width: width)
            .clipShape(Rectangle().inset(by: pressed ? -12 : 0))
            .animation(LeadingMainBar.pressSpring, value: pressed)
    }
}

extension EnvironmentValues {
    /// A tab the leading bar draws as pressed with no finger on it: the simulator's screen
    /// recording has no touch to give (MEMNG-690).
    @Entry var leadingBarHeldPress: MainTab?
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
