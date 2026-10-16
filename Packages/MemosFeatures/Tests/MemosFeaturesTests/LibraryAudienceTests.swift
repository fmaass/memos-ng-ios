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

/// "Captured by me" and Visibility pressed in the Library's own filter menu (MEMNG-787), hosted in
/// the real `MainTabView` over a real `SessionStore` and the real generated client: the store's
/// setters and the header lookup are held in MemosCoreTests, and what only a hosted screen shows is
/// that the menu's rows reach them — the list read, the day buckets read under the same query, and
/// the grid and its heading drawn from those two answers.
///
/// In this suite for the reason `MediaLibrarySegmentTests` is: it installs the loader's transport,
/// process-wide, and the suite is serialized.
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

    @Test("the Library's Captured by me and Just us read the list and the day counts; both show")
    func capturedByMeInTheLibrary() async {
        let wire = AudienceTransport()
        await withTransport(AudiencePictures()) {
            let session = audienceSession(wire)
            await session.enteredForeground()
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_aud")
            #expect(session.state.user?.subject == AudienceWire.subject, "precondition: signed in")
            let window = Self.audienceWindow()
            window.rootViewController = UIHostingController(
                rootView: MainTabView(opening: .library).environment(session))
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let everybody = Set(["aud-a", "aud-b", "aud-c"])
            let landed = await audienceUntil(window) {
                Set(TripProbe.tiles(in: window)) == everybody
                    && Self.audienceHeading(in: window) == bucketCountLabel(12)
            }
            #expect(landed, "control: the unfiltered grid drew \(Self.drawn(in: window))")
            let firstList = wire.reads(AudienceWire.listAttachments).first
            #expect(firstList?["mine"] == nil, "control: the first list asked for mine")
            #expect(firstList?["visibility"] == nil, "control: the first list named a visibility")

            // Captured by me, pressed as the menu would press it.
            let lists = wire.reads(AudienceWire.listAttachments).count
            let days = wire.reads(AudienceWire.buckets).count
            #expect(TripMenuProbe.perform("Captured by me", in: window), "no Captured by me row")
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
            #expect(TripMenuProbe.perform("Just us", in: window), "no Just us row")
            let justUs = await audienceUntil(window) {
                TripProbe.tiles(in: window) == ["aud-a"]
                    && Self.audienceHeading(in: window) == bucketCountLabel(3)
            }
            #expect(justUs, "Just us drew \(Self.drawn(in: window))")
            let usLists = wire.reads(AudienceWire.listAttachments).dropFirst(lists2)
            let usDays = wire.reads(AudienceWire.buckets).dropFirst(days2)
                .filter { $0["size"] == "day" }
            #expect(usLists.last?["mine"] == "true", "Just us dropped mine from the list")
            #expect(usLists.last?["visibility"] == "PROTECTED", "the list was not read as Just us")
            #expect(usDays.last?["mine"] == "true", "Just us dropped mine from the day counts")
            #expect(
                usDays.last?["visibility"] == "PROTECTED",
                "the day counts were not read as Just us")
        }
    }
}
