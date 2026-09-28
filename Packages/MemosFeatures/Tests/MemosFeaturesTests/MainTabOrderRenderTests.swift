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

/// The signed-in app's dock as a person meets it at launch: Library, Timeline, Places from left
/// to right, with the Timeline chosen (page 3929 decision 11).
///
/// The real `MainTabView` over a real `SessionStore` and the real generated client, rather than a
/// harness that builds its own `TabView`: the order and the default are both decided inside that
/// view — the order by `MainTab.allCases`, the default by its own `selection` — so a stand-in would
/// be asserting its own construction.
@MainActor
@Suite("The dock at launch")
struct MainTabOrderRenderTests {
    @Test("the dock reads Library, Timeline, Places from left to right, with the Timeline chosen")
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
            drawn = Self.dockTitlesLeftToRight(in: window, of: expected)
            if drawn.count == expected.count, Self.chosenTitle(in: window, of: expected) != nil {
                break
            }
        }

        // Where they are DRAWN: the order a person reads, taken from the dock's band at the foot
        // of the window so a title printed by the screen underneath cannot answer for it.
        #expect(drawn == expected, "the dock reads \(drawn)")
        // The default. The chosen tab is the one the dock marks selected, not the enum's middle
        // case: the Timeline in the middle is only right if it is also the one the app opens on.
        #expect(Self.chosenTitle(in: window, of: expected) == "Timeline")
        // The system bar the dock replaces is not drawn under it.
        #expect(!Self.systemTabBarShows(in: window), "the system tab bar is on screen")
    }

    /// Taps the dock's element labelled `title` the way VoiceOver does. Returns whether anything
    /// took the activation.
    private static func activate(_ title: String, in window: UIWindow) -> Bool {
        dockElements(in: window, of: [title]).contains { $0.accessibilityActivate() }
    }

    /// The Library's segment is the Library's alone (plan page 3929 decision 8: "On Timeline and
    /// Places the dock never shows the Years | Months | All segment"). The Library case is the
    /// control: the same tap on the chosen tab DOES bring the segment there, so
    /// the other two cases' silence is about the tab, not about a probe that cannot see it.
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
        for _ in 0..<120 where Self.chosenTitle(in: window, of: tabs) != tab.title {
            await Self.settle(window)
        }
        #expect(Self.chosenTitle(in: window, of: tabs) == tab.title, "precondition: on \(tab)")

        // A tap on the chosen tab: on the Library it toggles to the segment.
        let took = Self.activate(tab.title, in: window)
        var shown: [String] = []
        for _ in 0..<40 {
            await Self.settle(window)
            shown = Self.dockTitlesLeftToRight(in: window, of: tabs + segment)
            if tab == .library, shown.contains("Years") { break }
        }
        #expect(took, "the dock's \(tab.title) took no activation")
        if tab == .library {
            #expect(Set(shown) == Set(segment + [MainTab.library.title]), "dock: \(shown)")
        } else {
            #expect(shown == tabs, "a tap on the chosen \(tab.title) changed the dock: \(shown)")
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

    /// The one tab the dock marks selected, or nil when it marks none or more than one.
    private static func chosenTitle(in window: UIWindow, of titles: [String]) -> String? {
        let chosen = Set(
            dockElements(in: window, of: titles)
                .filter { $0.accessibilityTraits.contains(.selected) }
                .compactMap(\.accessibilityLabel)
        )
        return chosen.count == 1 ? chosen.first : nil
    }

    private static func collect(_ node: Any, into found: inout [NSObject]) {
        guard let object = node as? NSObject else { return }
        // The system tab bar is hidden under the dock but keeps its items' labels; it must not
        // answer for the dock.
        if object is UITabBar { return }
        found.append(object)
        for child in object.accessibilityElements ?? [] { collect(child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found) }
        }
    }
}
