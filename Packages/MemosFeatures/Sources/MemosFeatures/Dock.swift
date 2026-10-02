import MemosCore
import SwiftUI

/// The app's bottom chrome: which of the Library's two bars stands there, and whether a screen
/// has taken the chrome away for every tab at once (MEMNG-604).
///
/// The bars are `DockMode`'s: the system tab bar, or the Library's scope toolbar in its place,
/// moved only by presses. A claim takes both away, on every tab root, and leaves the mode as it
/// was, so ending it brings back whichever bar was there. Two parties claim it: select mode, whose
/// toolbar is then the only bottom chrome, as in Photos, and a pushed screen that stands for the
/// whole app (`StackChrome`), which also hides the bar on itself.
@MainActor
@Observable
final class AppDock {
    private(set) var mode: DockMode = .initial
    /// Screens on top of a stack that take the chrome away while they are up, one claim each.
    private var takeovers: Set<UUID> = []

    init() {}

    var isTakenOver: Bool { !takeovers.isEmpty }

    func claim(_ id: UUID) { takeovers.insert(id) }

    func release(_ id: UUID) { takeovers.remove(id) }

    func send(_ event: DockEvent) {
        let next = mode.after(event)
        if next != mode { mode = next }
    }

    /// Whether `tab`'s root stands over the system tab bar: not while a claim holds the chrome,
    /// and not on the Library while its scope toolbar has the bar's place.
    func showsSystemBar(on tab: MainTab) -> Bool {
        !isTakenOver && !(tab == .library && mode == .scope)
    }

    /// Whether the Library draws its scope toolbar. The mode is the tabs on every other tab, so
    /// this is the Library's alone.
    var showsScopeBar: Bool { mode == .scope && !isTakenOver }
}

/// Which of Years, Months and All the Library shows, and the year a Years card narrowed Months to.
///
/// Shared rather than the Library's own (plan page 3929 decision 11: "the Library-only segment is
/// injected by the view"): the control in the scope toolbar and the Library's views must read one
/// answer, because a day tile's jump or a year card's tap moves the scope from inside the
/// Library, and the control has to show where it went.
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

    /// A choice made in the scope control. It widens Months back to every year, because the
    /// narrowing belongs to the Years card that asked for it.
    func choose(_ chosen: LibraryScope) {
        // A jump still reading was on its way to the view being left; it lands nowhere.
        if chosen != scope { handChoiceAction?() }
        year = nil
        monthTarget = nil
        scope = chosen
    }

    /// The date pill's tap in All: Months, across every year, at that month. Leaving All by hand
    /// abandons a jump still reading, as a choice in the scope control does.
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

/// Years | Months | All, as the system's segmented control in the Library's scope toolbar
/// (MEMNG-604): a picker bound to the Library's scope, whose glass and selection iOS draws.
struct LibraryScopePicker: View {
    let scope: LibraryScopeChoice

    var body: some View {
        Picker(
            "Library view",
            selection: Binding(get: { scope.scope }, set: { scope.choose($0) })
        ) {
            ForEach(LibraryScope.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(Self.identifier)
    }

    /// What the control is found by, in a test and by VoiceOver's rotor alike.
    static let identifier = "library-scope"
}

/// The three tabs, each with its own navigation stack and scroll position, under the SYSTEM tab
/// bar (MEMNG-666), which steps aside on the Library for its scope toolbar (MEMNG-604).
///
/// The bar is the `TabView`'s own, so iOS draws its Liquid Glass, the selection's morph between
/// tabs and its minimising on scroll on Timeline and Places. The app decides only WHEN it stands
/// aside: on the Library while `AppDock`'s mode is the scope, and under a claim.
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
                        // A condition, never a constant: at rest the bar is the system's to
                        // draw, and a root that said `.automatic` while a takeover's destination
                        // said `.hidden` would bring the bar back under it.
                        .toolbarVisibility(
                            dock.showsSystemBar(on: tab) ? .automatic : .hidden,
                            for: .tabBar
                        )
                }
            }
        }
        .tabBarMinimizeBehavior(Self.minimizesOnScroll(on: selection) ? .onScrollDown : .never)
        .environment(dock)
        .environment(scope)
        // Every way off the Library — a press in the bar or a jump to a memo — gives the tabs
        // back, so coming back finds them.
        .onChange(of: selection) { _, now in dock.send(.selected(now)) }
    }

    /// Whether the system bar folds to its selected tab while `tab` scrolls down. Not on the
    /// Library: a bar shrunk there to a lone icon with no control beside it would be a third
    /// state, and its scope toolbar is reached by a press instead.
    static func minimizesOnScroll(on tab: MainTab) -> Bool {
        tab != .library
    }

    /// The selection the `TabView` is handed, which only the system bar writes: a press on
    /// another tab sets that tab, and a press on the tab already showing sets the value the
    /// selection already holds. Each press is told to the dock BEFORE the selection moves, so
    /// the one place that decides what a press does is `DockMode.after(_:)`.
    static func pressing(selection: Binding<MainTab>, dock: AppDock) -> Binding<MainTab> {
        Binding(
            get: { selection.wrappedValue },
            set: { tab in
                dock.send(.pressedTab(tab, showing: selection.wrappedValue))
                if tab != selection.wrappedValue { selection.wrappedValue = tab }
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
