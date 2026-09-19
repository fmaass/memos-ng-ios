import SwiftUI

/// What a pushed screen keeps of the app that pushed it.
///
/// The tab bar belongs to the `TabView`, not to the navigation stack inside a tab, so it stays
/// under everything the timeline pushes unless the pushed screen says otherwise. Nearly nothing
/// should say otherwise: a memo is a thing inside the Timeline tab, and the bar under it is how
/// you leave. Settings is the exception — it is the whole app's screen, reached from a tab it
/// does not belong to, so the Timeline and Library icons under it were the previous screen's
/// controls left sitting on somebody else's (MEMNG-220).
enum ScreenChrome: Equatable, Sendable {
    /// A screen inside its tab. The tab bar stays exactly as it was on the tab's root.
    case withinTab
    /// A screen that stands for the whole app. The tab bar goes while it is up, and comes back
    /// when it is popped.
    case takesOverTab

    /// The tab bar's visibility while such a screen is on top.
    ///
    /// `.automatic` rather than `.visible` for a screen inside its tab: automatic IS what the bar
    /// resolves to with nothing said at all, so a screen declaring itself ordinary changes nothing
    /// about what was already there.
    var tabBar: Visibility {
        switch self {
        case .withinTab: .automatic
        case .takesOverTab: .hidden
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
// conformance is the sanctioned answer to exactly that, and it costs nothing here: both
// destinations are declared from `body`, which is on the main actor already.
extension SettingsRoute: @MainActor StackRoute {
    static let chrome = ScreenChrome.takesOverTab
}

extension MemoRoute: @MainActor StackRoute {
    static let chrome = ScreenChrome.withinTab
}

extension View {
    /// A destination in one of the app's navigation stacks, drawn with the chrome its route asks
    /// for.
    /// The route's answer is read HERE rather than inside the closure, and the closure carries
    /// only the `Visibility` away with it. What it decides is the same either way; what changes is
    /// that the destination closure then touches nothing actor-isolated, so it is the same
    /// construct `navigationDestination` is handed today rather than a new one that has to be
    /// argued about.
    func stackDestination<Route: StackRoute, Destination: View>(
        for route: Route.Type,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) -> some View {
        let tabBar = Route.chrome.tabBar
        return navigationDestination(for: route) { value in
            destination(value).toolbarVisibility(tabBar, for: .tabBar)
        }
    }
}
