import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
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
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":true,"memoUid":null,\
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

    /// MEMNG-636: the day is opened where it starts, by the listing's own `bucket`, rather than
    /// reached by reading from the top. A server that answers a request WITHOUT the bucket with a
    /// page that never reaches the day is what a walk from the top would keep paging through.
    @Test("a jump is one listing request that opens the list at the day, in its zone")
    func jumpIsOneRequestAtTheBucket() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            guard Self.query("bucket", in: path) == "2019-03-02" else {
                return Self.page([("top", "2026-09-20T10:00:00Z")], nextCursor: "c-top")
            }
            return Self.page(
                [("first", "2019-03-02T18:00:00Z"), ("second", "2019-03-02T09:00:00Z")],
                nextCursor: "c-day")
        }
        let store = MediaLibraryStore()
        await store.jump(
            toDay: "2019-03-02", in: "America/New_York", using: client.handle,
            baseURL: Stub.baseURL)

        let sent = paths.get()
        #expect(sent.count == 1, "the jump sent \(sent.count) listing requests, not one")
        let only = try #require(sent.first)
        #expect(only.hasPrefix("/api/attachments"), "control: the request is the listing")
        #expect(Self.query("bucket", in: only) == "2019-03-02", "the jump did not name its day")
        #expect(Self.query("tz", in: only) == "America/New_York", "the day's zone was not sent")
        #expect(Self.query("cursor", in: only) == nil, "a bucket start carries no cursor")
        #expect(Self.query("order", in: only) == "taken_desc", "control: the grid's direction")
        #expect(store.items.map(\.id) == ["first", "second"], "the jump did not land its page")
        #expect(store.landing?.rowID == "first", "the landing is not the day's first row")
        #expect(store.landing?.day == "2019-03-02")
        #expect(store.hasMore, "control: the day's page left a cursor to scroll on with")
    }

    /// The jump's page, the list's own next page, then a pull. The list a jump opened at a day is
    /// continued FROM that day — the listing takes its filters back with every cursor — and only
    /// the pull reads from the top again.
    @Test("a jump's list pages on from its bucket, and the next reload reads from the top")
    func jumpListPagesOnFromItsBucket() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            switch (Self.query("bucket", in: path), Self.query("cursor", in: path)) {
            case ("2026-09-13", nil):
                return Self.page(
                    [("b", "2026-09-13T12:00:00Z"), ("c", "2026-09-13T10:00:00Z")],
                    nextCursor: "c2")
            case ("2026-09-13", "c2"): return Self.page([("d", "2026-09-01T10:00:00Z")])
            default: return Self.page([("fresh", "2026-09-26T10:00:00Z")])
            }
        }
        let store = MediaLibraryStore()
        await Self.jump(store, to: "2026-09-13", over: client)
        #expect(store.items.map(\.id) == ["b", "c"], "control: the jump landed")
        #expect(store.landing?.rowID == "b")
        #expect(store.hasEarlier, "a list opened at a day has no rows above it to read")

        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["b", "c", "d"], "control: the jump's list paged on")

        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        let sent = paths.get()
        try #require(sent.count == 3)
        #expect(Self.query("limit", in: sent[0]) == "60", "not a page of the grid's size")
        #expect(Self.query("cursor", in: sent[1]) == "c2", "control: scrolling on after the jump")
        #expect(Self.query("bucket", in: sent[1]) == "2026-09-13", "the next page lost its bucket")
        #expect(Self.query("tz", in: sent[1]) == "Europe/Zurich", "the next page lost its zone")
        #expect(Self.query("limit", in: sent[1]) == "60")
        #expect(Self.query("cursor", in: sent[2]) == nil, "control: that reload is a first page")
        #expect(Self.query("bucket", in: sent[2]) == nil, "the reload kept the jump's bucket")
        #expect(store.items.map(\.id) == ["fresh"])
        #expect(store.landing == nil, "a reload kept the jump's scroll target")
        #expect(!store.hasEarlier, "a list read from the top still reads rows above it")
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == 3, "rows above were read for a list read from the top")
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

    /// The listing opens an EMPTY bucket at the next row beyond it, which is on another day: a
    /// landing there would name the reader a day the grid is not showing.
    @Test("a jump whose bucket opens on another day leaves the grid as it was")
    func jumpToAnEmptyBucketAppliesNothing() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if Self.query("bucket", in: path) == nil {
                return Self.page([("old", "2026-09-26T10:00:00Z")], nextCursor: "old-2")
            }
            return Self.page([("beyond", "2026-09-10T10:00:00Z")], nextCursor: "c2")
        }
        let store = MediaLibraryStore()
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await Self.jump(store, to: "2026-09-13", over: client)

        #expect(paths.get().count == 2, "control: the jump sent its one request")
        #expect(store.items.map(\.id) == ["old"], "a jump that found nothing replaced the grid")
        #expect(store.landing == nil)
        #expect(!store.isJumping)
        #expect(!store.hasEarlier, "a jump that found nothing left rows above to read")
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        let last = paths.get().last ?? ""
        #expect(
            Self.query("cursor", in: last) == "old-2",
            "the grid's own cursor did not survive a jump that found nothing")
        #expect(Self.query("bucket", in: last) == nil, "the grid's list took the jump's bucket")
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

    // MARK: - The rows above a day (MEMNG-636)

    /// A list opened at 2 March 2019 in New York over a server that holds, from that day on
    /// upwards: two more rows of the day itself, one row of 3 March, three of 4 March split over
    /// the first page's end, and one of 5 March. The rows above are read from the SAME bucket in
    /// the other direction, so the day's own rows come back first.
    private nonisolated static let zone = "America/New_York"

    private nonisolated static func upward(_ path: String) -> (HTTPResponse, HTTPBody?) {
        switch (Self.query("order", in: path), Self.query("cursor", in: path)) {
        case ("taken_desc", _):
            return Self.page(
                [("d1", "2019-03-02T20:00:00Z"), ("d2", "2019-03-02T15:00:00Z")],
                nextCursor: "down-2")
        case ("taken_asc", nil):
            return Self.page(
                [
                    ("d2", "2019-03-02T15:00:00Z"), ("d1", "2019-03-02T20:00:00Z"),
                    // 22:00 New York is the 3rd in UTC and still the 2nd there: the day's own.
                    ("d3", "2019-03-03T03:00:00Z"),
                    ("e1", "2019-03-03T16:00:00Z"),
                    ("f1", "2019-03-04T14:00:00Z"), ("f2", "2019-03-04T15:00:00Z"),
                ],
                nextCursor: "up-2")
        case ("taken_asc", "up-2"):
            return Self.page([("f3", "2019-03-04T16:00:00Z"), ("g1", "2019-03-05T16:00:00Z")])
        default:
            return Self.page([("unexpected", "2026-01-01T10:00:00Z")])
        }
    }

    private static func jumpUpward(
        _ store: MediaLibraryStore, over client: any APIProtocol
    ) async throws {
        await store.jump(
            toDay: "2019-03-02", in: Self.zone, using: client.handle, baseURL: Stub.baseURL)
        try #require(store.items.map(\.id) == ["d1", "d2"], "control: the jump landed")
    }

    /// MEMNG-919 builds the Library with `mine` on: a jump on that list, the rows above it and the
    /// pages below it all keep asking for the account's own pictures only, from the same bucket.
    @Test("a jump on a mine-only list keeps mine on its bucket start, the rows above and below")
    func aMineOnlyJumpKeepsMine() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return Self.upward(path)
        }
        let store = MediaLibraryStore(mine: true)
        try await Self.jumpUpward(store, over: client)
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)

        let sent = paths.get()
        #expect(sent.count >= 3, "control: the jump, the rows above and a page below (\(sent))")
        for path in sent {
            #expect(Self.query("mine", in: path) == "true", "a request dropped mine: \(path)")
            #expect(Self.query("bucket", in: path) == "2019-03-02", "off the bucket: \(path)")
            #expect(Self.query("tz", in: path) == Self.zone, "off the zone: \(path)")
        }
    }

    @Test("the rows above a day come from its bucket the other way, a whole day at a time")
    func rowsAboveComeWholeDaysAtATime() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return Self.upward(path)
        }
        let store = MediaLibraryStore()
        try await Self.jumpUpward(store, over: client)
        store.consumeLanding(try #require(store.landing, "control: the jump named its landing"))
        #expect(store.shouldLoadEarlier(before: 0), "the top of a day's list asks for no rows")
        #expect(!store.shouldLoadEarlier(before: 12), "a row a screen down asked for rows above")

        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        let first = try #require(paths.get().last)
        #expect(Self.query("order", in: first) == "taken_asc", "not read away from the day")
        #expect(Self.query("bucket", in: first) == "2019-03-02")
        #expect(Self.query("tz", in: first) == Self.zone)
        #expect(Self.query("cursor", in: first) == nil)
        // The 4th goes on past the page, so it waits; the day's own rows are the list's already.
        #expect(store.items.map(\.id) == ["e1", "d1", "d2"], "not one whole day above the list")
        // Where the reader is, is the grid's to keep: a landing here would scroll them away.
        #expect(store.landing == nil, "rows put above the list named a landing")
        #expect(store.hasEarlier)

        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(Self.query("cursor", in: paths.get().last ?? "") == "up-2")
        #expect(
            store.items.map(\.id) == ["g1", "f3", "f2", "f1", "e1", "d1", "d2"],
            "the rest of the rows above were not put above the list in the grid's order")
        #expect(store.landing == nil, "rows put above the list named a landing")
        #expect(!store.hasEarlier, "the rows above ran out and are still asked for")
        #expect(!store.shouldLoadEarlier(before: 0))

        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == 3, "rows above were read once they had run out")
    }

    /// The read is asked for when the first tiles appear, and they do not appear twice: a call
    /// that came back with nothing to show would leave the reader at the top for good.
    @Test("a page of the rows above that holds no whole day is read past in the same call")
    func rowsAboveReadOnUntilADayIsWhole() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            switch (Self.query("order", in: path), Self.query("cursor", in: path)) {
            case ("taken_desc", _): return Self.page([("d1", "2019-03-02T20:00:00Z")])
            case ("taken_asc", nil):
                return Self.page([("d1", "2019-03-02T20:00:00Z")], nextCursor: "up-2")
            case ("taken_asc", "up-2"):
                return Self.page([("e1", "2019-03-03T16:00:00Z")], nextCursor: "up-3")
            default:
                return Self.page([("f1", "2019-03-04T16:00:00Z")], nextCursor: "up-4")
            }
        }
        let store = MediaLibraryStore()
        await store.jump(
            toDay: "2019-03-02", in: Self.zone, using: client.handle, baseURL: Stub.baseURL)
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == 4, "the call stopped before it had a whole day to show")
        #expect(store.items.map(\.id) == ["e1", "d1"])
        #expect(store.hasEarlier, "control: the 4th may go on")
    }

    @Test("a second call for the rows above while one is out sends nothing")
    func rowsAboveAreOneReadAtATime() async throws {
        let entered = JumpSignal()
        let release = JumpSignal()
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if Self.query("order", in: path) == "taken_asc" {
                entered.signal()
                await release.wait()
            }
            return Self.upward(path)
        }
        let store = MediaLibraryStore()
        try await Self.jumpUpward(store, over: client)
        let first = Task { await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        #expect(store.isLoadingEarlier)
        #expect(!store.shouldLoadEarlier(before: 0), "the trigger fired again while reading")
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == 2, "a second read of the rows above went out")
        release.signal()
        await first.value
        #expect(store.items.map(\.id) == ["e1", "d1", "d2"], "control: the first read landed")
    }

    /// The rows above are the list's that asked for them: a jump to another day that replaced the
    /// list while they were on their way opened a list with rows above of its OWN, read next,
    /// and the old list's land nowhere — not even in the new list's.
    @Test("rows above a day that answer after the list was replaced land nowhere")
    func rowsAboveForAReplacedListAreDropped() async throws {
        let entered = JumpSignal()
        let release = JumpSignal()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if Self.query("bucket", in: path) == "2019-04-01" {
                return Self.page([("n1", "2019-04-01T16:00:00Z")])
            }
            if Self.query("order", in: path) == "taken_asc" {
                entered.signal()
                await release.wait()
            }
            return Self.upward(path)
        }
        let store = MediaLibraryStore()
        try await Self.jumpUpward(store, over: client)
        let read = Task { await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        await store.jump(
            toDay: "2019-04-01", in: Self.zone, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["n1"], "control: the later jump replaced the list")
        release.signal()
        await read.value
        #expect(store.items.map(\.id) == ["n1"], "the old list's rows above reached the new one")
        #expect(store.landing?.rowID == "n1", "the old list's rows above moved the landing")
        #expect(!store.hasEarlier, "the read went on for the new list and found its top")
    }

    @Test("a failed read of the rows above says so and can be asked again")
    func aFailedReadOfTheRowsAboveIsReported() async throws {
        let failing = LockedValue(true)
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if Self.query("order", in: path) == "taken_asc", failing.get() {
                return (HTTPResponse(status: .internalServerError), nil)
            }
            return Self.upward(path)
        }
        let store = MediaLibraryStore()
        try await Self.jumpUpward(store, over: client)
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.lastError != nil, "a failed read of the rows above was swallowed")
        #expect(store.items.map(\.id) == ["d1", "d2"])
        #expect(store.hasEarlier, "a failed read gave up on the rows above")
        failing.set(false)
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["e1", "d1", "d2"], "control: asked again, they came")
        #expect(store.lastError == nil)
    }

    /// MEMNG-623 for a list opened at a day: its pages are read again the way they were first
    /// read, from the bucket — downwards for the list, the other way for the rows put above it.
    @Test("a lapsed row above a day is walked for from the bucket, the other way")
    func aLapsedRowAboveADayIsReissuedFromItsBucket() async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            return Self.upward(path)
        }
        let store = MediaLibraryStore(reissueCooldown: {})
        try await Self.jumpUpward(store, over: client)
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        try #require(store.items.map(\.id) == ["e1", "d1", "d2"], "control: rows above came")
        paths.set([])

        await store.reissue(uids: ["e1", "d2"], using: client.handle, baseURL: Stub.baseURL)
        let sent = paths.get()
        try #require(sent.count == 2, "the walk read \(sent.count) pages, not one of each")
        #expect(Self.query("order", in: sent[0]) == "taken_desc", "control: the list's own page")
        #expect(Self.query("bucket", in: sent[0]) == "2019-03-02", "walked from the top")
        #expect(Self.query("cursor", in: sent[0]) == nil)
        #expect(Self.query("order", in: sent[1]) == "taken_asc", "the row above was not walked for")
        #expect(Self.query("bucket", in: sent[1]) == "2019-03-02")
        #expect(Self.query("tz", in: sent[1]) == Self.zone)
        #expect(store.items.map(\.id) == ["e1", "d1", "d2"], "a reissue moved a row")
    }

    /// MEMNG-636 review: a later jump lands while the earlier list's read of its rows above is
    /// still out. That list's tiles ask, and are refused; the read that is out is what must then
    /// read the LATER list's rows above, or nothing ever will.
    @Test("rows above still out when a later jump lands are read for the list it landed")
    func rowsAboveFollowALaterJump() async throws {
        let entered = JumpSignal()
        let release = JumpSignal()
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            let upwards = Self.query("order", in: path) == "taken_asc"
            if Self.query("bucket", in: path) == "2019-04-01" {
                return upwards
                    ? Self.page([("n1", "2019-04-01T16:00:00Z"), ("n0", "2019-04-02T16:00:00Z")])
                    : Self.page([("n1", "2019-04-01T16:00:00Z")])
            }
            if upwards {
                entered.signal()
                await release.wait()
            }
            return Self.upward(path)
        }
        let store = MediaLibraryStore()
        try await Self.jumpUpward(store, over: client)
        let first = Task { await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        await store.jump(
            toDay: "2019-04-01", in: Self.zone, using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["n1"], "control: the later jump landed")
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == 3, "control: the later list's own ask was refused")
        release.signal()
        await first.value
        #expect(store.items.map(\.id) == ["n0", "n1"], "the later list's rows above went unread")
        let last = paths.get().last ?? ""
        #expect(Self.query("bucket", in: last) == "2019-04-01", "not read from the later day")
        #expect(Self.query("order", in: last) == "taken_asc")
        #expect(!store.hasEarlier)
    }

    @Test("a pull left behind by a jump does not hold back the landed list's rows above")
    func aSupersededPullDoesNotHoldBackTheRowsAbove() async throws {
        let entered = JumpSignal()
        let release = JumpSignal()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            guard Self.query("bucket", in: path) != nil else {
                entered.signal()
                await release.wait()
                return Self.page([("fresh", "2026-09-26T10:00:00Z")])
            }
            return Self.upward(path)
        }
        let store = MediaLibraryStore()
        let pull = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        try await Self.jumpUpward(store, over: client)
        #expect(store.isLoading, "control: the superseded pull is still out")
        #expect(store.shouldLoadEarlier(before: 0), "a superseded pull held back the trigger")
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["e1", "d1", "d2"], "a superseded pull held it back")
        release.signal()
        await pull.value
        #expect(store.items.map(\.id) == ["e1", "d1", "d2"], "control: the pull landed nowhere")
    }

    @Test("rows above a day that answer after the session ended are not shown")
    func rowsAboveForAnEndedSessionAreDropped() async throws {
        let entered = JumpSignal()
        let release = JumpSignal()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if Self.query("order", in: path) == "taken_asc" {
                entered.signal()
                await release.wait()
            }
            return Self.upward(path)
        }
        let handle = SessionHandle(client: client, generation: 1)
        let session = JumpSession(handle)
        let store = MediaLibraryStore()
        store.reports(to: session)
        await store.jump(toDay: "2019-03-02", in: Self.zone, using: handle, baseURL: Stub.baseURL)
        try #require(store.items.map(\.id) == ["d1", "d2"], "control: the jump landed")
        let read = Task { await store.loadEarlier(using: handle, baseURL: Stub.baseURL) }
        await entered.wait()
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.signal()
        await read.value
        #expect(store.items.map(\.id) == ["d1", "d2"], "an ended session's rows above were shown")
    }

    @Test("a picture deleted before the rows above it are read stays gone")
    func aDeletedPictureStaysOutOfTheRowsAbove() async throws {
        let client = Stub.client { request, _, _ in
            if request.method == .delete { return Stub.empty(.noContent) }
            return Self.upward(request.path ?? "")
        }
        let store = MediaLibraryStore()
        try await Self.jumpUpward(store, over: client)
        let outcome = await store.delete(["e1"], using: client.handle)
        #expect(outcome?.deleted == ["e1"], "control: the delete landed")
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        #expect(
            store.items.map(\.id) == ["g1", "f3", "f2", "f1", "d1", "d2"],
            "a deleted picture came back with the rows above")
    }

    /// A row held back for its day to be whole was read under the ledger's stamp of ITS page; a
    /// favorite committed before it is shown must reach it, as every other page's rows.
    @Test("a row held back across calls takes a favorite committed meanwhile")
    func aCarriedRowTakesALaterFavorite() async throws {
        let client = Stub.client { request, _, operation in
            if operation == FavoriteStoreTests.put || operation == FavoriteStoreTests.delete {
                return Stub.empty(.noContent)
            }
            return Self.upward(request.path ?? "")
        }
        let favorites = FavoriteStore()
        let store = MediaLibraryStore()
        store.follow(favorites)
        try await Self.jumpUpward(store, over: client)
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        try #require(!store.items.contains { $0.id == "f1" }, "control: f1 was held back")
        await favorites.setFavorite(
            uid: "f1", to: true, shownTags: [], using: client.handle, baseURL: Stub.baseURL
        ).value
        await store.loadEarlier(using: client.handle, baseURL: Stub.baseURL)
        let shown = try #require(store.items.first { $0.id == "f1" }, "control: f1 came")
        #expect(shown.attachment.tags == ["favorites"], "a held-back row lost the favorite")
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

/// The running session as the store asks it — `MediaLibraryReissueTests`'s `ReissueSession`.
private final class JumpSession: SessionReporting {
    var activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()

    init(_ handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }
    func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        activeHandle?.generation == handle.generation
    }
    func noteTransportFailure(_ failure: ServerReachability.Reason, issuedUnder generation: Int) {}
    func noteTransportSuccess(issuedUnder generation: Int) {}
}
