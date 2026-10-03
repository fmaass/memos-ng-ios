import MemosCore
import SwiftUI

/// The app's bottom chrome: the one bar that stands at the bottom of each tab's root
/// (MEMNG-604, MEMNG-679, MEMNG-684).
///
/// That bar is ONE derived value, `bar(on:)` (`DockBar`): the system tab bar, the Library's scope
/// toolbar, select mode's toolbar, or none, computed from `DockMode`, the tab and what holds the
/// claim. Every bar reads that value and keeps no condition of its own, so no two stand at once.
/// The mode is moved by presses and by the Library's own scroll. A claim decides the bar alone
/// and leaves the mode as it was, so ending it brings back whichever bar was there — a scroll
/// that arrives under a claim is dropped for that reason, and a claim or a release opens the same
/// settling window a swap does — and holds the Library's idle moves until its scroll view next
/// moves (`DockScrollFence`) — so the offset the layout moves as the bars come or go is no scroll
/// either. Two parties claim it: select mode (`DockClaim.select`), whose toolbar then
/// stands in the bars' place, as in Photos, and a pushed screen that stands for the whole app
/// (`StackChrome`, `DockClaim.takeover`), which leaves nothing there.
@MainActor
@Observable
final class AppDock {
    private(set) var mode: DockMode = .initial
    /// What holds the chrome, one claim per holder: select mode's, and each screen on top of a
    /// stack that takes the chrome away while it is up.
    private var claims: [UUID: DockClaim] = [:]
    /// The tab on screen, as the presses and selections the dock hears tell it; nil until the
    /// first of them. What a scroll is judged against: a Library scroll view that reports while
    /// another tab shows changes nothing. Not observed: nothing is drawn from it.
    @ObservationIgnored private(set) var showing: MainTab?
    /// When the bars last swapped — the mode changed, another tab came on screen, a claim was
    /// made or ended — nil until they first do. What a Library scroll view's layout settles from
    /// (`DockScrollFence`). Not observed: nothing is drawn from it.
    @ObservationIgnored private(set) var swappedAt: ContinuousClock.Instant?
    /// When a claim was last made or ended, nil until one is: what holds a Library scroll view's
    /// idle moves until it next moves (`DockScrollFence`). Not observed: nothing is drawn from it.
    @ObservationIgnored private(set) var heldAt: ContinuousClock.Instant?
    /// When a Library scroll view last asked to be scrolled to a place of the app's choosing, until
    /// the move it explains claims it. Not observed: nothing is drawn from it.
    @ObservationIgnored private var jumpAskedAt: ContinuousClock.Instant?

    init() {}

    var isTakenOver: Bool { !claims.isEmpty }

    /// What holds the chrome, nil when nothing does. A takeover outranks select mode: a screen
    /// that stands for the whole app leaves no bar, whatever is under it.
    var claimant: DockClaim? {
        if claims.values.contains(.takeover) { return .takeover }
        return claims.isEmpty ? nil : .select
    }

    /// The one bar that stands under `tab`'s root (`DockBar`): what every bar is drawn from.
    func bar(on tab: MainTab) -> DockBar {
        DockBar.standing(mode: mode, on: tab, claim: claimant)
    }

    /// `id` holds the chrome for `kind` until it is released. A claim made or changed is a swap of
    /// the bars, stamped as one; a claim delivered twice claims once and is stamped once.
    func claim(_ id: UUID, for kind: DockClaim) {
        guard claims.updateValue(kind, forKey: id) != kind else { return }
        swappedAt = .now
        heldAt = swappedAt
    }

    /// Ends `id`'s claim. The bars it hid come back, a swap stamped as one; a release with nothing
    /// claimed changes nothing and is not stamped.
    func release(_ id: UUID) {
        guard claims.removeValue(forKey: id) != nil else { return }
        swappedAt = .now
        heldAt = swappedAt
    }

    func send(_ event: DockEvent) {
        let shown = showing
        switch event {
        // A press moves the selection to the tab pressed, the tab showing pressed again included.
        case .pressedTab(let tab, _), .selected(let tab):
            showing = tab
        case .pressedLibraryIcon, .scrolled:
            break
        }
        let next = mode.after(event)
        if next != mode || showing != shown { swappedAt = .now }
        if next != mode { mode = next }
    }

    /// A Library scroll view is about to scroll itself to a place of the app's choosing — a day's
    /// landing, a month: the next move of an offset is that jump, not the layout settling, and
    /// counts inside a swap's window too. Asked on the main actor right before the scroll.
    func askedToJump() { jumpAskedAt = .now }

    /// Whether a jump asked for within `DockScrollFence.settling` before `instant` explains an
    /// offset that moved at `instant`. Claims it: one ask explains one move, and an ask nothing
    /// followed lapses rather than letting a later echo through.
    func claimJump(at instant: ContinuousClock.Instant) -> Bool {
        guard let asked = jumpAskedAt else { return false }
        jumpAskedAt = nil
        return instant < asked.advanced(by: DockScrollFence.settling)
    }

    /// One of the Library's scroll views now stands `y` points from the top of its content.
    /// Dropped while a claim holds the chrome, so ending the claim brings back the bar it hid, and
    /// before any tab is known to be on screen.
    func scrolled(to y: Double) {
        guard !isTakenOver, let showing else { return }
        send(.scrolled(y: y, showing: showing))
    }

    /// One reading of a Library scroll view, judged by that scroll view's `fence` against this
    /// dock's last swap and told as a scroll when it is one: the whole of `DockFeed`'s work, here
    /// so a test can drive the path a reading takes. `moving` is whether the scroll view was
    /// moving; the first move after an asked jump counts as moving (`askedToJump`).
    func scrolled(
        from previous: DockScrollReading,
        to now: DockScrollReading,
        judgedBy fence: inout DockScrollFence,
        moving: Bool,
        at instant: ContinuousClock.Instant = .now
    ) {
        let asked = now.y != previous.y && claimJump(at: instant)
        let y = fence.scrolled(
            from: previous, to: now, at: instant, swappedAt: swappedAt, heldAt: heldAt,
            moving: moving || asked)
        guard let y else { return }
        scrolled(to: y)
    }
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
        .frame(width: Self.width)
        .accessibilityIdentifier(Self.identifier)
    }

    /// How wide the control is drawn (MEMNG-680): left to itself it stretches to the bar's
    /// trailing edge; at this width its glass hugs the Library icon and ends near 79 % of a 402 pt
    /// window, as Photos' does. A trailing spacer alone left it full width, and a cap alone
    /// (`maxWidth`) let the bar shrink it until its titles were cut.
    static let width: CGFloat = 220

    /// What the control is found by, in a test and by VoiceOver's rotor alike.
    static let identifier = "library-scope"
}

/// The three tabs, each with its own navigation stack and scroll position, under the SYSTEM tab
/// bar (MEMNG-666), which steps aside on the Library for its scope toolbar (MEMNG-604, MEMNG-679).
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
                            dock.bar(on: tab) == .tabs ? .automatic : .hidden,
                            for: .tabBar
                        )
                }
            }
        }
        .tabBarMinimizeBehavior(Self.minimizesOnScroll(on: selection) ? .onScrollDown : .never)
        .environment(dock)
        .environment(scope)
        // Every way off the Library — a press in the bar or a jump to a memo — gives the tabs
        // back, so coming back finds them. Initially too, so the dock knows the tab it opens on.
        .onChange(of: selection, initial: true) { _, now in dock.send(.selected(now)) }
    }

    /// Whether the system bar folds to its selected tab while `tab` scrolls down. Not on the
    /// Library: a bar shrunk there to a lone icon with no control beside it would be a third
    /// state, and its scroll swaps the bar for its scope toolbar instead.
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
                if takesOver { dock?.claim(claim, for: .takeover) }
            }
            .onDisappear {
                dock?.release(claim)
            }
    }
}

extension View {
    /// Tells the dock each time the Library scroll view inside this view is scrolled: how far it
    /// then stands from the top of its content, 0 at rest, negative while rubber-banding. Only the
    /// Library's scroll views feed it.
    func feedsDock(_ dock: AppDock?) -> some View {
        modifier(DockFeed(dock: dock))
    }
}

/// A Library scroll view's feed to the dock. What the layout does on its own as a bar comes or
/// goes — a new frame, and the offset the system moves to keep the rows on screen in place — is
/// not told (`DockScrollFence`), so a bar's coming or going cannot swap the bars straight back;
/// a move made while the scroll view is moving always is, and so is the first move after the
/// Library asked to jump (`AppDock.askedToJump`).
private struct DockFeed: ViewModifier {
    let dock: AppDock?
    /// Per scroll view: each of the Library's three has its own layout to settle. A reference
    /// rather than observed state, for the reason `LibraryGrid`'s `onScreen` is one: it is asked
    /// on every reading, and nothing is drawn from it.
    @State private var fence = Fence()

    private final class Fence {
        var judge = DockScrollFence()
        /// Whether the scroll view is moving: a drag, its deceleration, an animated scroll.
        var moving = false
    }

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: DockScrollReading.self) { geometry in
            DockScrollReading(
                y: Double(geometry.contentOffset.y + geometry.contentInsets.top),
                width: Double(geometry.containerSize.width),
                height: Double(geometry.containerSize.height),
                insetTop: Double(geometry.contentInsets.top),
                insetLeading: Double(geometry.contentInsets.leading),
                insetBottom: Double(geometry.contentInsets.bottom),
                insetTrailing: Double(geometry.contentInsets.trailing)
            )
        } action: { previous, now in
            dock?.scrolled(from: previous, to: now, judgedBy: &fence.judge, moving: fence.moving)
        }
        .onScrollPhaseChange { _, phase in fence.moving = phase.isScrolling }
    }
}
