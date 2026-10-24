import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

@testable import MemosFeatures

/// The server an Add talks to: every inclusion's path and body kept as it was sent, each answered
/// `added` for every uid it names. Anything else is a 500, so a stray request fails the run.
nonisolated private final class InclusionServer: ClientTransport, @unchecked Sendable {
    static let inclusion = "include_attachments_api_collections__uid__attachments_post"

    private let lock = NSLock()
    private var sentRequests: [(path: String, uids: [String])] = []
    private var others: [String] = []

    var inclusions: [(path: String, uids: [String])] { lock.withLock { sentRequests } }
    var strays: [String] { lock.withLock { others } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard operationID == Self.inclusion else {
            lock.withLock { others.append(operationID) }
            return (HTTPResponse(status: .internalServerError), nil)
        }
        let sent = try await Data(collecting: body ?? HTTPBody(), upTo: 1 << 20)
        let object = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
        let uids = object?["attachmentUids"] as? [String] ?? []
        lock.withLock { sentRequests.append((request.path ?? "", uids)) }
        let results = uids.map { #"{"attachmentUid":"\#($0)","outcome":"added"}"# }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(#"{"results":[\#(results.joined(separator: ","))]}"#))
    }
}

/// Select mode's Add and its Add to collection sheet (MEMNG-855), held as values, and what a
/// trip's row sends, through the real store and the real generated client.
@MainActor
@Suite("Library select mode, Add to collection")
struct AddToCollectionTests {
    private static let day = Date(timeIntervalSince1970: 1_773_000_000)

    private static func trip(_ uid: String, _ title: String) -> Trip {
        Trip(
            uid: uid, title: title, tag: title.lowercased(), spanStart: nil, spanEnd: nil,
            cover: nil, memberCount: 2, createdAt: day, updatedAt: day)
    }

    private static let portugal = trip("trip-1", "Portugal")
    private static let family = trip("trip-2", "Family")

    @Test("the sheet lists the tagged trips under Trips, in order, and no album section")
    func theTripsSection() {
        let sections = AddToCollection.sections(
            memos: ["m1"], free: true, tagged: [Self.portugal, Self.family])

        #expect(sections.map(\.kind) == [.trips], "an album section before WPN-29")
        #expect(sections.map(\.header) == ["Trips"])
        let rows = sections.first?.rows ?? []
        #expect(rows.map(\.id) == ["add-to-trip-1", "add-to-trip-2"])
        #expect(rows.map(\.title) == ["Portugal", "Family"])
        #expect(rows.map(\.target) == [.trip(Self.portugal), .trip(Self.family)])
        #expect(rows.allSatisfy { !$0.disabled }, "control: the rows are live")
    }

    @Test("the trips' rows are off with nothing of mine chosen or the actions busy")
    func theRowsDisabled() {
        let mineNone = AddToCollection.sections(memos: [], free: true, tagged: [Self.portugal])
        #expect(mineNone.first?.rows.map(\.disabled) == [true])
        let busy = AddToCollection.sections(memos: ["m1"], free: false, tagged: [Self.portugal])
        #expect(busy.first?.rows.map(\.disabled) == [true])
    }

    @Test("with no tagged trip the sheet has no section at all")
    func noTrips() {
        #expect(AddToCollection.sections(memos: ["m1"], free: true, tagged: []).isEmpty)
    }

    @Test("Add is live only with a memo of mine chosen, the actions free and a tagged trip")
    func theAddRow() {
        func disabled(memos: [String], free: Bool, tagged: [Trip]) -> Bool {
            AddToCollection.addRow(memos: memos, free: free, tagged: tagged) {}.disabled
        }
        #expect(!disabled(memos: ["m1"], free: true, tagged: [Self.portugal]), "control")
        #expect(disabled(memos: [], free: true, tagged: [Self.portugal]), "nothing of mine")
        #expect(disabled(memos: ["m1"], free: false, tagged: [Self.portugal]), "busy")
        #expect(disabled(memos: ["m1"], free: true, tagged: []), "no tagged trip")

        var opened = 0
        let row = AddToCollection.addRow(memos: ["m1"], free: true, tagged: [Self.portugal]) {
            opened += 1
        }
        #expect(row.id == "add" && row.title == "Add" && row.children.isEmpty)
        row.action()
        #expect(opened == 1, "Add opens the sheet")
    }

    /// The client a test's Adds go out on, answered by `server`.
    private static func handle(_ server: InclusionServer) -> SessionHandle {
        SessionHandle(
            client: APIClientFactory.make(
                configuration: ServerConfiguration(baseURL: base),
                token: { "memos_pat_add" }, transport: server),
            generation: 1)
    }

    private static let base = URL(string: "https://memos.example.invalid")!

    /// A row pressed twice before the sheet has gone is the store's to serialise, not the
    /// sheet's: the second, identical Add joins the first, and one request goes on the wire.
    @Test("a trip's row pressed twice at once is one inclusion on the wire")
    func twoPressesOneRequest() async throws {
        let server = InclusionServer()
        let handle = Self.handle(server)
        let chosen = [MemoActionPicture(uid: "p1", memoUID: "m1", mine: true)]
        let row = try #require(
            AddToCollection.sections(memos: ["m1"], free: true, tagged: [Self.portugal])
                .first?.rows.first)
        let actions = MemoActionStore(trips: nil)

        // Two presses, each its own task on the main actor, as two taps' handlers are.
        let first = Task {
            await AddToCollection.send(
                row.target, chosen: chosen, actions: actions, using: handle, baseURL: Self.base)
        }
        let second = Task {
            await AddToCollection.send(
                row.target, chosen: chosen, actions: actions, using: handle, baseURL: Self.base)
        }
        let results = [await first.value, await second.value]

        #expect(server.inclusions.count == 1, "\(server.inclusions.count) inclusions")
        let added = MemoActionResult.finished(
            .init(action: .addToTrip("trip-1"), asked: 1, changed: 1))
        #expect(results == [added, added], "control: both presses report the one run")
    }

    /// The trip a row names gets ONE inclusion request naming exactly my chosen pictures that hang
    /// on a memo: another member's picture and an orphan are never sent, a picture chosen twice
    /// goes once, and nothing else goes on the wire.
    @Test("choosing a trip's row sends one inclusion of exactly the eligible pictures")
    func aRowSendsOneInclusion() async throws {
        let server = InclusionServer()
        let handle = Self.handle(server)
        let chosen = [
            MemoActionPicture(uid: "p1", memoUID: "m1", mine: true),
            MemoActionPicture(uid: "x1", memoUID: "m9", mine: false),
            MemoActionPicture(uid: "p2", memoUID: "m2", mine: true),
            MemoActionPicture(uid: "o1", memoUID: nil, mine: true),
            MemoActionPicture(uid: "p1", memoUID: "m1", mine: true),
        ]
        let sections = AddToCollection.sections(
            memos: MemoActionPicture.memos(of: chosen), free: true,
            tagged: [Self.family, Self.portugal])
        let row = try #require(sections.first?.rows.last)
        #expect(!row.disabled)

        let result = await AddToCollection.send(
            row.target, chosen: chosen, actions: MemoActionStore(trips: nil), using: handle,
            baseURL: Self.base)

        #expect(server.inclusions.count == 1, "one inclusion per collection")
        #expect(server.inclusions.first?.path == "/api/collections/trip-1/attachments")
        #expect(server.inclusions.first?.uids == ["p1", "p2"])
        #expect(server.strays.isEmpty, "a request besides the inclusion: \(server.strays)")
        #expect(
            result == .finished(.init(action: .addToTrip("trip-1"), asked: 4, changed: 2)))
    }
}
