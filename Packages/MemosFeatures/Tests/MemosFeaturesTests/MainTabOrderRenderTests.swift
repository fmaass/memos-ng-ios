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

/// The signed-in app's tab bar as a person meets it at launch: Library, Timeline, Places from left
/// to right, with the Timeline chosen (page 3929 decision 11).
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

        var bar: UITabBar?
        for _ in 0..<120 {
            await Self.settle(window)
            bar = Self.tabBar(in: window)
            if let bar, bar.items?.count == MainTab.allCases.count, bar.selectedItem != nil {
                break
            }
        }
        guard let bar else {
            Issue.record("no UITabBar in the hosted hierarchy")
            return
        }

        let expected = ["Library", "Timeline", "Places"]
        // The bar's own items, in the order the bar holds them.
        #expect(bar.items?.map { $0.title ?? "" } == expected)
        // And where they are DRAWN: the order a person reads, taken from the bar's own subtree so a
        // title printed by the screen underneath cannot answer for it.
        #expect(Self.titlesLeftToRight(in: bar, of: expected) == expected)
        // The default. Selection is the bar's, not the enum's: the Timeline in the middle is only
        // right if it is also the one the app opens on.
        #expect(bar.selectedItem?.title == "Timeline")
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

    private static func tabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let bar = tabBar(in: subview) { return bar }
        }
        return nil
    }

    /// The titles as the bar lays them out, left to right, by the on-screen frame of the
    /// accessibility element that reads each one out. By containment, because a tab's label
    /// carries its position in the bar along with its name; leftmost copy wins, because the bar
    /// may keep a second one it measures with.
    private static func titlesLeftToRight(in bar: UITabBar, of titles: [String]) -> [String] {
        var elements: [NSObject] = []
        collect(bar, into: &elements)
        var leftmost: [String: CGFloat] = [:]
        for element in elements {
            guard let label = element.accessibilityLabel else { continue }
            let frame = element.accessibilityFrame
            guard !frame.isEmpty else { continue }
            for title in titles where label.contains(title) {
                leftmost[title] = min(leftmost[title] ?? .infinity, frame.midX)
            }
        }
        return leftmost.sorted { $0.value < $1.value }.map(\.key)
    }

    private static func collect(_ node: Any, into found: inout [NSObject]) {
        guard let object = node as? NSObject else { return }
        found.append(object)
        for child in object.accessibilityElements ?? [] { collect(child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found) }
        }
    }
}
