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
/// `days` is which days of September 2026 hold pictures: every scope scrolls over the default,
/// and a single day is a grid too short to scroll.
private final class ChromeTransport: ClientTransport, @unchecked Sendable {
    private let rows: [String]
    private let dayBuckets: [String]
    private let markers: [String]

    init(days: ClosedRange<Int> = ChromeWire.days) {
        rows = Self.rows(days)
        dayBuckets = Self.dayBuckets(days)
        markers = Self.markers(days)
    }

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
            return Self.json(later ? "[]" : "[\(rows.joined(separator: ","))]")
        case ChromeWire.buckets:
            switch query.first(where: { $0.name == "size" })?.value {
            case "day": return Self.json("[\(dayBuckets.joined(separator: ","))]")
            case "year": return Self.json(Self.years)
            default: return Self.json("[]")
            }
        case ChromeWire.attachmentTags:
            return Self.json("[]")
        case ChromeWire.markers:
            return Self.json(#"{"markers":[\#(markers.joined(separator: ","))]}"#)
        case ChromeWire.listMemos:
            let items = later ? "" : Self.memos.joined(separator: ",")
            return Self.json(#"{"items":[\#(items)],"nextCursor":null,"totalCount":null}"#)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    private static func uid(day: Int, index: Int) -> String { "shot-\(day)-\(index)" }

    /// One located picture a day, strung along the lake, so Places opens on pins.
    private static func markers(_ days: ClosedRange<Int>) -> [String] {
        days.map { day in
            let name = uid(day: day, index: 0)
            let latitude = 47.30 + Double(day) * 0.01
            return """
                {"uid":"\(name)","mime":"image/jpeg","status":"ready","blurhash":null,"width":1200,\
                "height":800,"duration":null,"sha256":null,"capture_instant":null,\
                "capture_civil":null,"capture_source":null,"mine":true,"hasPrint":false,\
                "hasLegacyPrint":false,"renditions":[],"position":null,\
                "thumbnailUrl":"/api/attachments/\(name)/thumb",\
                "previewUrl":"/api/attachments/\(name)/mobile",\
                "webUrl":"/api/attachments/\(name)/web",\
                "posterUrl":"/api/attachments/\(name)/poster",\
                "downloadUrl":"/api/attachments/\(name)/download",\
                "printUrl":"/api/attachments/\(name)/print","memo_uid":"memo-\(day)",\
                "latitude":\(latitude),"longitude":8.55,"taken_at":"\(dayKey(day))T10:00:00Z"}
                """
        }
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
    private static func rows(_ days: ClosedRange<Int>) -> [String] {
        days.reversed().flatMap { day in
            (0..<ChromeWire.perDay).reversed().map { row(day: day, index: $0) }
        }
    }

    private static func dayBuckets(_ days: ClosedRange<Int>) -> [String] {
        days.reversed().map { day in
            let cover = uid(day: day, index: 0)
            return """
                {"key":"\(dayKey(day))","count":\(ChromeWire.perDay),"coverUid":"\(cover)",\
                "coverThumbnailUrl":"/api/attachments/\(cover)/thumb"}
                """
        }
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

/// The Library's bottom chrome is the system's (MEMNG-604, MEMNG-679): the tab bar at launch, and
/// once the Library is scrolled, or its item pressed where it shows, the Library's own system
/// toolbar in its place — its icon beside Years | Months | All, a system segmented control that
/// agrees with the Library's scope both ways — until the icon gives the bar back. Hosted in the real `MainTabView` over a
/// real `SessionStore`, the real generated client and a populated server, and photographed along
/// the way (`drawHierarchy`, attached to the result bundle) so a person can look at what ran.
///
/// In this suite for the reason `MediaLibrarySegmentTests` is: it installs the loader's
/// transport, which is process-wide, and the suite is serialized.
extension MediaImageLoaderTests {
    private func chromeHost(
        opening tab: MainTab, days: ClosedRange<Int> = ChromeWire.days
    ) async -> UIWindow {
        let transport = ChromeTransport(days: days)
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
            control = ScopeBarProbe.control(in: window)
            if let control, title == nil || ScopeBarProbe.chosen(in: control) == title {
                break
            }
        }
        return control
    }

    /// Waits until the Library has served its first screen of pictures — `pictures` of them —
    /// and settled.
    private func libraryServed(
        _ media: PaintedMedia, _ window: UIWindow, pictures: Int = 12
    ) async {
        var waited = 0
        while await media.served < pictures, waited < 200 {
            await chromeSettle(window)
            waited += 1
        }
        await chromeSettle(window, turns: 20)
    }

    /// Presses the Library's item in the system bar and waits for the scope toolbar to stand in
    /// the bar's place; returns its control.
    private func pressIntoScope(_ window: UIWindow) async -> UISegmentedControl? {
        #expect(ScopeBarProbe.pressTab(.library, in: window), "the bar's Library took no press")
        var control: UISegmentedControl?
        for _ in 0..<200 where control == nil || Self.barShows(in: window) {
            await chromeSettle(window)
            control = ScopeBarProbe.control(in: window)
        }
        await chromeSettle(window, turns: 20)
        return ScopeBarProbe.control(in: window)
    }

    /// Scrolls the main scroll view down in steps, the way a drag moves it.
    private func scrollDown(_ window: UIWindow) async {
        guard let scroller = Self.mainScroll(in: window) else { return }
        let top = -scroller.adjustedContentInset.top
        for step in 1...24 {
            scroller.setContentOffset(CGPoint(x: 0, y: top + CGFloat(step) * 40), animated: false)
            await chromeSettle(window, turns: 2)
        }
        await chromeSettle(window, turns: 20)
    }

    /// How far the main scroll view stands from the top of its content, the dock's own measure:
    /// 0 at rest, whatever bars stand over it.
    private static func scrolledBy(in window: UIWindow) -> CGFloat? {
        guard let scroller = mainScroll(in: window) else { return nil }
        return scroller.contentOffset.y + scroller.adjustedContentInset.top
    }

    /// Scrolls the main scroll view on down from where it stands, in steps, the way a drag does.
    private func scrollFurther(_ window: UIWindow, by distance: CGFloat) async {
        guard let scroller = Self.mainScroll(in: window) else { return }
        let from = scroller.contentOffset.y
        for step in 1...5 {
            let offset = CGPoint(x: 0, y: from + distance * CGFloat(step) / 5)
            scroller.setContentOffset(offset, animated: false)
            await chromeSettle(window, turns: 2)
        }
        await chromeSettle(window, turns: 20)
    }

    /// Drags the main scroll view on down from where it stands: the moves a finger makes, told to
    /// the scroll view's delegate as a drag that begins and ends around them, so the scroll phase
    /// is the reader's and not the layout's.
    private func drag(_ window: UIWindow, by distance: CGFloat) async {
        guard let scroller = Self.mainScroll(in: window) else { return }
        let from = scroller.contentOffset.y
        scroller.delegate?.scrollViewWillBeginDragging?(scroller)
        for step in 1...5 {
            let offset = CGPoint(x: 0, y: from + distance * CGFloat(step) / 5)
            scroller.setContentOffset(offset, animated: false)
            await chromeSettle(window, turns: 1)
        }
        var target = scroller.contentOffset
        scroller.delegate?.scrollViewWillEndDragging?(
            scroller, withVelocity: .zero, targetContentOffset: &target)
        scroller.delegate?.scrollViewDidEndDragging?(scroller, willDecelerate: false)
        await chromeSettle(window, turns: 20)
    }

    /// Scrolls the main scroll view to its foot, the last row clear of the bottom bar.
    private func scrollToFoot(_ window: UIWindow) async {
        guard let scroller = Self.mainScroll(in: window) else { return }
        let inset = scroller.adjustedContentInset.bottom
        let bottom = scroller.contentSize.height - scroller.bounds.height + inset
        scroller.setContentOffset(CGPoint(x: 0, y: max(bottom, 0)), animated: false)
        await chromeSettle(window, turns: 20)
    }

    /// Waits until the scope toolbar stands in the tab bar's place.
    private func scopeStands(_ window: UIWindow) async {
        for _ in 0..<200 where !Self.scopeShows(in: window) {
            await chromeSettle(window)
        }
        await chromeSettle(window, turns: 20)
    }

    /// Waits until the system tab bar stands again and no scope is drawn.
    private func tabsStand(_ window: UIWindow) async {
        for _ in 0..<200 where !Self.tabsShow(in: window) {
            await chromeSettle(window)
        }
        await chromeSettle(window, turns: 20)
    }

    private static func scopeShows(in window: UIWindow) -> Bool {
        ScopeBarProbe.control(in: window) != nil && !barShows(in: window)
    }

    private static func tabsShow(in window: UIWindow) -> Bool {
        ScopeBarProbe.control(in: window) == nil && barShows(in: window)
    }

    /// Waits until the system bar has `tab` chosen.
    private func tabChosen(_ tab: MainTab, _ window: UIWindow) async {
        for _ in 0..<200 where Self.tabBar(in: window)?.selectedItem?.title != tab.title {
            await chromeSettle(window)
        }
    }

    /// The Library at launch: the system tab bar and nothing of its scope. A scroll down past the
    /// threshold swaps the bar for the scope toolbar — the Library icon beside Years | Months |
    /// All, on All — the way the Timeline's bar minimises once it scrolls (MEMNG-679).
    @Test("the Library opens on the tab bar, and a scroll down swaps it for the scope toolbar")
    func libraryOpensOnTheTabs() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            let seen = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "the Library at launch: no system tab bar")
            #expect(ScopeBarProbe.control(in: window) == nil, "a scope at launch: \(seen)")
            #expect(!ScopeBarProbe.libraryIconShows(in: window), "an icon at launch: \(seen)")
            Self.shoot("library-tabs", window)

            await scrollDown(window)
            await scopeStands(window)
            let scrolled = ScopeBarProbe.describe(window)
            let control = ScopeBarProbe.control(in: window)
            #expect(control != nil, "All scrolled: no scope control: \(scrolled)")
            #expect(control?.numberOfSegments == 3, "segments: \(scrolled)")
            #expect(control.flatMap { ScopeBarProbe.chosen(in: $0) } == "All", "\(scrolled)")
            #expect(ScopeBarProbe.libraryIconShows(in: window), "no Library icon: \(scrolled)")
            #expect(!Self.barShows(in: window), "All scrolled: the tab bar stayed: \(scrolled)")
            Self.shoot("library-scrolled", window)
        }
    }

    /// A press on the Library's item swaps the system bar for the Library's scope toolbar — its
    /// icon, then Years | Months | All — whose control moves the Library in every scope; a scroll
    /// keeps it, and only the icon gives the bar back (MEMNG-604).
    @Test("a press on the Library swaps the tab bar for its scope toolbar until the icon")
    func pressSwapsTheBars() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)

            let control = await pressIntoScope(window)
            let seen = ScopeBarProbe.describe(window)
            Attachment.record(seen, named: "chrome-library-scope")
            #expect(control != nil, "the Library pressed: no scope control: \(seen)")
            #expect(control?.numberOfSegments == 3, "segments: \(seen)")
            #expect(control.flatMap { ScopeBarProbe.chosen(in: $0) } == "All", "\(seen)")
            #expect(ScopeBarProbe.libraryIconShows(in: window), "no Library icon: \(seen)")
            #expect(!Self.barShows(in: window), "the system tab bar beside the scope: \(seen)")
            Self.shoot("library-scope-all", window)

            // Each scope by hand, and the Library itself moves, not only the control: a Years card
            // reads its count, and Months heads a month "Sep 2026", which All does not draw.
            let marks: [(LibraryScope, String)] = [(.months, "Sep 2026"), (.years, "48 items")]
            for (scope, mark) in marks {
                let live = await ScopeBarProbe.settledControl(in: window) {
                    await chromeSettle(window)
                }
                if let live { ScopeBarProbe.choose(scope, in: live) }
                var drawn: [NSObject] = []
                for _ in 0..<200 where drawn.isEmpty {
                    await chromeSettle(window)
                    drawn = Self.elements(labelled: mark, in: window)
                }
                await chromeSettle(window, turns: 20)
                #expect(!drawn.isEmpty, "\(scope.label) not drawn: \(Self.labels(in: window))")
                let chosen = ScopeBarProbe.control(in: window).flatMap {
                    ScopeBarProbe.chosen(in: $0)
                }
                #expect(chosen == scope.label, "\(scope.label) not chosen: \(chosen ?? "-")")
                #expect(!Self.barShows(in: window), "\(scope.label): the tab bar came back")
                Self.shoot("library-scope-\(scope.rawValue)", window)
            }

            // All again, scrolled to its foot: the toolbar stays, and the last row clears it.
            if let live = await ScopeBarProbe.settledControl(
                in: window,
                settle: {
                    await chromeSettle(window)
                })
            {
                ScopeBarProbe.choose(.all, in: live)
            }
            for _ in 0..<200 where Self.labels(in: window).contains("48 items") {
                await chromeSettle(window)
            }
            await scrollDown(window)
            let scrolled = ScopeBarProbe.control(in: window)
            #expect(scrolled != nil, "All scrolled: the scope toolbar went")
            #expect(!Self.barShows(in: window), "All scrolled: the tab bar came back")
            if let scroller = Self.mainScroll(in: window), let scrolled {
                let inset = scroller.adjustedContentInset.bottom
                let bottom = scroller.contentSize.height - scroller.bounds.height + inset
                scroller.setContentOffset(CGPoint(x: 0, y: max(bottom, 0)), animated: false)
                await chromeSettle(window, turns: 20)
                let drawn = scroller.convert(scroller.bounds, to: window)
                let visible = drawn.maxY - scroller.adjustedContentInset.bottom
                let top = scrolled.convert(scrolled.bounds, to: window).minY
                #expect(visible <= top + 1, "the content ends at \(visible), the control at \(top)")
            }

            // The icon gives the bar back, still on the Library.
            let how = ScopeBarProbe.pressLibraryIcon(in: window)
            #expect(how != nil, "no Library icon took a press: \(ScopeBarProbe.describe(window))")
            for _ in 0..<200 where !Self.barShows(in: window) {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            let after = ScopeBarProbe.describe(window)
            Attachment.record("icon pressed by \(how ?? "nothing"); \(after)", named: "chrome-icon")
            #expect(Self.barShows(in: window), "the icon did not give the bar back: \(after)")
            #expect(ScopeBarProbe.control(in: window) == nil, "the scope stayed: \(after)")
            let selected = Self.tabBar(in: window)?.selectedItem?.title
            #expect(selected == MainTab.library.title, "the bar came back on \(selected ?? "-")")
        }
    }

    @Test("a jump inside the Library moves the scope control; a choice in it moves the Library")
    func scopeControlAndTheLibraryAgree() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .timeline)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let timeline = MainTab.timeline.title
            for _ in 0..<200 where Self.tabBar(in: window)?.selectedItem?.title != timeline {
                await chromeSettle(window)
            }
            // The Library pressed from the Timeline, which opens it on the tabs, and then again
            // where it shows, which gives the scope toolbar (MEMNG-679): what this test can fail
            // on is the control's binding alone.
            #expect(ScopeBarProbe.pressTab(.library, in: window), "the bar's Library took no press")
            await chromeSettle(window, turns: 20)
            _ = await pressIntoScope(window)
            await libraryServed(media, window)

            // From inside the Library, before any choice by hand, so a control that only
            // remembered its own taps would still read All: a scroll down All raises the date
            // pill, whose tap opens Months, and the control follows.
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
            let onPill = opened.flatMap { ScopeBarProbe.chosen(in: $0) }
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
            let chosen = followed.flatMap { ScopeBarProbe.chosen(in: $0) }
            #expect(chosen == "All", "the day's jump left the control on \(chosen ?? "nothing")")
        }
    }

    @Test("select mode hides the tab bar and the scope toolbar; Close restores the bar it hid")
    func selectModeHidesTheBar() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            _ = await pressIntoScope(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "precondition: the scope toolbar")

            // In select mode its toolbar is the only bottom chrome, as in Photos.
            let select = Self.elements(labelled: "Select", in: window)
            #expect(select.contains { $0.accessibilityActivate() }, "Select took no press")
            var share: [NSObject] = []
            for _ in 0..<200 where share.isEmpty || ScopeBarProbe.control(in: window) != nil {
                await chromeSettle(window)
                share = Self.elements(labelled: "Share", in: window)
            }
            await chromeSettle(window, turns: 20)
            let seen = ScopeBarProbe.describe(window)
            #expect(!share.isEmpty, "select mode drew no toolbar")
            #expect(!Self.barShows(in: window), "the system tab bar under select mode: \(seen)")
            #expect(ScopeBarProbe.control(in: window) == nil, "the scope under select: \(seen)")
            #expect(!ScopeBarProbe.libraryIconShows(in: window), "the icon under select: \(seen)")
            Self.shoot("library-select", window)

            // Close: the scope toolbar it hid, not the tab bar.
            await closeSelect(window)
            for _ in 0..<200 where ScopeBarProbe.control(in: window) == nil {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            let scope = ScopeBarProbe.describe(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "Close lost the scope: \(scope)")
            #expect(!Self.barShows(in: window), "Close brought the tab bar back: \(scope)")

            // From the tabs, the tabs: the icon first, then select mode in and out.
            #expect(ScopeBarProbe.pressLibraryIcon(in: window) != nil, "no icon took a press")
            for _ in 0..<200 where !Self.barShows(in: window) {
                await chromeSettle(window)
            }
            let again = Self.elements(labelled: "Select", in: window)
            #expect(again.contains { $0.accessibilityActivate() }, "Select took no press")
            for _ in 0..<200 where Self.barShows(in: window) {
                await chromeSettle(window)
            }
            #expect(!Self.barShows(in: window), "the system tab bar stayed under select mode")
            await closeSelect(window)
            for _ in 0..<200 where !Self.barShows(in: window) {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            let tabs = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "Close did not bring the tab bar back: \(tabs)")
            #expect(ScopeBarProbe.control(in: window) == nil, "Close drew the scope: \(tabs)")
        }
    }

    private func closeSelect(_ window: UIWindow) async {
        let close = Self.elements(labelled: "Close", in: window)
        #expect(close.contains { $0.accessibilityActivate() }, "Close took no press")
        for _ in 0..<200 where !Self.elements(labelled: "Share", in: window).isEmpty {
            await chromeSettle(window)
        }
    }

    /// Timeline and Places stand over the system bar with nothing of the Library's, and the
    /// Library's item pressed from either opens the Library on the tabs (MEMNG-679): a press from
    /// another tab is the way back to the Library, not into its scope. Pressed again where it
    /// shows, it gives the scope toolbar; a press back on the tab left gives that tab its bar.
    @Test("Timeline and Places keep the tab bar; the Library pressed from them opens on the tabs")
    func otherRootsHaveNoScope() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            for tab in [MainTab.timeline, .places] {
                let window = await chromeHost(opening: tab)
                await tabChosen(tab, window)
                await chromeSettle(window, turns: 80)
                let seen = ScopeBarProbe.describe(window)
                #expect(Self.barShows(in: window), "\(tab.title): no system tab bar")
                #expect(ScopeBarProbe.control(in: window) == nil, "\(tab.title): \(seen)")
                #expect(!ScopeBarProbe.libraryIconShows(in: window), "\(tab.title): \(seen)")
                Self.shoot(tab.rawValue, window)

                #expect(ScopeBarProbe.pressTab(.library, in: window), "Library took no press")
                await tabChosen(.library, window)
                await chromeSettle(window, turns: 40)
                let pressed = ScopeBarProbe.describe(window)
                #expect(Self.barShows(in: window), "the Library from \(tab.title): \(pressed)")
                #expect(
                    ScopeBarProbe.control(in: window) == nil,
                    "the Library from \(tab.title) opened on its scope: \(pressed)")
                #expect(!ScopeBarProbe.libraryIconShows(in: window), "\(tab.title): \(pressed)")

                let control = await pressIntoScope(window)
                let again = ScopeBarProbe.describe(window)
                #expect(control != nil, "the Library pressed where it shows: no scope: \(again)")
                #expect(!Self.barShows(in: window), "the bar beside the scope: \(again)")

                #expect(ScopeBarProbe.pressTab(tab, in: window), "\(tab.title) took no press")
                for _ in 0..<200 where !Self.barShows(in: window) {
                    await chromeSettle(window)
                }
                await chromeSettle(window, turns: 20)
                let back = ScopeBarProbe.describe(window)
                #expect(Self.barShows(in: window), "back on \(tab.title): no tab bar: \(back)")
                #expect(ScopeBarProbe.control(in: window) == nil, "back on \(tab.title): \(back)")
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }

    /// A scope picked in the scope toolbar keeps it (MEMNG-679): the pick swaps the scroll view for
    /// one standing at its top, and no scroll gives the tabs back, the top of a page included.
    @Test("a scope picked after a scroll keeps the scope toolbar, in every scope")
    func scopePickKeepsTheScopeBar() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "precondition: a scroll, no scope")

            let marks: [(LibraryScope, String)] = [(.months, "Sep 2026"), (.years, "48 items")]
            for (scope, mark) in marks {
                let live = await ScopeBarProbe.settledControl(in: window) {
                    await chromeSettle(window)
                }
                if let live { ScopeBarProbe.choose(scope, in: live) }
                for _ in 0..<200 where Self.elements(labelled: mark, in: window).isEmpty {
                    await chromeSettle(window)
                }
                await chromeSettle(window, turns: 40)
                let seen = ScopeBarProbe.describe(window)
                let chosen = ScopeBarProbe.control(in: window).flatMap {
                    ScopeBarProbe.chosen(in: $0)
                }
                #expect(chosen == scope.label, "\(scope.label) picked: the scope went: \(seen)")
                #expect(!Self.barShows(in: window), "\(scope.label) picked: the tab bar: \(seen)")
                #expect(ScopeBarProbe.libraryIconShows(in: window), "\(scope.label): \(seen)")
            }

            if let live = await ScopeBarProbe.settledControl(
                in: window,
                settle: {
                    await chromeSettle(window)
                })
            {
                ScopeBarProbe.choose(.all, in: live)
            }
            for _ in 0..<200 where Self.labels(in: window).contains("48 items") {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 40)
            let all = ScopeBarProbe.describe(window)
            let chosen = ScopeBarProbe.control(in: window).flatMap { ScopeBarProbe.chosen(in: $0) }
            #expect(chosen == "All", "All picked: the scope went: \(all)")
            #expect(!Self.barShows(in: window), "All picked: the tab bar came back: \(all)")
        }
    }

    /// The widest gap allowed between the Library icon and the scope control (MEMNG-680). Photos
    /// leaves about 9 pt between the two glasses (28 px at @3x, the owner's references); the frames
    /// read here are the glyph's and the control's, each about 5 pt inside its glass, so Photos'
    /// gap reads about 19 pt, and the bound is that with 5 pt of slack.
    private static let capsuleGapLimit: CGFloat = 24

    /// The capsule hugs the icon and stops short of the trailing edge, as Photos' does, in every
    /// scope (MEMNG-680): after the icon with no overlap and a bounded gap, its end at most 82 % of
    /// the window's width, and no segment's title given less width than its text needs. Every frame
    /// is read in the window's coordinates, and each scope is photographed.
    @Test("the scope capsule hugs the Library icon and ends short of the trailing edge")
    func scopeCapsuleHugsTheIcon() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "precondition: a scroll, no scope")

            let width = window.bounds.width
            for scope in [LibraryScope.years, .months, .all] {
                let live = await ScopeBarProbe.settledControl(in: window) {
                    await chromeSettle(window)
                }
                if let live { ScopeBarProbe.choose(scope, in: live) }
                _ = await controlShowing(scope.label, in: window)
                await chromeSettle(window, turns: 40)

                let seen = ScopeBarProbe.describe(window)
                Self.shoot("scope-capsule-\(scope.label.lowercased())", window)
                let control = ScopeBarProbe.control(in: window)
                let icon = ScopeBarProbe.libraryIconFrame(in: window)
                guard let control, let icon else {
                    Issue.record("\(scope.label): no capsule or no icon drawn: \(seen)")
                    continue
                }
                let chosen = ScopeBarProbe.chosen(in: control)
                #expect(chosen == scope.label, "\(scope.label) picked, \(chosen ?? "-") shows")

                let picker = control.convert(control.bounds, to: window)
                let gap = picker.minX - icon.maxX
                let labels = ScopeBarProbe.segmentLabels(of: control, in: window)
                let measured =
                    "\(scope.label): icon \(icon) of \(ScopeBarProbe.libraryIconFrames(in: window))"
                    + " capsule \(picker) gap \(gap) window \(width)"
                    + " end \(picker.maxX / width) labels \(labels)"
                print("MEMNG-680 measured \(measured)")
                Attachment.record(measured, named: "capsule-\(scope.label.lowercased())")

                #expect(icon.minX < picker.minX, "the capsule before the icon: \(measured)")
                #expect(icon.maxX <= picker.minX, "the capsule over the icon: \(measured)")
                #expect(gap <= Self.capsuleGapLimit, "the capsule left the icon: \(measured)")
                #expect(picker.maxX <= 0.82 * width, "the capsule runs on: \(measured)")
                let shown = Set(labels.map { $0.text })
                #expect(shown == Set(ScopeBarProbe.titles), "titles laid out: \(measured)")
                for label in labels {
                    #expect(label.needs <= label.has + 0.5, "\(label.text) cut: \(measured)")
                }
            }
        }
    }

    /// The Library icon gives the tab bar back where the Library stands, and the bar stays through
    /// the layout its return sets off; the next scroll down swaps them again (MEMNG-679).
    @Test("the icon gives the tab bar back until the next scroll down")
    func iconThenScrollCollapsesAgain() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "precondition: a scroll, no scope")

            let how = ScopeBarProbe.pressLibraryIcon(in: window)
            #expect(how != nil, "no Library icon took a press: \(ScopeBarProbe.describe(window))")
            await tabsStand(window)
            await chromeSettle(window, turns: 60)
            let after = ScopeBarProbe.describe(window)
            let at = Self.scrolledBy(in: window) ?? 0
            #expect(at > 24, "precondition: the icon pressed at \(at), not below the threshold")
            #expect(Self.barShows(in: window), "the icon did not give the bar back: \(after)")
            #expect(ScopeBarProbe.control(in: window) == nil, "the scope came back: \(after)")
            Self.shoot("library-icon", window)

            await scrollFurther(window, by: 200)
            await scopeStands(window)
            let again = ScopeBarProbe.describe(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "a scroll after the icon: \(again)")
            #expect(!Self.barShows(in: window), "a scroll after the icon: the tab bar: \(again)")
        }
    }

    /// A drag the reader starts while the layout is still settling from the icon's press is a
    /// scroll all the same: the bars swap on it, and do not wait for a further one (MEMNG-679).
    @Test("a drag straight after the icon swaps the bars again")
    func dragRightAfterTheIconCollapses() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "precondition: a scroll, no scope")

            let how = ScopeBarProbe.pressLibraryIcon(in: window)
            #expect(how != nil, "no Library icon took a press: \(ScopeBarProbe.describe(window))")
            await chromeSettle(window, turns: 2)
            await drag(window, by: 200)
            await scopeStands(window)
            let after = ScopeBarProbe.describe(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "a drag after the icon: \(after)")
            #expect(!Self.barShows(in: window), "a drag after the icon: the tab bar: \(after)")
        }
    }

    /// A jump the Library makes on its own — a day tile in Months opening All at that day — is a
    /// scroll even when it lands while the layout is still settling from the icon's press: the
    /// bars swap on it (MEMNG-679 round 3).
    @Test("a day's jump straight after the icon swaps the bars again")
    func jumpRightAfterTheIconCollapses() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            let live = await ScopeBarProbe.settledControl(in: window) {
                await chromeSettle(window)
            }
            #expect(live != nil, "precondition: no scope control to pick Months in")
            if let live { ScopeBarProbe.choose(.months, in: live) }
            _ = await controlShowing("Months", in: window)
            var tiles: [NSObject] = []
            for _ in 0..<200 where tiles.isEmpty {
                await chromeSettle(window)
                tiles = Self.elements(labelled: "7", in: window).filter {
                    $0.accessibilityTraits.contains(.button)
                }
            }
            #expect(!tiles.isEmpty, "no tile for the 7th: \(Self.labels(in: window))")

            let how = ScopeBarProbe.pressLibraryIcon(in: window)
            #expect(how != nil, "no Library icon took a press: \(ScopeBarProbe.describe(window))")
            await chromeSettle(window, turns: 2)
            #expect(tiles.contains { $0.accessibilityActivate() }, "no day tile took a press")
            await scopeStands(window)
            let after = ScopeBarProbe.describe(window)
            let at = Self.scrolledBy(in: window) ?? 0
            #expect(at > 24, "precondition: the day's jump landed at \(at)")
            #expect(ScopeBarProbe.control(in: window) != nil, "a jump after the icon: \(after)")
            #expect(!Self.barShows(in: window), "a jump after the icon: the tab bar: \(after)")
        }
    }

    /// A grid too short to scroll has no scroll to swap the bars on: it stays on the tabs whatever
    /// a drag does to it, and the Library's item pressed where it shows is its way to the scope.
    @Test("a grid too short to scroll stays on the tabs; a press on the Library reaches the scope")
    func shortGridStaysOnTheTabs() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library, days: 1...1)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window, pictures: ChromeWire.perDay)
            if let scroller = Self.mainScroll(in: window) {
                let top = -scroller.adjustedContentInset.top
                let inset = scroller.adjustedContentInset.bottom
                let end = max(top, scroller.contentSize.height - scroller.bounds.height + inset)
                #expect(end - top <= 24, "precondition: the grid scrolls \(end - top) points")
                // Pulled past its top and let go, then pushed to its end: all a drag can do.
                for y in [top - 10, top, end, top] {
                    scroller.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                    await chromeSettle(window, turns: 2)
                }
            } else {
                Issue.record("no scroll view on the Library")
            }
            await chromeSettle(window, turns: 40)
            let seen = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "a short grid lost the tab bar: \(seen)")
            #expect(ScopeBarProbe.control(in: window) == nil, "a short grid's scope: \(seen)")

            let control = await pressIntoScope(window)
            let pressed = ScopeBarProbe.describe(window)
            #expect(control != nil, "the Library pressed where it shows: no scope: \(pressed)")
            #expect(!Self.barShows(in: window), "the bar beside the scope: \(pressed)")
        }
    }

    /// The Library left on its scope toolbar at the foot of All — the way a jump to a memo leaves
    /// it — and pressed again from the Timeline comes back on the tabs, its scroll where it was,
    /// and stays on them through the layout of its return: an offset kept is no scroll
    /// (MEMNG-679).
    @Test("the Library left scrolled comes back from the Timeline on the tabs, and stays on them")
    func returnFromTimelineKeepsTheTabs() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "precondition: a scroll, no scope")
            await scrollToFoot(window)
            let left = Self.scrolledBy(in: window) ?? 0

            #expect(ScopeBarProbe.pressTab(.timeline, in: window), "Timeline took no press")
            await tabChosen(.timeline, window)
            await chromeSettle(window, turns: 40)
            #expect(ScopeBarProbe.pressTab(.library, in: window), "Library took no press")
            await tabChosen(.library, window)
            await chromeSettle(window, turns: 80)

            let back = ScopeBarProbe.describe(window)
            let kept = Self.scrolledBy(in: window) ?? 0
            #expect(kept > 24, "precondition: left at \(left), back at \(kept)")
            #expect(Self.barShows(in: window), "back from the Timeline: no tab bar: \(back)")
            #expect(ScopeBarProbe.control(in: window) == nil, "the scope flapped in: \(back)")
            #expect(!ScopeBarProbe.libraryIconShows(in: window), "an icon on return: \(back)")
            Self.shoot("library-return", window)
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
