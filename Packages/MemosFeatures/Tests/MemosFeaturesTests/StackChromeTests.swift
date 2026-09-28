import Foundation
import MemosCore
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

/// The signed-in app's shape in miniature: the real tabs under the real dock, a stack inside the
/// Timeline, and the app's own way of declaring what that stack pushes.
///
/// What is INSIDE each tab and destination is deliberately a stand-in, and only that. Everything
/// that decides the question is production code — `DockedTabs`, the dock it draws, the real
/// `SettingsRoute` and `MemoRoute`, the real `stackDestination`, and the chrome each route
/// declares.
private struct ChromeHarness: View {
    @Bindable var nav: TestPath

    var body: some View {
        // The selection is constant because nothing here switches tabs — the question is what the
        // dock does while the Timeline pushes.
        DockedTabs(selection: .constant(MainTab.timeline)) { tab in
            switch tab {
            case .timeline:
                NavigationStack(path: $nav.path) {
                    Text("the timeline")
                        .stackDestination(for: SettingsRoute.self) { _ in
                            Text("settings")
                        }
                        .stackDestination(for: MemoRoute.self) { route in
                            Text(route.uid)
                        }
                }
            case .library:
                Text("the library")
            case .places:
                Text("the places")
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

    /// Whether the dock is under what is on screen right now: the tab named `title` is offered
    /// by an element that reads it out, sits in the bottom band of the window where the dock is
    /// drawn, and is on screen at all.
    ///
    /// Read from the accessibility tree, because the dock is SwiftUI all the way down and has no
    /// view of its own to find. By equality, so the stand-in screens' lower-case "the timeline"
    /// cannot answer for the tab.
    func showsTab(_ title: String) -> Bool {
        var found: [NSObject] = []
        Self.collect(labelled: title, in: window, into: &found)
        let band = window.bounds.height * 0.8
        return found.contains { element in
            let frame = element.accessibilityFrame
            return !frame.isEmpty && frame.midY > band && frame.intersects(window.bounds)
        }
    }

    /// Whether the dock is drawn: both of the harness's tabs the ticket names are offered in it.
    var dockShows: Bool {
        showsTab(MainTab.timeline.title) && showsTab(MainTab.library.title)
    }

    /// Whether the SYSTEM tab bar is on screen. The dock replaces it, so it never should be.
    ///
    /// Not `UITabBar` merely existing: SwiftUI keeps the bar in the hierarchy and takes it off the
    /// screen, so the question is geometric as well as a matter of flags — is any part of it still
    /// inside the window, with nothing in its chain of superviews hiding it.
    var systemTabBarShows: Bool {
        guard let bar = Self.tabBar(in: window) else { return false }
        var node: UIView? = bar
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        let frame = bar.convert(bar.bounds, to: window)
        return !frame.isNull && !frame.isEmpty && frame.intersects(window.bounds)
    }

    /// Every label the hierarchy reads out, for when an assertion fails and the message alone
    /// cannot say what was on screen instead.
    var labels: String {
        var found: [NSObject] = []
        Self.collect(labelled: nil, in: window, into: &found)
        return found.compactMap { element in
            element.accessibilityLabel.map { "\($0)@\(Int(element.accessibilityFrame.midY))" }
        }.joined(separator: ", ")
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

    /// Every element that reads out `label` — or, with nil, every element that reads anything.
    private static func collect(
        labelled label: String?, in node: Any, into found: inout [NSObject]
    ) {
        guard let object = node as? NSObject else { return }
        // The system tab bar is hidden under the dock but keeps its items' labels; it must not
        // answer for the dock.
        if object is UITabBar { return }
        if let text = object.accessibilityLabel, !text.isEmpty, label == nil || text == label {
            found.append(object)
        }
        for child in object.accessibilityElements ?? [] {
            collect(labelled: label, in: child, into: &found)
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(labelled: label, in: subview, into: &found) }
        }
    }
}

/// Whether the app's dock is under a pushed screen, asked of the real hosted `DockedTabs` rather
/// than of the value that decides it.
///
/// `SettingsView` itself cannot be hosted from this bundle — it reads `SessionStore` out of the
/// environment, and constructing one inlines the API layer that Features reaches only through
/// Core; `SettingsRenderTests` says the same at more length. So the screen under the push is a
/// stand-in. The decision under test is not: put `SettingsRoute.chrome` back to `.withinTab` and
/// the first test here goes red on the assertion.
@MainActor
@Suite("The dock under a pushed screen")
struct StackChromeTests {
    @Test("Settings takes the dock over, and going back brings it straight back")
    func settingsTakesTheBarOverAndGivesItBack() {
        let nav = TestPath()
        let screen = HostedTabs(nav)
        defer { screen.tearDown() }
        screen.settle(waitingFor: { screen.dockShows })

        // The control. Without it, "the dock is gone" below would be equally true of a harness
        // that never managed to draw one — and it is what says the dock being tracked is THE dock,
        // the one offering the two tabs the ticket names.
        #expect(screen.dockShows, "on the timeline — \(screen.labels)")
        #expect(screen.showsTab(MainTab.timeline.title))
        #expect(screen.showsTab(MainTab.library.title))
        // The system bar the dock replaced is not drawn beside it.
        #expect(!screen.systemTabBarShows)

        withoutAnimation { nav.path.append(SettingsRoute()) }
        screen.settle(waitingFor: { !screen.showsTab(MainTab.library.title) })

        #expect(!screen.showsTab(MainTab.timeline.title), "on Settings — \(screen.labels)")
        #expect(!screen.showsTab(MainTab.library.title), "on Settings — \(screen.labels)")
        #expect(!screen.systemTabBarShows, "Settings brought the system tab bar back")

        withoutAnimation { nav.path.removeLast() }
        screen.settle(waitingFor: { screen.dockShows })

        #expect(screen.dockShows, "back on the timeline — \(screen.labels)")
        #expect(screen.showsTab(MainTab.timeline.title))
        #expect(screen.showsTab(MainTab.library.title))
        #expect(!screen.systemTabBarShows)
    }

    @Test("a memo pushed from the timeline keeps the dock under it")
    func memoKeepsTheBar() {
        let nav = TestPath()
        let screen = HostedTabs(nav)
        defer { screen.tearDown() }
        screen.settle(waitingFor: { screen.dockShows })

        #expect(screen.dockShows, "on the timeline — \(screen.labels)")

        withoutAnimation { nav.path.append(MemoRoute(uid: "m1")) }
        // The plain settle, not the waiting one: this push is supposed to change nothing, so
        // there is no arrival to give up on early — a wait that returned the instant the dock was
        // still there would pass before it had any chance to go.
        screen.settle()

        #expect(screen.dockShows, "on the memo — \(screen.labels)")
        #expect(screen.showsTab(MainTab.timeline.title))
        #expect(!screen.systemTabBarShows, "the memo brought the system tab bar back")
    }

    @Test("which screens take the dock over is said once, on the route")
    func routesDeclareTheirChrome() {
        #expect(SettingsRoute.chrome == .takesOverTab)
        #expect(MemoRoute.chrome == .withinTab)
        #expect(!ScreenChrome.takesOverTab.showsDock)
        #expect(ScreenChrome.withinTab.showsDock)
    }
}
