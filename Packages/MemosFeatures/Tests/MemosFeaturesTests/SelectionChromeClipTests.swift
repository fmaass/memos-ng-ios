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

/// The simulator clips WPN-12 and WPN-13 owe before they merge (MEMNG-779, MEMNG-781, MEMNG-783):
/// the real `MainTabView` over a scripted server, held on the simulator's screen while a driver
/// OUTSIDE the app records it (`simctl io recordVideo`) and touches it (`idb ui tap`) — a SwiftUI
/// `Menu` opens only on a real touch, which nothing inside the process can give. The driver is
/// `scripts/record-selection-clips.py`; the handshake per scene is in `ClipStage`.
///
/// These tests run only when `MEMNG_CLIP_REQUIRE` is set (passed by xcodebuild from
/// `TEST_RUNNER_MEMNG_CLIP_REQUIRE`): that variable IS the require marker. A run that sets it and
/// gets no answer from a recorder fails, so a clip run that recorded nothing is never green. The
/// gate sets nothing, so there the tests are reported skipped — never passed — and no gate run
/// waits on a recorder that is not there.
extension MediaImageLoaderTests {
    @Test(
        "clip 779: the Library's filter menu, Sort By and Show Selected, touched for real",
        .enabled(if: ClipStage.required != nil, "a clip run sets MEMNG_CLIP_REQUIRE")
    )
    func clipLibraryFilterMenu() async {
        let transport = ClipServer()
        await withTransport(ClipPaint(palette: ClipPaint.palette())) {
            let window = await clipHost(opening: .library, transport)
            defer { ClipStage.close(window) }
            #expect(await ClipStage.served(transport, ClipServer.listAttachments, atLeast: 1))
            await ClipStage.settle(window, seconds: 2)
            #expect(await ClipStage.scene("779a-library-filter-menu"))
            await ClipStage.settle(window, seconds: 1)
            #expect(await ClipStage.scene("779b-library-select-show-selected"))
        }
    }

    @Test(
        "clip 781: a re-tap over a trip returns its modes row; Back shows the root's +",
        .enabled(if: ClipStage.required != nil, "a clip run sets MEMNG_CLIP_REQUIRE")
    )
    func clipCollectionsRetap() async {
        let transport = ClipServer()
        await withTransport(ClipPaint(palette: ClipPaint.palette())) {
            let window = await clipHost(opening: .collections, transport)
            defer { ClipStage.close(window) }
            #expect(await ClipStage.served(transport, TripRows.list, atLeast: 1))
            await ClipStage.settle(window, seconds: 2)
            #expect(await ClipStage.scene("781a-collections-retap"))
            // The driver opened a trip, pressed the modes row's Collections icon, pressed the
            // Collections tab again — which brings the row back over the trip (MEMNG-822, amending
            // MEMNG-781) — and pressed Back: the root stands, its + with it, which a trip covers.
            let plus = CollectionsScreen.newTripButton
            let root = await ClipStage.showsSoon(plus, in: window)
            #expect(root, "after the re-tap the Collections root's + is not on screen")
        }
    }

    @Test(
        "clip 822: a collection's Photos | Journal | Map in the main bar's capsule",
        .enabled(if: ClipStage.required != nil, "a clip run sets MEMNG_CLIP_REQUIRE")
    )
    func clipCollectionModesBar() async {
        let transport = ClipServer()
        await withTransport(ClipPaint(palette: ClipPaint.palette())) {
            let window = await clipHost(opening: .collections, transport)
            defer { ClipStage.close(window) }
            #expect(await ClipStage.served(transport, TripRows.list, atLeast: 1))
            await ClipStage.settle(window, seconds: 2)
            #expect(await ClipStage.scene("822-collection-modes-bar"))
            // The driver's last touch is Back from the trip's modes row: the root's +.
            let plus = CollectionsScreen.newTripButton
            let root = await ClipStage.showsSoon(plus, in: window)
            #expect(root, "after Back the Collections root's + is not on screen")
        }
    }

    @Test(
        "clip 845: the Library's scope row, the reference the modes row is matched to",
        .enabled(if: ClipStage.required != nil, "a clip run sets MEMNG_CLIP_REQUIRE")
    )
    func clipLibraryScopeRow() async {
        let transport = ClipServer()
        await withTransport(ClipPaint(palette: ClipPaint.palette())) {
            let window = await clipHost(opening: .library, transport)
            defer { ClipStage.close(window) }
            #expect(await ClipStage.served(transport, ClipServer.listAttachments, atLeast: 1))
            await ClipStage.settle(window, seconds: 2)
            #expect(await ClipStage.scene("845a-library-scope-row"))
        }
    }

    @Test(
        "clip 783: the Collections root's cards, each row scrolled, one opened",
        .enabled(if: ClipStage.required != nil, "a clip run sets MEMNG_CLIP_REQUIRE")
    )
    func clipCollectionCards() async {
        let transport = ClipServer()
        await withTransport(ClipPaint(palette: ClipPaint.palette())) {
            let window = await clipHost(opening: .collections, transport)
            defer { ClipStage.close(window) }
            #expect(await ClipStage.served(transport, ClipServer.buckets, atLeast: 2))
            await ClipStage.settle(window, seconds: 3)
            #expect(await ClipStage.scene("783-collection-cards"))
        }
    }

    /// The real tabs over `transport`, signed in, in a key window over the whole screen.
    private func clipHost(opening tab: MainTab, _ transport: ClipServer) async -> UIWindow {
        let session = SessionStore(
            credentials: ClipCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration, credential: credential, transport: transport)
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            identity: identity
        )
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_clips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        let window: UIWindow
        if let scene = scene as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        }
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: MainTabView(opening: tab).environment(session))
        window.makeKeyAndVisible()
        return window
    }
}

/// One scene's handshake with the driver outside the app, through the host app's tmp directory
/// (the driver finds it with `simctl get_app_container`). Per scene the test writes
/// `clip-ready` = `<scene> <nonce>` — rewritten on every poll, so its modification time stays
/// newer than the driver's start — and waits for `clip-recording`, then `clip-finished`, each
/// counting only when its last field is this scene's nonce: a file any earlier run or scene left
/// behind never stands for this one.
enum ClipStage {
    /// The require marker: set, a recorder is expected and a silence fails the test.
    nonisolated static var required: String? {
        let value = ProcessInfo.processInfo.environment["MEMNG_CLIP_REQUIRE"] ?? ""
        return value.isEmpty ? nil : value
    }

    static func file(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    /// Hands `name` to the driver and holds the screen until it says the scene is recorded:
    /// up to 120 s for the recording to start, up to 300 s for the driver's touches to end.
    static func scene(_ name: String) async -> Bool {
        let nonce = UUID().uuidString
        var waited = 0
        while waited < 120_000, !carries("clip-recording", nonce) {
            try? "\(name) \(nonce)".write(to: file("clip-ready"), atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .milliseconds(250))
            waited += 250
        }
        print("CLIP \(name) recorder waited \(waited) ms for nonce \(nonce)")
        guard carries("clip-recording", nonce) else {
            Issue.record(
                "MEMNG_CLIP_REQUIRE (\(required ?? "")) is set and no recorder took \(name) in 120 s"
            )
            return false
        }
        waited = 0
        while waited < 300_000, !carries("clip-finished", nonce) {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 250
        }
        print("CLIP \(name) driver finished after \(waited) ms")
        guard carries("clip-finished", nonce) else {
            Issue.record("the driver never finished \(name) within 300 s")
            return false
        }
        return true
    }

    /// Whether the handshake file `name` answers `nonce`: its last space-separated field is it.
    static func carries(_ name: String, _ nonce: String) -> Bool {
        guard let text = try? String(contentsOf: file(name), encoding: .utf8) else { return false }
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").last
        return last.map(String.init) == nonce
    }

    /// Whether `transport` answered `operation` `count` times within 20 s.
    fileprivate static func served(
        _ transport: ClipServer, _ operation: String, atLeast count: Int
    ) async -> Bool {
        for _ in 0..<200 where transport.served(operation) < count {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return transport.served(operation) >= count
    }

    /// Whether `label` stands on screen within 20 s.
    static func showsSoon(_ label: String, in window: UIWindow) async -> Bool {
        for _ in 0..<200 where !shows(label, in: window) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return shows(label, in: window)
    }

    static func settle(_ window: UIWindow, seconds: Int) async {
        for _ in 0..<(seconds * 10) {
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether an accessibility element labelled `label` stands inside the window's bounds.
    static func shows(_ label: String, in window: UIWindow) -> Bool {
        var queue: [NSObject] = [window]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if next.isAccessibilityElement, next.accessibilityLabel == label,
                window.bounds.intersects(next.accessibilityFrame)
            {
                return true
            }
            if let view = next as? UIView, view.isHidden || view.alpha < 0.01 { continue }
            let count = next.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = next.accessibilityElement(at: index) as? NSObject {
                        queue.append(element)
                    }
                }
            } else if let elements = next.accessibilityElements as? [NSObject] {
                queue.append(contentsOf: elements)
            } else if let view = next as? UIView {
                queue.append(contentsOf: view.subviews)
            }
        }
        return false
    }

    static func close(_ window: UIWindow) {
        window.rootViewController?.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }
}

/// Every picture painted as a soft diagonal gradient of its own, so a card or a tile reads as a
/// picture on film rather than as a flat swatch.
private actor ClipPaint: MediaTransport {
    private let palette: [Data]

    init(palette: [Data]) {
        self.palette = palette
    }

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        let url = request.url ?? URL(string: "https://memos.example.invalid/")!
        let pick = url.path.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"])!
        return (palette[pick % palette.count], response)
    }

    static func palette() -> [Data] {
        let pairs: [(UIColor, UIColor)] = [
            (.systemTeal, .systemBlue), (.systemOrange, .systemPink),
            (.systemIndigo, .systemPurple), (.systemGreen, .systemTeal),
            (.systemYellow, .systemOrange), (.systemBrown, .systemOrange),
            (.systemBlue, .systemIndigo), (.systemPink, .systemPurple),
            (.systemMint, .systemGreen), (.systemRed, .systemOrange),
        ]
        let side: CGFloat = 240
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format)
        return pairs.map { pair in
            renderer.pngData { context in
                let colours = [pair.0.cgColor, pair.1.cgColor] as CFArray
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours,
                    locations: [0, 1])
                {
                    context.cgContext.drawLinearGradient(
                        gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
                }
                UIColor.white.withAlphaComponent(0.35).setFill()
                context.cgContext.fillEllipse(
                    in: CGRect(
                        x: side * 0.55, y: side * 0.15, width: side * 0.25, height: side * 0.25))
            }
        }
    }
}

private final class ClipCredentials: CredentialStore, @unchecked Sendable {
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

/// A household's server for the clips: three trips, eight tags (three of them the trips'), a
/// Library of forty-eight pictures over twelve September days, twelve months and three years.
private final class ClipServer: ClientTransport, @unchecked Sendable {
    nonisolated static let whoami = "whoami_api_auth_user_get"
    nonisolated static let listAttachments = "list_attachments_api_attachments_get"
    nonisolated static let tags = "attachment_tags_api_attachments_tags_get"
    nonisolated static let buckets = "attachment_buckets_api_attachments_buckets_get"
    nonisolated static let memos = "list_memos_api_memos_get"
    nonisolated static let markers = "list_markers_api_map_markers_get"

    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var operations: [String] = []
    nonisolated let trips = TripRows()

    nonisolated init() {
        trips.seed(
            "Portugal", tag: "portugal2026",
            spanStart: "2026-03-12T00:00:00Z", spanEnd: "2026-03-28T22:00:00Z",
            cover: "portugal2026-0", count: 6)
        trips.seed(
            "Gaggiano", tag: "gaggiano",
            spanStart: "2026-07-04T00:00:00Z", spanEnd: "2026-07-18T22:00:00Z",
            cover: "gaggiano-0", count: 6)
        trips.seed(
            "Engadin in winter", tag: "engadin",
            spanStart: "2026-01-02T00:00:00Z", spanEnd: "2026-01-09T22:00:00Z",
            cover: "engadin-0", count: 6)
    }

    nonisolated func served(_ operation: String) -> Int {
        lock.withLock { operations.filter { $0 == operation }.count }
    }

    nonisolated func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock { operations.append(operationID) }
        let path = request.path ?? ""
        if let answered = try await trips.answer(
            request, body: body, operationID: operationID,
            listing: { query in Self.list(CollectionsTransport.path(query)) })
        {
            return answered
        }
        let query = URLComponents(string: path)?.queryItems ?? []
        switch operationID {
        case Self.whoami:
            return Self.json(
                #"{"subject":"fabian","display_name":"fabian","email":null,"role":"user","auth_kind":"oidc"}"#
            )
        case Self.tags:
            let tags = [
                ("portugal2026", 6), ("gaggiano", 6), ("engadin", 6), ("garden", 24),
                ("family", 40), ("walks", 17), ("lake", 8), ("bikes", 5),
            ]
            return Self.json(
                "[" + tags.map { #"{"name":"\#($0.0)","count":\#($0.1)}"# }.joined(separator: ",")
                    + "]")
        case Self.buckets:
            switch query.first(where: { $0.name == "size" })?.value {
            case "day": return Self.json(Self.dayBuckets)
            case "month": return Self.json(Self.monthBuckets)
            case "year": return Self.json(Self.yearBuckets)
            default: return Self.json("[]")
            }
        case Self.listAttachments:
            return Self.list(path)
        case Self.memos:
            return Self.json(#"{"items":[],"nextCursor":null,"totalCount":null}"#)
        case Self.markers:
            return Self.json(#"{"markers":[]}"#)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    private nonisolated static func list(_ path: String) -> (HTTPResponse, HTTPBody?) {
        let query = URLComponents(string: path)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if !(value("cursor") ?? "").isEmpty { return json("[]") }
        var items: [String]
        if let tag = value("tag") {
            items = (0..<6).map { index in
                item(
                    "\(tag)-\(index)",
                    taken: "2026-03-\(String(format: "%02d", 12 + index * 3))T10:00:00Z")
            }.reversed()
        } else {
            items = (1...12).reversed().flatMap { day in
                (0..<4).reversed().map { index in
                    item(
                        "lib-\(day)-\(index)",
                        taken: "2026-09-\(String(format: "%02d", day))T\(10 + index):00:00Z",
                        wide: index.isMultiple(of: 2))
                }
            }
        }
        if value("type") == "video" { items = [] }
        if value("order") == "taken_asc" { items.reverse() }
        if value("limit") == "1" { items = Array(items.prefix(1)) }
        return json("[\(items.joined(separator: ","))]")
    }

    private nonisolated static func item(_ uid: String, taken: String, wide: Bool = true) -> String
    {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":\(wide ? 1200 : 800),"height":\(wide ? 800 : 1200),"mine":true,\
        "hasPrint":false,"hasLegacyPrint":false,"webReady":true,"renditions":[],"tags":[],\
        "orphan":true,"memoUid":null,"takenAt":"\(taken)","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile","webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private nonisolated static func bucket(_ key: String, count: Int, cover: String) -> String {
        """
        {"key":"\(key)","count":\(count),"coverUid":"\(cover)","tags":[],\
        "coverThumbnailUrl":"/api/attachments/\(cover)/thumb"}
        """
    }

    private nonisolated static var dayBuckets: String {
        "["
            + (1...12).reversed().map { day in
                bucket(String(format: "2026-09-%02d", day), count: 4, cover: "lib-\(day)-0")
            }.joined(separator: ",") + "]"
    }

    /// November 2025 to October 2026, newest first.
    private nonisolated static var monthBuckets: String {
        let months = (0..<12).map { offset -> String in
            let index = 10 - offset
            return index > 0
                ? String(format: "2026-%02d", index) : String(format: "2025-%02d", 12 + index)
        }
        return "["
            + months.enumerated().map { offset, key in
                bucket(key, count: 7 + offset * 3, cover: "month-\(key)")
            }.joined(separator: ",") + "]"
    }

    private nonisolated static var yearBuckets: String {
        "["
            + [("2026", 212), ("2025", 340), ("2019", 40)].map {
                bucket($0.0, count: $0.1, cover: "year-\($0.0)")
            }.joined(separator: ",") + "]"
    }

    private nonisolated static func json(_ text: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }
}
