import MemosCore
import SwiftUI

/// Whether a screen has taken the app's bottom chrome away, for every tab at once.
///
/// A claim takes the system tab bar and the Library's scope control in its accessory away
/// together, on every tab root (MEMNG-604). Two parties claim it: select mode, whose toolbar is
/// then the only bottom chrome, as in Photos, and a pushed screen that stands for the whole app
/// (`StackChrome`), which also hides the bar on itself.
@MainActor
@Observable
final class AppDock {
    /// Screens on top of a stack that take the chrome away while they are up, one claim each.
    private var takeovers: Set<UUID> = []

    init() {}

    var isTakenOver: Bool { !takeovers.isEmpty }

    func claim(_ id: UUID) { takeovers.insert(id) }

    func release(_ id: UUID) { takeovers.remove(id) }
}

/// Which of Years, Months and All the Library shows, and the year a Years card narrowed Months to.
///
/// Out of the Library's own state because the control that picks it is drawn in the tab bar's
/// accessory, not by the Library (plan page 3929 decision 11: "the Library-only segment is
/// injected by the view"), and both must read one answer: a day tile's jump or a year card's tap
/// moves the scope from inside the Library, and the control has to show where it went.
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

/// Years | Months | All, as the system's segmented control in the tab bar's bottom accessory
/// (MEMNG-604).
///
/// iOS draws the accessory's glass, stands it above the bar while the bar is expanded and beside
/// the bar once a scroll has minimised it, and animates the selection; the app hands it a picker
/// bound to the Library's scope and nothing drawn by hand. Its only adaptation is its side
/// margin, read from the placement the system reports, because the inline slot is narrow.
struct LibraryScopePicker: View {
    let scope: LibraryScopeChoice
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

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
        .padding(
            .horizontal,
            placement == .inline ? DesignTokens.Space.tight : DesignTokens.Space.roomy
        )
        .accessibilityIdentifier(Self.identifier)
    }

    /// What the control is found by, in a test and by VoiceOver's rotor alike.
    static let identifier = "library-scope"
}

/// The three tabs, each with its own navigation stack and scroll position, under the SYSTEM tab
/// bar (MEMNG-666), with the Library's scope in the bar's bottom accessory (MEMNG-604).
///
/// The bar is the `TabView`'s own, so iOS draws its Liquid Glass, the selection's morph between
/// tabs and its minimising on scroll itself — on every tab alike, the Library included. Only a
/// claim on the dock hides it: select mode, or a screen that takes the whole app over.
struct MainTabs<Screen: View>: View {
    @Binding var selection: MainTab
    @ViewBuilder let screen: (MainTab) -> Screen
    @State private var dock = AppDock()
    @State private var scope = LibraryScopeChoice()

    var body: some View {
        TabView(selection: $selection) {
            ForEach(MainTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    screen(tab)
                        // A condition, never a constant: at rest the bar is the system's to
                        // draw, and a root that said `.automatic` while a takeover's destination
                        // said `.hidden` would bring the bar back under it.
                        .toolbarVisibility(dock.isTakenOver ? .hidden : .automatic, for: .tabBar)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .libraryScopeAccessory(shown: Self.showsScope(on: selection, dock: dock), scope: scope)
        .environment(dock)
        .environment(scope)
    }

    /// Whether the accessory carries the scope control: on the Library alone, and not while select
    /// mode or a screen that takes the app over has claimed the chrome.
    static func showsScope(on tab: MainTab, dock: AppDock) -> Bool {
        tab == .library && !dock.isTakenOver
    }
}

extension View {
    /// The scope control in the tab bar's bottom accessory while `shown`, and no accessory at all
    /// otherwise.
    ///
    /// `isEnabled` is iOS 26.1's: it takes the accessory away without changing the view it is
    /// declared on, so the tabs keep their state. iOS 26.0, the deployment target, has only the
    /// unconditional accessory; there the content empties instead, which can leave the system's
    /// empty accessory standing on Timeline and Places.
    @ViewBuilder
    fileprivate func libraryScopeAccessory(shown: Bool, scope: LibraryScopeChoice) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: shown) {
                LibraryScopePicker(scope: scope)
            }
        } else {
            tabViewBottomAccessory {
                if shown { LibraryScopePicker(scope: scope) }
            }
        }
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
