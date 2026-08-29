import Foundation
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A navigation path a test can push and pop while the screen holding it stays up.
///
/// `@State` inside the hosted view would be out of reach: the point of these tests is the
/// TRANSITION — the bar going as a screen is pushed and coming back as it is popped — and a
/// transition cannot be read off two separately hosted windows.
@MainActor
@Observable
private final class TestPath {
    var path = NavigationPath()
}

/// The signed-in app's shape in miniature: two tabs, a stack inside the first, and the app's own
/// way of declaring what that stack pushes.
///
/// What is INSIDE each destination is deliberately a stand-in, and only that. Everything that
/// decides the question is production code — the real `SettingsRoute` and `MemoRoute`, the real
/// `stackDestination`, and the chrome each route declares.
private struct ChromeHarness: View {
    @Bindable var nav: TestPath

    var body: some View {
        // The same `Tab(_:systemImage:value:)` shape `MainTabView` builds its bar out of. The
        // selection is constant because nothing here switches tabs — the question is what the bar
        // does while the FIRST tab pushes.
        TabView(selection: .constant(MainTab.timeline)) {
            Tab(
                MainTab.timeline.title,
                systemImage: MainTab.timeline.symbol,
                value: MainTab.timeline
            ) {
                NavigationStack(path: $nav.path) {
                    Text("the timeline")
                        .stackDestination(for: SettingsRoute.self) { _ in
                            Text("settings")
                        }
                        .stackDestination(for: MemoRoute.self) { route in
                            Text(route.uid)
                        }
                }
            }
            Tab(
                MainTab.library.title,
                systemImage: MainTab.library.symbol,
                value: MainTab.library
            ) {
                Text("the library")
            }
        }
    }
}

/// Drives a navigation change the way a test needs it driven: at once, with no animation to wait
/// on.
///
/// A window built by hand is attached to no scene, and SwiftUI's animations are not reliably
/// advanced in one — measured, and asymmetrically: the bar's going was immediate, its coming back
/// was still unfinished after three seconds of run loop. The transition is not what is under test.
/// Where the bar ENDS UP is, and that is what this makes readable.
private func withoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

/// The harness on a real screen, kept up across several readings.
///
/// Separate from `ScreenProbe`, which hosts a view, reads it once and takes it down again: a push
/// that happens after the window is gone changes nothing anybody can see.
@MainActor
private final class HostedTabs {
    private let host: UIHostingController<ChromeHarness>
    private let window: UIWindow

    /// Built on the test host's OWN window scene rather than free-floating.
    ///
    /// A window belonging to no scene never completes its appearance transitions — UIKit says so
    /// out loud, "Unbalanced calls to begin/end appearance transitions" — and the tab bar's RESTORE
    /// rides on exactly those. Measured in a free-floating window: after popping Settings the bar
    /// came back to its on-screen frame (y=791, h=83, inside an 874pt window) still carrying
    /// `hidden=true, alpha=0`, which is a transition that started and was never finished rather
    /// than a bar that was told to stay away.
    init(_ nav: TestPath) {
        host = UIHostingController(rootView: ChromeHarness(nav: nav))
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        if let scene = scene as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    /// Lays out and lets SwiftUI finish, giving up the moment the screen has reached the state the
    /// next assertion is about.
    ///
    /// Bounded rather than fixed, and the bound matters in both directions: a push installs its
    /// screen on a later turn of the run loop than the state change and the bar's going and coming
    /// back is animated on top of that, so a fixed wait is either too short (it was — the bar had
    /// not finished coming back) or slow for every test that did not need it. A state that never
    /// arrives still fails the assertion below rather than hanging the suite, because the cap
    /// returns and the test then reads whatever is actually there.
    func settle(waitingFor reached: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if reached() { return }
        } while Date() < deadline
    }

    /// For the step whose whole point is that NOTHING changes: there is no state to wait for, so
    /// this spends the time a transition would have taken and then lets the assertion look.
    func settle() {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
    }

    /// Whether the tab bar is under what is on screen right now.
    ///
    /// Not `UITabBar` merely existing: SwiftUI keeps the bar in the hierarchy and takes it off the
    /// screen, so the question is geometric as well as a matter of flags — is any part of it still
    /// inside the window, with nothing in its chain of superviews hiding it.
    var tabBarShows: Bool {
        guard let bar = Self.tabBar(in: window) else { return false }
        var node: UIView? = bar
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        let frame = bar.convert(bar.bounds, to: window)
        return !frame.isNull && !frame.isEmpty && frame.intersects(window.bounds)
    }

    /// Whether this tab is one the reader is being offered right now — the Timeline and Library
    /// the ticket names.
    ///
    /// Both halves are load-bearing, and the visibility half is not decoration: a bar SwiftUI has
    /// taken off the screen goes on carrying its items' accessibility labels, so asking only what
    /// the bar offers answers "Timeline" just as readily on the Settings screen as on the timeline
    /// (measured — it did, which is what sent this probe back for a second draft). The labels are
    /// read from the BAR's own subtree, so the word printed by the screen underneath cannot answer
    /// for it, and by containment rather than equality, because a tab's accessibility label
    /// carries its position in the bar along with its name.
    func showsTab(_ title: String) -> Bool {
        guard tabBarShows, let bar = Self.tabBar(in: window) else { return false }
        var found: [String] = []
        Self.collectLabels(bar, into: &found)
        return found.contains { $0.contains(title) }
    }

    /// What the bar actually looks like, for when an assertion above fails and the message alone
    /// cannot say whether the bar is missing, hidden, transparent or merely parked off the screen.
    var barState: String {
        guard let bar = Self.tabBar(in: window) else { return "no UITabBar in the hierarchy" }
        let frame = bar.convert(bar.bounds, to: window)
        return "hidden=\(bar.isHidden) alpha=\(bar.alpha) frame=\(frame) window=\(window.bounds)"
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func tabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let bar = tabBar(in: subview) { return bar }
        }
        return nil
    }

    private static func collectLabels(_ node: Any, into found: inout [String]) {
        if let element = node as? NSObject {
            if let label = element.accessibilityLabel, !label.isEmpty { found.append(label) }
            for child in element.accessibilityElements ?? [] { collectLabels(child, into: &found) }
        }
        if let view = node as? UIView {
            for subview in view.subviews { collectLabels(subview, into: &found) }
        }
    }
}

/// Whether the app's tab bar is under a pushed screen, asked of a real hosted `TabView` rather
/// than of the value that decides it.
///
/// `SettingsView` itself cannot be hosted from this bundle — it reads `SessionStore` out of the
/// environment, and constructing one inlines the API layer that Features reaches only through
/// Core; `SettingsRenderTests` says the same at more length. So the screen under the push is a
/// stand-in. The decision under test is not: put `SettingsRoute.chrome` back to `.withinTab` and
/// the first test here goes red on the assertion, exactly as it did before this was fixed.
@MainActor
@Suite("The tab bar under a pushed screen")
struct StackChromeTests {
    @Test("Settings takes the tab bar over, and going back brings it straight back")
    func settingsTakesTheBarOverAndGivesItBack() {
        let nav = TestPath()
        let screen = HostedTabs(nav)
        defer { screen.tearDown() }
        screen.settle(waitingFor: { screen.tabBarShows })

        // The control. Without it, "the bar is gone" below would be equally true of a harness that
        // never managed to draw one — and it is what says the bar being tracked is THE bar, the
        // one offering the two tabs the ticket names.
        #expect(screen.tabBarShows)
        #expect(screen.showsTab(MainTab.timeline.title))
        #expect(screen.showsTab(MainTab.library.title))

        withoutAnimation { nav.path.append(SettingsRoute()) }
        screen.settle(waitingFor: { !screen.tabBarShows })

        #expect(!screen.tabBarShows, "on Settings — \(screen.barState)")
        #expect(!screen.showsTab(MainTab.timeline.title))
        #expect(!screen.showsTab(MainTab.library.title))

        withoutAnimation { nav.path.removeLast() }
        screen.settle(waitingFor: { screen.tabBarShows })

        #expect(screen.tabBarShows, "back on the timeline — \(screen.barState)")
        #expect(screen.showsTab(MainTab.timeline.title))
        #expect(screen.showsTab(MainTab.library.title))
    }

    @Test("a memo pushed from the timeline keeps the tab bar under it")
    func memoKeepsTheBar() {
        let nav = TestPath()
        let screen = HostedTabs(nav)
        defer { screen.tearDown() }
        screen.settle(waitingFor: { screen.tabBarShows })

        #expect(screen.tabBarShows)

        withoutAnimation { nav.path.append(MemoRoute(uid: "m1")) }
        // The plain settle, not the waiting one: this push is supposed to change nothing, so
        // there is no arrival to give up on early — a wait that returned the instant the bar was
        // still there would pass before the bar had any chance to go.
        screen.settle()

        #expect(screen.tabBarShows)
        #expect(screen.showsTab(MainTab.timeline.title))
    }

    @Test("which screens take the tab bar over is said once, on the route")
    func routesDeclareTheirChrome() {
        #expect(SettingsRoute.chrome == .takesOverTab)
        #expect(MemoRoute.chrome == .withinTab)
        #expect(ScreenChrome.takesOverTab.tabBar == .hidden)
        #expect(ScreenChrome.withinTab.tabBar == .automatic)
    }
}
