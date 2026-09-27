import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

// MEMNG-587: a day tile of the Months view opens the All grid at that day.

private func instant(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso), "the fixture \(iso) did not parse")
}

private func row(_ uid: String, _ iso: String?) throws -> LibraryRow {
    LibraryRow(
        attachment: MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready),
        takenAt: try iso.map(instant),
        mine: true,
        filename: "\(uid).jpg"
    )
}

@Suite("firstRowIndex")
struct FirstRowIndexTests {
    private let zurich = "Europe/Zurich"

    @Test("a day found on the first page answers the first of its rows")
    func hitOnFirstPage() throws {
        let rows = [
            try row("a", "2026-09-14T10:00:00Z"),
            try row("b", "2026-09-13T10:00:00Z"),
            try row("c", "2026-09-13T08:00:00Z"),
        ]
        #expect(firstRowIndex(onDay: "2026-09-13", in: rows, timeZone: zurich) == 1)
    }

    /// The jump hands the function every row it has read so far, so an index on a later page is
    /// an index into the whole run, not into the page that brought it.
    @Test("a day found on a later page answers its place in every row read so far")
    func hitOnLaterPage() throws {
        let firstPage = [
            try row("a", "2026-09-20T10:00:00Z"),
            try row("b", "2026-09-19T10:00:00Z"),
            try row("c", "2026-09-18T10:00:00Z"),
        ]
        let secondPage = [
            try row("d", "2026-09-17T10:00:00Z"),
            try row("e", "2026-09-02T10:00:00Z"),
            try row("f", "2026-09-02T09:00:00Z"),
        ]
        #expect(firstRowIndex(onDay: "2026-09-02", in: firstPage, timeZone: zurich) == nil)
        let everyRow = firstPage + secondPage
        #expect(firstRowIndex(onDay: "2026-09-02", in: everyRow, timeZone: zurich) == 4)
    }

    @Test("a day no row was taken on answers nil")
    func dayWithNoRow() throws {
        let rows = [try row("a", "2026-09-14T10:00:00Z"), try row("b", "2026-09-12T10:00:00Z")]
        #expect(firstRowIndex(onDay: "2026-09-13", in: rows, timeZone: zurich) == nil)
        #expect(
            firstRowIndex(onDay: "2026-09-12", in: rows, timeZone: zurich) == 1,
            "control: a day that IS there is found in the same rows"
        )
    }

    @Test("a row with no readable instant is on no day, and is passed over")
    func undatedRowIsSkipped() throws {
        let rows = [try row("undated", nil), try row("a", "2026-09-13T10:00:00Z")]
        #expect(firstRowIndex(onDay: "2026-09-13", in: rows, timeZone: zurich) == 1)
        #expect(firstRowIndex(onDay: "2026-09-12", in: rows, timeZone: zurich) == nil)
    }

    /// The grid files an undated row under `undatedSectionKey`; that is a section's name, not a
    /// day, and a key that names no day finds no row — not even an undated one.
    @Test("a key that is not a day finds nothing, not even an undated row")
    func nonDayKeyFindsNothing() throws {
        let rows = [try row("undated", nil), try row("a", "2026-09-13T10:00:00Z")]
        #expect(firstRowIndex(onDay: undatedSectionKey, in: rows, timeZone: zurich) == nil)
        #expect(firstRowIndex(onDay: "", in: rows, timeZone: zurich) == nil)
    }

    /// Tokyo is nine hours ahead of UTC with no summer time, so both instants are still the 14th
    /// in UTC — and in Zurich — and only a reading in the zone that was passed puts the second
    /// on the 15th.
    @Test("a day's edges are the passed zone's midnights")
    func zoneBoundaryAtLocalMidnight() throws {
        let tokyo = "Asia/Tokyo"
        let rows = [
            try row("late", "2026-03-14T14:59:59Z"),  // 23:59:59 on the 14th in Tokyo
            try row("early", "2026-03-14T15:00:00Z"),  // 00:00:00 on the 15th in Tokyo
        ]
        #expect(firstRowIndex(onDay: "2026-03-14", in: rows, timeZone: tokyo) == 0)
        #expect(firstRowIndex(onDay: "2026-03-15", in: rows, timeZone: tokyo) == 1)
        #expect(
            firstRowIndex(onDay: "2026-03-14", in: [rows[1]], timeZone: tokyo) == nil,
            "the first second of the 15th was filed under the 14th"
        )
    }
}

/// The jump over the REAL generated client, as everywhere in this bundle: what is asserted is the
/// query the store built and the rows it applied, never a value the test handed itself.
@MainActor
// The time limit is there for the held cases: a jump that never asks for its page leaves the test
// waiting for a request that will not come, and a hang is a failure nobody reads.
@Suite("Media library jump to a day", .timeLimit(.minutes(1)))
struct MediaLibraryJumpTests {
    /// Every day key below is a day in Zurich, and every row is taken at a time of day that is
    /// the same date there and in UTC, so no case here turns on a zone boundary but the one that
    /// says so (`FirstRowIndexTests`).
    private static func jump(
        _ store: MediaLibraryStore,
        to day: String,
        over client: any APIProtocol
    ) async {
        await store.jump(
            toDay: day, in: "Europe/Zurich", using: client.handle, baseURL: Stub.baseURL)
    }

    private nonisolated static func item(_ uid: String, _ takenAt: String) -> String {
        """
        {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":true,"memoUid":null,\
        "takenAt":"\(takenAt)","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    /// Rows as `(uid, takenAt)`, the continuation token in the header where the server puts it.
    private nonisolated static func page(
        _ rows: [(String, String)],
        nextCursor: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let nextCursor, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = nextCursor
        }
        let body = rows.map { item($0.0, $0.1) }.joined(separator: ",")
        return (response, HTTPBody("[\(body)]"))
    }

    private nonisolated static func query(_ name: String, in path: String) -> String? {
        URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value
    }

    /// Two pages to find the day, then the list's own next page, then a pull. Only the pull starts
    /// a list of its own, so only the pull goes back to the store's page size.
    @Test("a jump reads 500 at a time, its continuations too, and the next reload reads 60 again")
    func jumpPagesAtFiveHundred() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            switch Self.query("cursor", in: path) {
            case nil where paths.get().count == 1:
                return Self.page([("a", "2026-09-20T10:00:00Z")], nextCursor: "c2")
            case "c2":
                return Self.page(
                    [("b", "2026-09-14T10:00:00Z"), ("c", "2026-09-13T10:00:00Z")],
                    nextCursor: "c3"
                )
            case "c3":
                return Self.page([("d", "2026-09-01T10:00:00Z")])
            default:
                return Self.page([("fresh", "2026-09-26T10:00:00Z")])
            }
        }
        let store = MediaLibraryStore()
        await Self.jump(store, to: "2026-09-13", over: client)
        #expect(store.items.map(\.id) == ["a", "b", "c"], "control: the jump landed")
        #expect(store.landing?.rowID == "c")
        #expect(store.landing?.day == "2026-09-13")

        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["a", "b", "c", "d"], "control: the jump's list paged on")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let sent = paths.get()
        try #require(sent.count == 4)
        #expect(Self.query("cursor", in: sent[0]) == nil, "a jump starts from the first page")
        #expect(Self.query("limit", in: sent[0]) == "500", "the jump's first page")
        #expect(Self.query("limit", in: sent[1]) == "500", "the jump's own continuation")
        #expect(Self.query("limit", in: sent[2]) == "500", "scrolling on after the jump")
        #expect(Self.query("limit", in: sent[3]) == "60", "the reload after the jump")
        #expect(Self.query("cursor", in: sent[3]) == nil, "control: that reload is a first page")
        #expect(store.landing == nil, "a reload kept the jump's scroll target")
    }

    /// Both directions the grid offers are orders of when a picture was TAKEN, so the jump keeps
    /// the one the grid is sorted in rather than turning the library round under it.
    @Test("a jump reads in the grid's own direction, kind and tag")
    func jumpKeepsTheGridsDirection() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Self.page([("a", "2026-09-13T10:00:00Z")])
        }
        let store = MediaLibraryStore(filter: .images, order: .oldestFirst)
        store.setTag("travel")
        await Self.jump(store, to: "2026-09-13", over: client)
        let sent = try #require(paths.get().first)
        #expect(Self.query("order", in: sent) == "taken_asc")
        // The day's tile was counted under the kind and tag on screen; a jump read under any other
        // could look for the day among files the tile never counted.
        #expect(Self.query("type", in: sent) == "image", "the jump dropped the kind on screen")
        #expect(Self.query("tag", in: sent) == "travel", "the jump dropped the tag on screen")
        #expect(store.order == .oldestFirst)
        #expect(store.landing?.rowID == "a", "control: the jump landed")
    }

    @Test("a jump stops at the page that holds the day and reads nothing after it")
    func jumpStopsWhenItFindsTheDay() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            switch Self.query("cursor", in: path) {
            case nil: return Self.page([("a", "2026-09-20T10:00:00Z")], nextCursor: "c2")
            case "c2": return Self.page([("b", "2026-09-13T10:00:00Z")], nextCursor: "c3")
            default: return Self.page([("c", "2026-09-01T10:00:00Z")])
            }
        }
        let store = MediaLibraryStore()
        await Self.jump(store, to: "2026-09-13", over: client)

        #expect(paths.get().count == 2, "the jump read on past the page that held the day")
        #expect(!paths.get().contains { $0.contains("cursor=c3") })
        #expect(store.items.map(\.id) == ["a", "b"])
        #expect(store.hasMore, "the found page's cursor was not kept for scrolling on")
    }

    @Test("a jump to a day the list does not hold leaves the grid as it was")
    func jumpThatRunsOutAppliesNothing() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if Self.query("limit", in: path) == "60" {
                return Self.page([("old", "2026-09-26T10:00:00Z")], nextCursor: "old-2")
            }
            switch Self.query("cursor", in: path) {
            case nil: return Self.page([("a", "2026-09-20T10:00:00Z")], nextCursor: "c2")
            default: return Self.page([("b", "2026-09-10T10:00:00Z")])
            }
        }
        let store = MediaLibraryStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await Self.jump(store, to: "2026-09-13", over: client)

        #expect(paths.get().count == 3, "control: the jump read every page there was")
        #expect(store.items.map(\.id) == ["old"], "a jump that found nothing replaced the grid")
        #expect(store.landing == nil)
        #expect(!store.isJumping)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(
            paths.get().last.map { $0.contains("cursor=old-2") } == true,
            "the grid's own cursor did not survive a jump that found nothing"
        )
    }

    /// The same day asked for twice while the first is still reading is ONE read: the answer
    /// already on its way is the one that lands.
    @Test("the same day tapped twice while it is being read is one request")
    func sameDayTwiceIsOneRequest() async {
        let entered = JumpSignal()
        let release = JumpSignal()
        let requests = Counter()
        let client = Stub.client { _, _, _ in
            requests.increment()
            entered.signal()
            await release.wait()
            return Self.page([("a", "2026-09-13T10:00:00Z")])
        }
        let store = MediaLibraryStore()
        let first = Task { await Self.jump(store, to: "2026-09-13", over: client) }
        await entered.wait()
        #expect(store.isJumping)
        await Self.jump(store, to: "2026-09-13", over: client)
        #expect(requests.count == 1, "a second request went out for the day already being read")
        release.signal()
        await first.value
        #expect(store.landing?.rowID == "a", "control: the jump that was on its way landed")
    }

    // MARK: - Abandoned jumps

    /// A server that holds its `heldAt`-th request until the test lets it go, and answers every
    /// other one at once. The held page holds a row ON the day it was asked for, so if it were
    /// applied it would land.
    private final class HeldRequest: Sendable {
        let heldAt: Int
        init(heldAt: Int = 1) { self.heldAt = heldAt }
        let entered = JumpSignal()
        let release = JumpSignal()
        let paths = LockedValue<[String]>([])

        typealias Answer = @Sendable (String) async -> (HTTPResponse, HTTPBody?)

        func client(later: @escaping Answer) -> any APIProtocol {
            Stub.client { [self] request, _, _ in
                let path = request.path ?? ""
                paths.set(paths.get() + [path])
                if paths.get().count == heldAt {
                    entered.signal()
                    await release.wait()
                    return MediaLibraryJumpTests.page([("stale", "2026-09-13T10:00:00Z")])
                }
                return await later(path)
            }
        }
    }

    /// Both jumps are held, and the EARLIER one answers first: it must land nowhere, even with
    /// nothing yet applied over it, and the later one then lands as if the first had never been.
    @Test("a later tap drops the jump still reading, and only the later one lands")
    func laterJumpDropsTheEarlierOne() async {
        let server = HeldRequest()
        let laterEntered = JumpSignal()
        let laterRelease = JumpSignal()
        let client = server.client { _ in
            laterEntered.signal()
            await laterRelease.wait()
            return Self.page([("later", "2026-08-02T10:00:00Z")])
        }
        let store = MediaLibraryStore()
        let first = Task { await Self.jump(store, to: "2026-09-13", over: client) }
        await server.entered.wait()
        let second = Task { await Self.jump(store, to: "2026-08-02", over: client) }
        await laterEntered.wait()
        server.release.signal()
        await first.value
        #expect(store.items.isEmpty, "the dropped jump's page reached the grid")
        #expect(store.landing == nil, "the dropped jump's scroll target was applied")

        laterRelease.signal()
        await second.value
        #expect(store.items.map(\.id) == ["later"], "control: the later jump landed")
        #expect(store.landing?.day == "2026-08-02")
        #expect(server.paths.get().count == 2, "control: both jumps really went out")
    }

    @Test("leaving the All view drops the jump still reading")
    func segmentChangeDropsTheJump() async {
        // The grid's own read is the first request; the jump's is the second, and is held.
        let server = HeldRequest(heldAt: 2)
        let client = server.client { _ in Self.page([("old", "2026-09-26T10:00:00Z")]) }
        let store = MediaLibraryStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["old"], "control: the grid had rows of its own")
        let jump = Task { await Self.jump(store, to: "2026-09-13", over: client) }
        await server.entered.wait()
        #expect(store.isJumping, "control: the jump was reading when the view changed")
        store.abandonJump()
        #expect(!store.isJumping)
        server.release.signal()
        await jump.value

        #expect(store.items.map(\.id) == ["old"], "the abandoned jump's page reached the grid")
        #expect(store.landing == nil, "the abandoned jump's scroll target was applied")
    }

    @Test("signing in as somebody else drops the jump still reading")
    func subjectChangeDropsTheJump() async {
        let server = HeldRequest()
        let client = server.client { _ in Self.page([]) }
        let store = MediaLibraryStore()
        let jump = Task { await Self.jump(store, to: "2026-09-13", over: client) }
        await server.entered.wait()
        #expect(store.isJumping, "control: the jump was reading when the subject changed")
        store.sessionIdentityChanged()
        server.release.signal()
        await jump.value

        #expect(store.items.isEmpty, "the outgoing account's jump reached the incoming one's grid")
        #expect(store.landing == nil, "the outgoing account's scroll target was applied")
        #expect(!store.isJumping)
    }

    /// The pull is newer than the jump, so it wins even when the jump answers first: the jump's
    /// page lands nowhere and the list goes on at the ordinary size.
    @Test("a reload started during a jump wins, even when the jump answers first")
    func refreshDuringAJumpWins() async {
        let server = HeldRequest()
        let refreshEntered = JumpSignal()
        let refreshRelease = JumpSignal()
        let client = server.client { path in
            if Self.query("cursor", in: path) != nil {
                return Self.page([("next", "2026-09-01T10:00:00Z")])
            }
            refreshEntered.signal()
            await refreshRelease.wait()
            return Self.page([("fresh", "2026-09-26T10:00:00Z")], nextCursor: "f2")
        }
        let store = MediaLibraryStore()
        let jump = Task { await Self.jump(store, to: "2026-09-13", over: client) }
        await server.entered.wait()
        let pull = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        await refreshEntered.wait()
        server.release.signal()
        await jump.value
        #expect(store.landing == nil, "the jump landed over the reload that superseded it")
        #expect(store.items.isEmpty, "the superseded jump's page reached the grid")

        refreshRelease.signal()
        await pull.value
        #expect(store.items.map(\.id) == ["fresh"], "the reload's own answer was dropped")
        #expect(store.landing == nil)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        let last = server.paths.get().last ?? ""
        #expect(Self.query("cursor", in: last) == "f2", "control: the reload's list paged on")
        #expect(Self.query("limit", in: last) == "60", "the jump's page size outlived the reload")
    }

    @Test("a landing scrolled to is consumed, and only that landing")
    func consumingALanding() async throws {
        let client = Stub.client { request, _, _ in
            let day = (request.path ?? "").contains("cursor=") ? "2026-09-01" : "2026-09-13"
            return Self.page([("a", "\(day)T10:00:00Z")], nextCursor: "c2")
        }
        let store = MediaLibraryStore()
        await Self.jump(store, to: "2026-09-13", over: client)
        let first = store.landing
        await Self.jump(store, to: "2026-09-13", over: client)
        let second = store.landing
        #expect(first != nil && second != nil && first != second, "control: two landings")
        store.consumeLanding(try #require(first))
        #expect(store.landing == second, "an older landing's consumption cleared a newer one")
        store.consumeLanding(try #require(second))
        #expect(store.landing == nil, "a landing scrolled to stayed, to be scrolled to again")
    }

    @Test("a jump's scroll target goes with the list it was found in")
    func landingGoesWithItsList() async {
        let client = Stub.client { _, _, _ in Self.page([("a", "2026-09-13T10:00:00Z")]) }
        let store = MediaLibraryStore()
        await Self.jump(store, to: "2026-09-13", over: client)
        #expect(store.landing?.rowID == "a", "control: the jump landed")
        store.setFilter(.videos)
        #expect(store.landing == nil, "a scroll target outlived the list it pointed into")
    }
}

/// A one-shot hand-off between a test and the transport it drives — `MediaLibraryStoreTests`'s
/// `Signal`, for the same reason: a buffered stream, so neither order of the two events changes
/// the outcome.
private final class JumpSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func signal() { continuation.yield() }

    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
