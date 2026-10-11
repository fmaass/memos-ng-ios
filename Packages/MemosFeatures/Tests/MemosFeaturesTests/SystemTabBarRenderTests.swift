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
private enum SystemBarWire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
}

/// A server that knows who is signed in and nothing else. Every other read fails plainly, because
/// what is under test is the bar and the titles around the screens, not what the screens load.
private final class SystemBarTransport: ClientTransport, @unchecked Sendable {
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == SystemBarWire.whoami else {
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

/// The same server, except that every read past `whoami` never answers: the screens stay in the
/// state they are in before their first read lands, which is the layout MEMNG-605 is about.
private final class StalledReadsTransport: ClientTransport, @unchecked Sendable {
    private let signedIn = SystemBarTransport()

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        if operationID != SystemBarWire.whoami {
            try await Task.sleep(for: .seconds(3600))
        }
        return try await signedIn.send(
            request,
            body: body,
            baseURL: baseURL,
            operationID: operationID
        )
    }
}

/// The keychain, in memory.
private final class SystemBarCredentials: CredentialStore, @unchecked Sendable {
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

/// The signed-in app's bar is its own capsule, never the system's (MEMNG-690). A root that draws a
/// header stands under its large title (MEMNG-666); the Timeline and Places draw none (MEMNG-756).
///
/// The real `MainTabView` over a real `SessionStore` and the real generated client: which bar is
/// drawn is decided by the modifiers between the `TabView` and each root, and a harness that
/// built its own `TabView` would be asserting its own chain. The app's bar is read off what it
/// draws (`ScopeBarProbe.tabsFrame`), the selection off the controller UIKit built for the
/// `TabView`, and UIKit's own bar is held off the screen.
@MainActor
@Suite("The tab bar and the tab roots' titles")
struct SystemTabBarRenderTests {
    /// The least height of the label a LARGE title is drawn in: the large-title style measures
    /// about 41 points on a phone and the inline style about 22, so the threshold sits between.
    static let largeTitleHeight: CGFloat = 30
    /// The roots that draw a header with the tab's name in it (MEMNG-757); the others spend no
    /// band of the screen on their names (MEMNG-756).
    static let headed: Set<MainTab> = [.library, .collections]

    @Test(
        "each tab root stands over the app's bar, titled large where it draws a header",
        arguments: MainTab.allCases
    )
    func eachRootStandsOverTheAppBar(tab: MainTab) async {
        let window = await Self.host(opening: tab)
        defer { Self.tearDown(window) }

        for _ in 0..<160 where !Self.arrived(on: tab, in: window) {
            await Self.settle(window)
        }
        // A title is installed turns after the bar, so where none is wanted its absence is read
        // only after as many turns as one would take to come.
        if !Self.headed.contains(tab) {
            for _ in 0..<40 { await Self.settle(window) }
        }

        let titles = ScopeBarProbe.tabTitlesLeftToRight(in: window)
        #expect(ScopeBarProbe.tabsShow(in: window), "\(tab.title): the app's bar is not on screen")
        // On the screen, not merely built: SwiftUI keeps the hidden bar in the hierarchy.
        #expect(!ScopeBarProbe.systemTabBarShows(in: window), "\(tab.title): UIKit's bar shows")
        #expect(titles == MainTab.allCases.map(\.title), "\(tab.title): the bar reads \(titles)")
        #expect(
            ScopeBarProbe.selectedTitle(in: window) == tab.title,
            "\(tab.title) is not the tab selected")

        // A header's title stands LARGE: a label reading the tab's name, drawn in the top third
        // of the window outside the bar, at least as tall as the large-title style draws it. A
        // root without a header has no such label at all.
        let height = Self.titleHeight(tab.title, in: window)
        let seen = Self.labels(in: window)
        if Self.headed.contains(tab) {
            #expect(
                height >= Self.largeTitleHeight,
                "\(tab.title)'s title is \(height) tall, not large; the screen reads \(seen)"
            )
        } else {
            #expect(height == 0, "\(tab.title) is titled \(height) tall; the screen reads \(seen)")
        }
    }

    /// MEMNG-605: while Places loads, its root already fills the screen, so nothing laid out
    /// against it — the bar included — moves when the map arrives. Read with every read stalled,
    /// so what is measured is the loading state, not the map that replaces it.
    @Test("the Places root fills the screen from its first layout, while it is still loading")
    func placesRootFillsTheScreenWhileLoading() async {
        let window = await Self.host(opening: .places, transport: StalledReadsTransport())
        defer { Self.tearDown(window) }

        var root: CGRect?
        for _ in 0..<160 where root == nil {
            await Self.settle(window)
            root = Self.frame(identified: PlacesView.rootIdentifier, in: window)
        }
        let seen = Self.labels(in: window)
        #expect(root != nil, "no Places root on the screen; it reads \(seen)")
        let frame = root ?? .zero
        let bounds = window.bounds
        #expect(frame.width >= bounds.width - 1, "the Places root is \(frame) in \(bounds)")
        #expect(frame.height >= bounds.height / 2, "the Places root is \(frame) in \(bounds)")
        // And the bar it was laid out against stands at the foot of the window.
        #expect(ScopeBarProbe.tabsShow(in: window), "no tab bar under the loading Places")
        if let drawn = ScopeBarProbe.tabsFrame(in: window) {
            // Its foot 21 pt above the screen's edge, where the system bar's stood
            // (`LeadingMainBar.bottomDrop`); a pixel either way for the rounding of the glass.
            let foot = bounds.maxY - drawn.maxY
            #expect(foot > 10 && foot < 32, "the bar is drawn at \(drawn)")
        }
    }

    // MARK: - hosting

    private static func host(
        opening tab: MainTab,
        transport: any ClientTransport = SystemBarTransport()
    ) async -> UIWindow {
        let session = SessionStore(
            credentials: SystemBarCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: transport
                )
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            // Its own clock, so a sign-in here rotates nothing another suite is counting on.
            identity: MediaIdentity()
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_systembar")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")

        // On the test host's own window scene: a window belonging to no scene never completes
        // the appearance transitions the bar's hiding and showing ride on (`StackChromeTests`).
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        let window: UIWindow
        if let scene = scene as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: tab).environment(session))
        window.makeKeyAndVisible()
        return window
    }

    private static func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func settle(_ window: UIWindow) async {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(25))
    }

    /// Whether the screen has reached what the root test reads: the bar up on `tab`, and where the
    /// root draws a header, a large label reading its name.
    private static func arrived(on tab: MainTab, in window: UIWindow) -> Bool {
        guard ScopeBarProbe.tabsShow(in: window) else { return false }
        guard ScopeBarProbe.selectedTitle(in: window) == tab.title else { return false }
        return !headed.contains(tab) || titleHeight(tab.title, in: window) >= largeTitleHeight
    }

    // MARK: - what the screen reads

    /// One element the screen reads out, where it is drawn in the window.
    private struct Reading {
        let label: String
        let frame: CGRect
        let element: NSObject
    }

    /// Every visible element outside the system tab bar, with the frame it is drawn at. The bar's
    /// own items are read off the bar; here they must not answer for the screen.
    private static func readings(in window: UIWindow) -> [Reading] {
        var found: [Reading] = []
        func visit(_ node: Any) {
            guard let object = node as? NSObject else { return }
            if object is UITabBar { return }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
            if let label = object.accessibilityLabel, !label.isEmpty {
                found.append(Reading(label: label, frame: frame(of: object), element: object))
            }
            for child in object.accessibilityElements ?? [] { visit(child) }
            if let view = object as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(window)
        return found
    }

    /// A UIKit view is asked where it is directly; SwiftUI's elements are not views and answer
    /// with their accessibility frame, which on this scene's window at the origin is the same.
    private static func frame(of element: NSObject) -> CGRect {
        if let view = element as? UIView, let window = view.window {
            return view.convert(view.bounds, to: window)
        }
        return element.accessibilityFrame
    }

    /// The height of the tallest label reading `title` in the top third of the window.
    private static func titleHeight(_ title: String, in window: UIWindow) -> CGFloat {
        let top = window.bounds.height / 3
        var tallest: CGFloat = 0
        for reading in readings(in: window) where reading.label == title {
            guard !reading.frame.isEmpty, reading.frame.midY < top else { continue }
            tallest = max(tallest, reading.frame.height)
        }
        return tallest
    }

    /// Where the element `identifier` names is drawn, or nil when nothing on screen carries it.
    private static func frame(identified identifier: String, in window: UIWindow) -> CGRect? {
        let selector = Selector(("accessibilityIdentifier"))
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject else { continue }
            if object is UITabBar { continue }
            if object.responds(to: selector),
                object.value(forKey: "accessibilityIdentifier") as? String == identifier
            {
                return frame(of: object)
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    private static func labels(in window: UIWindow) -> [String] {
        readings(in: window).map { "\($0.label)@\(Int($0.frame.midY))h\(Int($0.frame.height))" }
    }
}
