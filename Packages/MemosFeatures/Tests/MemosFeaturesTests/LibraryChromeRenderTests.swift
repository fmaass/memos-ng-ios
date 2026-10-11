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
                "hasLegacyPrint":false,"webReady":true,"renditions":[],"position":null,\
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
            "hasPrint":false,"hasLegacyPrint":false,\
            "webReady":true,"renditions":[],"tags":[],"orphan":true,\
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
                "tags":[],"coverThumbnailUrl":"/api/attachments/\(cover)/thumb"}
                """
        }
    }

    private static let years = """
        [{"key":"2026","count":48,"coverUid":"\(uid(day: 12, index: 0))",\
        "tags":[],"coverThumbnailUrl":"/api/attachments/\(uid(day: 12, index: 0))/thumb"},\
        {"key":"2025","count":17,"coverUid":"\(uid(day: 3, index: 1))",\
        "tags":[],"coverThumbnailUrl":"/api/attachments/\(uid(day: 3, index: 1))/thumb"}]
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
        "hasLegacyPrint":false,"webReady":true,"renditions":[],"position":null,\
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
                rootView: DockWitnessTabs(opening: tab, witness: witness)
                    .environment(session))
        } else {
            window.rootViewController = UIHostingController(
                rootView: MainTabView(opening: tab)
                    .environment(session))
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

    /// Whether the tabs stand: the app's capsule, or the capsule folded to its icon — the one bar
    /// since the system style went (MEMNG-690).
    private static func barShows(in window: UIWindow) -> Bool {
        ScopeBarProbe.tabsShow(in: window)
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

    /// Presses the Library's item in the tab bar and waits for the scope toolbar to stand in
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

    /// Waits until the tab bar stands again and no scope is drawn.
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

    /// Waits until the tab bar has `tab` chosen.
    private func tabChosen(_ tab: MainTab, _ window: UIWindow) async {
        for _ in 0..<200 where ScopeBarProbe.selectedTitle(in: window) != tab.title {
            await chromeSettle(window)
        }
    }

    /// The Library at launch: the tab bar and nothing of its scope. A scroll down past the
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
            #expect(Self.barShows(in: window), "the Library at launch: no tab bar")
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

    /// A press on the Library's item swaps the tab bar for the Library's scope toolbar — its
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
            #expect(!Self.barShows(in: window), "the tab bar beside the scope: \(seen)")
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
            let selected = ScopeBarProbe.selectedTitle(in: window)
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
            for _ in 0..<200 where ScopeBarProbe.selectedTitle(in: window) != timeline {
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
            #expect(!Self.barShows(in: window), "the tab bar under select mode: \(seen)")
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
            #expect(!Self.barShows(in: window), "the tab bar stayed under select mode")
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
            // sampled turn on the way. A reader's drag: the idle moves just after a claim lets
            // go are held as the layout's (`AppDock.heldAt`), and fold nothing (MEMNG-690).
            await drag(window, by: 960)
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

    /// Which of the three bottom bars stand at one instant: the tab bar, the scope
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
            tabs: barShows(in: window) || leadingTabsShow(in: window),
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

    /// Timeline and Places stand over the tab bar with nothing of the Library's, and the
    /// Library's item pressed from either opens the Library on the tabs (MEMNG-679): a press from
    /// another tab is the way back to the Library, not into its scope. Pressed again where it
    /// shows, it gives the scope toolbar; a move back to the tab left, the one a jump makes
    /// past a scope row that offers no other tab, gives that tab its bar.
    @Test("Timeline and Places keep the tab bar; the Library pressed from them opens on the tabs")
    func otherRootsHaveNoScope() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            for tab in [MainTab.collections, .timeline, .places] {
                let window = await chromeHost(opening: tab)
                await tabChosen(tab, window)
                await chromeSettle(window, turns: 80)
                let seen = ScopeBarProbe.describe(window)
                #expect(Self.barShows(in: window), "\(tab.title): no tab bar")
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

                #expect(ScopeBarProbe.moveTo(tab, in: window), "\(tab.title) took no move")
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
    /// toolbar; scrolled back to the top, the tab bar stands again and the scope control is
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
            let by = how ?? "nothing"
            #expect(at > 24, "precondition: the icon pressed at \(at), not past 24, by \(by)")
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

            #expect(ScopeBarProbe.moveTo(.timeline, in: window), "Timeline took no move")
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
    // bars showed — the tab bar and the scope toolbar with Years | Months | All. The tests
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

        /// The owner's report: the tab bar and the scope toolbar on screen together.
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
            tabs: barShows(in: window) || leadingTabsShow(in: window),
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
            var modeAfterLate: DockMode?
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(3)) { _ in
                if releasedAt == nil, dock.heldAt != claimed { releasedAt = dock.heldAt }
                guard fed == "never", let release = releasedAt,
                    ContinuousClock.now >= release.advanced(by: .milliseconds(600))
                else { return }
                let now = Self.dockReading(of: scroller)
                let late = Self.dockReading(of: scroller, y: resting.y - 425)
                let modeBefore = dock.mode
                dock.scrolled(from: now, to: late, judgedBy: &fence, moving: false)
                modeAfterLate = dock.mode
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
            // The fence lived through the release, so an idle reflow is the layout's however late
            // it is heard: the tabs the icon gave back stay (MEMNG-703).
            #expect(modeAfterLate == .tabs, "C: the late idle reading moved the dock: \(fed)")
        }
    }

    /// Sequence D: the app as it opens, on the Timeline (`MainTabView`'s default); the Timeline
    /// dragged down, which folds the app's capsule to the Timeline icon (MEMNG-690); the icon
    /// pressed to widen it again, as a person must before reaching another tab; the Library
    /// pressed, scrolled down to its scope; Select; Close. Watched 2 s from the press. What A, B
    /// and C lack is the Timeline's screen, built before the Library: every built screen states the
    /// tab bar's visibility, and keyed on its own tab the Timeline's said `.automatic` here
    /// (MEMNG-684).
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
            // Folded, the capsule draws its selected tab alone: what it draws narrows.
            let wide = ScopeBarProbe.tabsFrame(in: window)?.width ?? 0
            var narrow = wide
            for _ in 0..<6 where narrow > wide - 40 {
                await drag(window, by: 200)
                await chromeSettle(window, turns: 30)
                narrow = ScopeBarProbe.tabsFrame(in: window)?.width ?? 0
            }
            print("DOUBLEBAR D timeline capsule drawn \(wide) -> \(narrow) pt")
            Self.shoot("doublebar-D-timeline", window)
            #expect(
                narrow <= wide - 40, "D: the Timeline's capsule did not fold: \(wide) -> \(narrow)")

            // The folded icon widens the capsule again; then its Library item can be pressed.
            #expect(
                ScopeBarProbe.pressTab(.timeline, in: window), "D: the folded icon took no press")
            for _ in 0..<200 where (ScopeBarProbe.tabsFrame(in: window)?.width ?? 0) < wide - 1 {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 30)
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
            #expect(Self.mainGlass(.scope, in: window) != nil, "precondition D: no app row")
            await enterSelect(window, pass: "D")
            // Since build 39 the scope is the app's row (MEMNG-690): Select's claim takes it away
            // as it took the system toolbar, and Close gives it back while the Library is scrolled.
            let selecting = ScopeBarProbe.describe(window)
            #expect(
                Self.mainGlass(.scope, in: window) == nil, "D: the row under Select: \(selecting)")
            let closed = pressClose(window, pass: "D")
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(2))
            let timeline = witness.dock?.bar(on: .timeline).rawValue ?? "nothing"
            let library = witness.dock?.bar(on: .library).rawValue ?? "nothing"
            print("DOUBLEBAR D after Close, dock per tab: timeline \(timeline), library \(library)")
            judgeDoubleBar(
                "D", samples, witness, in: window,
                context: "the Timeline's capsule drawn \(wide) -> \(narrow) pt before the Library")
            let row = Self.mainGlass(.scope, in: window) != nil
            #expect(
                row == (witness.dock?.bar(on: .library) == .scope),
                "D: the app row \(row ? "stands" : "is absent") where the dock says \(library)")
            #expect(!ScopeBarProbe.systemToolbarShows(in: window), "D: UIKit drew a toolbar")
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

/// The app's own main bar (MEMNG-690) at the leading edge, folding in place
/// on the Timeline's scroll and swapping to the scope row on the Library's, hosted as the tests
/// above host the app and photographed as `shot-690-leading-<n>-…`.
extension MediaImageLoaderTests {
    /// The frame of the leading bar's main glass in `shape`, nil when it is not on screen.
    fileprivate static func mainGlass(
        _ shape: LeadingMainBar.BarShape, in window: UIWindow
    ) -> CGRect? {
        let wanted = LeadingMainBar.identifier(of: shape)
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            // Asked by key, as `SystemTabBarRenderTests` asks the Places root: SwiftUI's
            // accessibility nodes answer the selector without declaring the protocol.
            var identifier: String?
            if object.responds(to: Selector(("accessibilityIdentifier"))) {
                identifier = object.value(forKey: "accessibilityIdentifier") as? String
            }
            if identifier == wanted {
                let frame = Self.frame(of: object)
                if !frame.isEmpty, frame.intersects(window.bounds) { return frame }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// Whether the leading bar's tabs stand, as a capsule or folded to an icon.
    fileprivate static func leadingTabsShow(in window: UIWindow) -> Bool {
        mainGlass(.tabs, in: window) != nil || mainGlass(.folded, in: window) != nil
    }

    /// Waits until the leading bar's main glass stands in `shape`; answers its frame.
    fileprivate func leadingGlass(
        _ shape: LeadingMainBar.BarShape, in window: UIWindow
    ) async -> CGRect? {
        for _ in 0..<200 where Self.mainGlass(shape, in: window) == nil {
            await chromeSettle(window)
        }
        // The morph's own time, so the picture shows where it ends.
        await chromeSettle(window, turns: 30)
        return Self.mainGlass(shape, in: window)
    }

    /// Presses `tab` in the leading bar, the button reading its name in the window's foot.
    fileprivate func pressLeading(_ tab: MainTab, in window: UIWindow) -> Bool {
        let foot = window.bounds.height * 0.8
        let buttons = Self.elements(labelled: tab.title, in: window).filter {
            Self.frame(of: $0).minY >= foot
        }
        return buttons.contains { $0.accessibilityActivate() }
    }

    /// The Timeline, its memos served and settled.
    fileprivate func leadingTimeline(
        _ media: PaintedMedia, witness: DockWitness? = nil
    ) async -> UIWindow {
        let window = await chromeHost(opening: .timeline, witness: witness)
        await libraryServed(media, window, pictures: 1)
        await chromeSettle(window, turns: 40)
        return window
    }

    private func notes(_ name: String, _ lines: [String]) {
        let text = lines.joined(separator: "\n")
        print("LEADING \(name): \(text)")
        Attachment.record(text, named: "notes-\(name)")
    }

    /// (1) The Timeline at rest: the capsule at the leading inset, the system tab bar hidden.
    @Test("leading 1: the Timeline at rest stands the capsule at the leading inset, no tab bar")
    func leadingTimelineAtRest() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let capsule = await leadingGlass(.tabs, in: window)
            Self.shoot("690-leading-1-timeline-rest", window)
            notes("690-leading-1", ["capsule=\(String(describing: capsule))"])
            #expect(!ScopeBarProbe.systemTabBarShows(in: window), "the system tab bar stands")
            let inset = window.safeAreaInsets.left + LeadingMainBar.leadingInset
            let at = String(describing: capsule)
            #expect(abs((capsule?.minX ?? -100) - inset) <= 1, "capsule at \(at)")
            #expect(
                (capsule?.width ?? 0) >= 4 * LeadingMainBar.itemWidth,
                "the capsule holds four tabs: \(at)")
        }
    }

    /// (2) The Timeline scrolled down by the reader: the icon alone, at the capsule's leading x;
    /// (3) scrolled back up, the capsule; folded again and the icon pressed, the capsule.
    @Test("leading 2-3: the Timeline's scroll folds the capsule in place; up or the icon unfolds")
    func leadingTimelineFoldsInPlace() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let rest = await leadingGlass(.tabs, in: window)
            await drag(window, by: 240)
            let folded = await leadingGlass(.folded, in: window)
            Self.shoot("690-leading-2-timeline-folded", window)
            let line =
                "rest=\(String(describing: rest)) folded=\(String(describing: folded))"
                + " scrolledBy=\(String(describing: Self.scrolledBy(in: window)))"
            #expect(folded != nil, "the capsule did not fold: \(line)")
            #expect(abs((folded?.minX ?? -100) - (rest?.minX ?? 100)) <= 1, "x moved: \(line)")
            #expect((folded?.width ?? .infinity) < (rest?.width ?? 0), "not narrower: \(line)")
            #expect(Self.mainGlass(.tabs, in: window) == nil, "capsule beside the icon: \(line)")

            await drag(window, by: -80)
            let back = await leadingGlass(.tabs, in: window)
            Self.shoot("690-leading-3a-timeline-scrolled-up", window)
            #expect(back != nil, "a scroll up left it folded")
            #expect(abs((back?.minX ?? -100) - (rest?.minX ?? 100)) <= 1)

            await drag(window, by: 160)
            let again = await leadingGlass(.folded, in: window)
            #expect(again != nil, "the second scroll down did not fold")
            #expect(pressLeading(.timeline, in: window), "the folded icon took no press")
            let tapped = await leadingGlass(.tabs, in: window)
            Self.shoot("690-leading-3b-timeline-icon-tapped", window)
            #expect(tapped != nil, "the icon's press left it folded")
            #expect(abs((tapped?.width ?? 0) - (rest?.width ?? 1)) <= 1)
            let back3 = "back=\(String(describing: back))"
            notes("690-leading-2-3", [line, back3, "tapped=\(String(describing: tapped))"])
        }
    }

    /// (4) The Library at rest, then scrolled: the scope row stands alone, where today's scope
    /// toolbar stands, and no capsule beside it.
    @Test("leading 4: the Library's scroll swaps the capsule for the scope row, one bar")
    func leadingLibraryScope() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await chromeHost(opening: .library, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            let rest = await leadingGlass(.tabs, in: window)
            Self.shoot("690-leading-4a-library-rest", window)
            #expect(abs((rest?.minX ?? -100) - LeadingMainBar.leadingInset) <= 1)
            await scrollDown(window)
            await scopeStands(window)
            let icon = await leadingGlass(.scope, in: window)
            let start = ContinuousClock.now
            let samples = await sampleBars(window, witness, from: start, for: .seconds(1))
            Self.shoot("690-leading-4b-library-scope", window)
            let control = ScopeBarProbe.control(in: window)
            let segment = control.map { $0.convert($0.bounds, to: window) }
            let glass = "rest=\(String(describing: rest)) icon=\(String(describing: icon))"
            let picker = "segmented=\(String(describing: segment)); system: x 93 y 798.7, 220 x 48"
            notes("690-leading-4", [glass, picker])
            #expect(control != nil, "no scope control")
            #expect(abs((icon?.minX ?? -100) - 28) <= 2, "icon at \(String(describing: icon))")
            #expect(!Self.leadingTabsShow(in: window), "the capsule stands beside the scope")
            judgeDoubleBar(
                "leading-4", samples, witness, in: window, context: "leading, Library scrolled")
        }
    }

    /// (5) Sequence D: the app opened on the Timeline, scrolled so its bar
    /// folds, scrolled back, the Library pressed in the capsule, scrolled to its scope, Select,
    /// Close. Watched 2 s from the press: one bar, the one the dock says.
    @Test("leading 5: arriving from the Timeline, Select and Close leave one bar")
    func leadingDoubleBarD() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await leadingTimeline(media, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await leadingGlass(.tabs, in: window)
            await drag(window, by: 240)
            let folded = await leadingGlass(.folded, in: window)
            #expect(folded != nil, "precondition: the Timeline's bar folded")
            await drag(window, by: -80)
            _ = await leadingGlass(.tabs, in: window)
            #expect(pressLeading(.library, in: window), "the capsule's Library took no press")
            for _ in 0..<200 where Self.elements(labelled: "Photo", in: window).isEmpty {
                await chromeSettle(window)
            }
            await chromeSettle(window, turns: 20)
            #expect(Self.leadingTabsShow(in: window), "precondition: the Library on the capsule")
            await scrollDown(window)
            await scopeStands(window)
            #expect(Self.scopeShows(in: window), "precondition: no scope")
            await enterSelect(window, pass: "leading-D")
            let closed = pressClose(window, pass: "leading-D")
            let samples = await sampleBars(window, witness, from: closed, for: .seconds(2))
            Self.shoot("690-leading-5-select-closed", window)
            judgeDoubleBar(
                "leading-D", samples, witness, in: window,
                context: "leading, the Timeline folded before the Library")
        }
    }
}

extension MediaImageLoaderTests {
    /// One drawn frame of a film: when it was drawn, the capsule's leading edge read from its
    /// pixels (nil when no edge was found), and where the main scroll view stood.
    fileprivate struct FilmFrame {
        let ms: Int
        let edge: CGFloat?
        let y: CGFloat?
        /// The main glass's leading x as the layout places it (`mainGlass`), nil when none stands.
        let glass: CGFloat?
        /// The bar's band read as column brightness (`barSignature`): what a frame between two
        /// shapes is told apart by.
        let bar: [Double]?
    }

    /// The bar's band of `image` — 800 to 845 pt down, inside the 62 pt bar standing 21 pt above
    /// the foot — as the mean brightness of 40 columns across the width.
    fileprivate static func barSignature(of image: UIImage) -> [Double]? {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let scale = image.scale
        let row = cg.bytesPerRow
        let size = cg.bitsPerPixel / 8
        let top = Int(800 * scale)
        let bottom = min(Int(845 * scale), cg.height)
        let columns = 40
        let step = cg.width / columns
        guard top < bottom, step > 0 else { return nil }
        return (0..<columns).map { column in
            var sum = 0
            var count = 0
            for y in stride(from: top, to: bottom, by: 2) {
                for x in stride(from: column * step, to: (column + 1) * step, by: 2) {
                    sum += (0..<min(size, 3)).reduce(0) { $0 + Int(bytes[y * row + x * size + $1]) }
                    count += 1
                }
            }
            return Double(sum) / Double(max(count, 1))
        }
    }

    /// Where the bar's glass starts on a row of `image`: the first pixel from 8 pt in that is
    /// clearly brighter than the screen's edge beside it — the glass's rim, 255 against the
    /// grouped background's ~228 — read on three rows through the bar's middle, the median taken.
    fileprivate static func leadingEdge(of image: UIImage) -> CGFloat? {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return nil }
        let scale = image.scale
        let row = cg.bytesPerRow
        let size = cg.bitsPerPixel / 8
        func level(_ x: Int, _ y: Int) -> Int {
            (0..<min(size, 4)).reduce(0) { $0 + Int(bytes[y * row + x * size + $1]) }
        }
        var found: [CGFloat] = []
        for points in [CGFloat(812), 822, 832] {
            let y = Int(points * scale)
            guard y < cg.height else { continue }
            let near = Array(Int(2 * scale)..<Int(6 * scale))
            let reference = near.map { level($0, y) }.reduce(0, +) / max(near.count, 1)
            let span = Int(8 * scale)..<min(Int(120 * scale), cg.width)
            if let x = span.first(where: { level($0, y) - reference > 30 }) {
                found.append(CGFloat(x) / scale)
            }
        }
        return found.isEmpty ? nil : found.sorted()[found.count / 2]
    }

    /// A drag a film plays: from `start` into the film, the main scroll view moved `distance` over
    /// `span` at an even pace, told to its delegate as one drag that begins and ends around it.
    @MainActor
    fileprivate final class Glide {
        let start: Duration
        let span: Duration
        let distance: CGFloat
        private var from: CGFloat?
        private var ended = false

        init(at start: Duration, by distance: CGFloat, over span: Duration = .milliseconds(250)) {
            self.start = start
            self.distance = distance
            self.span = span
        }

        /// The drag `elapsed` into the film.
        func turn(_ elapsed: Duration, _ scroller: UIScrollView?) {
            guard let scroller, elapsed >= start, !ended else { return }
            if from == nil {
                from = scroller.contentOffset.y
                scroller.delegate?.scrollViewWillBeginDragging?(scroller)
            }
            let done = min((elapsed - start) / span, 1)
            let offset = CGPoint(x: 0, y: (from ?? 0) + distance * CGFloat(done))
            scroller.setContentOffset(offset, animated: false)
            guard done >= 1 else { return }
            ended = true
            var target = scroller.contentOffset
            scroller.delegate?.scrollViewWillEndDragging?(
                scroller, withVelocity: .zero, targetContentOffset: &target)
            scroller.delegate?.scrollViewDidEndDragging?(scroller, willDecelerate: false)
        }
    }

    /// Films the window for `span`: `turn` runs every ~16 ms, handed the time since the film
    /// began — what drags or presses — and the window is drawn at 2x when ~33 ms have passed
    /// since the last frame, each frame attached and read for the leading edge.
    fileprivate func film(
        _ clip: String, _ window: UIWindow, for span: Duration = .milliseconds(1100),
        turn: (Duration) -> Void
    ) async -> [FilmFrame] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let start = ContinuousClock.now
        var drawn: ContinuousClock.Instant?
        var frames: [FilmFrame] = []
        while ContinuousClock.now < start.advanced(by: span) {
            turn(ContinuousClock.now - start)
            if drawn.map({ ContinuousClock.now - $0 >= .milliseconds(33) }) ?? true {
                drawn = ContinuousClock.now
                let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
                let image = renderer.image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let index = String(format: "%03d", frames.count)
                Attachment.record(image, named: "film-\(clip)-\(index)-\(ms)", as: .png)
                let edge = Self.leadingEdge(of: image)
                let glass = [LeadingMainBar.BarShape.tabs, .folded, .scope].lazy
                    .compactMap { Self.mainGlass($0, in: window)?.minX }.first
                frames.append(
                    FilmFrame(
                        ms: ms, edge: edge, y: Self.scrolledBy(in: window), glass: glass,
                        bar: Self.barSignature(of: image)))
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        let lines = frames.map { frame in
            let edge = frame.edge.map { String(format: "%.1f", $0) } ?? "-"
            let y = frame.y.map { String(format: "%.0f", $0) } ?? "-"
            let glass = frame.glass.map { String(format: "%.1f", $0) } ?? "-"
            return "t=\(frame.ms) edge=\(edge) glass=\(glass) y=\(y)"
        }
        print("FILM \(clip): \(frames.count) frames over \(frames.last?.ms ?? 0) ms")
        for line in lines { print("FILM \(clip) \(line)") }
        Attachment.record(lines.joined(separator: "\n"), named: "film-\(clip)-notes")
        return frames
    }

    /// `act` once, the first turn at or past `at`.
    fileprivate static func once(
        at moment: Duration, _ act: @escaping () -> Void
    ) -> (Duration) -> Void {
        var done = false
        return { elapsed in
            guard elapsed >= moment, !done else { return }
            done = true
            act()
        }
    }

    /// The fold's whole ask: the capsule's leading edge, read from the pixels of every frame of
    /// the transition, never moves by more than a point.
    fileprivate func judgeEdge(_ clip: String, _ frames: [FilmFrame]) {
        let edges = frames.compactMap(\.edge)
        let spread = (edges.max() ?? 0) - (edges.min() ?? 0)
        let seen = "\(clip): edges \(edges.map { Int(($0 * 10).rounded()) }) (tenths of a pt)"
        #expect(
            edges.count * 2 >= frames.count, "\(clip): the edge read on too few frames: \(seen)")
        #expect(spread <= 1, "\(clip): the leading edge moved \(spread) pt: \(seen)")
        let inset = LeadingMainBar.leadingInset
        #expect(abs((edges.first ?? -100) - inset) <= 2, "\(clip): not at the inset: \(seen)")
    }

    /// The frames between the clip's first shape and its last: those whose bar band is as far from
    /// both as 15 % of the way between them. A cut has none — every frame is one shape or the
    /// other — which is what the drawn frames of the fold showed while it swapped two glasses.
    fileprivate static func between(_ frames: [FilmFrame]) -> (whole: Double, ms: [Int]) {
        let bars = frames.compactMap { frame in frame.bar.map { (frame.ms, $0) } }
        guard let first = bars.first?.1, let last = bars.last?.1 else { return (0, []) }
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            zip(a, b).map { abs($0 - $1) }.reduce(0, +)
        }
        let whole = distance(first, last)
        let ms = bars.filter {
            distance($0.1, first) > 0.15 * whole && distance($0.1, last) > 0.15 * whole
        }
        .map { $0.0 }
        return (whole, ms)
    }

    /// The fold is a change the eye follows: the clip holds at least one frame between its two
    /// shapes. Judged where nothing else moves under the bar — the icon's press.
    fileprivate func judgeMorph(_ clip: String, _ frames: [FilmFrame]) {
        let (whole, ms) = Self.between(frames)
        print("FILM \(clip) between: whole=\(Int(whole)) frames at \(ms) ms")
        #expect(whole > 30, "\(clip): the bar did not change (\(whole))")
        #expect(!ms.isEmpty, "\(clip): no frame between the two shapes - a cut")
    }

    /// The bar stays at the leading inset as the layout places it, on every frame that has one:
    /// what a clip over the Library's grid or the map is judged by, where no pixel edge reads.
    fileprivate func judgeGlass(_ clip: String, _ frames: [FilmFrame]) {
        let placed = frames.compactMap(\.glass)
        let inset = LeadingMainBar.leadingInset
        let off = placed.filter { abs($0 - inset) > 1 }
        #expect(placed.count * 2 >= frames.count, "\(clip): the glass placed on too few frames")
        #expect(off.isEmpty, "\(clip): the glass placed away from \(inset): \(placed)")
    }

    /// The grid's foot clears the bar: the last row of content ends above the glass.
    fileprivate func footClears(_ glass: CGRect?, _ window: UIWindow, _ name: String) {
        guard let scroller = Self.mainScroll(in: window), let glass else {
            Issue.record("\(name): no scroll view or no glass to measure")
            return
        }
        let drawn = scroller.convert(scroller.bounds, to: window)
        let end = drawn.maxY - scroller.adjustedContentInset.bottom
        #expect(end <= glass.minY + 1, "\(name): the content ends at \(end), the glass at \(glass)")
    }

    /// The scope row's icon gives the capsule back where the grid stands:
    /// the grid is not moved to its top (39's probe: y 960 before the press, 0 after), and the next
    /// scroll down brings the row back (as `iconThenScrollCollapsesAgain`).
    @Test("leading 6: the row's icon gives the capsule back where the grid stands")
    func leadingIconKeepsTheGrid() async {
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
            _ = await leadingGlass(.scope, in: window)
            let before = Self.scrolledBy(in: window) ?? 0
            let how = ScopeBarProbe.pressLibraryIcon(in: window)
            #expect(how != nil, "no icon took a press: \(ScopeBarProbe.describe(window))")
            let capsule = await leadingGlass(.tabs, in: window)
            await chromeSettle(window, turns: 60)
            let after = Self.scrolledBy(in: window) ?? 0
            print(
                "LEADING 690-6: before=\(before) after=\(after) capsule=\(String(describing: capsule))"
            )
            #expect(before > 500, "precondition: the grid scrolled to \(before)")
            #expect(abs(after - before) <= 1, "the icon moved the grid from \(before) to \(after)")
            #expect(capsule != nil, "the icon gave no capsule back")
            #expect(ScopeBarProbe.control(in: window) == nil, "the row stayed")
            await scrollFurther(window, by: 200)
            await scopeStands(window)
            #expect(ScopeBarProbe.control(in: window) != nil, "a scroll after the icon: no row")
        }
    }

    /// The content's foot clears the bar on the Timeline and on the Library, on its scope row and
    /// on its capsule alike (the retired system style's foot was held by `pressSwapsTheBars`).
    @Test("leading 7: the foot of every scrolling root clears the leading bar")
    func leadingFootClears() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await scrollToFoot(window)
            let timeline = Self.mainGlass(.tabs, in: window) ?? Self.mainGlass(.folded, in: window)
            Self.shoot("690-fold-foot-timeline", window)
            footClears(timeline, window, "Timeline")
        }
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            await scrollDown(window)
            await scopeStands(window)
            await scrollToFoot(window)
            let row = await leadingGlass(.scope, in: window)
            Self.shoot("690-fold-foot-library-scope", window)
            footClears(row, window, "Library scope row")
            let atFoot = Self.scrolledBy(in: window) ?? 0
            #expect(ScopeBarProbe.pressLibraryIcon(in: window) != nil, "no icon took a press")
            let capsule = await leadingGlass(.tabs, in: window)
            await chromeSettle(window, turns: 40)
            Self.shoot("690-fold-foot-library-capsule", window)
            footClears(capsule, window, "Library capsule")
            let after = Self.scrolledBy(in: window) ?? 0
            print("LEADING 690-7: foot=\(atFoot) after the icon=\(after)")
            #expect(after > atFoot - 100, "the icon at the foot moved the grid to \(after)")
        }
    }

    /// Clips (a)–(c): the Timeline folds on a drag down, unfolds on a drag up, and unfolds on the
    /// icon's press — the capsule's leading edge read from every frame of each.
    @Test("film a-c: the Timeline's fold and unfold, the leading edge held")
    func filmTimelineFold() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await leadingGlass(.tabs, in: window)
            let down = Glide(at: .milliseconds(100), by: 240)
            let fold = await film("a-timeline-fold", window) {
                down.turn($0, Self.mainScroll(in: window))
            }
            judgeEdge("a", fold)
            judgeGlass("a", fold)
            #expect(Self.mainGlass(.folded, in: window) != nil, "(a) the drag down did not fold")
            let up = Glide(at: .milliseconds(100), by: -80, over: .milliseconds(150))
            let unfold = await film("b-timeline-unfold", window) {
                up.turn($0, Self.mainScroll(in: window))
            }
            judgeEdge("b", unfold)
            judgeGlass("b", unfold)
            #expect(Self.mainGlass(.tabs, in: window) != nil, "(b) the drag up did not unfold")
            await drag(window, by: 200)
            _ = await leadingGlass(.folded, in: window)
            let press = Self.once(at: .milliseconds(100)) {
                _ = self.pressLeading(.timeline, in: window)
            }
            let tap = await film("c-timeline-icon", window, turn: press)
            judgeEdge("c", tap)
            judgeGlass("c", tap)
            judgeMorph("c", tap)
            for (clip, frames) in [("a", fold), ("b", unfold)] {
                let (whole, ms) = Self.between(frames)
                print("FILM \(clip) between (the list moves too): whole=\(Int(whole)) at \(ms) ms")
            }
            #expect(Self.mainGlass(.tabs, in: window) != nil, "(c) the icon did not unfold")
            print("FILM a scroll y: \(fold.compactMap(\.y).map { Int($0) })")
        }
    }

    /// Clips (d)–(e): the Library's capsule morphs into the scope row on a drag down and back on
    /// the icon's press, the grid kept; (f) the capsule's tabs pressed, Timeline, Library, Places.
    @Test("film d-f: the Library's morph and the tabs pressed")
    func filmLibraryAndTabs() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await leadingGlass(.tabs, in: window)
            let library = Self.once(at: .milliseconds(100)) {
                _ = self.pressLeading(.library, in: window)
            }
            let places = Self.once(at: .milliseconds(800)) {
                _ = self.pressLeading(.places, in: window)
            }
            let tabs = await film("f-tabs", window, for: .milliseconds(1600)) {
                library($0)
                places($0)
            }
            judgeGlass("f", tabs)
            _ = pressLeading(.library, in: window)
            await libraryServed(media, window)
            _ = await leadingGlass(.tabs, in: window)
            let down = Glide(at: .milliseconds(100), by: 400, over: .milliseconds(300))
            let scope = await film("d-library-scope", window) {
                down.turn($0, Self.mainScroll(in: window))
            }
            #expect(ScopeBarProbe.control(in: window) != nil, "(d) the drag down drew no row")
            let icon = Self.once(at: .milliseconds(100)) {
                _ = ScopeBarProbe.pressLibraryIcon(in: window)
            }
            let back = await film("e-library-icon", window, turn: icon)
            #expect(Self.mainGlass(.tabs, in: window) != nil, "(e) the icon gave no capsule")
            let kept = back.compactMap(\.y)
            #expect((kept.max() ?? 0) - (kept.min() ?? 0) <= 1, "(e) the grid moved: \(kept)")
            print("FILM d frames=\(scope.count) e frames=\(back.count)")
        }
    }
}
/// The leading bar alone on a plain background, its shape written by the test: the control the
/// recording of the fold is read against (MEMNG-690).
@MainActor
@Observable
private final class BarLabShape {
    var shape: LeadingMainBar.BarShape? = .tabs
    /// The tab drawn as pressed (`leadingBarHeldPress`).
    var held: MainTab?
}

private struct BarLab: View {
    let box: BarLabShape

    var body: some View {
        Color(.systemGroupedBackground)
            .safeAreaBar(edge: .bottom) {
                LeadingMainBar(
                    shape: box.shape, selection: .timeline, press: { _ in },
                    pressLibraryIcon: {}, scope: LibraryScopeChoice())
            }
            .environment(\.leadingBarHeldPress, box.held)
    }
}

/// The system's own tab bar, the reference the pill and the press are matched to (MEMNG-690
/// phase 3): a plain `TabView` over the same tabs, its selection written by the test.
@MainActor
@Observable
private final class SystemTabLabSelection {
    var selection: MainTab = .library
}

private struct SystemTabLab: View {
    @Bindable var box: SystemTabLabSelection

    var body: some View {
        TabView(selection: $box.selection) {
            ForEach(MainTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    Color(.systemGroupedBackground)
                }
            }
        }
    }
}

extension MediaImageLoaderTests {
    /// A light window of the recording's size over `root`, made key.
    fileprivate static func labWindow(_ root: UIViewController) -> UIWindow {
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
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    /// The selection pill's frame on screen, nil when none is drawn.
    /// How many of the main bar's glass markers, in any shape, the window draws on screen.
    fileprivate static func mainBarMarkers(in window: UIWindow) -> Int {
        let wanted = Set(
            [LeadingMainBar.BarShape.tabs, .folded, .scope].map(LeadingMainBar.identifier(of:)))
        var count = 0
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            var identifier: String?
            if object.responds(to: Selector(("accessibilityIdentifier"))) {
                identifier = object.value(forKey: "accessibilityIdentifier") as? String
            }
            if let identifier, wanted.contains(identifier) {
                let frame = Self.frame(of: object)
                if !frame.isEmpty, frame.intersects(window.bounds) { count += 1 }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return count
    }

    fileprivate static func pillFrame(in window: UIWindow) -> CGRect? {
        var stack: [Any] = [window]
        while let node = stack.popLast() {
            guard let object = node as? NSObject, !(object is UITabBar) else { continue }
            if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            var identifier: String?
            if object.responds(to: Selector(("accessibilityIdentifier"))) {
                identifier = object.value(forKey: "accessibilityIdentifier") as? String
            }
            if identifier == LeadingMainBar.pillIdentifier {
                let frame = Self.frame(of: object)
                if !frame.isEmpty, frame.intersects(window.bounds) { return frame }
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// `tab`'s item in the bar at the window's foot, the leftmost if drawn twice.
    fileprivate static func itemFrame(_ tab: MainTab, in window: UIWindow) -> CGRect? {
        let foot = window.bounds.height * 0.8
        return elements(labelled: tab.title, in: window).map { frame(of: $0) }
            .filter { $0.minY >= foot && !$0.isEmpty && $0.intersects(window.bounds) }
            .min { $0.minX < $1.minX }
    }

    /// The bounds of the saturated pixels drawn inside `area` — a selected tab's tinted icon and
    /// title, whatever the tint — in points; nil when there are none.
    fileprivate static func tinted(in area: CGRect, of window: UIWindow) -> CGRect? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: area, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let drawn = image.cgImage else { return nil }
        let width = drawn.width
        let height = drawn.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var box: CGRect?
        for row in 0..<height {
            for column in 0..<width {
                let at = (row * width + column) * 4
                let channels = [bytes[at], bytes[at + 1], bytes[at + 2]].map(Int.init)
                guard let high = channels.max(), let low = channels.min(), high - low > 60 else {
                    continue
                }
                let dot = CGRect(
                    x: CGFloat(column) / 2, y: CGFloat(row) / 2, width: 0.5, height: 0.5)
                box = box.map { $0.union(dot) } ?? dot
            }
        }
        return box
    }

    /// MEMNG-690 phase 3: ONE bar for every tab, laid over the stacks. Through each switch,
    /// sampled every frame while the tab's content changes, the window holds exactly one main-bar
    /// marker — a bar per stack held two while the tabs crossfaded — and the capsule's frame is
    /// 40's on every tab: at the leading inset, its foot `bottomDrop` below the safe area.
    @Test("one bar: a single main-bar marker through every switch, the capsule's frame unmoved")
    func oneBarAcrossTheTabs() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            let first = await leadingGlass(.tabs, in: window)
            let inset = window.safeAreaInsets.left + LeadingMainBar.leadingInset
            let foot =
                window.bounds.height - window.safeAreaInsets.bottom + LeadingMainBar.bottomDrop
            var lines = ["Library: \(String(describing: first)) inset \(inset) foot \(foot)"]
            #expect(abs((first?.minX ?? -100) - inset) <= 1, "\(lines[0])")
            #expect(abs((first?.maxY ?? -100) - foot) <= 1, "\(lines[0])")
            #expect(abs((first?.height ?? 0) - LeadingMainBar.height) <= 1, "\(lines[0])")
            for tab in [MainTab.collections, .timeline, .places, .library] {
                #expect(pressLeading(tab, in: window), "\(tab.title) took no press")
                var counts: [Int] = []
                for _ in 0..<30 {
                    counts.append(Self.mainBarMarkers(in: window))
                    await chromeSettle(window)
                }
                await tabChosen(tab, window)
                let frame = await leadingGlass(.tabs, in: window)
                lines.append("\(tab.title): \(String(describing: frame)) markers \(counts)")
                #expect(counts.allSatisfy { $0 == 1 }, "\(lines.last ?? "")")
                let moved = [
                    (frame?.minX ?? 0) - (first?.minX ?? 0),
                    (frame?.minY ?? 0) - (first?.minY ?? 0),
                    (frame?.width ?? 0) - (first?.width ?? 0),
                    (frame?.height ?? 0) - (first?.height ?? 0),
                ]
                #expect(
                    frame != nil && moved.allSatisfy { abs($0) <= 1 },
                    "the bar moved: \(lines.last ?? "")")
            }
            notes("690-one-bar", lines)
        }
    }

    /// The one bar keeps 40's scroll edge effect: the content under it fades where it faded under
    /// the bar in the stack's own bottom bar (`EdgeLab`, red rows under each), read beside the
    /// capsule's leading edge as the row where the fade, to white or to black, is half done, and
    /// the same row at the window's far side. Hosted as `MainTabs` and a
    /// root host it: the bottom bar of a `TabView` around the stack, a clear room in the stack. An
    /// overlay with a clear room drew no effect at all (quick run 4), with any invisible room one
    /// 32 pt low (quick runs 5-7); the other rooms are printed beside it, for what decides it.
    @Test("one bar 2: the bar around the tabs fades the content under it where 40's bar did")
    func roomKeepsTheEdgeEffect() async {
        var middle: [CGFloat?] = []
        var insets: [CGFloat?] = []
        var lines: [String] = []
        for room in 0...EdgeLab.rooms {
            let window = Self.labWindow(UIHostingController(rootView: EdgeLab(room: room)))
            let reading = await steadyEdge(window)
            let (image, shifts, inset) = (reading.image, reading.shifts, reading.inset)
            Attachment.record(image, named: "edge-lab-\(room)", as: .png)
            middle.append(reading.middle)
            insets.append(inset)
            let sampled = stride(from: 0, to: shifts.count, by: 8).map { shifts[$0] }
            let at = String(describing: middle[room])
            let across = String(describing: reading.across)
            lines.append(
                "\(room): middle \(at) across \(across) inset \(String(describing: inset))"
                    + " \(sampled) after \(reading.turns) turns")
            window.isHidden = true
            window.rootViewController = nil
        }
        notes("690-edge-lab", lines)
        let bar = middle[0]
        #expect(bar != nil, "the bar faded nothing in the lab: \(lines)")
        #expect(middle[EdgeLab.none] == nil, "no bar, and yet a fade: \(lines)")
        let hosted = middle[EdgeLab.production]
        #expect(
            abs((hosted ?? -100) - (bar ?? 100)) <= 3,
            "the fade around the tabs is not the bar's: \(lines)")
        // The room insets the stack's scroll view as the bar in its place did: the TabView's
        // bottom bar alone inset none (quick run 9, 34 pt).
        #expect(
            abs((insets[EdgeLab.production] ?? -100) - (insets[0] ?? 100)) <= 1,
            "the room's inset is not the bar's: \(lines)")
    }

    /// How far the colour of `image` at `x` has moved, on every point row from `from` to `to`, from
    /// its colour on the first: the red, green and blue differences summed. The scroll edge effect
    /// fades the red content toward white in its light style and toward black in its dark one, and
    /// the system picks the style over this red differently run to run (quick run 8's captures:
    /// rooms 0, 2, 4 and 5 dark, R 235 to 173, rooms 3, 6, 7 and 8 light, G 75 to 223); the green
    /// alone saw only the light one, and a dark fade read as none.
    fileprivate static func shifts(of image: UIImage, x: CGFloat, from: Int, to: Int) -> [Int] {
        guard let cg = image.cgImage else { return [] }
        let (width, height) = (cg.width, cg.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            // RGBA in this order whatever the image's own layout, row 0 at the top.
            guard
                let context = CGContext(
                    data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        let column = Int(x * image.scale)
        let colours: [[Int]] = (from...to).compactMap { row in
            let line = Int(CGFloat(row) * image.scale)
            guard line < height, column < width else { return nil }
            let at = (line * width + column) * 4
            return (0..<3).map { Int(pixels[at + $0]) }
        }
        guard let base = colours.first else { return [] }
        return colours.map { colour in (0..<3).reduce(0) { $0 + abs(colour[$1] - base[$1]) } }
    }

    /// The first row, from `from` down, where `shifts` has come half way to its largest; nil when
    /// it never moves by more than 20.
    fileprivate static func fadeMiddle(_ shifts: [Int], from: Int) -> CGFloat? {
        guard let top = shifts.max(), top > 20 else { return nil }
        return shifts.firstIndex { $0 * 2 >= top }.map { CGFloat(from + $0) }
    }

    /// One drawing of the edge lab's window, read as `roomKeepsTheEdgeEffect` reads it, and the
    /// settle turns it took to reach.
    private struct EdgeReading {
        let image: UIImage
        let shifts: [Int]
        let middle: CGFloat?
        /// The middle read at the window's far side, clear of every bar the lab draws.
        let across: CGFloat?
        let inset: CGFloat?
        let turns: Int
    }

    /// Drawn turn by turn until the fade and the inset read alike 6 drawings running with a fade
    /// drawn, or 6 s: a run's first window is cold and the system's scroll edge effect gives no
    /// signal that it is drawn, so a still nil is no proof of settled (a fadeless room waits).
    private func steadyEdge(_ window: UIWindow) async -> EdgeReading {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        await chromeSettle(window, turns: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        var turns = 40
        var last: EdgeReading?
        var alike = 0
        while true {
            await chromeSettle(window, turns: 1)
            turns += 1
            let image = renderer.image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let shifts = Self.shifts(of: image, x: 10, from: 700, to: 872)
            let far = Self.shifts(of: image, x: 395, from: 700, to: 872)
            let near = Self.fadeMiddle(shifts, from: 700)
            let across = Self.fadeMiddle(far, from: 700)
            // The edge effect fades the whole width alike (run 8: 789 at 10, 788 at 395); a change
            // beside the capsule alone, its shadow say, is no fade.
            let spans = near.flatMap { at in across.map { abs($0 - at) <= 2 } } == true
            let reading = EdgeReading(
                image: image, shifts: shifts, middle: spans ? near : nil, across: across,
                inset: Self.mainScroll(in: window)?.adjustedContentInset.bottom, turns: turns)
            let same = last.map { $0.middle == reading.middle && $0.inset == reading.inset }
            alike = same == true ? alike + 1 : 1
            last = reading
            if (alike >= 6 && reading.middle != nil) || ContinuousClock.now >= deadline {
                return reading
            }
        }
    }

    /// MEMNG-690 phase 3, the owner on 40: the main bar's bubble. The pill stands under the
    /// selected tab, and a press on another tab slides it there from the tab left — on the
    /// tab's first visit too, Timeline and Places here — and the scope row draws none.
    @Test("bubble 1: the selection pill stands under the tab pressed, and none on the scope row")
    func pillFollowsThePress() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            _ = await leadingGlass(.tabs, in: window)
            var lines: [String] = []
            for tab in [MainTab.library, .collections, .timeline, .places, .library] {
                if tab != .library || !lines.isEmpty {
                    #expect(pressLeading(tab, in: window), "\(tab.title) took no press")
                    await tabChosen(tab, window)
                }
                var seen: [Int] = []
                for _ in 0..<40 {
                    if let x = Self.pillFrame(in: window)?.midX { seen.append(Int(x)) }
                    await chromeSettle(window)
                }
                let pill = Self.pillFrame(in: window)
                let item = Self.itemFrame(tab, in: window)
                let drawn = "item \(String(describing: item)) pill \(String(describing: pill))"
                lines.append("\(tab.title): \(drawn) seen \(seen)")
                #expect(
                    abs((pill?.midX ?? -100) - (item?.midX ?? 100)) <= 2,
                    "\(tab.title): the pill not under the tab: \(lines.last ?? "")")
                #expect(
                    abs((pill?.width ?? 0) - LeadingMainBar.pillWidth) <= 1,
                    "\(tab.title): \(lines.last ?? "")")
                // Pressed from another tab, the pill was seen on its way: away from the tab
                // pressed by more than half a tab at some sample.
                if !seen.isEmpty, tab != .library || lines.count > 1 {
                    let home = Int(item?.midX ?? 0)
                    #expect(
                        seen.contains { abs($0 - home) > 40 },
                        "\(tab.title): the pill did not travel: \(lines.last ?? "")")
                }
            }
            let control = await pressIntoScope(window)
            #expect(control != nil, "no scope row")
            #expect(Self.pillFrame(in: window) == nil, "a pill on the scope row")
            notes("690-bubble-1", lines)
        }
    }

    /// The fold keeps the look 40 shipped: the folded icon has no pill, and the unfold brings it
    /// back under the Timeline.
    @Test("bubble 2: the folded capsule draws no pill; unfolded, the pill is back")
    func foldDrawsNoPill() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await leadingGlass(.tabs, in: window)
            #expect(Self.pillFrame(in: window) != nil, "no pill at rest")
            await drag(window, by: 240)
            #expect(await leadingGlass(.folded, in: window) != nil, "the drag did not fold")
            #expect(Self.pillFrame(in: window) == nil, "a pill on the folded icon")
            await drag(window, by: -80)
            _ = await leadingGlass(.tabs, in: window)
            let pill = Self.pillFrame(in: window)
            let item = Self.itemFrame(.timeline, in: window)
            #expect(
                abs((pill?.midX ?? -100) - (item?.midX ?? 100)) <= 2,
                "unfolded: pill \(String(describing: pill)) item \(String(describing: item))")
        }
    }

    /// A press swells the tab under it and the release lets it go, read from the drawing: the
    /// selected tab's tinted icon and title grow by the press's scale while it is held.
    @Test("bubble 3: a held press swells the tab under it, and the release lets it go")
    func pressSwellsTheTab() async {
        let box = BarLabShape()
        let window = Self.labWindow(UIHostingController(rootView: BarLab(box: box)))
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        await chromeSettle(window, turns: 20)
        guard let item = Self.itemFrame(.timeline, in: window) else {
            Issue.record("no Timeline item in the bar")
            return
        }
        let area = item.insetBy(dx: -12, dy: -12)
        let rest = Self.tinted(in: area, of: window)
        box.held = .timeline
        try? await Task.sleep(for: .milliseconds(700))
        await chromeSettle(window, turns: 4)
        let pressed = Self.tinted(in: area, of: window)
        box.held = nil
        try? await Task.sleep(for: .milliseconds(700))
        await chromeSettle(window, turns: 4)
        let back = Self.tinted(in: area, of: window)
        let seen = [rest, pressed, back].map { String(describing: $0) }
        notes("690-bubble-3", ["item \(item)", "rest/pressed/back \(seen)"])
        let restHeight = rest?.height ?? 0
        #expect(restHeight > 10, "no tinted tab drawn: \(seen)")
        #expect((pressed?.height ?? 0) >= restHeight * 1.06, "the press did not swell: \(seen)")
        #expect(abs((back?.height ?? 0) - restHeight) <= 1, "the release kept it: \(seen)")
    }
}

/// MEMNG-702: a press on the main bar while a tab comes back or the pill slides. Run 7 of the
/// MEMNG-690 recordings saw the capsule fold again on a scrolled Timeline shown again, and the
/// next press found its tab gone; and a second press inside one pill slide retargets the spring.
extension MediaImageLoaderTests {
    /// One sample of the bar while presses land: the dock's mode and tab, the tab the tab view has
    /// chosen, which glass stands and how far the main scroll view stands from its top.
    private static func refoldSample(
        _ window: UIWindow, _ witness: DockWitness, at ms: Int
    ) -> String {
        let glass = [LeadingMainBar.BarShape.tabs, .folded, .scope]
            .filter { mainGlass($0, in: window) != nil }
        let mode = witness.dock?.mode.rawValue ?? "-"
        let showing = witness.dock?.showing?.rawValue ?? "-"
        let chosen = ScopeBarProbe.selectedTitle(in: window) ?? "-"
        let y = scrolledBy(in: window).map { "\(Int($0))" } ?? "-"
        return "t=\(ms) mode=\(mode) showing=\(showing) chosen=\(chosen) glass=\(glass) y=\(y)"
    }

    /// The Timeline scrolled down and folded, the icon pressed so the capsule stands again over a
    /// list still scrolled; then, at the recording's pace (`play`: 8 ms turns, nothing drawn or
    /// laid out by the test), Places at 300 ms, the Timeline at 900 and the Library at 1500 —
    /// 600 ms after the Timeline's return, as run 7 pressed them. Nobody scrolls the Timeline
    /// after it comes back, so nothing may fold it, and the Library's press must reach the Library.
    @Test("refold 1: a scrolled Timeline shown again keeps the capsule; a press 600 ms on lands")
    func returnedTimelineKeepsTheCapsule() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let witness = DockWitness()
            let window = await leadingTimeline(media, witness: witness)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await leadingGlass(.tabs, in: window)
            await drag(window, by: 200)
            #expect(await leadingGlass(.folded, in: window) != nil, "precondition: no fold")
            #expect(pressLeading(.timeline, in: window), "the folded icon took no press")
            #expect(await leadingGlass(.tabs, in: window) != nil, "the icon left it folded")
            await chromeSettle(window, turns: 20)
            let presses: [(MainTab, Int)] = [(.places, 300), (.timeline, 900), (.library, 1500)]
            var pressed: [MainTab: Int] = [:]
            var took: [String] = []
            var modes: [String] = []
            var foldedOnReturn: [Int] = []
            let start = ContinuousClock.now
            while ContinuousClock.now < start.advanced(by: .milliseconds(2100)) {
                let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
                for (tab, at) in presses where ms >= at && pressed[tab] == nil {
                    pressed[tab] = ms
                    let landed = pressLeading(tab, in: window)
                    took.append("\(tab.title)@\(ms)=\(landed)")
                }
                let showing = witness.dock?.showing?.rawValue ?? "-"
                let mode = "\(witness.dock?.mode.rawValue ?? "-")/\(showing)"
                if modes.last.map({ !$0.hasSuffix(" \(mode)") }) ?? true {
                    modes.append("t=\(ms) \(mode)")
                }
                let returned = pressed[.timeline] != nil && pressed[.library] == nil
                if returned, witness.dock?.mode == .folded { foldedOnReturn.append(ms) }
                try? await Task.sleep(for: .milliseconds(8))
            }
            await tabChosen(.library, window)
            let end = Self.refoldSample(window, witness, at: 2100)
            let lines = ["presses \(took)", "end \(end)"] + modes
            for line in lines { print("REFOLD702 \(line)") }
            notes("702-refold-1", lines)
            #expect(took.allSatisfy { $0.hasSuffix("=true") }, "a press hit nothing: \(took)")
            #expect(foldedOnReturn.isEmpty, "folded on the return at \(foldedOnReturn) ms")
            #expect(witness.dock?.showing == .library, "the dock is not on the Library: \(took)")
            #expect(
                ScopeBarProbe.selectedTitle(in: window) == MainTab.library.title,
                "the Library was not chosen: \(took) \(end)")
        }
    }

    /// Two presses inside one slide of the selection pill: Places from the Library, two tabs
    /// along, and the Timeline between them as soon as the pill is seen on its way. The spring is
    /// retargeted, and the pill ends under the Timeline, the last tab pressed.
    @Test("refold 2: a second press inside one pill slide ends the pill under the last tab")
    func pillRetargetsOnASecondPress() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await chromeHost(opening: .library)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            await libraryServed(media, window)
            _ = await leadingGlass(.tabs, in: window)
            await chromeSettle(window, turns: 20)
            let from = Self.itemFrame(.library, in: window)?.midX ?? -1
            let first = Self.itemFrame(.places, in: window)?.midX ?? -1
            // Strictly between the two ends of the first slide, clear of both by more than 2 pt.
            let inside = { (x: CGFloat) in
                x > min(from, first) + 2 && x < max(from, first) - 2
            }
            // The second press as soon as the pill has left the Library, inside its slide. A
            // settle turn's sleep is a minimum: on a loaded simulator one can wake after the
            // whole slide, and the press would come after it. So a missed window is set up again
            // from the Library, at most three times, and the last miss is the failure below.
            var between: CGFloat?
            var attempts = 0
            while attempts < 3 {
                attempts += 1
                if attempts > 1 {
                    #expect(pressLeading(.library, in: window), "the Library took no press")
                    for _ in 0..<80 {
                        if let x = Self.pillFrame(in: window)?.midX, abs(x - from) <= 2 { break }
                        await chromeSettle(window)
                    }
                    await chromeSettle(window, turns: 20)
                }
                #expect(pressLeading(.places, in: window), "Places took no press")
                between = Self.pillFrame(in: window)?.midX
                for _ in 0..<40 where between.map({ abs($0 - from) <= 2 }) ?? true {
                    await chromeSettle(window)
                    between = Self.pillFrame(in: window)?.midX
                }
                if between.map(inside) ?? false { break }
            }
            #expect(pressLeading(.timeline, in: window), "the Timeline took no press")
            var seen: [Int] = []
            for _ in 0..<40 {
                if let x = Self.pillFrame(in: window)?.midX { seen.append(Int(x)) }
                await chromeSettle(window)
            }
            await tabChosen(.timeline, window)
            let pill = Self.pillFrame(in: window)
            let item = Self.itemFrame(.timeline, in: window)
            let line =
                "library \(Int(from)) places \(Int(first)) attempts \(attempts) at the second press "
                + "\(String(describing: between)) pill \(String(describing: pill)) "
                + "timeline \(String(describing: item)) seen \(seen)"
            print("REFOLD702 pill \(line)")
            notes("702-refold-2", [line])
            // The second press came while the pill moved: away from both ends of the first slide.
            #expect(
                between.map(inside) ?? false,
                "the second press did not land inside the slide: \(line)")
            #expect(
                abs((pill?.midX ?? -100) - (item?.midX ?? 100)) <= 2,
                "the pill did not end under the Timeline: \(line)")
            #expect(
                ScopeBarProbe.selectedTitle(in: window) == MainTab.timeline.title,
                "the Timeline was not chosen: \(line)")
        }
    }
}

extension MediaImageLoaderTests {
    /// Runs `turn` for `span` and draws nothing, so the main thread stays free for the animation
    /// the simulator's own screen recording sees — a frame drawn in the test blocks it for tens of
    /// milliseconds, and the glass's morph is drawn outside the app, where no drawn frame reaches.
    /// Answers the segment's wall-clock bounds, by which the recording is cut.
    fileprivate func play(
        _ clip: String, for span: Duration = .milliseconds(1500), turn: (Duration) -> Void
    ) async -> String {
        let begun = Date().timeIntervalSince1970
        let start = ContinuousClock.now
        while ContinuousClock.now < start.advanced(by: span) {
            turn(ContinuousClock.now - start)
            try? await Task.sleep(for: .milliseconds(8))
        }
        let line = "REC \(clip) \(begun) \(Date().timeIntervalSince1970)"
        print(line)
        return line
    }

    /// The host app's temporary directory, where the recorder outside the simulator looks.
    private static func recordingFile(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    /// The clips (a)–(e) as the simulator's screen shows them, for a recording made outside the
    /// app (`simctl io recordVideo`), plus the bar alone as the control: the transitions played
    /// with nothing drawn, each segment's wall-clock bounds written where the recorder reads them.
    @Test("record a-e: the fold and the morph as the simulator's screen shows them")
    func recordFold() async {
        var marks: [String] = []
        // The recorder starts on this file and answers with `rec690-recording`, so a run of the
        // whole bundle records this test alone.
        try? "ready".write(
            to: Self.recordingFile("rec690-ready"), atomically: true, encoding: .utf8)
        var waited = 0
        while !FileManager.default.fileExists(atPath: Self.recordingFile("rec690-recording").path),
            waited < 90_000
        {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 250
        }
        print("REC recorder waited \(waited) ms")
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            let window = await leadingTimeline(media)
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            _ = await leadingGlass(.tabs, in: window)
            let atRest = Self.mainScroll(in: window)?.adjustedContentInset.bottom
            let down = Glide(at: .milliseconds(400), by: 240)
            marks.append(
                await play("a-timeline-fold") { down.turn($0, Self.mainScroll(in: window)) })
            #expect(Self.mainGlass(.folded, in: window) != nil, "(a) the drag down did not fold")
            // The list is not reframed by the fold: the bar is one height in every shape.
            let folded = Self.mainScroll(in: window)?.adjustedContentInset.bottom
            print("REC a inset \(String(describing: atRest)) -> \(String(describing: folded))")
            #expect(atRest != nil && atRest == folded, "(a) the fold moved the list's foot")
            let up = Glide(at: .milliseconds(400), by: -80, over: .milliseconds(150))
            marks.append(
                await play("b-timeline-unfold") { up.turn($0, Self.mainScroll(in: window)) })
            #expect(Self.mainGlass(.tabs, in: window) != nil, "(b) the drag up did not unfold")
            await drag(window, by: 200)
            _ = await leadingGlass(.folded, in: window)
            let press = Self.once(at: .milliseconds(400)) {
                _ = self.pressLeading(.timeline, in: window)
            }
            marks.append(await play("c-timeline-icon", turn: press))
            #expect(Self.mainGlass(.tabs, in: window) != nil, "(c) the icon did not unfold")
            _ = pressLeading(.library, in: window)
            await libraryServed(media, window)
            _ = await leadingGlass(.tabs, in: window)
            let scroll = Glide(at: .milliseconds(400), by: 400, over: .milliseconds(300))
            marks.append(
                await play("d-library-scope") { scroll.turn($0, Self.mainScroll(in: window)) })
            #expect(ScopeBarProbe.control(in: window) != nil, "(d) the drag down drew no row")
            let icon = Self.once(at: .milliseconds(400)) {
                _ = ScopeBarProbe.pressLibraryIcon(in: window)
            }
            marks.append(await play("e-library-icon", turn: icon))
            #expect(Self.mainGlass(.tabs, in: window) != nil, "(e) the icon gave no capsule")
            // (g) MEMNG-690 phase 3: the pill's travel, Library -> Timeline -> Places -> Library.
            await chromeSettle(window, turns: 20)
            let plan: [(MainTab, Int)] = [(.timeline, 300), (.places, 1100), (.library, 1900)]
            let taps = plan.map { tap in
                Self.once(at: .milliseconds(tap.1)) { _ = self.pressLeading(tap.0, in: window) }
            }
            marks.append(
                await play("g-pill-travel", for: .milliseconds(2700)) { at in
                    for tap in taps { tap(at) }
                })
            #expect(Self.pillFrame(in: window) != nil, "(g) no pill after the taps")
            // (f2) Tab switches over three different screens: the bar is one view over them all,
            // so it neither fades with the tab's content nor flickers.
            await chromeSettle(window, turns: 20)
            let switches: [(MainTab, Int)] = [(.places, 300), (.timeline, 900), (.library, 1500)]
            let presses = switches.map { tap in
                Self.once(at: .milliseconds(tap.1)) { _ = self.pressLeading(tap.0, in: window) }
            }
            marks.append(
                await play("f2-tab-switches", for: .milliseconds(2100)) { at in
                    for press in presses { press(at) }
                })
            #expect(Self.mainBarMarkers(in: window) == 1, "(f2) not one bar after the switches")
        }
        let box = BarLabShape()
        let window = Self.labWindow(UIHostingController(rootView: BarLab(box: box)))
        await chromeSettle(window, turns: 20)
        let fold = Self.once(at: .milliseconds(400)) { box.shape = .folded }
        let unfold = Self.once(at: .milliseconds(1100)) { box.shape = .tabs }
        marks.append(
            await play("lab-bar-alone", for: .milliseconds(1900)) {
                fold($0)
                unfold($0)
            })
        #expect(Self.mainGlass(.tabs, in: window) != nil, "(lab) the bar did not come back")
        // (h) A press held with no finger — the recording has no touch to give — on the selected
        // tab, then on another.
        let holds = [
            Self.once(at: .milliseconds(400)) { box.held = .timeline },
            Self.once(at: .milliseconds(1300)) { box.held = nil },
            Self.once(at: .milliseconds(1800)) { box.held = .places },
            Self.once(at: .milliseconds(2700)) { box.held = nil },
        ]
        marks.append(
            await play("h-press-bulge", for: .milliseconds(3300)) { at in
                for hold in holds { hold(at) }
            })
        window.isHidden = true
        window.rootViewController = nil
        // The reference: the system's own tab bar, a plain TabView, its selection moved by the
        // test as a tap moves it.
        let system = SystemTabLabSelection()
        let reference = Self.labWindow(UIHostingController(rootView: SystemTabLab(box: system)))
        await chromeSettle(reference, turns: 40)
        let steps: [(MainTab, Int)] = [(.timeline, 400), (.places, 1200), (.library, 2000)]
        let moves = steps.map { move in
            Self.once(at: .milliseconds(move.1)) { system.selection = move.0 }
        }
        marks.append(
            await play("s-system-tabs", for: .milliseconds(2800)) { at in
                for move in moves { move(at) }
            })
        reference.isHidden = true
        reference.rootViewController = nil
        try? marks.joined(separator: "\n").write(
            to: Self.recordingFile("rec690-done"), atomically: true, encoding: .utf8)
        // The recorder stops on that file; the device must outlive the stop.
        try? await Task.sleep(for: .seconds(3))
    }
}

/// A stack's root with bright red rows under its bottom bar, the bar one of several: 0 the main
/// bar as 40 drew it there, 1 a clear room, 2 the main bar in the bottom bar of a `TabView` around
/// the stack with `LeadingMainBar.room` in the stack, as `MainTabs` and a root host them, 3 a
/// fill of the bar's height alone (quick run 5's room), 4 the bar folded, 5 the scope row, 6 a
/// glass no eye can see alone, 7 the bar no eye can see, 8 the tab labels no eye can see, 9 no
/// bottom bar at all.
private struct EdgeLab: View {
    static let rooms = 9
    static let production = 2
    static let none = 9
    let room: Int

    var body: some View {
        if room == Self.production {
            TabView {
                Tab("Timeline", systemImage: MainTab.timeline.symbol) {
                    stack { LeadingMainBar.room }.toolbarVisibility(.hidden, for: .tabBar)
                }
            }
            .tabBarMinimizeBehavior(.never)
            .safeAreaBar(edge: .bottom) { bar(.tabs) }
        } else {
            stack { bottom }
        }
    }

    private func stack(@ViewBuilder room: () -> some View) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<40, id: \.self) { _ in Color.red.frame(height: 60) }
                }
            }
            .safeAreaBar(edge: .bottom, content: room)
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder private var bottom: some View {
        switch room {
        case 0: bar(.tabs)
        case 1: Color.clear.frame(height: LeadingMainBar.height)
        case 3: Color.white.opacity(0.001).frame(height: LeadingMainBar.height)
        case 4: bar(.folded)
        case 5: bar(.scope)
        case 6:
            Color.clear.frame(width: 62, height: 62).glassEffect(.regular, in: .capsule)
                .opacity(0.001)
                .frame(maxWidth: .infinity, alignment: .leading)
        case 7: bar(.tabs).opacity(0.001)
        case 8:
            HStack { ForEach(MainTab.allCases) { Text($0.title) } }
                .frame(height: LeadingMainBar.height)
                .opacity(0.001)
        default: EmptyView()
        }
    }

    private func bar(_ shape: LeadingMainBar.BarShape) -> some View {
        LeadingMainBar(
            shape: shape, selection: .timeline, press: { _ in }, pressLibraryIcon: {},
            scope: LibraryScopeChoice())
    }
}
