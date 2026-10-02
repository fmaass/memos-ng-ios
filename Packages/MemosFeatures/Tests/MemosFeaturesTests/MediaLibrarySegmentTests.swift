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
private enum SegmentWire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
    nonisolated static let listAttachments = "list_attachments_api_attachments_get"
    nonisolated static let attachmentTags = "attachment_tags_api_attachments_tags_get"
    nonisolated static let buckets = "attachment_buckets_api_attachments_buckets_get"
    nonisolated static let outgoing = "fabian"
    nonisolated static let incoming = "someone-else"
    /// What every cover of the outgoing account is named after, so a picture request can be told
    /// apart as a cover of THEIRS.
    nonisolated static let coverPrefix = "outgoing-cover-"
}

/// A server for the Library's Years view: one account's year buckets — one of them with a cover
/// that does not resolve — and, once the subject is swapped, every list and bucket read held until
/// the test lets it go, so the only thing that can take the outgoing cards off is the screen.
private final class SegmentTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var swapped = false
    private var released = false
    private var bucketSizes: [String] = []
    /// Set by `signing`: covers and rows carry `?exp&scope&sig`, lapsed on the first read of each
    /// and signed afresh on every read after it, the way an hour-old list and a fresh one differ.
    private let signs: Bool
    private var yearReads = 0
    private var listReads = 0

    init(signing: Bool = false) {
        signs = signing
    }

    func swapSubject() { lock.withLock { swapped = true } }
    func release() { lock.withLock { released = true } }
    /// The `size` of every bucket read, in the order they were asked.
    var sizesAsked: [String] { lock.withLock { bucketSizes } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let isSwapped = lock.withLock { swapped }
        switch operationID {
        case SegmentWire.whoami:
            let subject = isSwapped ? SegmentWire.incoming : SegmentWire.outgoing
            return Self.json(
                """
                {"subject":"\(subject)","display_name":"\(subject)","email":null,\
                "role":"user","auth_kind":"oidc"}
                """
            )
        case SegmentWire.buckets:
            let size = Self.size(in: request.path)
            lock.withLock { bucketSizes.append(size) }
            if isSwapped { try await held() }
            if signs, size == "year" {
                let first = lock.withLock {
                    yearReads += 1
                    return yearReads == 1
                }
                return Self.json(Self.signedYears(sig: first ? "old" : "newcover"))
            }
            return Self.json(size == "year" ? Self.years : "[]")
        case SegmentWire.listAttachments:
            if isSwapped { try await held() }
            if signs {
                let first = lock.withLock {
                    listReads += 1
                    return listReads == 1
                }
                return Self.json("[\(Self.signedRow(sig: first ? "old" : "newrow"))]")
            }
            return Self.json("[]")
        case SegmentWire.attachmentTags:
            return Self.json("[]")
        default:
            // The health handshake: not what these cases are about; a plain failure keeps it out.
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    private func held() async throws {
        while !lock.withLock({ released }) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 2026 with a cover, 2019 with a cover URL that does not resolve.
    private static let years = """
        [{"key":"2026","count":12,"coverUid":"\(SegmentWire.coverPrefix)2026",\
        "coverThumbnailUrl":"/api/attachments/\(SegmentWire.coverPrefix)2026/thumb"},\
        {"key":"2019","count":3,"coverUid":"\(SegmentWire.coverPrefix)2019",\
        "coverThumbnailUrl":""}]
        """

    /// The signed server's one year, whose cover is the library's one row.
    nonisolated static let signedUID = "signed-cover"

    private static func signedQuery(_ sig: String) -> String {
        let exp = sig == "old" ? 1_000_000_000 : 4_000_000_000
        return "?exp=\(exp)&scope=1&sig=\(sig)"
    }

    private static func signedYears(sig: String) -> String {
        """
        [{"key":"2026","count":12,"coverUid":"\(signedUID)",\
        "coverThumbnailUrl":"/api/attachments/\(signedUID)/thumb\(signedQuery(sig))"}]
        """
    }

    private static func signedRow(sig: String) -> String {
        let query = signedQuery(sig)
        return """
            {"uid":"\(signedUID)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "renditions":[],"orphan":true,"memoUid":null,\
            "takenAt":"2026-09-26T10:00:00Z","filename":"cover.jpg",\
            "thumbnailUrl":"/api/attachments/\(signedUID)/thumb\(query)",\
            "previewUrl":"/api/attachments/\(signedUID)/mobile\(query)",\
            "webUrl":"/api/attachments/\(signedUID)/web\(query)",\
            "posterUrl":"/api/attachments/\(signedUID)/poster\(query)",\
            "downloadUrl":"/api/attachments/\(signedUID)/download",\
            "printUrl":"/api/attachments/\(signedUID)/print"}
            """
    }

    private static func size(in path: String?) -> String {
        let query = path.flatMap { URLComponents(string: $0)?.queryItems } ?? []
        return query.first { $0.name == "size" }?.value ?? "?"
    }

    private static func json(_ payload: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }
}

/// A server for All's pull-to-refresh (MEMNG-597): one picture on Mon 14 Sep 2026, whose day
/// bucket counts 12 until the test says a picture arrived, and 13 after.
private final class RefreshTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var lists = 0
    private var dayReads = 0

    func arrive() { lock.withLock { arrived = true } }
    var listsAsked: Int { lock.withLock { lists } }
    var dayReadsAsked: Int { lock.withLock { dayReads } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        switch operationID {
        case SegmentWire.whoami:
            return Self.json(
                """
                {"subject":"\(SegmentWire.outgoing)","display_name":"\(SegmentWire.outgoing)",\
                "email":null,"role":"user","auth_kind":"oidc"}
                """
            )
        case SegmentWire.buckets:
            let query = request.path.flatMap { URLComponents(string: $0)?.queryItems } ?? []
            guard query.first(where: { $0.name == "size" })?.value == "day" else {
                return Self.json("[]")
            }
            let count = lock.withLock {
                dayReads += 1
                return arrived ? 13 : 12
            }
            return Self.json(
                """
                [{"key":"2026-09-14","count":\(count),"coverUid":"refresh-a",\
                "coverThumbnailUrl":"/api/attachments/refresh-a/thumb"}]
                """
            )
        case SegmentWire.listAttachments:
            lock.withLock { lists += 1 }
            return Self.json("[\(Self.picture)]")
        case SegmentWire.attachmentTags:
            return Self.json("[]")
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    /// Noon in Zurich on Monday 14 September 2026.
    private static let picture = """
        {"uid":"refresh-a","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":true,"memoUid":null,\
        "takenAt":"2026-09-14T10:00:00Z","filename":"refresh-a.jpg",\
        "thumbnailUrl":"/api/attachments/refresh-a/thumb",\
        "previewUrl":"/api/attachments/refresh-a/mobile",\
        "webUrl":"/api/attachments/refresh-a/web",\
        "posterUrl":"/api/attachments/refresh-a/poster",\
        "downloadUrl":"/api/attachments/refresh-a/download",\
        "printUrl":"/api/attachments/refresh-a/print"}
        """

    private static func json(_ payload: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }
}

/// Every picture request a mounted tile makes, each refused at once. Only a MOUNTED tile hears
/// `MediaRetrySignal`, so the requests one publication causes name exactly the covers on screen.
private actor CoverProbe: MediaTransport {
    private var requested: [String] = []

    var paths: [String] { requested }

    func requests(for uid: String) -> Int {
        requested.count(where: { $0.contains("/\(uid)/") })
    }

    var outgoingCovers: Int {
        requested.count(where: { $0.contains("/\(SegmentWire.coverPrefix)") })
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        requested.append(request.url?.path() ?? "")
        throw URLError(.timedOut)
    }
}

/// The keychain, in memory.
private final class SegmentCredentials: CredentialStore, @unchecked Sendable {
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

/// The Years | Months | All segment (MEMNG-586), in the dock over the Library (MEMNG-594), hosted
/// in the real `MainTabView` over a real `SessionStore` and the real generated client.
///
/// In this suite for the reason `MediaLibrarySubjectChangeTests` is: it installs the loader's
/// transport and publishes its retry signal, both process-wide, and the suite is serialized.
extension MediaImageLoaderTests {
    private func segmentSession(_ transport: any ClientTransport) -> SessionStore {
        SessionStore(
            credentials: SegmentCredentials(),
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
    }

    private func segmentSettle(_ window: UIWindow, turns: Int = 20) async {
        for _ in 0..<turns {
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Every accessibility element that reads out `label`, wherever the hierarchy put it.
    private static func elements(
        labelled label: String, in node: Any, into found: inout [NSObject]
    ) {
        guard let object = node as? NSObject else { return }
        // The system tab bar is hidden under the dock but keeps its items' labels; it must not
        // answer for the dock.
        if object is UITabBar { return }
        if object.accessibilityLabel == label { found.append(object) }
        for child in object.accessibilityElements ?? [] {
            elements(labelled: label, in: child, into: &found)
        }
        if let view = object as? UIView {
            for subview in view.subviews { elements(labelled: label, in: subview, into: &found) }
        }
    }

    /// Where the navigation bar is on screen, which is where the Library's toolbar is drawn.
    private static func navigationBarFrame(in window: UIWindow) -> CGRect? {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UINavigationBar, !bar.isHidden {
                return bar.convert(bar.bounds, to: nil)
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Whether an element is drawn in the navigation bar. Judged by where it is on screen, because
    /// SwiftUI's accessibility elements are not views, and have no superview to walk up.
    private static func isInNavigationBar(_ element: NSObject, bar: CGRect?) -> Bool {
        guard let bar else { return false }
        let frame = frame(of: element)
        return !frame.isEmpty && bar.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Where an element is drawn, in the window's coordinates. A UIKit view is asked directly:
    /// in a window attached to no scene its accessibility frame is not converted to the screen
    /// (measured: a segment label of the dock's control read y=7), while SwiftUI's elements are.
    private static func frame(of element: NSObject) -> CGRect {
        if let view = element as? UIView, let window = view.window {
            return view.convert(view.bounds, to: window)
        }
        return element.accessibilityFrame
    }

    /// The system tab bar, when it is on screen: nothing up its chain of superviews hiding it,
    /// and some part of it inside the window.
    private static func systemTabBarOnScreen(in window: UIWindow) -> UITabBar? {
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UITabBar {
                var node: UIView? = bar
                while let current = node {
                    if current.isHidden || current.alpha < 0.01 { return nil }
                    node = current.superview
                }
                let frame = bar.convert(bar.bounds, to: window)
                return !frame.isEmpty && frame.intersects(window.bounds) ? bar : nil
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// On the test host's own window scene: a window belonging to no scene never completes the
    /// appearance transitions the system bar's hiding and showing ride on (`StackChromeTests`).
    private static func sceneWindow() -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        guard let scene = scene as? UIWindowScene else { return UIWindow(frame: frame) }
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    /// Every segmented control in the navigation bar. The Library's toolbar used to carry the
    /// Years | Months | All picker; the dock carries it now, and the bar must carry none.
    private static func navigationBarSegmentedControls(in window: UIWindow) -> Int {
        var count = 0
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let bar = view as? UINavigationBar, !bar.isHidden {
                var inner: [UIView] = [bar]
                while let node = inner.popLast() {
                    if node is UISegmentedControl { count += 1 }
                    inner.append(contentsOf: node.subviews)
                }
            }
            stack.append(contentsOf: view.subviews)
        }
        return count
    }

    /// Every label the hosted hierarchy reads out.
    private static func labels(in node: Any, into found: inout [String]) {
        guard let object = node as? NSObject else { return }
        // The system tab bar is hidden under the dock but keeps its items' labels; it must not
        // answer for the dock.
        if object is UITabBar { return }
        if let label = object.accessibilityLabel, !label.isEmpty { found.append(label) }
        for child in object.accessibilityElements ?? [] { labels(in: child, into: &found) }
        if let view = object as? UIView {
            for subview in view.subviews { labels(in: subview, into: &found) }
        }
    }

    private static func labels(in window: UIWindow) -> [String] {
        var found: [String] = []
        labels(in: window, into: &found)
        return found
    }

    /// Signs in, hosts the app on the Library under the real tab bar and switches it to Years
    /// through the scope control in the bar's accessory.
    private func hostYears(
        _ wire: SegmentTransport,
        atRest: (UIWindow) -> Void = { _ in }
    ) async -> (SessionStore, UIWindow) {
        let session = segmentSession(wire)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_segment")
        #expect(session.state.user?.subject == SegmentWire.outgoing, "precondition: signed in")

        let window = Self.sceneWindow()
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: .library).environment(session))
        window.makeKeyAndVisible()

        // At rest the system tab bar is up and Years | Months | All stands in its accessory, on
        // All (MEMNG-604).
        var control: UISegmentedControl?
        for _ in 0..<200 where control == nil || Self.systemTabBarOnScreen(in: window) == nil {
            await segmentSettle(window, turns: 1)
            control = ScopeAccessoryProbe.control(in: window)
        }
        let seen = ScopeAccessoryProbe.describe(window)
        #expect(Self.systemTabBarOnScreen(in: window) != nil, "the Library at rest: no tab bar")
        #expect(control != nil, "the Library at rest: no scope control: \(seen)")
        #expect(control.flatMap { ScopeAccessoryProbe.chosen(in: $0) } == "All", "All not chosen")
        // The navigation bar carries no segmented control: the picker left it for the accessory.
        #expect(Self.navigationBarSegmentedControls(in: window) == 0)
        var years: [NSObject] = []
        Self.elements(labelled: "Years", in: window, into: &years)
        let bar = Self.navigationBarFrame(in: window)
        #expect(!years.contains { Self.isInNavigationBar($0, bar: bar) }, "Years in the bar")
        // The control: All is what the Library opens on, and All reads DAY buckets only — its
        // day headings' counts (MEMNG-597) — never the year buckets a card is drawn from.
        await segmentSettle(window)
        #expect(wire.sizesAsked.allSatisfy { $0 == "day" }, "All read buckets: \(wire.sizesAsked)")
        #expect(!Self.labels(in: window).contains("12 items"), "a year card drawn under All")
        atRest(window)

        let live = await ScopeAccessoryProbe.settledControl(in: window) {
            await segmentSettle(window, turns: 1)
        }
        let before = ScopeAccessoryProbe.describe(window)
        if let live { ScopeAccessoryProbe.choose(.years, in: live) }
        await segmentSettle(window)
        #expect(
            wire.sizesAsked.first { $0 != "day" } == "year", "Years read no year buckets: \(before)"
        )
        return (session, window)
    }

    @Test("a lapsed cover that is also a library row is re-signed by reading the buckets again")
    func aLapsedCoverIsReSignedByItsBuckets() async {
        let wire = SegmentTransport(signing: true)
        let media = SignatureMediaServer(payload: MediaFixture.png(.red))
        await withTransport(media) {
            let (_, window) = await hostYears(wire)
            defer {
                wire.release()
                window.isHidden = true
                window.rootViewController = nil
            }
            let uid = SegmentTransport.signedUID
            let lapsed = await eventually(tries: 200) {
                await media.asked(uid: uid, sig: "old") >= 1
            }
            #expect(lapsed, "precondition: the lapsed cover was never asked for")

            let recovered = await eventually(tries: 200) {
                await media.asked(uid: uid, sig: "newcover") >= 1
            }
            #expect(recovered, "the cover kept its refused URL: the year buckets were not re-read")
            #expect(
                wire.sizesAsked.filter { $0 == "year" }.count >= 2,
                "the year buckets were read once: \(wire.sizesAsked)"
            )
        }
    }

    @Test("the scope control switches the Library to Years, which draws a card per year")
    func segmentSwitchesToYears() async {
        let wire = SegmentTransport()
        let probe = CoverProbe()
        await withTransport(probe) {
            let (_, window) = await hostYears(wire)
            defer {
                wire.release()
                window.isHidden = true
                window.rootViewController = nil
            }

            #expect(
                await eventually(tries: 200) {
                    await probe.requests(for: "\(SegmentWire.coverPrefix)2026") >= 1
                },
                "the 2026 card's cover was never asked for"
            )
            // All's day read comes first (MEMNG-597); the year buckets are read once.
            #expect(
                wire.sizesAsked.filter { $0 != "day" } == ["year"], "Years reads year buckets, once"
            )
            var labels: [String] = []
            for _ in 0..<80 where !labels.contains("12 items") {
                await segmentSettle(window, turns: 1)
                labels = Self.labels(in: window)
            }
            #expect(labels.contains("2026"), "no 2026 card: \(labels)")
            #expect(labels.contains("12 items"), "the 2026 card has no count: \(labels)")
            // The card whose cover does not resolve is drawn all the same, over a placeholder,
            // and asks for no picture — not even the server's own address.
            #expect(labels.contains("2019"), "no 2019 card: \(labels)")
            #expect(labels.contains("3 items"), "the 2019 card has no count: \(labels)")
            #expect(await probe.requests(for: "\(SegmentWire.coverPrefix)2019") == 0)
            let paths = await probe.paths
            #expect(!paths.contains { $0.isEmpty || $0 == "/" }, "a cover fetched \(paths)")
        }
    }

    /// The value a day heading reads out, or nil while no heading of that name is on screen.
    private static func headingValue(_ label: String, in window: UIWindow) -> String? {
        var found: [NSObject] = []
        elements(labelled: label, in: window, into: &found)
        return found.first?.accessibilityValue
    }

    /// The refresh control SwiftUI's `refreshable` put on the scroll on screen.
    private static func refreshControl(in view: UIView) -> UIRefreshControl? {
        if let scroll = view as? UIScrollView, let control = scroll.refreshControl {
            return control
        }
        for subview in view.subviews {
            if let control = refreshControl(in: subview) { return control }
        }
        return nil
    }

    /// A day heading's count is the day bucket's, so a pull-to-refresh that reads the list again
    /// and leaves the buckets would draw a day that gained a picture under its old count.
    @Test("All's pull-to-refresh reads the day counts again with the list")
    func refreshReadsTheDayCountsAgain() async {
        let wire = RefreshTransport()
        await withTransport(CoverProbe()) {
            let session = segmentSession(wire)
            await session.enteredForeground()
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_refresh")
            #expect(session.state.user?.subject == SegmentWire.outgoing, "precondition: signed in")
            let window = Self.sceneWindow()
            window.rootViewController = UIHostingController(
                rootView: MainTabView(opening: .library).environment(session))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            var value: String?
            for _ in 0..<200 where value != "12 items" {
                await segmentSettle(window, turns: 1)
                value = Self.headingValue("Mon 14 Sep", in: window)
            }
            #expect(
                value == "12 items",
                "control: the day heading never read its count (\(value ?? "none"))")
            let lists = wire.listsAsked
            let reads = wire.dayReadsAsked

            wire.arrive()
            let control = Self.refreshControl(in: window)
            #expect(control != nil, "no pull-to-refresh on All")
            control?.beginRefreshing()
            control?.sendActions(for: .valueChanged)
            for _ in 0..<200 where wire.listsAsked == lists || value != "13 items" {
                await segmentSettle(window, turns: 1)
                value = Self.headingValue("Mon 14 Sep", in: window)
            }
            #expect(wire.listsAsked > lists, "control: the refresh never read the list again")
            #expect(wire.dayReadsAsked > reads, "the refresh left the day buckets unread")
            #expect(value == "13 items", "a day that gained a picture kept its old count")
            control?.endRefreshing()
        }
    }

    /// The words of the kind filter, and the name its bar was read out by. Since MEMNG-595 the
    /// kind is chosen in the header's options menu, whose rows are drawn only while it is open.
    private static let kindWords: Set<String> = [
        "All Items", "Images", "Photos", "Videos", "Filter media type",
    ]

    /// Every kind word a segmented control on screen draws, or any element reads out.
    private static func kindFilterShown(in window: UIWindow) -> [String] {
        var found: [String] = []
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let control = view as? UISegmentedControl {
                for index in 0..<control.numberOfSegments {
                    if let title = control.titleForSegment(at: index), kindWords.contains(title) {
                        found.append(title)
                    }
                }
            }
            stack.append(contentsOf: view.subviews)
        }
        return found + labels(in: window).filter { kindWords.contains($0) }
    }

    /// Plan page 3929 decision 5: sort and filter are in the header's options button, not on a bar
    /// over the Library, so no segmented control draws Photos or Videos over All, Years or Months.
    @Test("no kind filter bar is drawn over the grid, Years or Months")
    func noKindFilterBar() async {
        let wire = SegmentTransport()
        let probe = CoverProbe()
        await withTransport(probe) {
            var overAll: [String] = ["never looked"]
            var select: [NSObject] = []
            var options: [NSObject] = []
            // Read while All is on screen: the elements are live, and by the time `hostYears`
            // returns they answer for Years, where Select is inert by design.
            var live = false
            let (_, window) = await hostYears(wire) { window in
                overAll = Self.kindFilterShown(in: window)
                Self.elements(labelled: "Select", in: window, into: &select)
                Self.elements(labelled: "Options", in: window, into: &options)
                live = select.allSatisfy { !$0.accessibilityTraits.contains(.notEnabled) }
            }
            defer {
                wire.release()
                window.isHidden = true
                window.rootViewController = nil
            }
            #expect(overAll.isEmpty, "a kind filter over the All grid: \(overAll)")
            // The header the kind moved into, on the real Library: its options button, and the
            // Select capsule (decision 10), live over All where there are files to choose
            // (MEMNG-588).
            #expect(!options.isEmpty, "the Library draws no options button")
            #expect(!select.isEmpty && live, "Select is missing or inert in All")

            var labels: [String] = []
            for _ in 0..<80 where !labels.contains("12 items") {
                await segmentSettle(window, turns: 1)
                labels = Self.labels(in: window)
            }
            // The control: this is Years, drawn.
            #expect(labels.contains("12 items"), "precondition: the Years cards are on screen")
            let overYears = Self.kindFilterShown(in: window)
            #expect(overYears.isEmpty, "a kind filter over Years: \(overYears)")
            // Over Years there is nothing to select: the capsule is drawn and inert.
            var selectOverYears: [NSObject] = []
            Self.elements(labelled: "Select", in: window, into: &selectOverYears)
            let inert = selectOverYears.allSatisfy { $0.accessibilityTraits.contains(.notEnabled) }
            #expect(!selectOverYears.isEmpty && inert, "Select is missing or live over Years")

            // All reads day buckets too (MEMNG-597), so Months' read is the one AFTER the choice.
            let dayReads = { wire.sizesAsked.filter { $0 == "day" }.count }
            let before = dayReads()
            let control = ScopeAccessoryProbe.control(in: window)
            #expect(control != nil, "precondition: the scope control stands over Years")
            if let control { ScopeAccessoryProbe.choose(.months, in: control) }
            for _ in 0..<80 where dayReads() <= before {
                await segmentSettle(window, turns: 1)
            }
            #expect(dayReads() > before, "precondition: Months read day buckets")
            await segmentSettle(window)
            let overMonths = Self.kindFilterShown(in: window)
            #expect(overMonths.isEmpty, "a kind filter over Months: \(overMonths)")
        }
    }

    @Test("a revalidation that names another account takes A's year cards off")
    func subjectChangeEmptiesTheYears() async {
        let wire = SegmentTransport()
        let probe = CoverProbe()
        await withTransport(probe) {
            let signal = MediaRetrySignal.shared
            let (session, window) = await hostYears(wire)
            defer {
                wire.release()
                window.isHidden = true
                window.rootViewController = nil
            }

            #expect(
                await eventually(tries: 200) { await probe.outgoingCovers >= 1 },
                "precondition: A's year cards were drawn"
            )
            await segmentSettle(window)

            // The probe's own control: while A's card is on screen, a signal makes it ask again.
            guard MediaRetrySignal.shared === signal else {
                Issue.record("MediaRetrySignal.shared was replaced; this case proves nothing")
                return
            }
            let mounted = await probe.outgoingCovers
            signal.publish()
            #expect(
                await eventually { await probe.outgoingCovers > mounted },
                "precondition: a signal reaches A's cards while they are on screen"
            )
            await segmentSettle(window)

            wire.swapSubject()
            await session.retryNow()
            #expect(
                session.state.user?.subject == SegmentWire.incoming,
                "precondition: the revalidation established B"
            )
            await segmentSettle(window)

            let before = await probe.outgoingCovers
            signal.publish()
            let askedAgain = await eventually { await probe.outgoingCovers > before }
            guard MediaRetrySignal.shared === signal else {
                Issue.record("MediaRetrySignal.shared was replaced; this case proves nothing")
                return
            }
            // B's bucket read is held, so no answer of B's took A's cards off: only the screen
            // emptying its bucket store can.
            #expect(!askedAgain, "A's year cards are still on screen after B was established")
            #expect(!Self.labels(in: window).contains("12 items"), "A's 2026 card is still drawn")
        }
    }
}

/// The cover a bucket hands the grid's tile.
@MainActor
@Suite("Library bucket cover")
struct LibraryBucketCoverTests {
    @Test("a bucket with a cover hands the tile its uid and signed URL; one without hands none")
    func coverAttachment() throws {
        let url = try #require(
            URL(string: "https://memos.example.invalid/api/attachments/c/thumb?sig=s"))
        let covered = LibraryBucket(key: "2026", count: 2, coverUID: "c", coverThumbnailURL: url)
        let cover = try #require(LibraryBucketCover.attachment(for: covered))
        #expect(cover.uid == "c")
        #expect(MemoPresentation.url(for: cover, tier: .thumb) == url)
        #expect(
            MediaImageLoader.key(for: cover, tier: .thumb) == MediaImageKey(uid: "c", tier: "thumb")
        )

        let bare = LibraryBucket(key: "2019", count: 1, coverUID: "d", coverThumbnailURL: nil)
        #expect(LibraryBucketCover.attachment(for: bare) == nil)
    }
}
