import MemosCore
import SwiftUI

/// The dock's state, and whether a screen has taken it away, for every tab at once.
///
/// One object rather than a `@State` inside the bar because three parties write to it: the bar's
/// own taps, the Library's scroll view, and a pushed screen that stands for the whole app. The
/// rule each event is judged by is `DockMode.after(_:)`; this only holds its answer.
@MainActor
@Observable
final class AppDock {
    private(set) var mode: DockMode = .initial
    /// Screens on top of a stack that take the dock away while they are up, one claim each.
    private var takeovers: Set<UUID> = []

    init() {}

    func send(_ event: DockEvent) {
        let next = mode.after(event)
        // Unchanged is not written, so an idle scroll invalidates nothing that reads the mode.
        if next != mode { mode = next }
    }

    /// Whether the dock is the Library's segment on `tab`. The tab check is the reducer's too;
    /// repeating it here keeps the segment off every other tab for the instant between a switch
    /// and the `leaveLibrary` that follows it — the web dock does the same.
    func showsSegment(on tab: MainTab) -> Bool {
        tab == .library && mode == .segment
    }

    var isTakenOver: Bool { !takeovers.isEmpty }

    /// Whether the system tab bar is drawn under `tab`: on every root at rest, and not while the
    /// Library's segment stands in its place or a screen has taken the whole app over.
    func showsSystemBar(on tab: MainTab) -> Bool {
        !isTakenOver && !showsSegment(on: tab)
    }

    func claim(_ id: UUID) { takeovers.insert(id) }

    func release(_ id: UUID) { takeovers.remove(id) }
}

/// Which of Years, Months and All the Library shows, and the year a Years card narrowed Months to.
///
/// Out of the Library's own state because the segment that picks it is drawn by the dock, not by
/// the Library (plan page 3929 decision 11: "the Library-only segment is injected by the view"),
/// and both must read one answer: a day tile's jump or a year card's tap moves the scope from
/// inside the Library, and the segment in the dock has to show where it went.
@MainActor
@Observable
final class LibraryScopeChoice {
    private(set) var scope: LibraryScope = .all
    private(set) var year: String?
    /// The `YYYY-MM` month the date pill asked Months to open at, until Months has scrolled to it
    /// (plan page 3929 decision 13).
    private(set) var monthTarget: String?
    /// What a choice made by hand also does to the Library — abandoning a jump still reading. Set
    /// by the Library, which owns the store the jump is reading on, and called synchronously so
    /// no page of the abandoned jump can land between the choice and the abandonment.
    private var handChoiceAction: (@MainActor () -> Void)?

    init() {}

    /// Registers what a choice made by hand must also do. The last registration wins.
    func whenChosenByHand(_ action: @escaping @MainActor () -> Void) {
        handChoiceAction = action
    }

    /// A choice made in the segment. It widens Months back to every year, because the narrowing
    /// belongs to the Years card that asked for it.
    func choose(_ chosen: LibraryScope) {
        // A jump still reading was on its way to the view being left; it lands nowhere.
        if chosen != scope { handChoiceAction?() }
        year = nil
        monthTarget = nil
        scope = chosen
    }

    /// The date pill's tap in All: Months, across every year, at that month. Leaving All by hand
    /// abandons a jump still reading, as a choice in the segment does.
    func showMonth(_ key: String) {
        if scope != .months { handChoiceAction?() }
        year = nil
        monthTarget = key
        scope = .months
    }

    /// Months has scrolled to the pill's month, or found it is not among its months.
    func consumeMonthTarget() {
        monthTarget = nil
    }

    /// A Years card: that year's days in Months.
    func showMonths(of key: String) {
        year = key
        monthTarget = nil
        scope = .months
    }

    /// A day tile: the All grid, where the jump lands.
    func showAll() {
        monthTarget = nil
        scope = .all
    }

    func clearYear() {
        year = nil
    }
}

/// The Library's collapsed chrome (plan page 3929 decision 8): the Library icon beside
/// Years | Months | All, drawn in the system tab bar's place while the Library is in its segment.
///
/// Everything else the bar used to draw by hand is the system's now (MEMNG-666): the tabs, their
/// glass and the selection's morph between them. This is the one part the system bar cannot be —
/// it has no state in which it turns into a picker — so it stays the app's, on the Library alone,
/// and it gives the bar back through its icon.
struct LibrarySegmentBar: View {
    let dock: AppDock
    let scope: LibraryScopeChoice

    var body: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            Button {
                dock.send(.tapActive(.library))
            } label: {
                Image(systemName: MainTab.library.symbol)
                    .symbolVariant(.fill)
                    .font(.body)
                    .foregroundStyle(DesignTokens.accent)
                    .padding(.vertical, DesignTokens.Space.snug)
                    .padding(.horizontal, DesignTokens.Space.roomy)
                    .background(Capsule().fill(DesignTokens.accent.opacity(0.15)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MainTab.library.title)

            ForEach(LibraryScope.allCases) { option in
                let chosen = option == scope.scope
                Button {
                    scope.choose(option)
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(chosen ? .semibold : .regular))
                        .padding(.vertical, DesignTokens.Space.snug)
                        .padding(.horizontal, DesignTokens.Space.roomy)
                        .foregroundStyle(
                            chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                        )
                        .background {
                            if chosen {
                                Capsule().fill(.primary.opacity(0.12))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(DesignTokens.Space.tight)
        // Interactive, as the system bar's own glass is: it answers a press with the glass's
        // light and give, which the static material cannot (MEMNG-604 #6).
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.bottom, DesignTokens.Space.tight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    /// What the chrome is found by, in a test and by VoiceOver's rotor alike.
    static let identifier = "library-segment"
}

/// The three tabs, each with its own navigation stack and scroll position, under the SYSTEM tab
/// bar (MEMNG-666).
///
/// The bar is the `TabView`'s own, so iOS draws its Liquid Glass, the selection's morph between
/// tabs and its minimising on scroll itself — none of which a bar drawn by hand can borrow. The
/// app decides only WHEN it stands aside: under the Library's segment, and under a screen that
/// takes the whole app over (`AppDock.showsSystemBar(on:)`). The segment sits in the Library tab's
/// bottom safe-area inset, outside its navigation stack, so the last row of every scroll view
/// stops above it rather than under it.
struct MainTabs<Screen: View>: View {
    @Binding var selection: MainTab
    @ViewBuilder let screen: (MainTab) -> Screen
    @State private var dock = AppDock()
    @State private var scope = LibraryScopeChoice()

    var body: some View {
        TabView(selection: Self.pressing(selection: $selection, dock: dock)) {
            ForEach(MainTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    screen(tab)
                        // A condition, never a constant: on every root at rest the bar is the
                        // system's to draw, and only the dock's rule takes it away.
                        .toolbarVisibility(
                            dock.showsSystemBar(on: tab) ? .automatic : .hidden,
                            for: .tabBar
                        )
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if dock.showsSegment(on: tab), !dock.isTakenOver {
                                LibrarySegmentBar(dock: dock, scope: scope)
                            }
                        }
                }
            }
        }
        .tabBarMinimizeBehavior(Self.minimizesOnScroll(on: selection) ? .onScrollDown : .never)
        .environment(dock)
        .environment(scope)
        // Every way off the Library — a tap in the bar or a memo jump from the viewer — resets it,
        // so coming back finds the tabs.
        .onChange(of: selection) { _, now in
            if now != .library { dock.send(.leaveLibrary) }
        }
    }

    /// Whether the system bar folds to its selected tab while `tab` scrolls down. Everywhere but
    /// the Library, which collapses to its own chrome instead: a bar left minimised under that
    /// chrome would come back folded when the Library icon gives it back, and the icon's tap is
    /// meant to show Library | Timeline | Places at once (MEMNG-653).
    static func minimizesOnScroll(on tab: MainTab) -> Bool {
        tab != .library
    }

    /// The selection the `TabView` is handed, pressed the way the system bar presses it: a tap on
    /// another tab is a set of that tab, and a tap on the tab already showing is a set of the value
    /// the selection already holds. The first moves the selection; the second is the dock's
    /// `tapActive` and writes nothing — on the Library it is what collapses the bar to the segment.
    static func pressing(selection: Binding<MainTab>, dock: AppDock) -> Binding<MainTab> {
        Binding(
            get: { selection.wrappedValue },
            set: { tab in
                if tab == selection.wrappedValue {
                    dock.send(.tapActive(tab))
                } else {
                    selection.wrappedValue = tab
                }
            }
        )
    }
}

/// A pushed screen's claim on the dock: a screen that takes it over holds one claim while it is
/// up. A claim is a set member rather than a count, so an appearance delivered twice claims once.
struct DockTakeover: ViewModifier {
    let takesOver: Bool
    @Environment(AppDock.self) private var dock: AppDock?
    @State private var claim = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear {
                if takesOver { dock?.claim(claim) }
            }
            .onDisappear {
                dock?.release(claim)
            }
    }
}

extension View {
    /// Tells the dock how far the scroll view inside this view is from the top of its content: 0
    /// at rest, negative while rubber-banding. Only the Library's scroll views feed it; the dock's
    /// rule ignores every other tab anyway.
    func feedsDock(_ dock: AppDock?, on tab: MainTab) -> some View {
        onScrollGeometryChange(for: Double.self) { geometry in
            Double(geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, y in
            dock?.send(.scroll(y: y, tab: tab))
        }
    }
}
