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
private enum AudienceWire {
    nonisolated static let whoami = "whoami_api_auth_user_get"
    nonisolated static let listAttachments = "list_attachments_api_attachments_get"
    nonisolated static let attachmentTags = "attachment_tags_api_attachments_tags_get"
    nonisolated static let buckets = "attachment_buckets_api_attachments_buckets_get"
    nonisolated static let subject = "fabian"
    /// Every picture's day, and the heading it is drawn under.
    nonisolated static let day = "2026-09-14"
    nonisolated static let heading = "Mon 14 Sep"
}

/// A server whose answer follows the audience a read asks for (MEMNG-787): three pictures on one
/// day for everybody's, two of them mine, one of those shared just with us — and the day bucket
/// counting 12, 7 and 3 under the same three queries, so the heading shows which answer it was
/// drawn from. Every read's query is kept, by operation.
private final class AudienceTransport: ClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(operation: String, query: [String: String])] = []

    /// The query of every read of `operation` so far, oldest first.
    func reads(_ operation: String) -> [[String: String]] {
        lock.withLock { asked.filter { $0.operation == operation }.map(\.query) }
    }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let items = request.path.flatMap { URLComponents(string: $0)?.queryItems } ?? []
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value ?? "" }
        lock.withLock { asked.append((operation: operationID, query: query)) }
        let mine = query["mine"] == "true"
        let justUs = query["visibility"] == "PROTECTED"
        switch operationID {
        case AudienceWire.whoami:
            return Self.json(
                """
                {"subject":"\(AudienceWire.subject)","display_name":"\(AudienceWire.subject)",\
                "email":null,"role":"user","auth_kind":"oidc"}
                """
            )
        case AudienceWire.buckets:
            guard query["size"] == "day" else { return Self.json("[]") }
            let count = justUs ? 3 : mine ? 7 : 12
            return Self.json(
                """
                [{"key":"\(AudienceWire.day)","count":\(count),"coverUid":"aud-a",\
                "tags":[],"coverThumbnailUrl":"/api/attachments/aud-a/thumb"}]
                """
            )
        case AudienceWire.listAttachments:
            let everybody = ["aud-a", "aud-b", "aud-c"]
            let uids = justUs ? ["aud-a"] : mine ? ["aud-a", "aud-b"] : everybody
            return Self.json("[\(uids.map(Self.row).joined(separator: ","))]")
        case AudienceWire.attachmentTags:
            return Self.json("[]")
        default:
            // The health handshake: nothing this case is about, and a plain failure keeps it out.
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    /// Noon in Zurich on Monday 14 September 2026, with real dimensions so the grid draws a tile.
    private static func row(_ uid: String) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":true,"memoUid":null,\
        "takenAt":"2026-09-14T10:00:00Z","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private static func json(_ payload: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(payload))
    }
}

/// Every picture request a tile makes, refused at once: the grid is read by its tiles' names.
private actor AudiencePictures: MediaTransport {
    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        throw URLError(.timedOut)
    }
}

/// The keychain, in memory.
private final class AudienceCredentials: CredentialStore, @unchecked Sendable {
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

/// The Library header's menus, read and pressed without opening them. A menu drawn in the
/// screen's content rather than in a navigation bar is handed to UIKit as a button's menu or as a
/// context-menu interaction whose configuration builds it on demand; either way the row's own
/// `UIAction` is performed as the open menu would perform it (`TripMenuProbe`).
@MainActor
enum LibraryMenuProbe {
    /// Performs the first row titled `title`, looking at the topmost menu holders first so the
    /// header answers before any tile's long-press menu is asked for its rows.
    static func perform(_ title: String, in window: UIWindow) -> Bool {
        for holder in holders(in: window) {
            guard let menu = menu(of: holder) else { continue }
            for case let action as UIAction in leaves(menu) where action.title == title {
                action.performWithSender(nil, target: nil)
                return true
            }
        }
        return false
    }

    /// The rows of the long-press menu on the grid tile drawing `uid` (MEMNG-902), asked of every
    /// interaction whose view holds the tile's centre, at that centre: one interaction can answer
    /// for a whole hosting view by location. Empty when no tile draws `uid`.
    static func tileRows(_ uid: String, in window: UIWindow) -> [UIAction] {
        guard let frame = tileFrame(uid, in: window) else { return [] }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        for holder in holders(in: window) where holder.interaction != nil {
            let point = holder.view.convert(centre, from: window)
            guard holder.view.bounds.contains(point),
                let menu = menu(of: holder, at: point)
            else { continue }
            let rows = leaves(menu).compactMap { $0 as? UIAction }
            if !rows.isEmpty { return rows }
        }
        return []
    }

    /// Where the tile identified as `uid`'s is, in the window's coordinates.
    private static func tileFrame(_ uid: String, in window: UIWindow) -> CGRect? {
        let identifier = LibraryGrid.tileIdentifier(uid)
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.responds(to: Selector(("accessibilityIdentifier"))),
                object.value(forKey: "accessibilityIdentifier") as? String == identifier
            {
                return window.convert(object.accessibilityFrame, from: nil)
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// What holds a menu on screen, for a failure's message: each holder's kind, its button
    /// menu, its interaction's configuration and the rows either gave.
    static func describe(_ window: UIWindow) -> String {
        holders(in: window).prefix(8).map { holder in
            var parts = ["\(type(of: holder.view))"]
            if let button = holder.view as? UIButton {
                parts.append("menu=\(button.menu.map(summary) ?? "nil")")
                parts.append("primary=\(button.showsMenuAsPrimaryAction)")
            }
            if let configuration = configuration(of: holder) {
                let names = ivarNames(of: configuration)
                parts.append("cfg=\(type(of: configuration)) \(names)")
            } else {
                let kind = holder.interaction.map { String(describing: type(of: $0)) } ?? "-"
                parts.append("cfg=nil ia=\(kind)")
            }
            parts.append("rows=\(menu(of: holder).map { leaves($0).map(title) } ?? [])")
            return parts.joined(separator: " ")
        }
        .joined(separator: "; ")
    }

    private struct Holder {
        let view: UIView
        let interaction: UIContextMenuInteraction?
    }

    /// Every button and every view with a context-menu interaction, top to bottom.
    private static func holders(in window: UIWindow) -> [Holder] {
        var found: [(Holder, CGFloat)] = []
        var views: [UIView] = [window]
        while let view = views.popLast() {
            views.append(contentsOf: view.subviews)
            let top = view.convert(view.bounds, to: window).minY
            let interactions = view.interactions.compactMap { $0 as? UIContextMenuInteraction }
            if let button = view as? UIButton {
                let own = button.contextMenuInteraction ?? interactions.first
                found.append((Holder(view: button, interaction: own), top))
            } else {
                for interaction in interactions {
                    found.append((Holder(view: view, interaction: interaction), top))
                }
            }
        }
        return found.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// The configuration the holder's interaction would open, asked where the header's Filter
    /// button is drawn whenever that point is inside it: one interaction can answer for a whole
    /// hosting view by location.
    /// `at` asks at that point instead (`tileRows`).
    private static func configuration(
        of holder: Holder, at asked: CGPoint? = nil
    ) -> UIContextMenuConfiguration? {
        guard let interaction = holder.interaction else { return nil }
        let view = holder.view
        var point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if let asked {
            point = asked
        } else if let window = view.window, let filter = filterFrame(in: window) {
            let inside = view.convert(CGPoint(x: filter.midX, y: filter.midY), from: window)
            if view.bounds.contains(inside) { point = inside }
        }
        return interaction.delegate?.contextMenuInteraction(
            interaction, configurationForMenuAtLocation: point)
    }

    private static func menu(of holder: Holder, at asked: CGPoint? = nil) -> UIMenu? {
        typealias Provider = @convention(block) ([UIMenuElement]) -> UIMenu?
        let button = holder.view as? UIButton
        if let menu = button?.menu, !leaves(menu).isEmpty { return menu }
        // A button that builds its menu as it is about to open hears this event first, as UIKit
        // sends it on the tap that opens the menu.
        button?.sendActions(for: .menuActionTriggered)
        if let menu = button?.menu, !leaves(menu).isEmpty { return menu }
        guard let configuration = configuration(of: holder, at: asked) else { return nil }
        if let interaction = holder.interaction, let button {
            // Or as the menu is displayed: told, read, then told it ended.
            interaction.delegate?.contextMenuInteraction?(
                interaction, willDisplayMenuFor: configuration, animator: nil)
            let shown = button.menu
            interaction.delegate?.contextMenuInteraction?(
                interaction, willEndFor: configuration, animator: nil)
            if let shown, !leaves(shown).isEmpty { return shown }
        }
        var type: AnyClass? = Swift.type(of: configuration)
        while let next = type, next != NSObject.self {
            for (name, encoding) in CollectionScreenTests.ivarList(of: next) {
                guard encoding == "@?", name.lowercased().contains("action") else { continue }
                let found = CollectionScreenTests.ivar(named: name, of: configuration)
                guard let block = found as AnyObject?, !(block is NSNull) else { continue }
                if let menu = unsafeBitCast(block, to: Provider.self)([]) { return menu }
            }
            type = class_getSuperclass(next)
        }
        return nil
    }

    private static func ivarNames(of object: AnyObject) -> [String] {
        var names: [String] = []
        var type: AnyClass? = Swift.type(of: object)
        while let next = type, next != NSObject.self {
            names += CollectionScreenTests.ivarList(of: next).map { "\($0.name):\($0.encoding)" }
            type = class_getSuperclass(next)
        }
        return names
    }

    /// A menu element's kind and title, and a menu's children one level down.
    private static func summary(_ element: UIMenuElement) -> String {
        guard let menu = element as? UIMenu else {
            if let deferred = element as? UIDeferredMenuElement {
                return "deferred\(ivarNames(of: deferred))"
            }
            return "\(type(of: element))(\(title(element)))"
        }
        return "menu[\(menu.children.map(summary).joined(separator: ","))]"
    }

    /// Where the element read out as "Filter" is, in the window's coordinates.
    private static func filterFrame(in window: UIWindow) -> CGRect? {
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object is UITabBar { continue }
            if object.accessibilityLabel == "Filter" {
                return window.convert(object.accessibilityFrame, from: nil)
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    private static func leaves(_ element: UIMenuElement?) -> [UIMenuElement] {
        guard let element else { return [] }
        if let menu = element as? UIMenu { return menu.children.flatMap(leaves) }
        if let deferred = element as? UIDeferredMenuElement {
            return CollectionScreenTests.provided(by: deferred).flatMap(leaves)
        }
        return [element]
    }

    private static func title(_ element: UIMenuElement) -> String {
        (element as? UIAction)?.title ?? (element as? UICommand)?.title ?? "?"
    }
}

/// "Captured by me" and Visibility pressed in the Library's own filter menu (MEMNG-787),
/// hosted in the real `MainTabView` over a real `SessionStore` and the real generated client.
/// The store's setters and the header lookup are held in MemosCoreTests; what only a hosted
/// screen shows is that the menu's rows reach them — the list read, the day buckets read under
/// the same query, and the grid and its heading drawn from those two answers.
///
/// In this suite for the reason `MediaLibrarySegmentTests` is: it installs the loader's
/// transport, process-wide, and the suite is serialized.
extension MediaImageLoaderTests {
    private func audienceSession(_ transport: AudienceTransport) -> SessionStore {
        SessionStore(
            credentials: AudienceCredentials(),
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

    /// On the test host's own window scene, as `MediaLibrarySegmentTests.sceneWindow` explains.
    private static func audienceWindow() -> UIWindow {
        let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        guard let scene = scene as? UIWindowScene else { return UIWindow(frame: frame) }
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    /// The value the day heading reads out, or nil while it is not on screen.
    private static func audienceHeading(in window: UIWindow) -> String? {
        var stack: [Any] = [window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            // The system tab bar is hidden under the dock but keeps its items' labels.
            if object is UITabBar { continue }
            if object.accessibilityLabel == AudienceWire.heading {
                return object.accessibilityValue
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// The tiles on screen and the count their heading reads, for a failure's message.
    private static func drawn(in window: UIWindow) -> String {
        "\(TripProbe.tiles(in: window)) under \(audienceHeading(in: window) ?? "no heading")"
    }

    /// Lays the window out until `condition` holds, or about five seconds have passed.
    private func audienceUntil(_ window: UIWindow, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            window.setNeedsLayout()
            window.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    @Test("the Library opens on Captured by me; unchecked, mine and Just us each read and show")
    func capturedByMeInTheLibrary() async {
        let wire = AudienceTransport()
        await withTransport(AudiencePictures()) {
            let session = audienceSession(wire)
            await session.enteredForeground()
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_aud")
            #expect(
                session.state.user?.subject == AudienceWire.subject, "precondition: signed in")
            let window = Self.audienceWindow()
            window.rootViewController = UIHostingController(
                rootView: MainTabView(opening: .library).environment(session))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            // The Library opens on Captured by me (MEMNG-919): my own pictures and their counts.
            let everybody = Set(["aud-a", "aud-b", "aud-c"])
            let landed = await audienceUntil(window) {
                Set(TripProbe.tiles(in: window)) == ["aud-a", "aud-b"]
                    && Self.audienceHeading(in: window) == bucketCountLabel(7)
            }
            #expect(landed, "the opening grid drew \(Self.drawn(in: window))")
            let firstList = wire.reads(AudienceWire.listAttachments).first
            #expect(firstList?["mine"] == "true", "the Library did not open on Captured by me")
            #expect(firstList?["visibility"] == nil, "control: the first list named a visibility")

            // Unchecked on purpose: everyone's pictures, everyone's counts.
            let opened = wire.reads(AudienceWire.listAttachments).count
            #expect(
                LibraryMenuProbe.perform("Captured by me", in: window),
                "no Captured by me row: \(LibraryMenuProbe.describe(window))")
            let widened = await audienceUntil(window) {
                Set(TripProbe.tiles(in: window)) == everybody
                    && Self.audienceHeading(in: window) == bucketCountLabel(12)
            }
            #expect(widened, "unchecking drew \(Self.drawn(in: window))")
            let everyLists = wire.reads(AudienceWire.listAttachments).dropFirst(opened)
            #expect(everyLists.last?["mine"] == nil, "unchecking still read mine")

            // Captured by me, pressed as the menu would press it.
            let lists = wire.reads(AudienceWire.listAttachments).count
            let days = wire.reads(AudienceWire.buckets).count
            #expect(
                LibraryMenuProbe.perform("Captured by me", in: window),
                "no Captured by me row: \(LibraryMenuProbe.describe(window))")
            let mine = await audienceUntil(window) {
                Set(TripProbe.tiles(in: window)) == ["aud-a", "aud-b"]
                    && Self.audienceHeading(in: window) == bucketCountLabel(7)
            }
            #expect(mine, "Captured by me drew \(Self.drawn(in: window))")
            let mineLists = wire.reads(AudienceWire.listAttachments).dropFirst(lists)
            let mineDays = wire.reads(AudienceWire.buckets).dropFirst(days)
                .filter { $0["size"] == "day" }
            #expect(mineLists.last?["mine"] == "true", "the list was not read as mine")
            #expect(mineLists.last?["visibility"] == nil, "the list named a visibility")
            #expect(mineDays.last?["mine"] == "true", "the day counts were not read as mine")
            #expect(mineDays.last?["visibility"] == nil, "the day counts named a visibility")

            // Visibility → Just us, with Captured by me still on.
            let lists2 = wire.reads(AudienceWire.listAttachments).count
            let days2 = wire.reads(AudienceWire.buckets).count
            #expect(
                LibraryMenuProbe.perform("Just us", in: window),
                "no Just us row: \(LibraryMenuProbe.describe(window))")
            let justUs = await audienceUntil(window) {
                TripProbe.tiles(in: window) == ["aud-a"]
                    && Self.audienceHeading(in: window) == bucketCountLabel(3)
            }
            #expect(justUs, "Just us drew \(Self.drawn(in: window))")
            let usLists = wire.reads(AudienceWire.listAttachments).dropFirst(lists2)
            let usDays = wire.reads(AudienceWire.buckets).dropFirst(days2)
                .filter { $0["size"] == "day" }
            #expect(usLists.last?["mine"] == "true", "Just us dropped mine from the list")
            #expect(
                usLists.last?["visibility"] == "PROTECTED", "the list was not read as Just us")
            #expect(usDays.last?["mine"] == "true", "Just us dropped mine from the day counts")
            #expect(
                usDays.last?["visibility"] == "PROTECTED",
                "the day counts were not read as Just us")
        }
    }
}
