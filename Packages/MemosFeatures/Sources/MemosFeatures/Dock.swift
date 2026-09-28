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
        scope = chosen
    }

    /// A Years card: that year's days in Months.
    func showMonths(of key: String) {
        year = key
        scope = .months
    }

    /// A day tile: the All grid, where the jump lands.
    func showAll() {
        scope = .all
    }

    func clearYear() {
        year = nil
    }
}

/// The app's one-row bottom bar (plan page 3929 decisions 8 and 11).
///
/// The tab pill everywhere — icon plus label, the chosen tab filled — and, inside the Library once
/// it has been scrolled, the Library icon beside Years | Months | All. A tap on the chosen tab does
/// not navigate: on the Library it toggles the two states, so Years and Months stay reachable on a
/// library too short to scroll.
struct DockBar: View {
    @Binding var selection: MainTab
    let dock: AppDock
    let scope: LibraryScopeChoice

    var body: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            if dock.showsSegment(on: selection) {
                segment
            } else {
                tabs
            }
        }
        .padding(DesignTokens.Space.tight)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, DesignTokens.Space.roomy)
        .padding(.bottom, DesignTokens.Space.tight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    /// What the dock is found by, in a test and by VoiceOver's rotor alike.
    static let identifier = "app-dock"

    private var tabs: some View {
        ForEach(MainTab.allCases) { tab in
            let chosen = tab == selection
            Button {
                if chosen {
                    dock.send(.tapActive(tab))
                } else {
                    selection = tab
                }
            } label: {
                VStack(spacing: DesignTokens.Space.hair) {
                    Image(systemName: tab.symbol)
                        .symbolVariant(chosen ? .fill : .none)
                        .font(.body)
                    Text(tab.title)
                        .font(.caption2.weight(.medium))
                }
                .frame(minWidth: 72)
                .padding(.vertical, DesignTokens.Space.tight)
                .padding(.horizontal, DesignTokens.Space.regular)
                .foregroundStyle(
                    chosen ? AnyShapeStyle(DesignTokens.accent) : AnyShapeStyle(.secondary)
                )
                .background {
                    if chosen {
                        Capsule().fill(DesignTokens.accent.opacity(0.15))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // A label, not `.accessibilityElement(children: .ignore)`: that would put a new element
            // in the button's place, one that reads the title and takes no press.
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : [.isButton])
        }
    }

    private var segment: some View {
        Group {
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
    }
}

/// The three tabs, each with its own navigation stack and scroll position, under the dock.
///
/// A `TabView` still holds the tabs — it is what keeps each one's stack alive while another is on
/// screen, and what loads a tab only once it is first chosen — but its own bar is hidden: the
/// system bar cannot turn into the Library's segment. The dock sits in each tab's bottom safe-area
/// inset, OUTSIDE the tab's navigation stack, so it stays put while a memo is pushed, and the last
/// row of every scroll view stops above it rather than under it.
struct DockedTabs<Screen: View>: View {
    @Binding var selection: MainTab
    @ViewBuilder let screen: (MainTab) -> Screen
    @State private var dock = AppDock()
    @State private var scope = LibraryScopeChoice()

    var body: some View {
        TabView(selection: $selection) {
            ForEach(MainTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    screen(tab)
                        .toolbarVisibility(.hidden, for: .tabBar)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if !dock.isTakenOver {
                                DockBar(selection: $selection, dock: dock, scope: scope)
                            }
                        }
                }
            }
        }
        .environment(dock)
        .environment(scope)
        // Every way off the Library — a tap in the dock or a memo jump from the viewer — resets it,
        // so coming back finds the tabs.
        .onChange(of: selection) { _, now in
            if now != .library { dock.send(.leaveLibrary) }
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
