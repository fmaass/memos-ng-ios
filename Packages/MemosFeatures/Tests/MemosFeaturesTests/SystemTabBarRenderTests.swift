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

/// The signed-in app's bar is the SYSTEM's, and each tab root stands under a large title of its
/// own (MEMNG-666).
///
/// The real `MainTabView` over a real `SessionStore` and the real generated client: whether the
/// system bar is drawn is decided by the modifiers between the `TabView` and each root, and a
/// harness that built its own `TabView` would be asserting its own chain. The bar is read off the
/// `UITabBar` UIKit built for it — its items, the one it marks selected, and whether it is on the
/// screen at all — and pressed through the controller that owns it, which is the path the system
/// bar's own taps take.
@MainActor
@Suite("The system tab bar and the tab roots' titles")
struct SystemTabBarRenderTests {
    /// The least height of the label a LARGE title is drawn in: the large-title style measures
    /// about 41 points on a phone and the inline style about 22, so the threshold sits between.
    static let largeTitleHeight: CGFloat = 30

    @Test(
        "each tab root stands over the system tab bar, under a large title of its own",
        arguments: MainTab.allCases
    )
    func eachRootStandsOverTheSystemBar(tab: MainTab) async {
        let window = await Self.host(opening: tab)
        defer { Self.tearDown(window) }

        for _ in 0..<160 where !Self.arrived(on: tab, in: window) {
            await Self.settle(window)
        }

        let bar = Self.systemTabBar(in: window)
        let titles = bar?.items?.compactMap(\.title) ?? []
        // On the screen, not merely built: SwiftUI keeps a hidden bar in the hierarchy.
        #expect(Self.barShows(in: window), "\(tab.title): the system tab bar is not on screen")
        #expect(titles == MainTab.allCases.map(\.title), "\(tab.title): the bar reads \(titles)")
        #expect(bar?.selectedItem?.title == tab.title, "\(tab.title) is not the tab selected")

        // The title stands LARGE: a label reading the tab's name, drawn in the top third of the
        // window outside the bar, at least as tall as the large-title style draws it.
        let height = Self.titleHeight(tab.title, in: window)
        let seen = Self.labels(in: window)
        #expect(
            height >= Self.largeTitleHeight,
            "\(tab.title)'s title is \(height) tall, not large; the screen reads \(seen)"
        )
    }

    /// The Library's chrome (plan page 3929 decision 8): a press on the Library while it is the
    /// tab showing hands the bar's place to the Library icon beside Years | Months | All, and the
    /// icon is what gives the bar back. The segment and the bar are never drawn together.
    @Test("the Library's chrome stands in the bar's place until its own icon is pressed")
    func libraryChromeHoldsUntilItsIcon() async {
        let window = await Self.host(opening: .library)
        defer { Self.tearDown(window) }
        let segment = Set(LibraryScope.allCases.map(\.label) + [MainTab.library.title])

        for _ in 0..<160 where !Self.arrived(on: .library, in: window) {
            await Self.settle(window)
        }
        #expect(Self.barShows(in: window), "the Library at rest: no system tab bar on screen")
        let atRest = Self.chromeLabels(segment, in: window)
        #expect(atRest.isEmpty, "the Library at rest draws its chrome: \(atRest)")

        // The Library pressed again, the way the system bar presses the tab already showing.
        #expect(Self.press(.library, in: window), "no bar item reads Library")
        for _ in 0..<80 where Self.chromeLabels(segment, in: window) != segment {
            await Self.settle(window)
        }
        let collapsed = Self.chromeLabels(segment, in: window)
        #expect(collapsed == segment, "the Library pressed again: the chrome reads \(collapsed)")
        for _ in 0..<80 where Self.barShows(in: window) {
            await Self.settle(window)
        }
        #expect(!Self.barShows(in: window), "the system tab bar is drawn beside the chrome")

        // The icon, and only the icon, gives the bar back.
        let took = Self.activate(MainTab.library.title, in: window)
        #expect(took, "the chrome's Library icon took no press")
        for _ in 0..<80 where !Self.barShows(in: window) {
            await Self.settle(window)
        }
        #expect(Self.barShows(in: window), "the icon did not give the system tab bar back")
        let selected = Self.systemTabBar(in: window)?.selectedItem?.title
        #expect(selected == MainTab.library.title, "the bar came back on \(selected ?? "nothing")")
        for _ in 0..<80 where !Self.chromeLabels(segment, in: window).isEmpty {
            await Self.settle(window)
        }
        let after = Self.chromeLabels(segment, in: window)
        #expect(after.isEmpty, "the chrome stayed beside the bar: \(after)")
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
        #expect(Self.barShows(in: window), "no system tab bar under the loading Places")
        if let bar = Self.systemTabBar(in: window) {
            let drawn = bar.convert(bar.bounds, to: window)
            #expect(abs(drawn.maxY - bounds.maxY) < 1, "the bar is drawn at \(drawn)")
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

    /// Whether the screen has reached what the root test reads: the bar up on `tab`, and a large
    /// label reading its name.
    private static func arrived(on tab: MainTab, in window: UIWindow) -> Bool {
        guard barShows(in: window) else { return false }
        guard systemTabBar(in: window)?.selectedItem?.title == tab.title else { return false }
        return titleHeight(tab.title, in: window) >= largeTitleHeight
    }

    // MARK: - the bar

    private static func systemTabBar(in view: UIView) -> UITabBar? {
        if let bar = view as? UITabBar { return bar }
        for subview in view.subviews {
            if let bar = systemTabBar(in: subview) { return bar }
        }
        return nil
    }

    /// Whether the system tab bar is on screen: in the hierarchy, nothing up its chain of
    /// superviews hiding it, and some part of it inside the window.
    private static func barShows(in window: UIWindow) -> Bool {
        guard let bar = systemTabBar(in: window) else { return false }
        var node: UIView? = bar
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        let frame = bar.convert(bar.bounds, to: window)
        return !frame.isNull && !frame.isEmpty && frame.intersects(window.bounds)
    }

    /// Presses `tab` through the controller UIKit built for the bar, the way a tap on its item
    /// does: the delegate is asked, the controller selects, the delegate is told.
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

    /// Which of `labels` the bottom fifth of the window reads out, outside the system tab bar —
    /// where the Library's chrome is drawn.
    private static func chromeLabels(_ labels: Set<String>, in window: UIWindow) -> Set<String> {
        Set(chrome(in: window).map(\.label).filter(labels.contains))
    }

    private static func chrome(in window: UIWindow) -> [Reading] {
        let band = window.bounds.height * 0.8
        return readings(in: window).filter { reading in
            guard !reading.frame.isEmpty, reading.frame.midY > band else { return false }
            return reading.frame.intersects(window.bounds)
        }
    }

    /// Activates the chrome's control labelled `label` the way VoiceOver does.
    private static func activate(_ label: String, in window: UIWindow) -> Bool {
        chrome(in: window)
            .filter { $0.label == label && $0.element.accessibilityTraits.contains(.button) }
            .contains { $0.element.accessibilityActivate() }
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
