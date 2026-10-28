import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// Outside a trip a month and a year start on everyone's pictures of Public memos (the owner,
/// 2026-10-28; MEMNG-933 keeps a Just us picture inside its trip or album): the REAL
/// `TripMemberStore` reading a month's and a year's members with no `mine` and
/// `visibility=PUBLIC` on the wire, over a scripted listing that answers as `GET /api/attachments`
/// does — another household member's picture inside the period is listed for everyone's read and
/// left out of a `mine=true` one, and my own Just us picture is left out of a `PUBLIC` one.
/// "Captured by me" stays a choice that narrows to my own.
@MainActor
@Suite("Collection scope — a month and a year start on everyone's Public pictures")
struct EveryonePeriodTests {
    private let seeder = TripSeeder()

    /// Another member's picture, taken inside September 2026.
    nonisolated static let family = "fam-1"
    /// My own picture on a Just us memo (MEMNG-933): seen only inside its trip or album.
    nonisolated static let justUs = "us-1"

    /// Two Public of mine, one of theirs and my Just us one, oldest taken first.
    nonisolated static let rows: [(uid: String, taken: String, mine: Bool, open: Bool)] = [
        ("pic-1", "2026-09-02T10:00:00Z", true, true),
        (family, "2026-09-03T10:00:00Z", false, true),
        (justUs, "2026-09-03T12:00:00Z", true, false),
        ("pic-2", "2026-09-04T10:00:00Z", true, true),
    ]

    /// The listing: `mine=true` keeps my pictures, no `mine` every one; `visibility=PUBLIC` keeps
    /// the Public memos' pictures; `order=taken_desc` turns the rows round. Every request's path
    /// is recorded.
    nonisolated static func server(_ paths: LockedValue<[String]>) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            #expect(operation == TripWire.library, "not the attachments route: \(operation)")
            var kept = rows
            if TripWire.query(path, "mine") == "true" { kept = kept.filter(\.mine) }
            if TripWire.query(path, "visibility") == "PUBLIC" { kept = kept.filter(\.open) }
            if TripWire.query(path, "order") == "taken_desc" { kept.reverse() }
            let body = kept.map { row in
                TripWire.item(row.uid, taken: CollectionScopeTests.instant(row.taken))
                    .replacingOccurrences(of: #""mine":true"#, with: #""mine":\#(row.mine)"#)
            }
            return Stub.json("[\(body.joined(separator: ","))]")
        }
    }

    nonisolated static let periods = ["month", "year"]

    static func period(_ kind: String) -> CollectionScope {
        CollectionScopeDrainTests.scope(kind == "month" ? .month("2026-09") : .year("2026"))
    }

    @Test(
        "a month's and a year's drain reads no mine, PUBLIC: theirs too, never Just us",
        arguments: periods)
    func aPeriodDrainsEveryonesPublic(_ kind: String) async throws {
        let scope = Self.period(kind)
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(!paths.get().isEmpty, "the drain sent nothing")
        for path in paths.get() {
            #expect(TripWire.query(path, "mine") == nil, "a Captured by me read: \(path)")
            #expect(TripWire.query(path, "visibility") == "PUBLIC", "a Just us read: \(path)")
            #expect(TripWire.hasQuery(path, "bucket"), "\(path)")
        }
        #expect(members.members(for: scope).map(\.id) == ["pic-1", Self.family, "pic-2"])
        let start = TripMemberQuery(visibility: .public)
        #expect(TripMemberStore.drainQuery(for: scope) == start)
        // The grid's first choice is the drain itself: no read of its own, the drain's rows.
        let sent = paths.get().count
        await members.drainFiltered(
            scope, query: start, using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == sent, "the drain's own query read again: \(paths.get())")
        let shown = try #require(members.filteredMembers(for: scope, query: start))
        #expect(shown.map(\.id) == ["pic-1", Self.family, "pic-2"])
        #expect(members.filteredState(for: scope, query: start) == .complete)
    }

    @Test(
        "checking Captured by me on a month or a year reads mine=true: my own Public pictures only",
        arguments: periods)
    func checkingNarrowsToMyOwn(_ kind: String) async throws {
        let scope = Self.period(kind)
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let drained = paths.get().count

        let mine = TripMemberQuery(mine: true, visibility: .public)
        await members.drainFiltered(
            scope, query: mine, using: client.handle, baseURL: Stub.baseURL)

        let read = try #require(paths.get().dropFirst(drained).first, "no read of its own")
        #expect(TripWire.query(read, "mine") == "true", "\(read)")
        #expect(TripWire.query(read, "visibility") == "PUBLIC", "\(read)")
        let shown = try #require(members.filteredMembers(for: scope, query: mine))
        #expect(shown.map(\.id) == ["pic-1", "pic-2"])
        #expect(members.filteredState(for: scope, query: mine) == .complete)
        // The hero and the Map read the drain, which the choice never narrows.
        #expect(members.members(for: scope).map(\.id) == ["pic-1", Self.family, "pic-2"])
    }

    @Test("Newest First on a month is its everyone's drain turned round, with no read of its own")
    func newestFirstTurnsTheOwnDrain() async throws {
        let scope = Self.period("month")
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let drained = paths.get().count

        let start = TripMemberQuery(visibility: .public)
        let newest = TripMemberQuery(order: .newestFirst, visibility: .public)
        #expect(newest.isOrderOnly(over: start))
        #expect(
            !TripMemberQuery(order: .newestFirst, mine: true, visibility: .public)
                .isOrderOnly(over: start))
        await members.drainFiltered(
            scope, query: newest, using: client.handle, baseURL: Stub.baseURL)

        #expect(paths.get().count == drained, "a read for the order alone: \(paths.get())")
        let shown = try #require(members.filteredMembers(for: scope, query: newest))
        #expect(shown.map(\.id) == ["pic-2", Self.family, "pic-1"])
        #expect(members.filteredState(for: scope, query: newest) == .complete)
    }

    @Test(
        "a tag's and Favorites' drain is everyone's Public pictures, never Just us (MEMNG-933)",
        arguments: ["tag", "favorites"])
    func aTagIsEveryonesPublic(_ kind: String) async throws {
        let scope = CollectionScopeDrainTests.scope(
            kind == "tag" ? .tag("lisbon") : .pictureTag("favorites"))
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(TripMemberStore.drainQuery(for: scope) == TripMemberQuery(visibility: .public))
        #expect(!paths.get().isEmpty, "the drain sent nothing")
        for path in paths.get() {
            #expect(TripWire.query(path, "mine") == nil, "\(path)")
            #expect(TripWire.query(path, "visibility") == "PUBLIC", "a Just us read: \(path)")
        }
        #expect(members.members(for: scope).map(\.id) == ["pic-1", Self.family, "pic-2"])
    }
    @Test("a trip and an album read their members exactly as before: no mine, no visibility")
    func aTripAndAnAlbumKeepTheirQuery() async throws {
        let server = TripServer()
        server.seed(title: "Lisbon", tag: "lisbon", pictures: [0, 1, 2])
        server.seed(title: "At the sea", pictures: [0, 1], kind: "album")
        let (trips, members) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first { $0.kind == .trip })
        let album = try #require(trips.trips.first { $0.kind == .album })
        for scope in [CollectionScope.trip(trip), .trip(album)] {
            #expect(TripMemberStore.drainQuery(for: scope) == .unfiltered, "\(scope.id)")
            await members.drain(scope, using: server.client.handle, baseURL: Stub.baseURL)
        }
        let reads = server.calls.of(TripWire.members).map(\.path)
        #expect(reads.count >= 2, "a trip or an album was not read: \(reads)")
        for read in reads {
            #expect(!read.contains("visibility="), "a Just us picture left its trip: \(read)")
            #expect(!read.contains("mine="), "\(read)")
        }
        #expect(members.members(for: trip).count == 3)
        #expect(members.members(for: album).count == 2)
    }

    // MARK: - The Journal (MEMNG-817)

    /// Whose a memo is, as the memo list says it: mine, or another member's.
    nonisolated static let ownMemo = #""owner":"fabian","mine":true"#
    nonisolated static let familyMemo = #""owner":"anna","mine":false"#

    /// One of my memos and one of another member's (Just us), both dated in September 2026.
    nonisolated static let journalPage: String = Stub.page([
        CollectionScopeJournalTests.memo("mine-memo", "2026-09-03T10:00:00Z"),
        CollectionScopeJournalTests.memo("family-memo", "2026-09-04T10:00:00Z")
            .replacingOccurrences(of: Self.ownMemo, with: Self.familyMemo)
            .replacingOccurrences(of: #""PRIVATE""#, with: #""PROTECTED""#),
    ])

    @Test(
        "a month's and a year's Journal starts on everyone's memos; Captured by me narrows it",
        arguments: periods)
    func aPeriodJournalStartsOnEveryone(_ kind: String) async {
        let paths = LockedValue<[String]>([])
        let client = CollectionScopeJournalTests.memos(paths) { _ in Stub.json(Self.journalPage) }
        let (_, store) = await seeder.members()
        let scope = Self.period(kind)
        await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)

        let everyone = ["mine-memo", "family-memo"]
        #expect(store.journal(for: scope).map(\.uid) == everyone, "the screen's start")
        #expect(store.journal(for: scope, mine: false).map(\.uid) == everyone)
        // Checked on purpose: my own memos, from the same read.
        let read = paths.get().count
        #expect(store.journal(for: scope, mine: true).map(\.uid) == ["mine-memo"])
        #expect(paths.get().count == read, "narrowing read again: \(paths.get())")
    }

    @Test("a trip's Journal over the same days keeps another member's memo, checked or not")
    func aTripJournalKeepsTheFamily() async throws {
        let family = CollectionScopeJournalTests.memo("family-memo", "2026-07-12T10:00:00Z")
            .replacingOccurrences(of: Self.ownMemo, with: Self.familyMemo)
        let server = TripJournalWire.server(
            tagged: [CollectionScopeJournalTests.memo("tagged", "2026-07-11T10:00:00Z")],
            spanned: [family])
        server.seed(title: "Lisbon", tag: TripJournalWire.tag, span: TripJournalWire.span)
        let (trips, store) = await TripSeeder(server: server).members()
        let trip = try #require(trips.trips.first)
        await store.loadJournal(.trip(trip), using: server.client.handle, baseURL: Stub.baseURL)

        for mine in [nil, true, false] as [Bool?] {
            let uids = Set(store.journal(for: .trip(trip), mine: mine).map(\.uid))
            let asked = String(describing: mine)
            #expect(uids == ["tagged", "family-memo"], "mine \(asked): \(uids)")
        }
    }
}
