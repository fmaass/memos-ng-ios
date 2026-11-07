import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import os

@testable import MemosFeatures

/// A guest memo in a trip's Journal (MEMNG-1263, MEMNG-1264): it opens on the trip, never on the
/// Timeline that leaves guest memos out, and every signed-in member can edit it there — remove its
/// pictures or delete it — but never add to it.
@MainActor
@Suite("Guest memos in the Journal")
struct GuestJournalTests {
    private func picture(_ uid: String) -> MemoAttachment {
        let file = "https://memos.example.invalid/api/attachments/\(uid)"
        return MemoAttachment(
            uid: uid, mime: "image/jpeg", status: .ready, width: 1000, height: 800,
            thumbnailURL: URL(string: "\(file)/thumb"), previewURL: URL(string: "\(file)/mobile"),
            webURL: URL(string: "\(file)/web"))
    }

    /// A guest memo the signed-in member did not issue the pass for: `mine` is false.
    private func guestMemo(_ attachments: [MemoAttachment], mine: Bool = false) -> Memo {
        var memo = MemoFixture.memo(
            uid: "g1", owner: "fabian", content: "From the beach", mine: mine,
            attachments: attachments)
        memo.guest = MemoGuest(contributorName: "iPhone", passUid: "pass-1")
        return memo
    }

    private func household(_ attachments: [MemoAttachment], mine: Bool = true) -> Memo {
        MemoFixture.memo(
            uid: "h1", content: "Tram up to the castle", mine: mine, attachments: attachments)
    }

    @Test("a guest memo's text opens the viewer on its first picture, never the Timeline")
    func aGuestMemoOpensTheViewer() throws {
        let pdf = MemoAttachment(uid: "d", mime: "application/pdf", status: .ready)
        let memo = guestMemo([pdf, picture("a"), picture("b")])
        let opening = TripView.journalOpening(nil, of: memo)
        guard case .viewer(let selection) = opening else {
            Issue.record("a guest memo's text opened \(opening)")
            return
        }
        #expect(selection.startPage.id == "a", "opened on \(selection.startPage.id)")
        #expect(selection.pages.map(\.id) == ["a", "b"])
        // Its photo opens the viewer too, at the one tapped.
        let both = guestMemo([picture("a"), picture("b")])
        let tapped = TripView.journalOpening(picture("b"), of: both)
        guard case .viewer(let at) = tapped else {
            Issue.record("a guest memo's photo opened \(tapped)")
            return
        }
        #expect(at.startPage.id == "b")
    }

    @Test("a guest memo with nothing the viewer shows opens its detail here, never the Timeline")
    func aGuestMemoWithoutPicturesOpensItsDetail() {
        #expect(TripView.journalOpening(nil, of: guestMemo([])) == .detail("g1"))
        let pdf = MemoAttachment(uid: "d", mime: "application/pdf", status: .ready)
        #expect(TripView.journalOpening(nil, of: guestMemo([pdf])) == .detail("g1"))
        #expect(TripView.journalOpening(pdf, of: guestMemo([pdf])) == .detail("g1"))
    }

    @Test("a household memo's text still jumps to the Timeline")
    func aHouseholdMemoStillJumps() {
        #expect(TripView.journalOpening(nil, of: household([picture("a")])) == .memo("h1"))
        #expect(TripView.journalOpening(nil, of: household([])) == .memo("h1"))
        let pdf = MemoAttachment(uid: "d", mime: "application/pdf", status: .ready)
        #expect(TripView.journalOpening(pdf, of: household([pdf])) == .memo("h1"))
    }

    @Test("the Journal's Edit: a guest memo's card offers it, mine or not; a household card never")
    func theEditMenuRule() {
        #expect(TripView.journalEdits(guestMemo([])))
        #expect(TripView.journalEdits(guestMemo([], mine: true)))
        #expect(!TripView.journalEdits(household([])))
        #expect(!TripView.journalEdits(household([], mine: false)))
    }

    @Test("a looked-up guest memo's Info sheet offers no Show memo; a household memo's does")
    func showMemoIsHiddenForAGuestMemo() throws {
        let guest = try #require(MediaInfoRows.memoCard(.lookup("g1"), looked: guestMemo([])))
        #expect(!guest.showable, "Show memo would jump to a Timeline without the memo")
        let own = try #require(MediaInfoRows.memoCard(.lookup("h1"), looked: household([])))
        #expect(own.showable, "control: a household memo lost Show memo")
    }

    /// The viewer's ⋯ is the other way to the Timeline: a guest memo's pictures name their memo
    /// (the Info sheet reads it), so the page alone would offer Show Memo.
    @Test("a guest memo's picture offers no Show Memo in the viewer; a household memo's does")
    func theViewerOffersNoShowMemoForAGuestMemo() throws {
        func rows(_ memo: Memo) throws -> [MediaTileAction] {
            guard case .viewer(let selection) = TripView.journalOpening(picture("a"), of: memo)
            else {
                Issue.record("\(memo.uid)'s picture opened no viewer")
                return []
            }
            let source = TripView.journalViewerSource(for: selection, memos: [memo])
            #expect(selection.startPage.memoUID == memo.uid, "the page lost its memo")
            guard
                case .menu(let actions) = MediaViewerView.control(
                    for: selection.startPage, in: source, albums: true,
                    showsMemo: selection.showsMemo)
            else { return [] }
            return actions
        }
        let guest = try rows(guestMemo([picture("a")]))
        #expect(!guest.contains(.showMemo(uid: "g1")), "a guest page offers Show Memo: \(guest)")
        #expect(guest.contains(.addToAlbum(uid: "a")), "control: the guest page lost its menu")
        let own = try rows(household([picture("a")]))
        #expect(own.contains(.showMemo(uid: "h1")), "control: a household page lost Show Memo")
    }

    @Test("a guest memo edits for every member, removes pictures, and adds none")
    func theDetailRules() {
        let guest = guestMemo([picture("a")])
        #expect(MemoDetailPresentation.editMode(for: guest) != nil, "no Edit for a member")
        #expect(MemoDetailPresentation.attachmentActions(for: guest) == [.delete])
        #expect(!MemoDetailPresentation.addsMedia(to: guest))
        // Archive stays the issuer's: the owner gave members edit and delete, nothing more.
        #expect(MemoDetailPresentation.archiveAction(for: guest) == nil)
        let theirs = household([picture("a")], mine: false)
        #expect(MemoDetailPresentation.editMode(for: theirs) == nil, "another's memo edits")
        #expect(MemoDetailPresentation.attachmentActions(for: theirs).isEmpty)
        #expect(MemoDetailPresentation.addsMedia(to: household([])))
    }

    @Test("a guest memo's detail shows the pencil to a member who did not issue the pass")
    func theDetailShowsEdit() {
        let memo = guestMemo([])
        let labels = ScreenProbe.labels(
            of: MemoDetailView(uid: memo.uid, initial: memo, timeline: TimelineStore()))
        #expect(labels.contains { $0.contains("From the beach") }, "control: \(labels)")
        #expect(labels.contains("Edit memo"), "no Edit on a guest memo: \(labels)")
    }

    @Test("a guest memo's edit sheet has no photos pill; a household edit keeps it")
    func theEditSheetAddsNothing() {
        let mode = ComposeView.Mode.edit(
            uid: "g1", content: "From the beach",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000), attachments: [])
        let sheet = ComposeView(mode: mode, addsMedia: false) { _ in .saved }
        let guest = ScreenProbe.labels(of: sheet)
        #expect(guest.contains { $0.contains("Save") }, "control: the probe saw no sheet: \(guest)")
        #expect(!guest.contains("Add photos or videos"), "a guest memo's edit adds: \(guest)")
        #expect(guest.contains("Memo date"), "the date row went with the pill: \(guest)")
        let own = ScreenProbe.labels(of: ComposeView(mode: mode) { _ in .saved })
        #expect(own.contains("Add photos or videos"), "a household edit lost the pill: \(own)")
    }

    /// The timeline never holds a guest memo, so the detail opened from the Journal shows its own
    /// copy: a picture deleted there must leave that copy, or it stays on screen.
    @Test("a picture deleted from a guest memo's detail leaves the detail")
    func aDeletedPictureLeavesTheGuestDetail() async throws {
        let server = GuestPictureServer(attachments: ["ga", "gb"])
        let base = URL(string: "https://memos.example.invalid")!
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_guest" },
            transport: server)
        let handle = SessionHandle(client: client, generation: 1)
        let timeline = TimelineStore()
        let initial = try #require(
            await timeline.fetchMemo(uid: GuestPictureServer.memoUID, using: handle, baseURL: base))
        #expect(initial.guest != nil, "precondition: the memo read is not a guest's")
        #expect(timeline.memos.isEmpty, "precondition: the timeline holds the memo")
        let detached = DetachedMemo(uid: initial.uid)
        func shown() -> [String] {
            MemoDetailView.shown(
                uid: initial.uid, timeline: timeline, detached: detached, initial: initial
            ).attachments.map(\.uid)
        }
        #expect(shown() == ["ga", "gb"], "precondition: the detail opened without both pictures")

        var heard: [Bool] = []
        let deleted = await MemoDetailView.deletePicture(
            "ga", of: initial.uid, timeline: timeline, detached: detached, using: handle,
            reading: IssuingSession(handle: { handle }, baseURL: { base })
        ) { heard.append($0) }

        #expect(deleted, "the delete did not land")
        #expect(heard == [true], "the feedback heard \(heard)")
        #expect(server.deletes == ["ga"], "the wire saw \(server.deletes)")
        #expect(shown() == ["gb"], "the deleted picture stayed on the detail: \(shown())")
        #expect(server.memoReads == 2, "the detail did not read its memo again exactly once")
    }

    /// The timeline drops a save's answer for a memo it does not hold, so a guest memo's detail
    /// must take the saved words itself: the next Edit starts from what the screen shows, and a
    /// second save sends the whole text again.
    @Test("a second edit on a guest memo's detail keeps the first edit's words")
    func aSecondEditKeepsTheFirst() async throws {
        let server = GuestPictureServer(attachments: ["ga"])
        let base = URL(string: "https://memos.example.invalid")!
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: base), token: { "memos_pat_guest" },
            transport: server)
        let handle = SessionHandle(client: client, generation: 1)
        let timeline = TimelineStore()
        let initial = try #require(
            await timeline.fetchMemo(uid: GuestPictureServer.memoUID, using: handle, baseURL: base))
        #expect(timeline.memos.isEmpty, "precondition: the timeline holds the memo")
        let detached = DetachedMemo(uid: initial.uid)
        let reading = IssuingSession(handle: { handle }, baseURL: { base })
        func shown() -> Memo {
            MemoDetailView.shown(
                uid: initial.uid, timeline: timeline, detached: detached, initial: initial)
        }
        /// What the pencil opens on the memo the detail shows, saved with `change` applied.
        func edit(_ change: (inout ComposeSubmission) -> Void) async throws -> ComposeOutcome {
            let mode = try #require(MemoDetailPresentation.editMode(for: shown()))
            guard case .edit(let uid, let content, let createdAt, _, _) = mode else {
                Issue.record("the pencil opened \(mode)")
                return .failed(.rejection)
            }
            var submission = ComposeSubmission(
                content: content, visibility: nil, createdAt: createdAt)
            change(&submission)
            return await MemoDetailView.saveEdit(
                submission, of: uid, createdAt: createdAt, timeline: timeline,
                detached: detached, through: nil, composedUnder: nil, using: handle,
                reading: reading)
        }

        let first = try await edit { $0.content = "Sunset at the beach" }
        #expect(first == .saved)
        #expect(shown().content == "Sunset at the beach", "the detail kept \(shown().content)")
        let moved = initial.createdAt.addingTimeInterval(-3600)
        let second = try await edit { $0.createdAt = moved }
        #expect(second == .saved)
        #expect(server.patches.count == 2, "the wire saw \(server.patches.count) saves")
        #expect(
            server.content == "Sunset at the beach",
            "the second save wrote the old words back: \(server.content)")
        #expect(server.patches.last?["created_at"] != nil, "the date change was not sent")
    }
}

/// One guest memo on the server, read by uid through the real generated client, whose pictures a
/// DELETE takes away: every later read answers without them.
nonisolated final class GuestPictureServer: ClientTransport, Sendable {
    static let memoUID = "g-detail"

    private struct State {
        var attachments: [String]
        var content = "From the beach"
        var deletes: [String] = []
        var patches: [[String: String]] = []
        var memoReads = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(attachments: [String]) {
        state = OSAllocatedUnfairLock(uncheckedState: State(attachments: attachments))
    }

    var deletes: [String] { state.withLock { $0.deletes } }
    var memoReads: Int { state.withLock { $0.memoReads } }
    var content: String { state.withLock { $0.content } }
    /// Each PATCH body's string fields, in the order they arrived.
    var patches: [[String: String]] { state.withLock { $0.patches } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        switch operationID {
        case "get_memo_api_memos__uid__get":
            let (attachments, content) = state.withLock {
                $0.memoReads += 1
                return ($0.attachments, $0.content)
            }
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(Self.memo(attachments: attachments, content: content)))
        case "patch_memo_api_memos__uid__patch":
            var data = Data()
            if let body { data = try await Data(collecting: body, upTo: 1 << 20) }
            let fields = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let strings = fields.compactMapValues { $0 as? String }
            let (attachments, content) = state.withLock {
                $0.patches.append(strings)
                if let content = strings["content"] { $0.content = content }
                return ($0.attachments, $0.content)
            }
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(Self.memo(attachments: attachments, content: content)))
        case "delete_attachment_api_attachments__uid__delete":
            let uid = String((request.path ?? "").split(separator: "/").last ?? "")
            state.withLock {
                $0.deletes.append(uid)
                $0.attachments.removeAll { $0 == uid }
            }
            return (HTTPResponse(status: .noContent), nil)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    private static func memo(attachments: [String], content: String) -> String {
        let refs = attachments.map { ResigningMemoServer.attachment(uid: $0, sig: "new") }
        return """
            {"uid":"\(memoUID)","owner":"fabian","mine":false,"content":"\(content)",\
            "visibility":"PRIVATE","pinned":false,"created_at":"2026-03-13T19:00:00Z",\
            "updated_at":"2026-03-13T19:00:00Z","archived_at":null,"tags":["portugal2026"],\
            "attachments":[\(refs.joined(separator: ","))],\
            "guest":{"contributor_name":"iPhone","pass_uid":"pass-1"}}
            """
    }
}
