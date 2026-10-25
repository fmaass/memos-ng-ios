import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// Outside a trip the library is my own pictures (MEMNG-919): the REAL `TripMemberStore` reading a
/// month's and a year's members with `mine=true` on the wire, over a scripted listing that answers
/// as `GET /api/attachments` does — another household member's picture inside the period is
/// listed for everyone's read and left out of a `mine=true` one.
@MainActor
@Suite("Collection scope — a month and a year are my own pictures")
struct MineOnlyPeriodTests {
    private let seeder = TripSeeder()

    /// Another member's picture (Just us), taken inside September 2026.
    nonisolated static let family = "fam-1"

    /// Two of mine and one of theirs, oldest taken first.
    nonisolated static let rows: [(uid: String, taken: String, mine: Bool)] = [
        ("pic-1", "2026-09-02T10:00:00Z", true),
        (family, "2026-09-03T10:00:00Z", false),
        ("pic-2", "2026-09-04T10:00:00Z", true),
    ]

    /// The listing: `mine=true` keeps my pictures, no `mine` every one; `order=taken_desc` turns
    /// the rows round. Every request's path is recorded.
    nonisolated static func server(_ paths: LockedValue<[String]>) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            #expect(operation == TripWire.library, "not the attachments route: \(operation)")
            var kept = rows
            if TripWire.query(path, "mine") == "true" { kept = kept.filter(\.mine) }
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
        "a month's and a year's drain reads mine=true and holds no other member's picture",
        arguments: periods)
    func aPeriodDrainsMyOwn(_ kind: String) async throws {
        let scope = Self.period(kind)
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(!paths.get().isEmpty, "the drain sent nothing")
        for path in paths.get() {
            #expect(TripWire.query(path, "mine") == "true", "an everyone read: \(path)")
            #expect(TripWire.hasQuery(path, "bucket"), "\(path)")
        }
        #expect(members.members(for: scope).map(\.id) == ["pic-1", "pic-2"])
        #expect(TripMemberStore.drainQuery(for: scope) == .capturedByMe)
        // The grid's first choice is the drain itself: no read of its own, the drain's rows.
        let sent = paths.get().count
        await members.drainFiltered(
            scope, query: .capturedByMe, using: client.handle, baseURL: Stub.baseURL)
        #expect(paths.get().count == sent, "the drain's own query read again: \(paths.get())")
        let shown = try #require(members.filteredMembers(for: scope, query: .capturedByMe))
        #expect(shown.map(\.id) == ["pic-1", "pic-2"])
        #expect(members.filteredState(for: scope, query: .capturedByMe) == .complete)
    }

    @Test(
        "unchecking Captured by me on a month or a year reads everyone's, the family picture too",
        arguments: periods)
    func uncheckingReadsEveryone(_ kind: String) async throws {
        let scope = Self.period(kind)
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let drained = paths.get().count

        let everyone = TripMemberQuery.unfiltered
        await members.drainFiltered(
            scope, query: everyone, using: client.handle, baseURL: Stub.baseURL)

        let read = try #require(paths.get().dropFirst(drained).first, "no read of its own")
        #expect(TripWire.query(read, "mine") == nil, "\(read)")
        let shown = try #require(members.filteredMembers(for: scope, query: everyone))
        #expect(shown.map(\.id) == ["pic-1", Self.family, "pic-2"])
        #expect(members.filteredState(for: scope, query: everyone) == .complete)
        // The hero and the Map read the drain, which the choice never widens.
        #expect(members.members(for: scope).map(\.id) == ["pic-1", "pic-2"])
    }

    @Test("Newest First on a month is its own drain turned round, with no read of its own")
    func newestFirstTurnsTheOwnDrain() async throws {
        let scope = Self.period("month")
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let drained = paths.get().count

        let newest = TripMemberQuery(order: .newestFirst, mine: true)
        #expect(newest.isOrderOnly(over: .capturedByMe))
        #expect(!TripMemberQuery(order: .newestFirst).isOrderOnly(over: .capturedByMe))
        await members.drainFiltered(
            scope, query: newest, using: client.handle, baseURL: Stub.baseURL)

        #expect(paths.get().count == drained, "a read for the order alone: \(paths.get())")
        let shown = try #require(members.filteredMembers(for: scope, query: newest))
        #expect(shown.map(\.id) == ["pic-2", "pic-1"])
        #expect(members.filteredState(for: scope, query: newest) == .complete)
    }

    @Test("a tag's drain stays everyone's: only a month and a year are narrowed")
    func aTagStaysEveryones() async throws {
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(TripMemberStore.drainQuery(for: scope) == .unfiltered)
        for path in paths.get() {
            #expect(TripWire.query(path, "mine") == nil, "\(path)")
        }
        #expect(members.members(for: scope).map(\.id) == ["pic-1", Self.family, "pic-2"])
    }
    // MARK: - The Journal (MEMNG-919)

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
        "a month's and a year's Journal is my own memos while Captured by me is on",
        arguments: periods)
    func aPeriodJournalIsMyOwn(_ kind: String) async {
        let paths = LockedValue<[String]>([])
        let client = CollectionScopeJournalTests.memos(paths) { _ in Stub.json(Self.journalPage) }
        let (_, store) = await seeder.members()
        let scope = Self.period(kind)
        await store.loadJournal(scope, using: client.handle, baseURL: Stub.baseURL)

        #expect(store.journal(for: scope).map(\.uid) == ["mine-memo"], "the screen's start")
        #expect(store.journal(for: scope, mine: true).map(\.uid) == ["mine-memo"])
        // Unchecked on purpose: everyone's memos, from the same read.
        let read = paths.get().count
        #expect(store.journal(for: scope, mine: false).map(\.uid) == ["mine-memo", "family-memo"])
        #expect(paths.get().count == read, "widening read again: \(paths.get())")
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
