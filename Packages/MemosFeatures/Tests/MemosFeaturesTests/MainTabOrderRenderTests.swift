import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Nonisolated because the transport below is: the generated client calls it off the main actor.
private enum TabOrderWire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
}

/// A server that knows who is signed in and nothing else. Every other read fails plainly, because
/// what is under test is the bar around the screens, not what the screens load.
private final class TabOrderTransport: ClientTransport, @unchecked Sendable {
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == TabOrderWire.whoami else {
            return (HTTPResponse(status: .notFound), nil)
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (
            response,
            HTTPBody(
                """
                {"subject":"fabian","display_name":"fabian","email":null,\
                "role":"user","auth_kind":"oidc"}
                """
            )
        )
    }
}

/// The keychain, in memory.
private final class TabOrderCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, for account: String) async throws {
        lock.withLock { values[account] = value }
    }

    func string(for account: String) async throws -> String? {
        lock.withLock { values[account] }
    }

    func remove(_ account: String) async throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

/// The signed-in app's bar as a person meets it at launch: Library, Timeline, Places from left
/// to right, with the Timeline chosen (page 3929 decision 11). The bar is the system's since
/// MEMNG-666, so it is read off the `UITabBar` UIKit built for it.
///
/// The real `MainTabView` over a real `SessionStore` and the real generated client, rather than a
/// harness that builds its own `TabView`: the order and the default are both decided inside that
/// view — the order by `MainTab.allCases`, the default by its own `selection` — so a stand-in would
/// be asserting its own construction.
@MainActor
@Suite("The tab bar at launch")
struct MainTabOrderRenderTests {
    @Test("the bar reads Library, Timeline, Places from left to right, with the Timeline chosen")
    func barOrderAndDefault() async {
        let session = SessionStore(
            credentials: TabOrderCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: TabOrderTransport()
                )
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            // Its own clock, so a sign-in here rotates nothing another suite is counting on.
            identity: MediaIdentity()
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_taborder")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")

        let window = Self.window()
        window.rootViewController = UIHostingController(
            rootView: MainTabView().environment(session))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let expected = ["Library", "Timeline", "Places"]
        var drawn: [String] = []
        for _ in 0..<120 {
            await Self.settle(window)
            drawn = Self.barTitlesLeftToRight(in: window)
            if drawn.count == expected.count, Self.chosenTitle(in: window) != nil {
                break
            }
        }

        // Where they are DRAWN: the order a person reads, taken from the frames of the bar's
        // buttons rather than from the order of its items.
        #expect(drawn == expected, "the bar reads \(drawn)")
        // The default. The chosen tab is the one the bar marks selected, not the enum's middle
        // case: the Timeline in the middle is only right if it is also the one the app opens on.
        #expect(Self.chosenTitle(in: window) == "Timeline")
        // The system bar is the one on screen.
        #expect(Self.systemTabBarShows(in: window), "the system tab bar is not on screen")
    }

    /// The Library's segment is the Library's alone (plan page 3929 decision 8: "On Timeline and
    /// Places the dock never shows the Years | Months | All segment"). The Library case is the
    /// control: the same press on the chosen tab DOES bring the segment there, in the system
    /// bar's place, so the other two cases' silence is about the tab, not about a probe that
    /// cannot see it.
    /// What `.tabBarMinimizeBehavior` handed UIKit, read off the controller the system bar
    /// belongs to: the bar folds on scroll down on the Timeline and Places, and never on the
    /// Library, which collapses to its own chrome (MEMNG-666, MEMNG-653).
    @Test(
        "the hosted tab controller minimises on scroll down off the Library, and never on it",
        arguments: [MainTab.library, MainTab.timeline, MainTab.places]
    )
    func minimiseBehaviourReachesUIKit(tab: MainTab) async {
        let session = SessionStore(
            credentials: TabOrderCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: TabOrderTransport()
                )
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            identity: MediaIdentity()
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_taborder")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")

        let window = Self.window()
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: tab).environment(session))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for _ in 0..<120 where Self.chosenTitle(in: window) != tab.title {
            await Self.settle(window)
        }
        #expect(Self.chosenTitle(in: window) == tab.title, "precondition: on \(tab)")
        await Self.settle(window)

        let controller = Self.tabController(in: window.rootViewController)
        #expect(controller != nil, "no UITabBarController hosts the bar")
        let behaviour = controller?.tabBarMinimizeBehavior
        if tab == .library {
            #expect(
                behaviour == .never,
                "the Library's bar minimises: \(String(describing: behaviour))"
            )
        } else {
            #expect(
                behaviour == .onScrollDown,
                "\(tab.title)'s bar: \(String(describing: behaviour)), not on scroll down"
            )
        }
    }

    @Test(
        "a tap on the chosen tab brings the segment on the Library and nowhere else",
        arguments: [MainTab.library, MainTab.timeline, MainTab.places]
    )
    func segmentIsTheLibrarysAlone(tab: MainTab) async {
        let session = SessionStore(
            credentials: TabOrderCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: TabOrderTransport()
                )
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            identity: MediaIdentity()
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_taborder")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")

        let window = Self.window()
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: tab).environment(session))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let tabs = MainTab.allCases.map(\.title)
        let segment = LibraryScope.allCases.map(\.label)
        for _ in 0..<120 where Self.chosenTitle(in: window) != tab.title {
            await Self.settle(window)
        }
        #expect(Self.chosenTitle(in: window) == tab.title, "precondition: on \(tab)")

        // A press on the chosen tab: on the Library it toggles to the segment.
        let took = Self.press(tab, in: window)
        var shown: [String] = []
        for _ in 0..<40 {
            await Self.settle(window)
            shown = Self.dockTitlesLeftToRight(in: window, of: tabs + segment)
            if tab == .library, shown.contains("Years") { break }
        }
        #expect(took, "the bar's \(tab.title) took no press")
        if tab == .library {
            #expect(Set(shown) == Set(segment + [MainTab.library.title]), "chrome: \(shown)")
            #expect(!Self.systemTabBarShows(in: window), "the bar is drawn beside the segment")
        } else {
            #expect(shown.isEmpty, "a press on the chosen \(tab.title) drew \(shown)")
            let still = Self.barTitlesLeftToRight(in: window)
            #expect(still == tabs, "a press on the chosen \(tab.title) left the bar \(still)")
        }
    }

    /// Built on the test host's own window scene, for the reason `StackChromeTests` gives: a
    /// window belonging to no scene never completes the appearance transitions the bar rides on.
    private static func window() -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        guard let scene = scene as? UIWindowScene else { return UIWindow(frame: frame) }
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    private static func settle(_ window: UIWindow) async {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(25))
    }

    /// Whether a system tab bar is on screen: in the hierarchy, unhidden up its superview chain,
    /// and inside the window.
    private static func systemTabBarShows(in window: UIWindow) -> Bool {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UITabBar {
                var node: UIView? = bar
                var hidden = false
                while let current = node {
                    if current.isHidden || current.alpha < 0.01 { hidden = true }
                    node = current.superview
                }
                let frame = bar.convert(bar.bounds, to: window)
                if !hidden, !frame.isEmpty, frame.intersects(window.bounds) { return true }
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }

    /// The dock's elements: labelled exactly with one of `titles`, drawn in the bottom fifth of
    /// the window, where the dock sits.
    private static func dockElements(in window: UIWindow, of titles: [String]) -> [NSObject] {
        var elements: [NSObject] = []
        collect(window, into: &elements)
        let band = window.bounds.height * 0.8
        return elements.filter { element in
            guard let label = element.accessibilityLabel, titles.contains(label) else {
                return false
            }
            let frame = element.accessibilityFrame
            return !frame.isEmpty && frame.midY > band && frame.intersects(window.bounds)
        }
    }

    /// The titles as the dock lays them out, left to right, by the on-screen frame of the
    /// accessibility element that reads each one out; leftmost copy wins.
    private static func dockTitlesLeftToRight(
        in window: UIWindow, of titles: [String]
    ) -> [String] {
        var leftmost: [String: CGFloat] = [:]
        for element in dockElements(in: window, of: titles) {
            guard let label = element.accessibilityLabel else { continue }
            leftmost[label] = min(leftmost[label] ?? .infinity, element.accessibilityFrame.midX)
        }
        return leftmost.sorted { $0.value < $1.value }.map(\.key)
    }

    /// The one tab the system bar marks selected, or nil when it is not on screen.
    private static func chosenTitle(in window: UIWindow) -> String? {
        guard systemTabBarShows(in: window) else { return nil }
        return tabBar(in: window)?.selectedItem?.title
    }

    private static func tabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let bar = tabBar(in: subview) { return bar }
        }
        return nil
    }

    /// The bar's item titles in the order its buttons are drawn, left to right: each item's
    /// button is the control in the bar whose accessibility label is the item's title.
    private static func barTitlesLeftToRight(in window: UIWindow) -> [String] {
        guard systemTabBarShows(in: window), let bar = tabBar(in: window) else { return [] }
        let titles = bar.items?.compactMap(\.title) ?? []
        // Only what is drawn inside the bar answers: the iOS 26 bar also carries a copy of the
        // selected item that is not where the item is (MEMNG-666, first run: the chosen tab read
        // leftmost on every tab).
        let drawnIn = bar.convert(bar.bounds, to: window)
        var drawnAt: [String: [CGFloat]] = [:]
        var stack: [Any] = [bar]
        while let node = stack.popLast() {
            guard let object = node as? NSObject else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if let label = object.accessibilityLabel, titles.contains(label) {
                let frame = object.accessibilityFrame
                if !frame.isEmpty, drawnIn.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    drawnAt[label, default: []].append(frame.midX)
                }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        // Each item must be measured at one place: copies within a few points of each other are
        // one item drawn twice (a selection over its own item). An item not found, or found at two
        // places, is not measured, and the reading says so instead of passing on the items' order.
        var position: [String: CGFloat] = [:]
        for title in titles {
            guard let found = drawnAt[title], let low = found.min(), let high = found.max(),
                high - low <= 8
            else {
                return titles.map { "\($0) unmeasured at \(drawnAt[$0] ?? [])" }
            }
            position[title] = low
        }
        return titles.sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
    }

    /// Presses `tab` through the controller UIKit built for the bar, the way a tap on its item
    /// does — which, on the tab already showing, is a re-selection the `TabView` hears.
    private static func press(_ tab: MainTab, in window: UIWindow) -> Bool {
        guard
            let controller = tabController(in: window.rootViewController),
            let index = controller.tabBar.items?.firstIndex(where: { $0.title == tab.title }),
            let controllers = controller.viewControllers,
            controllers.indices.contains(index)
        else { return false }
        let target = controllers[index]
        let delegate = controller.delegate
        guard delegate?.tabBarController?(controller, shouldSelect: target) ?? true else {
            return false
        }
        controller.selectedViewController = target
        delegate?.tabBarController?(controller, didSelect: target)
        return true
    }

    private static func tabController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let found = controller as? UITabBarController { return found }
        for child in controller.children {
            if let found = tabController(in: child) { return found }
        }
        return tabController(in: controller.presentedViewController)
    }

    private static func collect(_ node: Any, into found: inout [NSObject]) {
        guard let object = node as? NSObject else { return }
        // The system tab bar's items are read off the bar; they must not answer for the chrome.
        if object is UITabBar { return }
        found.append(object)
        for child in object.accessibilityElements ?? [] { collect(child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found) }
        }
    }
}
