import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import MemosOutbox
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// Nonisolated because the transport below is: the generated client calls it off the main actor.
private enum ChromeWire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
    nonisolated static let listAttachments = "list_attachments_api_attachments_get"
    nonisolated static let attachmentTags = "attachment_tags_api_attachments_tags_get"
    nonisolated static let buckets = "attachment_buckets_api_attachments_buckets_get"
    nonisolated static let listMemos = "list_memos_api_memos_get"
    nonisolated static let markers = "list_markers_api_map_markers_get"
    /// Twelve days of September 2026, four pictures each: enough for every scope to scroll.
    nonisolated static let days = 1...12
    nonisolated static let perDay = 4
}

/// A populated server: one account's pictures, their day and year buckets, and a page of memos.
/// A read that asks for a further page gets an empty one, so the grid ends where the fixture does.
private final class ChromeTransport: ClientTransport, @unchecked Sendable {
    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let query = request.path.flatMap { URLComponents(string: $0)?.queryItems } ?? []
        let later = query.contains { $0.name == "cursor" && !($0.value ?? "").isEmpty }
        switch operationID {
        case ChromeWire.whoami:
            return Self.json(
                """
                {"subject":"fabian","display_name":"fabian","email":null,\
                "role":"user","auth_kind":"oidc"}
                """
            )
        case ChromeWire.listAttachments:
            return Self.json(later ? "[]" : "[\(Self.rows.joined(separator: ","))]")
        case ChromeWire.buckets:
            switch query.first(where: { $0.name == "size" })?.value {
            case "day": return Self.json("[\(Self.dayBuckets.joined(separator: ","))]")
            case "year": return Self.json(Self.years)
            default: return Self.json("[]")
            }
        case ChromeWire.attachmentTags:
            return Self.json("[]")
        case ChromeWire.markers:
            return Self.json(#"{"markers":[\#(Self.markers.joined(separator: ","))]}"#)
        case ChromeWire.listMemos:
            let items = later ? "" : Self.memos.joined(separator: ",")
            return Self.json(#"{"items":[\#(items)],"nextCursor":null,"totalCount":null}"#)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    private static func uid(day: Int, index: Int) -> String { "shot-\(day)-\(index)" }

    /// One located picture a day, strung along the lake, so Places opens on pins.
    private static let markers: [String] = ChromeWire.days.map { day in
        let name = uid(day: day, index: 0)
        let latitude = 47.30 + Double(day) * 0.01
        return """
            {"uid":"\(name)","mime":"image/jpeg","status":"ready","blurhash":null,"width":1200,\
            "height":800,"duration":null,"sha256":null,"capture_instant":null,\
            "capture_civil":null,"capture_source":null,"mine":true,"hasPrint":false,\
            "hasLegacyPrint":false,"renditions":[],"position":null,\
            "thumbnailUrl":"/api/attachments/\(name)/thumb",\
            "previewUrl":"/api/attachments/\(name)/mobile","webUrl":"/api/attachments/\(name)/web",\
            "posterUrl":"/api/attachments/\(name)/poster",\
            "downloadUrl":"/api/attachments/\(name)/download",\
            "printUrl":"/api/attachments/\(name)/print","memo_uid":"memo-\(day)",\
            "latitude":\(latitude),"longitude":8.55,"taken_at":"\(dayKey(day))T10:00:00Z"}
            """
    }

    private static func dayKey(_ day: Int) -> String { String(format: "2026-09-%02d", day) }

    private static func row(day: Int, index: Int) -> String {
        let uid = uid(day: day, index: index)
        let wide = index.isMultiple(of: 2)
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":\(wide ? 1200 : 800),"height":\(wide ? 800 : 1200),"mine":true,\
            "hasPrint":false,"hasLegacyPrint":false,"renditions":[],"orphan":true,\
            "memoUid":null,"takenAt":"\(dayKey(day))T\(10 + index):00:00Z",\
            "filename":"\(uid).jpg","thumbnailUrl":"/api/attachments/\(uid)/thumb",\
            "previewUrl":"/api/attachments/\(uid)/mobile","webUrl":"/api/attachments/\(uid)/web",\
            "posterUrl":"/api/attachments/\(uid)/poster",\
            "downloadUrl":"/api/attachments/\(uid)/download",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    /// Newest first, as the server lists them.
    private static let rows: [String] = ChromeWire.days.reversed().flatMap { day in
        (0..<ChromeWire.perDay).reversed().map { row(day: day, index: $0) }
    }

    private static let dayBuckets: [String] = ChromeWire.days.reversed().map { day in
        let cover = uid(day: day, index: 0)
        return """
            {"key":"\(dayKey(day))","count":\(ChromeWire.perDay),"coverUid":"\(cover)",\
            "coverThumbnailUrl":"/api/attachments/\(cover)/thumb"}
            """
    }

    private static let years = """
        [{"key":"2026","count":48,"coverUid":"\(uid(day: 12, index: 0))",\
        "coverThumbnailUrl":"/api/attachments/\(uid(day: 12, index: 0))/thumb"},\
        {"key":"2025","count":17,"coverUid":"\(uid(day: 3, index: 1))",\
        "coverThumbnailUrl":"/api/attachments/\(uid(day: 3, index: 1))/thumb"}]
        """

    private static let memos: [String] = (1...6).map { index in
        let pictures = (0..<(index % 3)).map { attachment(uid(day: index, index: $0)) }
        return """
            {"uid":"memo-\(index)","owner":"fabian","mine":true,\
            "content":"Memo \(index): a walk by the lake, and what the light did there. #walks",\
            "visibility":"PRIVATE","pinned":false,\
            "created_at":"2026-09-\(String(format: "%02d", 20 - index))T09:00:00Z",\
            "updated_at":"2026-09-\(String(format: "%02d", 20 - index))T09:00:00Z",\
            "archived_at":null,"tags":["walks"],"attachments":[\(pictures.joined(separator: ","))]}
            """
    }

    private static func attachment(_ uid: String) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":1000,"duration":null,"mine":true,"hasPrint":false,\
        "hasLegacyPrint":false,"renditions":[],"position":null,\
        "sha256":null,"capture_instant":null,"capture_civil":null,"capture_source":null,\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/original",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private static func json(_ payload: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }
}

/// Every picture answered with a flat colour of its own, so the screen is visibly populated.
private actor PaintedMedia: MediaTransport {
    private let palette: [Data]
    private(set) var served = 0

    init(palette: [Data]) {
        self.palette = palette
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        served += 1
        let pick = url.path.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        return (palette[pick % palette.count], response)
    }
}

/// The Library's bottom chrome is the system's (MEMNG-604): the tab bar is never taken away on
/// the Library, Years | Months | All is a system segmented control in the bar's bottom accessory,
/// and the two agree with the Library's scope both ways. Hosted in the real `MainTabView` over a
/// real `SessionStore`, the real generated client and a populated server, and photographed along
/// the way (`drawHierarchy`, attached to the result bundle) so a person can look at what ran.
///
/// In this suite for the reason `MediaLibrarySegmentTests` is: it installs the loader's
/// transport, which is process-wide, and the suite is serialized.
extension MediaImageLoaderTests {
    private func chromeHost(opening tab: MainTab) async -> UIWindow {
        let transport = ChromeTransport()
        let session = SessionStore(
            credentials: ChromeCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration,
                    credential: credential,
                    transport: transport
                )
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            identity: identity
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_chrome")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")

        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        let window: UIWindow
        if let scene = scene as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: tab).environment(session))
        window.makeKeyAndVisible()
        return window
    }

    private static func palette() -> [Data] {
        let colours: [UIColor] = [
            .systemTeal, .systemOrange, .systemIndigo, .systemGreen, .systemPink,
            .systemBrown, .systemBlue, .systemYellow, .systemPurple, .systemRed,
        ]
        return colours.map { MediaFixture.png($0, side: 16) }
    }

    private func chromeSettle(_ window: UIWindow, turns: Int = 1) async {
        for _ in 0..<turns {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The window as drawn, attached to the test's result as `shot-<name>.png`.
    private static func shoot(_ name: String, _ window: UIWindow) {
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "shot-\(name)", as: .png)
    }

    private static func tabBar(in window: UIWindow) -> UITabBar? {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UITabBar { return bar }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Whether the system tab bar is on screen: nothing up its chain hiding it, inside the window.
    private static func barShows(in window: UIWindow) -> Bool {
        guard let bar = tabBar(in: window) else { return false }
        var node: UIView? = bar
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        let frame = bar.convert(bar.bounds, to: window)
        return !frame.isEmpty && frame.intersects(window.bounds)
    }

    /// The tallest scroll view on screen: the one the Library's scope is drawn in.
    private static func mainScroll(in window: UIWindow) -> UIScrollView? {
        var best: UIScrollView?
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let scroller = view as? UIScrollView, scroller.window != nil,
                !(scroller is UITextView),
                scroller.bounds.height > (best?.bounds.height ?? window.bounds.height / 2)
            {
                best = scroller
            }
            stack.append(contentsOf: view.subviews)
        }
        return best
    }

    /// Every element reading out `label`, outside the tab bar.
    private static func elements(labelled label: String, in window: UIWindow) -> [NSObject] {
        var found: [NSObject] = []
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if object.accessibilityLabel == label { found.append(object) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    /// Every label the screen reads out, outside the tab bar.
    private static func labels(in window: UIWindow) -> [String] {
        var found: [String] = []
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return found
    }

    private static func frame(of element: NSObject) -> CGRect {
        if let view = element as? UIView, let window = view.window {
            return view.convert(view.bounds, to: window)
        }
        return element.accessibilityFrame
    }

    /// Waits until the scope control is on screen and shows `title` chosen; returns it.
    private func controlShowing(
        _ title: String?, in window: UIWindow
    ) async -> UISegmentedControl? {
        var control: UISegmentedControl?
        for _ in 0..<200 {
            await chromeSettle(window)
            control = ScopeAccessoryProbe.control(in: window)
            if let control, title == nil || ScopeAccessoryProbe.chosen(in: control) == title {
                break
            }
        }
        return control
    }

    @Test("the Library keeps the system tab bar in every scope and after a scroll")
    func libraryKeepsTheSystemBar() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let first = await controlShowing("All", in: window)
            var waited = 0
            while await media.served < 12, waited < 200 {
                await chromeSettle(window)
                waited += 1
            }
            await chromeSettle(window, turns: 20)
            let seen = ScopeAccessoryProbe.describe(window)
            #expect(Self.barShows(in: window), "the Library at rest: no system tab bar")
            #expect(first != nil, "the Library at rest: no scope control: \(seen)")
            Self.shoot("library-expanded", window)

            for scope in [LibraryScope.years, .months, .all] {
                if let control = ScopeAccessoryProbe.control(in: window) {
                    ScopeAccessoryProbe.choose(scope, in: control)
                }
                // The Library itself moved, not only the control: a Years card reads its count,
                // and nothing else draws one.
                var shown: [String] = []
                for _ in 0..<200 {
                    await chromeSettle(window)
                    shown = Self.labels(in: window)
                    if shown.contains("48 items") == (scope == .years) { break }
                }
                await chromeSettle(window, turns: 20)
                let card = shown.contains("48 items")
                #expect(card == (scope == .years), "\(scope.label): the Library reads \(shown)")
                let control = ScopeAccessoryProbe.control(in: window)
                let chosen = control.flatMap { ScopeAccessoryProbe.chosen(in: $0) }
                #expect(chosen == scope.label, "\(scope.label) not chosen: \(chosen ?? "-")")
                #expect(Self.barShows(in: window), "\(scope.label): the system tab bar is gone")
                if scope == .months { Self.shoot("library-months", window) }
            }

            // All, scrolled down in steps the way a drag moves it.
            let scroller = Self.mainScroll(in: window)
            #expect(scroller != nil, "no scroll view under All")
            if let scroller {
                let top = -scroller.adjustedContentInset.top
                for step in 1...24 {
                    let offset = CGPoint(x: 0, y: top + CGFloat(step) * 40)
                    scroller.setContentOffset(offset, animated: false)
                    await chromeSettle(window, turns: 2)
                }
            }
            await chromeSettle(window, turns: 40)
            let after = ScopeAccessoryProbe.control(in: window)
            let placement = after.map { ScopeAccessoryProbe.placement(of: $0).rawValue }
            #expect(Self.barShows(in: window), "All scrolled: the system tab bar is gone")
            let placed = String(describing: placement)
            #expect(after != nil, "All scrolled: no scope control (placement \(placed))")
            Self.shoot("library-scrolled", window)

            // At the foot of All the last row stands clear of the accessory.
            if let scroller, let after {
                let inset = scroller.adjustedContentInset.bottom
                let bottom = scroller.contentSize.height - scroller.bounds.height + inset
                scroller.setContentOffset(CGPoint(x: 0, y: max(bottom, 0)), animated: false)
                await chromeSettle(window, turns: 20)
                let drawn = scroller.convert(scroller.bounds, to: window)
                let visible = drawn.maxY - scroller.adjustedContentInset.bottom
                let control = after.convert(after.bounds, to: window)
                #expect(
                    visible <= control.minY + 1,
                    "the content ends at \(visible), under the control at \(control.minY)"
                )
            }
        }
    }

    @Test("a jump inside the Library moves the scope control; a choice in it moves the Library")
    func scopeControlAndTheLibraryAgree() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await controlShowing("All", in: window)
            var waited = 0
            while await media.served < 12, waited < 200 {
                await chromeSettle(window)
                waited += 1
            }
            await chromeSettle(window, turns: 20)

            // From inside the Library, before any choice by hand, so a control that only
            // remembered its own taps would still read All: a drag down All raises the date pill,
            // whose tap opens Months, and the control follows.
            let pillLabels = Set(
                ChromeWire.days.map { dayPillLabel(String(format: "2026-09-%02d", $0)) })
            var pills: [NSObject] = []
            if let scroller = Self.mainScroll(in: window) {
                let top = -scroller.adjustedContentInset.top
                for step in 1...24 where pills.isEmpty {
                    let offset = CGPoint(x: 0, y: top + CGFloat(step) * 40)
                    scroller.setContentOffset(offset, animated: false)
                    await chromeSettle(window)
                    pills = pillLabels.flatMap { Self.elements(labelled: $0, in: window) }
                }
            }
            #expect(!pills.isEmpty, "no date pill while All scrolled: \(Self.labels(in: window))")
            #expect(pills.contains { $0.accessibilityActivate() }, "the date pill took no press")
            let opened = await controlShowing("Months", in: window)
            let onPill = opened.flatMap { ScopeAccessoryProbe.chosen(in: $0) }
            #expect(onPill == "Months", "the pill left the control on \(onPill ?? "nothing")")

            // Months draws a tile per day — the newest six, the 12th among them — and a day tile
            // jumps back to All; the control follows that way too.
            var tiles: [NSObject] = []
            for _ in 0..<200 where tiles.isEmpty {
                await chromeSettle(window)
                tiles = Self.elements(labelled: "12", in: window).filter {
                    $0.accessibilityTraits.contains(.button)
                }
            }
            #expect(tiles.contains { $0.accessibilityActivate() }, "no day tile took a press")
            let followed = await controlShowing("All", in: window)
            let chosen = followed.flatMap { ScopeAccessoryProbe.chosen(in: $0) }
            #expect(chosen == "All", "the day's jump left the control on \(chosen ?? "nothing")")

            // By hand: Months again, and the Library draws it — the month's own title, which All
            // does not draw (All heads its months "September 2026").
            let control = await ScopeAccessoryProbe.settledControl(in: window) {
                await chromeSettle(window)
            }
            #expect(control != nil, "no scope control: \(ScopeAccessoryProbe.describe(window))")
            if let control { ScopeAccessoryProbe.choose(.months, in: control) }
            var drawn: [NSObject] = []
            for _ in 0..<200 where drawn.isEmpty {
                await chromeSettle(window)
                drawn = Self.elements(labelled: "Sep 2026", in: window)
            }
            #expect(!drawn.isEmpty, "Months is not drawn after the control chose it")
        }
    }

    @Test("select mode hides the system tab bar and the scope control; Close brings both back")
    func selectModeHidesTheBar() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await controlShowing("All", in: window)
            var waited = 0
            while await media.served < 12, waited < 200 {
                await chromeSettle(window)
                waited += 1
            }
            #expect(Self.barShows(in: window), "precondition: the system tab bar at rest")

            // In select mode its toolbar is the only bottom chrome, as in Photos.
            let select = Self.elements(labelled: "Select", in: window)
            #expect(select.contains { $0.accessibilityActivate() }, "Select took no press")
            var share: [NSObject] = []
            for _ in 0..<200 where share.isEmpty || Self.barShows(in: window) {
                await chromeSettle(window)
                share = Self.elements(labelled: "Share", in: window)
            }
            await chromeSettle(window, turns: 20)
            let seen = ScopeAccessoryProbe.describe(window)
            #expect(!share.isEmpty, "select mode drew no toolbar")
            #expect(!Self.barShows(in: window), "the system tab bar stayed under select mode")
            #expect(ScopeAccessoryProbe.control(in: window) == nil, "the scope control: \(seen)")
            Self.shoot("library-select", window)

            // Leaving it gives the bar and the control back.
            let close = Self.elements(labelled: "Close", in: window)
            #expect(close.contains { $0.accessibilityActivate() }, "Close took no press")
            for _ in 0..<200 where !Self.barShows(in: window) {
                await chromeSettle(window)
            }
            #expect(Self.barShows(in: window), "the system tab bar did not come back after Close")
            let back = await controlShowing("All", in: window)
            let after = ScopeAccessoryProbe.describe(window)
            #expect(back != nil, "no scope control after Close: \(after)")
        }
    }

    @Test("Timeline and Places stand over the system tab bar, with no scope control")
    func otherRootsHaveNoScope() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            for tab in [MainTab.timeline, .places] {
                let window = await chromeHost(opening: tab)
                for _ in 0..<200 where Self.tabBar(in: window)?.selectedItem?.title != tab.title {
                    await chromeSettle(window)
                }
                await chromeSettle(window, turns: 80)
                #expect(Self.barShows(in: window), "\(tab.title): no system tab bar")
                let control = ScopeAccessoryProbe.control(in: window)
                #expect(control == nil, "\(tab.title) shows the Library's scope control")
                Self.shoot(tab.rawValue, window)
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }
}

/// The keychain, in memory.
private final class ChromeCredentials: CredentialStore, @unchecked Sendable {
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
