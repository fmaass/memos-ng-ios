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
/// and a single day is a grid too short to scroll. `mine` is whether the library's pictures are the
/// signed-in account's: false is the household's case, every picture another member's.
private final class ChromeTransport: ClientTransport, @unchecked Sendable {
    private let rows: [String]
    private let dayBuckets: [String]
    private let markers: [String]

    init(days: ClosedRange<Int> = ChromeWire.days, mine: Bool = true) {
        rows = Self.rows(days, mine: mine)
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

    private static func row(day: Int, index: Int, mine: Bool) -> String {
        let uid = uid(day: day, index: index)
        let wide = index.isMultiple(of: 2)
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":\(wide ? 1200 : 800),"height":\(wide ? 800 : 1200),"mine":\(mine),\
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
    private static func rows(_ days: ClosedRange<Int>, mine: Bool) -> [String] {
        days.reversed().flatMap { day in
            (0..<ChromeWire.perDay).reversed().map { row(day: day, index: $0, mine: mine) }
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
    /// With a `witness`, the tabs are `DockWitnessTabs` — `MainTabView`'s tree with each screen
    /// reporting the dock — so the test can ask the dock which bar it says stands.
    private func chromeHost(
        opening tab: MainTab, days: ClosedRange<Int> = ChromeWire.days, mine: Bool = true,
        witness: DockWitness? = nil
    ) async -> UIWindow {
        let transport = ChromeTransport(days: days, mine: mine)
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
        if let witness {
            window.rootViewController = UIHostingController(
                rootView: DockWitnessTabs(opening: tab, witness: witness).environment(session))
        } else {
            window.rootViewController = UIHostingController(
                rootView: MainTabView(opening: tab).environment(session))
        }
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

    /// Drags the main scroll view back up to the top of its content, the inset-adjusted top, and
    /// `past` points beyond it: the reader's scroll back to the top (MEMNG-685), told to the
    /// delegate as a drag, so each move is made while the scroll view moves and nothing was asked.
    private func dragToTop(_ window: UIWindow, past: CGFloat = 0) async {
        guard let scroller = Self.mainScroll(in: window) else { return }
        let top = -scroller.adjustedContentInset.top
        await drag(window, by: top - past - scroller.contentOffset.y)
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
    /// down keeps it, and the icon gives the bar back (MEMNG-604), as a scroll back to the top
    /// does (MEMNG-685).
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

            // MEMNG-684: the same from a grid that scrolled. Scrolled down, the scope stands;
            // Select and Close must bring back the scope, and no two bars may stand at any
            // sampled turn on the way.
            await scrollDown(window)
            await scopeStands(window)
            #expect(Self.scopeShows(in: window), "precondition: the scroll gave the scope")
            Self.shoot("684-scrolled-scope", window)
            let fromScope = await selectThenClose(window, pass: "scrolled-scope")
            #expect(fromScope.last?.scope == true, "Close lost the scope: \(fromScope.last!)")
            #expect(fromScope.last?.tabs == false, "Close brought the tabs: \(fromScope.last!)")

            // At the foot of All the lazy stack measures its rows again on every layout after
            // the bars change, and the offset swings for a second or more (the swing below is
            // that move, made idle): none of it is a scroll. Reached by a drag straight from the
            // scope above, onto the foot the lazy stack estimates; watched for 1.5 s after Close.
            if let scroller = Self.mainScroll(in: window) {
                let inset = scroller.adjustedContentInset.bottom
                let foot = scroller.contentSize.height - scroller.bounds.height + inset
                await drag(window, by: foot - scroller.contentOffset.y)
            }
            await scopeStands(window)
            #expect(ScopeBarProbe.pressLibraryIcon(in: window) != nil, "no icon took a press")
            await tabsStand(window)
            #expect(Self.tabsShow(in: window), "precondition: the icon gave the tabs at the foot")
            Self.shoot("684-foot-tabs", window)
            let atFoot = await selectThenClose(
                window, pass: "foot-tabs", observe: .seconds(1.5), swing: 60)
            let end = atFoot.last!
            #expect(end.tabs, "Close at the foot lost the tabs: \(end)")
            #expect(!end.scope, "Close at the foot drew the scope: \(end)")
            // Every sample from the first layout turn after Close on — through the swing and the
            // 1.5 s after it — shows the tabs alone. The first is read before any turn, while the
            // press has not yet been drawn, and shows Select's toolbar.
            let notTabs = atFoot.enumerated().dropFirst().filter {
                $0.element != BottomBars(tabs: true, scope: false, select: false)
            }
            let first = notTabs.first.map { "\($0)" } ?? "-"
            #expect(
                notTabs.isEmpty,
                "after Close at the foot \(notTabs.count) of \(atFoot.count) not tabs: \(first)")

            // Back up the page, the icon gives the tabs while the grid stands scrolled: Select and
            // Close must bring back the TABS, the bar Select hid there. Reached by a drag, which
            // ends idle as a reader's does (a bare offset jump leaves the scroll phase non-idle,
            // under which every later move counts as a scroll).
            await drag(window, by: -1500)
            await scopeStands(window)
            #expect(ScopeBarProbe.pressLibraryIcon(in: window) != nil, "no icon took a press")
            await tabsStand(window)
            #expect(Self.tabsShow(in: window), "precondition: the icon gave the tabs")
            Self.shoot("684-scrolled-tabs", window)
            let fromTabs = await selectThenClose(window, pass: "scrolled-tabs")
            #expect(fromTabs.last?.tabs == true, "Close lost the tabs: \(fromTabs.last!)")
            #expect(fromTabs.last?.scope == false, "Close drew the scope: \(fromTabs.last!)")
        }
    }

    /// Which of the three bottom bars stand at one instant: the system tab bar, the scope
    /// control, and select mode's toolbar (its Share button).
    private struct BottomBars: Equatable, CustomStringConvertible {
        let tabs: Bool
        let scope: Bool
        let select: Bool

        var description: String { "tabs=\(tabs) scope=\(scope) select=\(select)" }
        /// Two bars at once: the tabs with the scope, or Select's toolbar with either.
        var clash: Bool { (tabs && scope) || (select && (tabs || scope)) }
    }

    private static func bottomBars(in window: UIWindow) -> BottomBars {
        BottomBars(
            tabs: barShows(in: window),
            scope: ScopeBarProbe.control(in: window) != nil,
            select: !elements(labelled: "Share", in: window).isEmpty)
    }

    /// The bottom bars sampled once per settle turn — one layout pass of the window and 25 ms —
    /// starting with a reading taken before the first turn, until the reading has stayed the
    /// same for `steady` turns in a row (at most 300 turns). Exclusivity is proven at these
    /// sample points, not between them.
    private func barsUntilSettled(_ window: UIWindow, steady: Int = 20) async -> [BottomBars] {
        var samples = [Self.bottomBars(in: window)]
        var held = 0
        for _ in 0..<300 where held < steady {
            await chromeSettle(window)
            let now = Self.bottomBars(in: window)
            held = now == samples.last ? held + 1 : 0
            samples.append(now)
        }
        return samples
    }

    /// Select pressed, then Close; photographed at each step. Returns the samples from the Close
    /// on, having checked that no two bars stood together at any of them.
    private func selectThenClose(
        _ window: UIWindow, pass: String, observe: Duration? = nil, swing: CGFloat? = nil
    ) async -> [BottomBars] {
        let before = await barsUntilSettled(window)
        let offsetBefore = Self.scrolledBy(in: window) ?? -1
        let select = Self.elements(labelled: "Select", in: window)
        #expect(select.contains { $0.accessibilityActivate() }, "Select took no press (\(pass))")
        let entering = await barsUntilSettled(window)
        let offsetSelecting = Self.scrolledBy(in: window) ?? -1
        #expect(entering.last?.select == true, "select mode drew no toolbar (\(pass))")
        Self.shoot("684-\(pass)-select", window)
        let close = Self.elements(labelled: "Close", in: window)
        #expect(close.contains { $0.accessibilityActivate() }, "Close took no press (\(pass))")
        let closed = ContinuousClock.now
        var closing = await barsUntilSettled(window)
        Self.shoot("684-\(pass)-closed", window)
        // Observed on for `observe` after the Close, a reading per settle turn as above, the
        // window drawn again at the end: a layout the drawing forces is one the system makes too.
        // With `swing`, the offset is moved by that much 800 ms after the Close, idle — no drag
        // around it — as the lazy stack moved it at the foot in the trace of run-684-10
        // (5379 -> 4954, idle, 797 ms after the release): past the settling window.
        // The swing is checked to be what it models: made while the scroll view neither tracks,
        // drags nor decelerates (the states SwiftUI's scroll phase reads as moving), and still
        // standing a layout turn later, so the dock was handed it as an idle move.
        if let observe {
            var swung = swing == nil
            while ContinuousClock.now < closed.advanced(by: observe) {
                if !swung, ContinuousClock.now >= closed.advanced(by: .milliseconds(800)),
                    let scroller = Self.mainScroll(in: window), let swing
                {
                    let from = scroller.contentOffset.y
                    let still = !scroller.isTracking && !scroller.isDragging
                    #expect(still && !scroller.isDecelerating, "the swing was not idle (\(pass))")
                    scroller.contentOffset.y -= swing
                    swung = true
                    await chromeSettle(window)
                    let moved = from - scroller.contentOffset.y
                    #expect(abs(moved - swing) < 1, "the swing moved \(moved) pt (\(pass))")
                    print("MEMNG684 swing \(pass): \(from) -> \(scroller.contentOffset.y), idle")
                    closing.append(Self.bottomBars(in: window))
                    continue
                }
                await chromeSettle(window)
                closing.append(Self.bottomBars(in: window))
            }
            #expect(swung, "the swing was never made (\(pass))")
            Self.shoot("684-\(pass)-late", window)
            closing.append(contentsOf: await barsUntilSettled(window))
        }
        let offsetClosed = Self.scrolledBy(in: window) ?? -1
        let clashes = closing.enumerated().filter { $0.element.clash }
        let evidence =
            "\(pass): entering \(entering.count) samples, clashes "
            + "\(entering.filter(\.clash).count), last \(entering.last!); closing "
            + "\(closing.count) samples, clashes at \(clashes.map(\.offset)) "
            + "\(clashes.first.map { "\($0.element)" } ?? ""), last \(closing.last!); "
            + "before Select \(before.first!) -> \(before.last!) over \(before.count); "
            + "entering first \(entering.first!), closing first \(closing.first!), "
            + "closing second \(closing.dropFirst().first.map { "\($0)" } ?? "-"); offsets "
            + "\(offsetBefore) / \(offsetSelecting) / \(offsetClosed)"
        print("MEMNG684 bars \(evidence)")
        Attachment.record(evidence, named: "684-\(pass)-bars")
        #expect(clashes.isEmpty, "two bars stood together after Close: \(evidence)")
        return closing
    }

    /// The tile whose centre is nearest `point` among those reading out "Photo" — or, with no
    /// point, the first whole one below the header and above the bottom bars.
    private static func photoTile(near point: CGPoint? = nil, in window: UIWindow) -> NSObject? {
        let tiles = elements(labelled: "Photo", in: window)
        if let point {
            return tiles.min {
                hypot(frame(of: $0).midX - point.x, frame(of: $0).midY - point.y)
                    < hypot(frame(of: $1).midX - point.x, frame(of: $1).midY - point.y)
            }
        }
        let whole = tiles.filter { frame(of: $0).minY > 250 && frame(of: $0).maxY < 650 }
        return whole.min { frame(of: $0).minY < frame(of: $1).minY }
    }

    /// The colour of the window as drawn at `point`, red, green and blue from 0 to 1.
    private static func pixel(at point: CGPoint, in window: UIWindow) -> [Double] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let spot = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        let image = UIGraphicsImageRenderer(bounds: spot, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let drawn = image.cgImage else { return [] }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(drawn, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map { Double($0) / 255 }
    }

    /// MEMNG-684, the owner's first sentence: in select mode a tap on one of my own pictures
    /// chooses it — "1 Item Selected" — and a second tap lets it go again. The fixture's pictures
    /// are all the signed-in account's (`mine`), across twelve day bands.
    ///
    /// The tap goes through the tile's own accessibility activation, which SwiftUI answers with
    /// the tile's button action — the same closure a finger's tap runs (`tapped`), never `toggle`
    /// called from here. Before the fix the tile's tap was a bare `.onTapGesture`, and its
    /// activation answered false and chose nothing (the reproduction, run-684-2). Whether a tile
    /// is dimmed is read from the drawing: the colour at its centre before select mode and in it
    /// (a tile with no row is drawn at 0.4 opacity).
    @Test("in select mode a tap on my picture chooses it, and a second tap lets it go")
    func selectTapChoosesATile() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            guard let first = Self.photoTile(in: window) else {
                Issue.record("no picture on screen: \(Self.labels(in: window))")
                return
            }
            let centre = CGPoint(x: Self.frame(of: first).midX, y: Self.frame(of: first).midY)
            let browsing = Self.pixel(at: centre, in: window)

            let select = Self.elements(labelled: "Select", in: window)
            #expect(select.contains { $0.accessibilityActivate() }, "Select took no press")
            for _ in 0..<200 where Self.elements(labelled: "0 Items Selected", in: window).isEmpty {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            let selecting = Self.pixel(at: centre, in: window)
            let dimmed = zip(browsing, selecting).contains { abs($0 - $1) > 0.08 }
            Self.shoot("684-tap-select", window)

            let tile = Self.photoTile(near: centre, in: window)
            let took = tile?.accessibilityActivate() ?? false
            for _ in 0..<200 where Self.elements(labelled: "1 Item Selected", in: window).isEmpty {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 5)
            let chosen = !Self.elements(labelled: "1 Item Selected", in: window).isEmpty
            let traits = Self.photoTile(near: centre, in: window)?.accessibilityTraits ?? []
            let marked = traits.contains(.selected)
            Self.shoot("684-tap-selected", window)
            let evidence =
                "dimmed=\(dimmed) browsing=\(browsing) selecting=\(selecting) "
                + "tile=\(tile != nil) activated=\(took) oneSelected=\(chosen) "
                + "markedSelected=\(marked) counts="
                + "\(Self.labels(in: window).filter { $0.hasSuffix("Selected") })"
            print("MEMNG684 tap \(evidence)")
            Attachment.record(evidence, named: "684-tap-evidence")
            #expect(!dimmed, "my picture was dimmed in select mode: \(evidence)")
            #expect(chosen, "the tap chose nothing: \(evidence)")
            #expect(marked, "the chosen tile is not marked selected: \(evidence)")

            let again = Self.photoTile(near: centre, in: window)?.accessibilityActivate() ?? false
            for _ in 0..<200 where Self.elements(labelled: "0 Items Selected", in: window).isEmpty {
                await chromeSettle(window)
            }
            #expect(again, "the second tap reached no tile")
            #expect(
                !Self.elements(labelled: "0 Items Selected", in: window).isEmpty,
                "the second tap kept the picture: \(Self.labels(in: window))")

            // Chosen again, then Close: nothing stays chosen and select mode's toolbar goes.
            _ = Self.photoTile(near: centre, in: window)?.accessibilityActivate()
            for _ in 0..<200 where Self.elements(labelled: "1 Item Selected", in: window).isEmpty {
                await chromeSettle(window)
            }
            await closeSelect(window)
            await chromeSettle(window, turns: 20)
            #expect(Self.elements(labelled: "Share", in: window).isEmpty, "Close kept the toolbar")
            Self.shoot("684-tap-closed", window)
        }
    }

    /// MEMNG-684 as the household sees it: most of the pictures in the grid are the other
    /// member's, and a tap on one of THOSE in select mode chooses it too — undimmed, counted and
    /// marked. Share takes the selection; Delete does not, because nothing chosen is mine to
    /// delete. Every picture in this fixture is another member's (`mine: false`), so the tile
    /// tapped is one. The tap and the dimming are read as `selectTapChoosesATile` reads them.
    @Test("in select mode a tap on another member's picture chooses it, and only Share is offered")
    func selectTapChoosesAnothersTile() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library, mine: false)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            guard let first = Self.photoTile(in: window) else {
                Issue.record("no picture on screen: \(Self.labels(in: window))")
                return
            }
            let centre = CGPoint(x: Self.frame(of: first).midX, y: Self.frame(of: first).midY)
            let browsing = Self.pixel(at: centre, in: window)

            let select = Self.elements(labelled: "Select", in: window)
            #expect(select.contains { $0.accessibilityActivate() }, "Select took no press")
            for _ in 0..<200 where Self.elements(labelled: "0 Items Selected", in: window).isEmpty {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            let selecting = Self.pixel(at: centre, in: window)
            let dimmed = zip(browsing, selecting).contains { abs($0 - $1) > 0.08 }

            let took = Self.photoTile(near: centre, in: window)?.accessibilityActivate() ?? false
            for _ in 0..<200 where Self.elements(labelled: "1 Item Selected", in: window).isEmpty {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 5)
            let chosen = !Self.elements(labelled: "1 Item Selected", in: window).isEmpty
            let traits = Self.photoTile(near: centre, in: window)?.accessibilityTraits ?? []
            let marked = traits.contains(.selected)
            let share = Self.elements(labelled: "Share", in: window).first
            let delete = Self.elements(labelled: "Delete", in: window).first
            let shareLive = share.map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
            let deleteLive = delete.map { !$0.accessibilityTraits.contains(.notEnabled) } ?? true
            Self.shoot("684-theirs-selected", window)
            let evidence =
                "dimmed=\(dimmed) browsing=\(browsing) selecting=\(selecting) activated=\(took) "
                + "oneSelected=\(chosen) markedSelected=\(marked) share=\(share != nil) "
                + "shareLive=\(shareLive) delete=\(delete != nil) deleteLive=\(deleteLive)"
            print("MEMNG684 theirs \(evidence)")
            Attachment.record(evidence, named: "684-theirs-evidence")
            #expect(!dimmed, "another member's picture was dimmed in select mode: \(evidence)")
            #expect(chosen, "the tap chose nothing: \(evidence)")
            #expect(marked, "the chosen tile is not marked selected: \(evidence)")
            #expect(shareLive, "Share is not offered for another member's picture: \(evidence)")
            #expect(!deleteLive, "Delete is offered for a picture that is not mine: \(evidence)")

            await closeSelect(window)
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

    /// A scope picked in the scope toolbar keeps it (MEMNG-679, MEMNG-685): the pick swaps the
    /// scroll view for one standing at its top, and that landing — with the collapse of the
    /// scroll view it takes away — is the pick's, not a scroll, so it gives no tabs back there,
    /// though a scroll back to the top would. The guard against scope picks; photographed after
    /// each pick.
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
                Self.shoot("685-pick-\(scope.label.lowercased())", window)
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
            Self.shoot("685-pick-all", window)
        }
    }

    /// The owner's report of 2026-10-03 (MEMNG-685): scrolled down, the Library shows its scope
    /// toolbar; scrolled back to the top, the system tab bar stands again and the scope control is
    /// gone, and stays gone through the layout the swap sets off — the offset the system shifts
    /// after it is no scroll. The way up is a drag told to the scroll view's delegate
    /// (`dragToTop`), so it is judged a scroll for the reason a reader's is: it moves while the
    /// scroll view moves, and nothing was asked.
    @Test("a scroll back to the top gives the tab bar back, and it stays")
    func scrollBackToTheTopGivesTheTabs() async {
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
            let down = ScopeBarProbe.describe(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "scrolled down: no scope: \(down)")
            #expect(!Self.barShows(in: window), "scrolled down: the tab bar stayed: \(down)")
            Self.shoot("685-scrolled", window)

            await dragToTop(window)
            await tabsStand(window)
            let at = Self.scrolledBy(in: window) ?? 1
            #expect(at <= 0, "precondition: the drag ended \(at) points from the top")
            let top = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "back at the top: no tab bar: \(top)")
            #expect(ScopeBarProbe.control(in: window) == nil, "back at the top: a scope: \(top)")
            Self.shoot("685-top", window)

            await chromeSettle(window, turns: 40)
            let settled = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "40 turns on: the tab bar went: \(settled)")
            #expect(ScopeBarProbe.control(in: window) == nil, "40 turns on: \(settled)")
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

    /// A grid too short to scroll has no scroll down to swap the bars on: on the tabs it stays on
    /// them whatever a drag does to it, and the Library's item pressed where it shows is its way to
    /// the scope. From the scope, a drag that pulls it past its top is a scroll reaching the top,
    /// and gives the tabs back (MEMNG-685).
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

            await dragToTop(window, past: 10)
            await tabsStand(window)
            await chromeSettle(window, turns: 40)
            let pulled = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "a pull past the top: no tab bar: \(pulled)")
            #expect(ScopeBarProbe.control(in: window) == nil, "a pull past the top: \(pulled)")
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

    // The owner's device report of 2026-10-04: after Close on the Library's Select, BOTH bottom
    // bars showed — the system tab bar and the scope toolbar with Years | Months | All. The tests
    // above prove the two exclusive only from a settled, idle grid on a Library opened directly;
    // the four below each drive one sequence they never run, and are allowed to fail: a failure
    // is the reproduction.

    /// One sample of the bottom bars after a Close: how long after it, which bars stand, what the
    /// dock says stands on the Library and its mode, the grid's offset, and each bar's own state.
    private struct BarSample: CustomStringConvertible {
        let ms: Int
        let tabs: Bool
        let scope: Bool
        let select: Bool
        let said: DockBar?
        let mode: DockMode?
        let y: CGFloat?
        let tabBar: String
        let scopeBar: String

        /// The owner's report: the system tab bar and the scope toolbar on screen together.
        var clash: Bool { tabs && scope }
        var standing: Int { [tabs, scope, select].filter { $0 }.count }
        var bars: String { "tabs=\(tabs) scope=\(scope) select=\(select)" }

        /// Whether `bar` stands, and nothing beside it.
        func shows(_ bar: DockBar) -> Bool {
            switch bar {
            case .tabs: return tabs && !scope && !select
            case .scope: return scope && !tabs && !select
            case .select: return select && !tabs && !scope
            case .none: return !tabs && !scope && !select
            }
        }

        var description: String {
            let offset = y.map { "\(Int($0))" } ?? "-"
            let dock = "\(said?.rawValue ?? "-")/\(mode?.rawValue ?? "-")"
            return "t=\(ms)ms \(bars) dock=\(dock) y=\(offset) | tabBar \(tabBar)"
                + " | scope \(scopeBar)"
        }
    }

    private static func barSample(
        _ window: UIWindow, _ witness: DockWitness, since start: ContinuousClock.Instant
    ) -> BarSample {
        BarSample(
            ms: Int(((ContinuousClock.now - start) / .milliseconds(1)).rounded()),
            tabs: barShows(in: window),
            scope: ScopeBarProbe.control(in: window) != nil,
            select: !elements(labelled: "Share", in: window).isEmpty,
            said: witness.dock?.bar(on: .library),
            mode: witness.dock?.mode,
            y: scrolledBy(in: window),
            tabBar: DoubleBarProbe.tabBarDetail(in: window),
            scopeBar: DoubleBarProbe.scopeDetail(in: window))
    }

    /// The bars sampled once per settle turn — one layout pass of the window and 25 ms — from
    /// `start` for `span`, the first sample read before any turn. `turn` runs before each layout,
    /// handed the time since `start`: what keeps a scroll view moving, or hands the dock a
    /// reading, while the bars are watched.
    private func sampleBars(
        _ window: UIWindow, _ witness: DockWitness, from start: ContinuousClock.Instant,
        for span: Duration, turn: (Duration) -> Void = { _ in }
    ) async -> [BarSample] {
        var samples = [Self.barSample(window, witness, since: start)]
        while ContinuousClock.now < start.advanced(by: span) {
            turn(ContinuousClock.now - start)
            await chromeSettle(window)
            samples.append(Self.barSample(window, witness, since: start))
        }
        return samples
    }

    /// The verdict on one sequence: at no sample the tab bar and the scope toolbar together, and
    /// at the end one bar alone, the one the dock says stands on the Library. Printed for the gate
    /// log, prefixed `DOUBLEBAR <name>`: a head line, then every sample whose bars or whose dock
    /// changed from the one before and every clash, each with the bars' hidden flag, alpha, the
    /// view that hides them and their frames. Every sample goes to the result bundle.
    private func judgeDoubleBar(
        _ name: String, _ samples: [BarSample], _ witness: DockWitness, in window: UIWindow,
        context: String
    ) {
        let clashes = samples.enumerated().filter { $0.element.clash }
        let last = samples.last!
        let said = witness.dock?.bar(on: .library)
        let head =
            "DOUBLEBAR \(name): \(samples.count) samples over \(last.ms) ms, clashes at "
            + "\(clashes.map(\.offset)); the dock says \(said?.rawValue ?? "nothing"); end "
            + "\(last.bars); \(context)"
        print(head)
        var previous: BarSample?
        for (index, sample) in samples.enumerated() {
            let changed = previous.map { $0.bars != sample.bars || $0.said != sample.said } ?? true
            if changed || sample.clash { print("DOUBLEBAR \(name) #\(index) \(sample)") }
            previous = sample
        }
        let every = samples.enumerated().map { "#\($0.offset) \($0.element)" }
        Attachment.record(([head] + every).joined(separator: "\n"), named: "doublebar-\(name)")
        Self.shoot("doublebar-\(name)-end", window)
        let first = clashes.first.map { "#\($0.offset) \($0.element)" } ?? "-"
        let together =
            "\(name): the tab bar and the scope toolbar together at samples "
            + "\(clashes.map(\.offset)) of \(samples.count); first \(first)"
        #expect(clashes.isEmpty, "\(together)")
        #expect(last.standing == 1, "\(name): \(last.standing) bars stand at the end: \(last)")
        let says = said?.rawValue ?? "nothing"
        #expect(
            said.map { last.shows($0) } == true,
            "\(name): the end shows \(last.bars), the dock says \(says)")
    }

    /// Select pressed, and select mode's toolbar waited for.
    private func enterSelect(_ window: UIWindow, pass: String) async {
        let select = Self.elements(labelled: "Select", in: window)
        #expect(select.contains { $0.accessibilityActivate() }, "Select took no press (\(pass))")
        let entering = await barsUntilSettled(window)
        #expect(entering.last?.select == true, "select mode drew no toolbar (\(pass))")
    }

    /// The header's Close pressed; answers the instant of the press.
    private func pressClose(_ window: UIWindow, pass: String) -> ContinuousClock.Instant {
        let close = Self.elements(labelled: "Close", in: window)
        #expect(close.contains { $0.accessibilityActivate() }, "Close took no press (\(pass))")
        return .now
    }

    /// The main scroll view's reading as `DockFeed` builds one from its scroll geometry, at its
    /// own offset or at `y`.
    private static func dockReading(
        of scroller: UIScrollView, y: Double? = nil
    ) -> DockScrollReading {
        let inset = scroller.adjustedContentInset
        return DockScrollReading(
            y: y ?? Double(scroller.contentOffset.y + inset.top),
            width: Double(scroller.bounds.width),
            height: Double(scroller.bounds.height),
            insetTop: Double(inset.top),
            insetLeading: Double(inset.left),
            insetBottom: Double(inset.bottom),
            insetTrailing: Double(inset.right))
    }

    /// Sequence A: the scope stands on a grid a scroll moved; Select; a fling under select mode;
    /// Close while the fling still moves the grid, so its readings — each made while the scroll
    /// view moves — arrive through the release and after it. Watched 2 s from the press.
    @Test("double bar A: Close while a fling moves the grid, from the scope")
    func doubleBar_A_closeDuringScopeMotion() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await chromeHost(opening: .library, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            let start = ScopeBarProbe.describe(window)
            let dockSays = witness.dock?.bar(on: .library)
            #expect(Self.scopeShows(in: window), "precondition A: no scope: \(start)")
            let said = String(describing: dockSays)
            #expect(dockSays == .scope, "precondition A: the dock says \(said)")
            await enterSelect(window, pass: "A")
            guard let scroller = Self.mainScroll(in: window) else {
                Issue.record("A: no scroll view on the Library")
                return
            }
            // Kept past the threshold, so every reading of the fling says the scope.
            let threshold = CGFloat(DockMode.scopeThreshold)
            let floor = -scroller.adjustedContentInset.top + threshold + 40
            let fling = Fling(scroller, by: 900, floor: floor)
            let before = 8
            for _ in 0..<before {
                fling.step()
                await chromeSettle(window)
            }
            let closed = pressClose(window, pass: "A")
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(2)) { _ in
                fling.step()
            }
            judgeDoubleBar(
                "A", samples, witness, in: window,
                context: "\(fling.summary), \(before) before Close")
        }
    }

    /// Sequence B: the Library at its top on the tabs; Select; a fling down under select mode,
    /// whose readings the dock drops while the claim holds; Close mid-fling, after which the
    /// fling's next readings are past the threshold — the tab bar hidden under Select, shown on
    /// the release, hidden again for the scope. Never two bars in one sample, and one at the end.
    @Test("double bar B: Close while a fling from the top moves the grid, from the tabs")
    func doubleBar_B_closeDuringTabsMotion() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await chromeHost(opening: .library, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            let at = Self.scrolledBy(in: window) ?? 1
            let start = ScopeBarProbe.describe(window)
            let dockSays = witness.dock?.bar(on: .library)
            #expect(Self.tabsShow(in: window), "precondition B: no tabs at the top: \(start)")
            #expect(at <= 0, "precondition B: the grid stands \(at) points from its top")
            let said = String(describing: dockSays)
            #expect(dockSays == .tabs, "precondition B: the dock says \(said)")
            await enterSelect(window, pass: "B")
            guard let scroller = Self.mainScroll(in: window) else {
                Issue.record("B: no scroll view on the Library")
                return
            }
            let fling = Fling(scroller, by: 900)
            let before = 8
            for _ in 0..<before {
                fling.step()
                await chromeSettle(window)
            }
            let closed = pressClose(window, pass: "B")
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(2)) { _ in
                fling.step()
            }
            judgeDoubleBar(
                "B", samples, witness, in: window,
                context: "\(fling.summary), \(before) before Close")
        }
    }

    /// Sequence C: at the foot of All, the tabs given back by the Library icon; Select; Close; and
    /// the first reading after the release comes 600 ms after it — past the 500 ms in which a
    /// release holds a scroll view that lived through it (`DockScrollFence`) — an idle reflow of
    /// 425 points, still past the threshold. The real grid's readings arrive when the layout makes
    /// them, so that late one is handed to the dock through the path `DockFeed` hands it
    /// (`AppDock.scrolled(from:to:judgedBy:moving:at:)`), by a fence of its own that read once
    /// before Select. Watched 3 s from the press.
    @Test("double bar C: at the foot on the tabs, the first reading after Close comes at 600 ms")
    func doubleBar_C_lateFirstReadingAfterRelease() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await chromeHost(opening: .library, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            if let scroller = Self.mainScroll(in: window) {
                let inset = scroller.adjustedContentInset.bottom
                let foot = scroller.contentSize.height - scroller.bounds.height + inset
                await drag(window, by: foot - scroller.contentOffset.y)
            }
            await scopeStands(window)
            #expect(ScopeBarProbe.pressLibraryIcon(in: window) != nil, "C: no icon took a press")
            await tabsStand(window)
            let atFoot = Self.scrolledBy(in: window) ?? 0
            let start = ScopeBarProbe.describe(window)
            #expect(Self.tabsShow(in: window), "precondition C: no tabs at the foot: \(start)")
            #expect(atFoot > 500, "precondition C: the foot stands \(atFoot) from the top")
            guard let dock = witness.dock, let scroller = Self.mainScroll(in: window) else {
                Issue.record("C: no dock witnessed, or no scroll view on the Library")
                return
            }
            #expect(dock.bar(on: .library) == .tabs, "precondition C: \(dock.bar(on: .library))")
            // The late reading's fence reads once now, before Select, so the claim and the release
            // find it already reading, as the grid's own fence is (the witness rule).
            var fence = DockScrollFence()
            let resting = Self.dockReading(of: scroller)
            dock.scrolled(from: resting, to: resting, judgedBy: &fence, moving: false)
            await enterSelect(window, pass: "C")
            let claimed = dock.heldAt
            let closed = pressClose(window, pass: "C")
            var releasedAt: ContinuousClock.Instant?
            var fed = "never"
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(3)) { _ in
                if releasedAt == nil, dock.heldAt != claimed { releasedAt = dock.heldAt }
                guard fed == "never", let release = releasedAt,
                    ContinuousClock.now >= release.advanced(by: .milliseconds(600))
                else { return }
                let now = Self.dockReading(of: scroller)
                let late = Self.dockReading(of: scroller, y: resting.y - 425)
                let modeBefore = dock.mode
                dock.scrolled(from: now, to: late, judgedBy: &fence, moving: false)
                let after = (ContinuousClock.now - release) / .milliseconds(1)
                fed =
                    "at \(Int(after)) ms after the release, idle, y \(Int(now.y)) -> "
                    + "\(Int(late.y)), mode \(modeBefore.rawValue) -> \(dock.mode.rawValue)"
            }
            let released = releasedAt.map { "\(Int(($0 - closed) / .milliseconds(1))) ms" }
            judgeDoubleBar(
                "C", samples, witness, in: window,
                context: "foot at \(Int(atFoot)); release stamped \(released ?? "never") after "
                    + "the press; late reading \(fed)")
        }
    }

    /// Sequence D: the app as it opens, on the Timeline (`MainTabView`'s default); the Timeline
    /// dragged down, which minimises its tab bar on a device
    /// (`tabBarMinimizeBehavior(.onScrollDown)` there) — the simulator does not minimise on these
    /// synthetic drags, so whether it did is logged, not asserted; the Library pressed, scrolled
    /// down to its scope; Select; Close. Watched 2 s from the press. What A, B and C lack is the
    /// Timeline's screen, built before the Library: every built screen states the tab bar's
    /// visibility, and keyed on its own tab the Timeline's said `.automatic` here (MEMNG-684).
    @Test("double bar D: arriving from the Timeline, Select and Close")
    func doubleBar_D_arrivingFromTimeline() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await chromeHost(opening: .timeline, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await tabChosen(.timeline, window)
            await chromeSettle(window, turns: 80)
            // Minimised, the bar draws its selected tab alone: what it draws narrows.
            let wide = DoubleBarProbe.tabBarDrawnWidth(in: window) ?? 0
            var narrow = wide
            for _ in 0..<6 where narrow > wide - 40 {
                await drag(window, by: 200)
                narrow = DoubleBarProbe.tabBarDrawnWidth(in: window) ?? 0
            }
            let timelineBar = DoubleBarProbe.tabBarDetail(in: window)
            print("DOUBLEBAR D timeline tab bar drawn \(wide) -> \(narrow) pt: \(timelineBar)")
            Self.shoot("doublebar-D-timeline", window)
            let minimised = narrow <= wide - 40
            print("DOUBLEBAR D observation: the Timeline's tab bar minimised: \(minimised)")

            #expect(ScopeBarProbe.pressTab(.library, in: window), "D: Library took no press")
            await tabChosen(.library, window)
            for _ in 0..<200 where Self.elements(labelled: "Photo", in: window).isEmpty {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            let arrived = ScopeBarProbe.describe(window)
            #expect(Self.tabsShow(in: window), "precondition D: the Library arrived: \(arrived)")
            await scrollDown(window)
            await scopeStands(window)
            let scrolled = ScopeBarProbe.describe(window)
            #expect(Self.scopeShows(in: window), "precondition D: no scope: \(scrolled)")
            await enterSelect(window, pass: "D")
            let closed = pressClose(window, pass: "D")
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(2))
            let timeline = witness.dock?.bar(on: .timeline).rawValue ?? "nothing"
            let library = witness.dock?.bar(on: .library).rawValue ?? "nothing"
            print("DOUBLEBAR D after Close, dock per tab: timeline \(timeline), library \(library)")
            judgeDoubleBar(
                "D", samples, witness, in: window,
                context: "the Timeline's tab bar drawn \(wide) -> \(narrow) pt before the Library")
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
