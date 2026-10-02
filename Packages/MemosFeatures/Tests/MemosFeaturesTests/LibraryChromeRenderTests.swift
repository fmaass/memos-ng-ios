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

/// The Library's bottom chrome is the system's (MEMNG-604): the tab bar at launch, and after a
/// press on the Library's item the Library's own system toolbar in its place — its icon beside
/// Years | Months | All, a system segmented control that agrees with the Library's scope both
/// ways — until the icon gives the bar back. Hosted in the real `MainTabView` over a
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
            control = ScopeBarProbe.control(in: window)
            if let control, title == nil || ScopeBarProbe.chosen(in: control) == title {
                break
            }
        }
        return control
    }

    /// Waits until the Library has served its first screen of pictures and settled.
    private func libraryServed(_ media: PaintedMedia, _ window: UIWindow) async {
        var waited = 0
        while await media.served < 12, waited < 200 {
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

    /// The Library at launch: the system tab bar and nothing of its scope, and a scroll changes
    /// neither (MEMNG-604) — the scope toolbar is reached by a press, never by a scroll.
    @Test("the Library opens on the system tab bar with no scope, and a scroll changes nothing")
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
            let scrolled = ScopeBarProbe.describe(window)
            #expect(Self.barShows(in: window), "All scrolled: the system tab bar is gone")
            #expect(ScopeBarProbe.control(in: window) == nil, "a scope after a scroll: \(scrolled)")
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
            // The Library pressed from the Timeline and then again where it shows: either press
            // alone gives the scope toolbar, so the pair reaches it whichever one a broken rule
            // lost, and what this test can fail on is the control's binding alone.
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
    /// Library's item pressed from either opens the Library on its scope toolbar; a press back
    /// on the tab left gives that tab its bar (MEMNG-604).
    @Test("Timeline and Places keep the tab bar; the Library pressed from them opens on its scope")
    func otherRootsHaveNoScope() async {
        let media = PaintedMedia(palette: Self.palette())
        await withTransport(media) {
            for tab in [MainTab.timeline, .places] {
                let window = await chromeHost(opening: tab)
                for _ in 0..<200 where Self.tabBar(in: window)?.selectedItem?.title != tab.title {
                    await chromeSettle(window)
                }
                await chromeSettle(window, turns: 80)
                let seen = ScopeBarProbe.describe(window)
                #expect(Self.barShows(in: window), "\(tab.title): no system tab bar")
                #expect(ScopeBarProbe.control(in: window) == nil, "\(tab.title): \(seen)")
                #expect(!ScopeBarProbe.libraryIconShows(in: window), "\(tab.title): \(seen)")
                Self.shoot(tab.rawValue, window)

                let control = await pressIntoScope(window)
                let pressed = ScopeBarProbe.describe(window)
                #expect(control != nil, "the Library from \(tab.title): no scope: \(pressed)")
                #expect(!Self.barShows(in: window), "the Library from \(tab.title): \(pressed)")

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
