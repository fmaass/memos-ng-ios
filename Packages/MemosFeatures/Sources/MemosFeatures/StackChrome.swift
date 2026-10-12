import SwiftUI

/// What a pushed screen keeps of the app that pushed it.
///
/// The dock belongs to the tabs, not to the navigation stack inside a tab, so it stays under
/// everything the timeline pushes unless the pushed screen says otherwise. Nearly nothing should
/// say otherwise: a memo is a thing inside the Timeline tab, and the dock under it is how you
/// leave. Settings was the exception until the chrome trim (2026-10-10) deleted that screen — the
/// whole app's screen, reached from a tab it did not belong to, so the Timeline and Library icons
/// under it were the previous screen's controls left sitting on somebody else's (MEMNG-220).
enum ScreenChrome: Equatable, Sendable {
    /// A screen inside its tab. The dock stays exactly as it was on the tab's root.
    case withinTab
    /// A screen that stands for the whole app. The dock goes while it is up, and comes back when
    /// it is popped.
    case takesOverTab

    /// Whether the dock is under such a screen while it is on top.
    var showsDock: Bool {
        switch self {
        case .withinTab: true
        case .takesOverTab: false
        }
    }
}

/// A place one of the app's navigation stacks can go, and what the app's chrome does while it is
/// there.
///
/// The chrome hangs off the ROUTE TYPE rather than off the call that builds the destination.
/// Reading it from the type is what puts the decision out of reach of the call site: where a push
/// goes and what the tab bar does under it become one statement that cannot disagree with itself.
protocol StackRoute: Hashable {
    static var chrome: ScreenChrome { get }
}

// `@MainActor` on the CONFORMANCE, not on the protocol. A route is a main-actor type like
// everything else in this layer, so the `Hashable` conformance it already had is main-actor
// isolated, and a protocol refining `Hashable` inherits that — which is the whole of what the
// compiler means by a conformance "crossing into main actor-isolated code". Isolating the
// conformance is the sanctioned answer to exactly that, and it costs nothing here: every
// destination is declared from `body`, which is on the main actor already.
extension MemoRoute: @MainActor StackRoute {
    static let chrome = ScreenChrome.withinTab
}

extension View {
    /// A destination in one of the app's navigation stacks, drawn with the chrome its route asks
    /// for.
    /// The route's answer is read HERE rather than inside the closure, and the closure carries
    /// only a `Bool` away with it, so what the destination does to the bar cannot disagree with
    /// the route it was pushed for. A screen inside its tab keeps the system tab bar under it, as
    /// every app's pushed screens do; a screen that takes the tab over hides it while it is up,
    /// on the destination itself as well as through its claim, so the bar cannot come back under
    /// it between the push and the claim.
    func stackDestination<Route: StackRoute, Destination: View>(
        for route: Route.Type,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) -> some View {
        let takesOver = !Route.chrome.showsDock
        return navigationDestination(for: route) { value in
            if takesOver {
                destination(value)
                    .toolbarVisibility(.hidden, for: .tabBar)
                    .modifier(DockTakeover(takesOver: true))
            } else {
                // The dock stays as it was on the tab's root: the bar `MainTabs` keeps under every
                // tab stands still, and a screen inside the tab keeps its room too (MEMNG-690).
                destination(value)
                    .leadingFootBar(on: nil)
                    .modifier(DockTakeover(takesOver: false))
            }
        }
    }
}
