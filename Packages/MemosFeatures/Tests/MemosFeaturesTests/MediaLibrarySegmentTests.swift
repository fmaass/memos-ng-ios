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
            return Self.json(size == "year" ? Self.years : "[]")
        case SegmentWire.listAttachments:
            if isSwapped { try await held() }
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
    private func segmentSession(_ transport: SegmentTransport) -> SessionStore {
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

    /// Whether an element is drawn in the dock: the bottom fifth of the window, where it sits.
    private static func isInDock(_ element: NSObject, window: UIWindow) -> Bool {
        let frame = frame(of: element)
        return !frame.isEmpty && frame.midY > window.bounds.height * 0.8
            && frame.intersects(window.bounds)
    }

    /// The labels among `titles` the dock reads out right now.
    private static func dockLabels(_ titles: [String], in window: UIWindow) -> Set<String> {
        var shown: Set<String> = []
        for title in titles {
            var found: [NSObject] = []
            elements(labelled: title, in: window, into: &found)
            if found.contains(where: { isInDock($0, window: window) }) { shown.insert(title) }
        }
        return shown
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

    /// Scrolls every tall scroll view on screen `distance` points below the top of its content,
    /// the way a drag leaves it: the offset moves and the scroll view tells its delegate.
    private static func scroll(_ window: UIWindow, by distance: CGFloat) -> Int {
        var moved = 0
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let scroller = view as? UIScrollView, scroller.window != nil,
                scroller.bounds.height > window.bounds.height / 2,
                !(scroller is UITextView)
            {
                let top = -scroller.adjustedContentInset.top
                scroller.setContentOffset(CGPoint(x: 0, y: top + distance), animated: false)
                moved += 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return moved
    }

    /// The dock's element that reads out `label`, if the dock draws one.
    private static func dockElement(_ label: String, in window: UIWindow) -> NSObject? {
        var found: [NSObject] = []
        elements(labelled: label, in: window, into: &found)
        return found.first { isInDock($0, window: window) }
    }

    /// Picks the dock's "Years" segment the way VoiceOver presses it. Returns what it found, for
    /// the message of a case that then sees no change.
    private static func chooseYears(in window: UIWindow) -> String {
        guard let years = dockElement("Years", in: window) else {
            var found: [NSObject] = []
            elements(labelled: "Years", in: window, into: &found)
            let kinds = found.map { "\(type(of: $0))@\(Int(frame(of: $0).midY))" }
            return "the dock draws no Years: \(kinds)"
        }
        return years.accessibilityActivate() ? "pressed Years" : "Years took no press"
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

    /// Signs in, hosts the app on the Library under the real dock, scrolls it past the dock's
    /// threshold and switches it to Years through the segment the dock turns into.
    private func hostYears(_ wire: SegmentTransport) async -> (SessionStore, UIWindow) {
        let session = segmentSession(wire)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_segment")
        #expect(session.state.user?.subject == SegmentWire.outgoing, "precondition: signed in")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: .library).environment(session))
        window.makeKeyAndVisible()

        let tabs = MainTab.allCases.map(\.title)
        let segment = LibraryScope.allCases.map(\.label)
        var inDock: Set<String> = []
        for _ in 0..<200 where inDock != Set(tabs) {
            await segmentSettle(window, turns: 1)
            inDock = Self.dockLabels(tabs + segment, in: window)
        }
        // At rest the dock is the three tabs and nothing else (plan page 3929 decision 8).
        #expect(inDock == Set(tabs), "the Library at rest: the dock reads \(inDock)")
        // The navigation bar carries no segmented control: the picker left it for the dock.
        #expect(Self.navigationBarSegmentedControls(in: window) == 0)
        var years: [NSObject] = []
        Self.elements(labelled: "Years", in: window, into: &years)
        let bar = Self.navigationBarFrame(in: window)
        #expect(!years.contains { Self.isInNavigationBar($0, bar: bar) }, "Years in the bar")
        // The control: All is what the Library opens on, and All reads no buckets.
        await segmentSettle(window)
        #expect(wire.sizesAsked.isEmpty, "All read buckets: \(wire.sizesAsked)")
        #expect(!Self.labels(in: window).contains("12 items"), "a year card drawn under All")

        // Past the threshold the dock collapses to the Library icon beside Years | Months | All.
        var moved = 0
        for _ in 0..<100 where !inDock.isSuperset(of: segment) {
            moved = Self.scroll(window, by: DockMode.segmentThreshold * 8)
            await segmentSettle(window, turns: 1)
            inDock = Self.dockLabels(tabs + segment, in: window)
        }
        #expect(moved > 0, "no scroll view to scroll")
        #expect(
            inDock == Set(segment + [MainTab.library.title]),
            "the Library scrolled: the dock reads \(inDock)"
        )
        #expect(Self.navigationBarSegmentedControls(in: window) == 0)
        // All is the segment's default, as it is the Library's.
        #expect(
            Self.dockElement("All", in: window)?.accessibilityTraits.contains(.selected) == true,
            "All is not the chosen segment"
        )

        let chosen = Self.chooseYears(in: window)
        await segmentSettle(window)
        #expect(wire.sizesAsked.first == "year", "Years read no year buckets: \(chosen)")
        return (session, window)
    }

    @Test("the dock's segment switches the Library to Years, which draws a card per year")
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
            #expect(wire.sizesAsked == ["year"], "Years reads year buckets, once")
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
