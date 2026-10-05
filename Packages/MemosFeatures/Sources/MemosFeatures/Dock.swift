import MemosCore
import SwiftUI

/// The app's bottom chrome: the one bar that stands at the bottom of each tab's root
/// (MEMNG-604, MEMNG-679, MEMNG-684, MEMNG-685).
///
/// That bar is ONE derived value, `bar(on:)` (`DockBar`): the system tab bar, the Library's scope
/// toolbar, select mode's toolbar, or none, computed from `DockMode`, the tab and what holds the
/// claim. Every bar reads that value and keeps no condition of its own, so no two stand at once.
/// The mode is moved by presses and by the Library's own scroll: down past the threshold to the
/// scope, back to the top to the tabs — a scroll's top alone, not the landing of a scope pick
/// (`pickedScope`) nor a jump the Library asked for (`askedToJump`), which the dock tells apart
/// as each reading arrives (`DockScrollKind`). A claim decides the bar alone
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
    /// Whether a scope pick's landing is unsettled: a pick swapped the Library's scroll view and
    /// no scroll view has moved since. Not observed: nothing is drawn from it.
    @ObservationIgnored private var landing = false

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
        case .pressedLibraryIcon, .scrolled, .scrolledTab:
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

    /// The Library's scope moved — a pick in the scope control, a Years card, a day tile, the date
    /// pill — and swaps its scroll view for another: what the layout settles of the two before a
    /// scroll view next moves is that pick's landing, which gives no tabs back at the top
    /// (MEMNG-685). Told on the main actor before the scope moves.
    func pickedScope() { landing = true }

    /// Whether a jump asked for within `DockScrollFence.settling` before `instant` explains an
    /// offset that moved at `instant`. Claims it: one ask explains one move, and an ask nothing
    /// followed lapses rather than letting a later echo through.
    func claimJump(at instant: ContinuousClock.Instant) -> Bool {
        guard let asked = jumpAskedAt else { return false }
        jumpAskedAt = nil
        return instant < asked.advanced(by: DockScrollFence.settling)
    }

    /// One of the Library's scroll views now stands `y` points from the top of its content, moved
    /// by `kind`. Dropped while a claim holds the chrome, so ending the claim brings back the bar
    /// it hid, and before any tab is known to be on screen.
    func scrolled(to y: Double, by kind: DockScrollKind) {
        guard !isTakenOver, let showing else { return }
        send(.scrolled(y: y, showing: showing, by: kind))
    }

    /// One reading of a Library scroll view, judged by that scroll view's `fence` against this
    /// dock's last swap and told as a scroll when it is one: the whole of `DockFeed`'s work, here
    /// so a test can drive the path a reading takes. `moving` is whether the scroll view was
    /// moving; the first move after an asked jump counts as moving (`askedToJump`). What moved it
    /// travels with the offset (`DockScrollKind`): the jump asked, a scope pick's landing while no
    /// scroll view has moved since the pick, else a scroll. A move made while the scroll view moves
    /// ends a pick's landing.
    func scrolled(
        from previous: DockScrollReading,
        to now: DockScrollReading,
        judgedBy fence: inout DockScrollFence,
        moving: Bool,
        at instant: ContinuousClock.Instant = .now,
        on tab: MainTab = .library
    ) {
        // Another tab's scroll view (the Timeline's): its moves fold and unfold the leading bar,
        // judged in `DockMode` by whether the reader moved it. The Library's jumps, landings and
        // settling are the Library's alone, so none of them is asked here.
        guard tab == .library else {
            guard now.y != previous.y, !isTakenOver, let showing else { return }
            send(
                .scrolledTab(
                    tab, y: now.y, travel: now.y - previous.y, showing: showing, moving: moving))
            return
        }
        let asked = now.y != previous.y && claimJump(at: instant)
        let kind = DockScrollKind.of(asked: asked, moving: moving, landing: landing)
        if moving { landing = false }
        let y = fence.scrolled(
            from: previous, to: now, at: instant, swappedAt: swappedAt, heldAt: heldAt,
            moving: moving || asked)
        guard let y else { return }
        scrolled(to: y, by: kind)
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
    /// What every move of the scope also does — telling the dock the Library's scroll view is
    /// swapped for another (`AppDock.pickedScope`, MEMNG-685). Set by the tabs, which own the dock.
    private var scopeMovedAction: (@MainActor () -> Void)?

    init() {}

    /// Registers what a choice made by hand must also do. The last registration wins.
    func whenChosenByHand(_ action: @escaping @MainActor () -> Void) {
        handChoiceAction = action
    }

    /// Registers what every move of the scope must also do, called before the scope moves. The
    /// last registration wins.
    func whenScopeMoves(_ action: @escaping @MainActor () -> Void) {
        scopeMovedAction = action
    }

    /// The scope becomes `next`; a move to another scope is told first.
    private func move(to next: LibraryScope) {
        if next != scope { scopeMovedAction?() }
        scope = next
    }

    /// A choice made in the scope control. It widens Months back to every year, because the
    /// narrowing belongs to the Years card that asked for it.
    func choose(_ chosen: LibraryScope) {
        // A jump still reading was on its way to the view being left; it lands nowhere.
        if chosen != scope { handChoiceAction?() }
        year = nil
        monthTarget = nil
        move(to: chosen)
    }

    /// The date pill's tap in All: Months, across every year, at that month. Leaving All by hand
    /// abandons a jump still reading, as a choice in the scope control does.
    func showMonth(_ key: String) {
        if scope != .months { handChoiceAction?() }
        year = nil
        monthTarget = key
        move(to: .months)
    }

    /// Months has scrolled to the pill's month, or found it is not among its months.
    func consumeMonthTarget() {
        monthTarget = nil
    }

    /// A Years card: that year's days in Months.
    func showMonths(of key: String) {
        year = key
        monthTarget = nil
        move(to: .months)
    }

    /// A day tile: the All grid, where the jump lands.
    func showAll() {
        monthTarget = nil
        move(to: .all)
    }

    func clearYear() {
        year = nil
    }
}

/// Years | Months | All, as the system's segmented control in the Library's scope row
/// (MEMNG-604, MEMNG-690): a picker bound to the Library's scope, whose selection iOS draws.
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
/// bar (MEMNG-666), which steps aside on the Library for its scope row (MEMNG-604, MEMNG-679).
///
/// The bar is the `TabView`'s own, so iOS draws its Liquid Glass, the selection's morph between
/// tabs and its minimising on scroll on Timeline and Places. The app decides only WHEN it stands
/// aside: on the Library while `AppDock`'s mode is the scope, and under a claim. The scope row is
/// the app's own glass under both styles (`LeadingMainBar`, MEMNG-690).
struct MainTabs<Screen: View>: View {
    @Binding var selection: MainTab
    @ViewBuilder let screen: (MainTab) -> Screen
    @State private var dock = AppDock()
    @State private var scope = LibraryScopeChoice()
    /// The bar style a host put in the environment, else the device's (`BarStylePreference`).
    @Environment(BarStylePreference.self) private var styleHost: BarStylePreference?

    private var style: BarStyle { (styleHost ?? .shared).style }

    var body: some View {
        TabView(selection: Self.pressing(selection: $selection, dock: dock)) {
            ForEach(MainTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    screen(tab)
                        // A condition, never a constant: at rest the bar is the system's to
                        // draw, and a root that said `.automatic` while a takeover's destination
                        // said `.hidden` would bring the bar back under it. Keyed on the SELECTED
                        // tab, not this screen's: there is one tab bar and every screen built so
                        // far keeps saying its value. Keyed per screen, a Timeline built before
                        // the Library said `.automatic` once Select's claim ended while the
                        // Library said `.hidden`, and the bar stood beside the scope toolbar.
                        .toolbarVisibility(
                            Self.systemBar(for: dock.bar(on: selection), style: style),
                            for: .tabBar
                        )
                        // Attached under every style, its content empty under the system's: a
                        // modifier that came and went with the style would rebuild the screen,
                        // and the switch is pressed in Settings, which that screen's stack holds.
                        // The system style's scope row is the Library's own, inside its stack
                        // (`MediaLibraryView.systemRow`): a change of what this bar holds moved
                        // the Library's grid to its top (MEMNG-690, build 39).
                        .safeAreaBar(edge: .bottom) {
                            if style == .leading, let shape = Self.leadingShape(dock, on: tab) {
                                LeadingMainBar(
                                    shape: shape,
                                    selection: selection,
                                    press: { pressed in
                                        Self.pressing(selection: $selection, dock: dock)
                                            .wrappedValue = pressed
                                    },
                                    pressLibraryIcon: { dock.send(.pressedLibraryIcon) },
                                    scope: scope
                                )
                            }
                        }
                }
            }
        }
        .tabBarMinimizeBehavior(
            Self.minimizesOnScroll(on: selection, style: style) ? .onScrollDown : .never
        )
        .environment(dock)
        .environment(scope)
        // A move of the scope swaps the Library's scroll view: the dock hears of it first.
        .onAppear { [dock] in scope.whenScopeMoves { dock.pickedScope() } }
        // Every way off the Library — a press in the bar or a jump to a memo — gives the tabs
        // back, so coming back finds them. Initially too, so the dock knows the tab it opens on.
        .onChange(of: selection, initial: true) { _, now in dock.send(.selected(now)) }
    }

    /// Whether the system bar folds to its selected tab while `tab` scrolls down. Not on the
    /// Library: a bar shrunk there to a lone icon with no control beside it would be a third
    /// state, and its scroll swaps the bar for its scope toolbar instead.
    static func minimizesOnScroll(on tab: MainTab, style: BarStyle = .system) -> Bool {
        style == .system && tab != .library
    }

    /// The system tab bar's visibility under the dock's one bar: shown where the tabs stand under
    /// the system style, hidden everywhere under the leading style, whose bar is the app's own.
    static func systemBar(for bar: DockBar, style: BarStyle) -> Visibility {
        bar == .tabs && style == .system ? .automatic : .hidden
    }

    /// What the leading bar draws under `tab`'s root: the capsule where the tabs stand, folded to
    /// its icon when the dock's mode folds it there, the scope row where the Library's scope
    /// stands, and nothing under a claim — select mode's toolbar is the Library's own.
    static func leadingShape(_ dock: AppDock, on tab: MainTab) -> LeadingMainBar.BarShape? {
        switch dock.bar(on: tab) {
        case .tabs: return dock.mode.folds(on: tab) ? .folded : .tabs
        case .scope: return .scope
        case .select, .none: return nil
        }
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
    /// Tells the dock each time the scroll view inside this view is scrolled: how far it then
    /// stands from the top of its content, 0 at rest, negative while rubber-banding. The Library's
    /// scroll views feed it, and the Timeline's list (`tab`), whose scrolls fold the leading bar.
    func feedsDock(_ dock: AppDock?, on tab: MainTab = .library) -> some View {
        modifier(DockFeed(dock: dock, tab: tab))
    }
}

/// A Library scroll view's feed to the dock. What the layout does on its own as a bar comes or
/// goes — a new frame, and the offset the system moves to keep the rows on screen in place — is
/// not told (`DockScrollFence`), so a bar's coming or going cannot swap the bars straight back;
/// a move made while the scroll view is moving always is, and so is the first move after the
/// Library asked to jump (`AppDock.askedToJump`).
private struct DockFeed: ViewModifier {
    let dock: AppDock?
    /// The tab whose scroll view this is: the Library's three, or the Timeline's list.
    let tab: MainTab
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
            dock?.scrolled(
                from: previous, to: now, judgedBy: &fence.judge, moving: fence.moving, on: tab)
        }
        .onScrollPhaseChange { _, phase in fence.moving = phase.isScrolling }
    }
}
