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
/// to right, with the Timeline chosen (page 3929 decision 11). The bar is the app's own capsule
/// (MEMNG-690), so it is read off what the capsule draws, and the selection off the controller
/// UIKit built for the `TabView`.
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
            drawn = ScopeBarProbe.tabTitlesLeftToRight(in: window)
            if drawn.count == expected.count, Self.chosenTitle(in: window) != nil {
                break
            }
        }

        // Where they are DRAWN: the order a person reads, taken from the frames of the capsule's
        // buttons rather than from the order of the tabs.
        #expect(drawn == expected, "the bar reads \(drawn)")
        // The default. The chosen tab is the one the bar marks selected, not the enum's middle
        // case: the Timeline in the middle is only right if it is also the one the app opens on.
        #expect(Self.chosenTitle(in: window) == "Timeline")
        // The app's bar is the one on screen, UIKit's never.
        #expect(ScopeBarProbe.tabsShow(in: window), "the app's bar is not on screen")
        #expect(!ScopeBarProbe.systemTabBarShows(in: window), "UIKit's tab bar is on screen")
    }

    /// What `.tabBarMinimizeBehavior` handed UIKit, read off the controller the hidden system bar
    /// belongs to: never, on every tab and after a move between them — the app's own bar folds
    /// instead (MEMNG-690), and UIKit's must not minimise under it.
    @Test(
        "the hosted tab controller never minimises, on any tab or after a move",
        arguments: [MainTab.library, MainTab.timeline, MainTab.places]
    )
    func minimiseBehaviourReachesUIKit(tab: MainTab) async {
        let window = await Self.signedInWindow(opening: tab)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        let controller = Self.tabController(in: window.rootViewController)
        #expect(controller != nil, "no UITabBarController hosts the bar")
        let behaviour = controller?.tabBarMinimizeBehavior
        let expected: UITabBarController.MinimizeBehavior = .never
        #expect(
            behaviour == expected,
            "\(tab.title)'s bar: \(String(describing: behaviour)), not \(String(describing: expected))"
        )

        // Another tab: the setting stays.
        let away: MainTab = tab == .library ? .places : .library
        #expect(ScopeBarProbe.pressTab(away, in: window), "the bar's \(away.title) took no press")
        for _ in 0..<120 where Self.chosenTitle(in: window) != away.title {
            await Self.settle(window)
        }
        await Self.settle(window)
        let after = controller?.tabBarMinimizeBehavior
        let expectedAway: UITabBarController.MinimizeBehavior = .never
        #expect(
            after == expectedAway,
            "\(away.title)'s bar: \(String(describing: after)), not \(String(describing: expectedAway))"
        )
    }

    /// At launch every tab stands over the app's capsule and nothing of the Library's scope is
    /// drawn (MEMNG-604). A press on the tab already showing is then the Library's way to its scope
    /// row — the capsule gives way to the Library icon beside Years | Months | All, on All — and on
    /// Timeline and Places it changes nothing the app draws.
    @Test(
        "a press on the chosen tab gives the Library its scope toolbar and leaves the others be",
        arguments: [MainTab.library, MainTab.timeline, MainTab.places]
    )
    func pressOnTheChosenTab(tab: MainTab) async {
        let window = await Self.signedInWindow(opening: tab)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        await Self.settle(window)
        let atLaunch = ScopeBarProbe.describe(window)
        #expect(ScopeBarProbe.tabsShow(in: window), "\(tab.title): no tab bar at launch")
        #expect(ScopeBarProbe.control(in: window) == nil, "\(tab.title) at launch: \(atLaunch)")
        #expect(!ScopeBarProbe.libraryIconShows(in: window), "an icon at launch: \(atLaunch)")

        #expect(ScopeBarProbe.pressTab(tab, in: window), "the bar's \(tab.title) took no press")
        var control: UISegmentedControl?
        for _ in 0..<80 {
            await Self.settle(window)
            control = ScopeBarProbe.control(in: window)
            if tab == .library, control != nil, !ScopeBarProbe.tabsShow(in: window) { break }
        }
        let pressed = ScopeBarProbe.describe(window)
        if tab == .library {
            #expect(control != nil, "the Library pressed: no scope control: \(pressed)")
            #expect(control?.numberOfSegments == 3, "segments: \(pressed)")
            #expect(control.flatMap { ScopeBarProbe.chosen(in: $0) } == "All", "\(pressed)")
            #expect(ScopeBarProbe.libraryIconShows(in: window), "no Library icon: \(pressed)")
            #expect(!ScopeBarProbe.tabsShow(in: window), "the bar beside the scope: \(pressed)")
        } else {
            #expect(control == nil, "a press on \(tab.title) drew the scope: \(pressed)")
            #expect(ScopeBarProbe.tabsShow(in: window), "a press on \(tab.title) took the bar")
        }
    }

    /// Signs in over the tab-order wire and hosts the app on `tab`, chosen.
    private static func signedInWindow(opening tab: MainTab) async -> UIWindow {
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
        for _ in 0..<120 where Self.chosenTitle(in: window) != tab.title {
            await Self.settle(window)
        }
        #expect(Self.chosenTitle(in: window) == tab.title, "precondition: on \(tab)")
        return window
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

    /// The one tab the `TabView` has selected, or nil while the app's bar is not on screen.
    private static func chosenTitle(in window: UIWindow) -> String? {
        guard ScopeBarProbe.tabsShow(in: window) else { return nil }
        return ScopeBarProbe.selectedTitle(in: window)
    }

    private static func tabController(in controller: UIViewController?) -> UITabBarController? {
        guard let controller else { return nil }
        if let found = controller as? UITabBarController { return found }
        for child in controller.children {
            if let found = tabController(in: child) { return found }
        }
        return tabController(in: controller.presentedViewController)
    }
}
