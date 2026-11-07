import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// A guest memo names the person who sent it, never the account that owns it (MEMNG-1164; the
/// contributor chip and Info row of MEMNG-1007 are this same label). The pass's account owns every
/// memo a guest sends in, so a card reading `owner` would put the household's name on a guest's
/// words.
@MainActor
@Suite("Guest memos say Guest")
struct GuestContributorTests {
    static func guestMemo(_ name: String?, uid: String = "g1") -> Memo {
        var memo = MemoFixture.memo(uid: uid, owner: "fabian", content: "From the beach")
        memo.guest = MemoGuest(contributorName: name, passUid: "pass-1")
        return memo
    }

    /// The owner's decision of 2026-11-06 (MEMNG-1164): the plain word "Guest", never the name the
    /// guest's device sent, until guests can type their own (MEMNG-1265).
    @Test("the label: 'Guest' whatever name the device sent, the owner otherwise")
    func theLabel() {
        for name in ["Anna", " Anna ", "iPhone", nil, "  "] {
            #expect(MemoCardPresentation.displayName(for: Self.guestMemo(name)) == "Guest")
            // The avatar's letter follows the word: "G", never the device's or the owner's.
            #expect(MemoCardPresentation.avatarName(for: Self.guestMemo(name)) == "Guest")
        }
        let own = MemoFixture.memo(owner: "fabian@example.invalid")
        #expect(MemoCardPresentation.displayName(for: own) == "fabian")
        #expect(MemoCardPresentation.avatarName(for: own) == "fabian@example.invalid")
        // The Guests sheet still tells devices apart by the name each sent.
        #expect(MemoCardPresentation.guestName(nil) == "A guest")
        #expect(MemoCardPresentation.guestName("Ben") == "Ben")
    }

    @Test("a guest memo's card says Guest, not the owner or the device; an owner's card the owner")
    func theCardNamesTheContributor() {
        let guest = ScreenProbe.labels(of: MemoCard(memo: Self.guestMemo("Anna")))
        #expect(guest.contains { $0.contains("Guest") }, "no Guest: \(guest)")
        #expect(!guest.contains { $0.contains("fabian") }, "the owner's name is on it: \(guest)")
        #expect(!guest.contains { $0.contains("Anna") }, "the device's name is on it: \(guest)")

        let nameless = ScreenProbe.labels(of: MemoCard(memo: Self.guestMemo(nil)))
        #expect(nameless.contains { $0.contains("Guest") }, "\(nameless)")
        #expect(!nameless.contains { $0.contains("fabian") }, "\(nameless)")

        let own = ScreenProbe.labels(of: MemoCard(memo: MemoFixture.memo(owner: "fabian")))
        #expect(own.contains { $0.contains("fabian") }, "control: the owner's card: \(own)")
        #expect(!own.contains { $0.contains("Guest") }, "an owner's card says Guest: \(own)")
    }

    @Test("a guest memo's detail names the contributor, not the owner")
    func theDetailNamesTheContributor() {
        let memo = Self.guestMemo("Anna")
        let labels = ScreenProbe.labels(
            of: MemoDetailView(uid: memo.uid, initial: memo, timeline: TimelineStore()))
        #expect(labels.contains { $0.contains("Guest") }, "no Guest: \(labels)")
        #expect(!labels.contains { $0.contains("fabian") }, "the owner's name is on it: \(labels)")
        #expect(!labels.contains { $0.contains("Anna") }, "the device's name is on it: \(labels)")
    }

    @Test("the Info sheet carries a contributor row for a guest memo, and none for the owner's")
    func theInfoSheetNamesTheContributor() throws {
        let guest = try #require(
            MediaInfoRows.memoCard(.carried(Self.guestMemo("Anna")), looked: nil))
        #expect(guest.contributor == "Guest")
        let nameless = try #require(
            MediaInfoRows.memoCard(.carried(Self.guestMemo(nil)), looked: nil))
        #expect(nameless.contributor == "Guest")
        // A looked-up memo carries it the same way.
        let looked = try #require(
            MediaInfoRows.memoCard(.lookup("g1"), looked: Self.guestMemo("Anna")))
        #expect(looked.contributor == "Guest")
        let own = try #require(
            MediaInfoRows.memoCard(.carried(MemoFixture.memo(owner: "fabian")), looked: nil))
        #expect(own.contributor == nil, "an owner's memo grew a contributor row")
    }

    @Test("the Info sheet over a guest memo's picture draws the contributor row")
    func theInfoSheetDrawsTheContributor() throws {
        let files = "https://memos.example.invalid/api/attachments/a"
        let picture = MemoAttachment(
            uid: "a", mime: "image/jpeg", status: .ready, width: 1000, height: 800,
            thumbnailURL: URL(string: "\(files)/thumb"), previewURL: URL(string: "\(files)/mobile"),
            webURL: URL(string: "\(files)/web"))
        let page = try #require(MediaViewerPresentation.pages(for: [picture]).first)
        func drawn(_ memo: Memo) -> UIWindow {
            let store = MediaContextStore()
            let sheet = MediaInfoSheet(
                page: page, context: MediaViewerContext.resolve(page, carried: memo),
                store: store, opening: store.open("a"))
            let host = UIHostingController(rootView: sheet)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.rootViewController = host
            window.isHidden = false
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.view.layoutIfNeeded()
            return window
        }

        let guest = drawn(Self.guestMemo("Anna"))
        defer { guest.isHidden = true }
        #expect(PressProbe.reads("Guest", in: guest), "no contributor row")
        #expect(!PressProbe.reads("Anna", in: guest), "the device's name is on the sheet")
        #expect(PressProbe.reads("Contributor", in: guest), "no contributor label")
        let own = drawn(MemoFixture.memo(owner: "fabian"))
        defer { own.isHidden = true }
        #expect(PressProbe.reads("Visibility", in: own), "control: the memo section drew")
        #expect(!PressProbe.reads("Contributor", in: own), "an owner's memo drew a contributor")
    }

    /// The home timeline end to end: the real store over the real generated client, a server that
    /// answers a guest memo anyway, and the card that memo becomes.
    @Test("the home timeline asks for no guests; a guest memo that arrives names its contributor")
    func theHomeTimelineLabelsAGuestMemo() async throws {
        let server = GuestLeakServer()
        let base = URL(string: "https://memos.example.invalid")!
        let handle = SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base),
                token: { "memos_pat_guest" }, transport: server),
            generation: 1)
        let timeline = TimelineStore()

        await timeline.refresh(using: handle, baseURL: base)

        let sent = server.paths
        #expect(sent.count == 1, "\(sent)")
        for path in sent {
            let names = URLComponents(string: path)?.queryItems?.map(\.name) ?? []
            #expect(!names.contains("guest"), "the home timeline asked about guests: \(path)")
        }
        let memo = try #require(timeline.memos.first { $0.uid == "g1" })
        let labels = ScreenProbe.labels(of: MemoCard(memo: memo))
        #expect(labels.contains { $0.contains("Guest") }, "no Guest: \(labels)")
        #expect(!labels.contains { $0.contains("fabian") }, "the owner's name is on it: \(labels)")
    }
}

/// A memo list that holds one guest memo whatever it is asked — a server that leaks one — and
/// keeps every path it was asked on.
nonisolated private final class GuestLeakServer: ClientTransport, @unchecked Sendable {
    static let list = "list_memos_api_memos_get"
    static let memo = """
        {"uid":"g1","owner":"fabian","mine":true,"content":"From the beach",\
        "visibility":"PRIVATE","pinned":false,"created_at":"2026-08-23T09:00:00Z",\
        "updated_at":"2026-08-23T09:00:00.443000Z","archived_at":null,"tags":[],\
        "attachments":[],"guest":{"contributor_name":"Anna","pass_uid":"pass-1"}}
        """

    private let lock = NSLock()
    private var asked: [String] = []

    var paths: [String] { lock.withLock { asked } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == Self.list else {
            return (HTTPResponse(status: .internalServerError), nil)
        }
        lock.withLock { asked.append(request.path ?? "") }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let page = #"{"items":[\#(Self.memo)],"nextCursor":null,"totalCount":null}"#
        return (response, HTTPBody(page))
    }
}
