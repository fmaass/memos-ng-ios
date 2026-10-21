import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The filter menu on a tag's, a month's and a year's Photos view (MEMNG-827): the REAL
/// `TripMemberStore` reading the Library's listing under the collection's own `tag=` or
/// `bucket=`, with the chosen kind, order, "Captured by me" and Visibility on the wire, every page
/// through the generated client over a scripted transport that answers as the server does.
@MainActor
@Suite("Collection scope — the grid's filter")
struct CollectionFilterTests {
    private let seeder = TripSeeder()

    /// One listing item of `mime`, taken at `taken`.
    nonisolated static func item(_ uid: String, _ taken: String, mime: String) -> String {
        TripWire.item(uid, taken: CollectionScopeTests.instant(taken))
            .replacingOccurrences(of: "image/jpeg", with: mime)
    }

    /// A scripted listing that answers as `GET /api/attachments` does: `type=video` keeps the
    /// videos, `type=image` the pictures, no `type` every kind; `order=taken_desc` turns the rows
    /// round. Every request's path is recorded.
    nonisolated static func server(
        _ paths: LockedValue<[String]>, rows: [(uid: String, taken: String, video: Bool)]
    ) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            #expect(operation == TripWire.library, "not the attachments route: \(operation)")
            var kept = rows
            switch TripWire.query(path, "type") {
            case "video": kept = rows.filter(\.video)
            case "image": kept = rows.filter { !$0.video }
            default: break
            }
            if TripWire.query(path, "order") == "taken_desc" { kept.reverse() }
            let body = kept.map {
                item($0.uid, $0.taken, mime: $0.video ? "video/mp4" : "image/jpeg")
            }
            return Stub.json("[\(body.joined(separator: ","))]")
        }
    }

    /// A tag's or a month's members: pictures and videos, oldest taken first.
    nonisolated static let mixed: [(uid: String, taken: String, video: Bool)] = [
        ("pic-1", "2026-09-02T10:00:00Z", false),
        ("vid-1", "2026-09-03T10:00:00Z", true),
        ("pic-2", "2026-09-04T10:00:00Z", false),
        ("vid-2", "2026-09-05T10:00:00Z", true),
    ]

    @Test(
        "choosing Videos on a tag or a month leaves only that collection's videos",
        arguments: ["tag", "month"])
    func videosLeaveOnlyVideos(_ kind: String) async throws {
        let scope = CollectionScopeDrainTests.scope(
            kind == "tag" ? .tag("lisbon") : .month("2026-09"))
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths, rows: Self.mixed)
        let (_, members) = await seeder.members()
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.members(for: scope).count == 4, "control: the drain holds every kind")

        let videos = TripMemberQuery(filter: .videos)
        await members.drainFiltered(
            scope, query: videos, using: client.handle, baseURL: Stub.baseURL)

        let shown = try #require(members.filteredMembers(for: scope, query: videos))
        #expect(shown.map(\.id) == ["vid-1", "vid-2"])
        #expect(shown.allSatisfy { $0.attachment.mediaKind == .video })
        #expect(members.filteredState(for: scope, query: videos) == .complete)
        // Narrowed by the server, under the collection's own listing.
        let read = try #require(paths.get().last)
        #expect(TripWire.query(read, "type") == "video", "\(read)")
        if case .automatic(let collection) = scope, let tag = collection.tagName {
            #expect(TripWire.query(read, "tag") == tag, "\(read)")
        } else {
            #expect(TripWire.query(read, "bucket") == "2026-09", "\(read)")
            #expect(TripWire.hasQuery(read, "tz"), "\(read)")
        }
        // The hero, the Journal and the Map read the drain, which the filter never moves.
        #expect(members.members(for: scope).count == 4)
    }

    @Test("Captured by me and Visibility go to the server with the collection's tag")
    func mineAndVisibilityOnTheWire() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths, rows: Self.mixed)
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let query = TripMemberQuery(mine: true, visibility: .public)
        await members.drainFiltered(
            scope, query: query, using: client.handle, baseURL: Stub.baseURL)
        let read = try #require(paths.get().last)
        #expect(paths.get().count == 1, "\(paths.get())")
        #expect(TripWire.query(read, "mine") == "true", "\(read)")
        #expect(TripWire.query(read, "visibility") == "PUBLIC", "\(read)")
        #expect(TripWire.query(read, "tag") == "lisbon", "\(read)")
        #expect(members.filteredMembers(for: scope, query: query) != nil)
    }

    @Test("newest first over a complete drain is the drain turned round, with no read of its own")
    func newestFirstReusesACompleteDrain() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths, rows: Self.mixed)
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        let drained = paths.get().count

        let newest = TripMemberQuery(order: .newestFirst)
        await members.drainFiltered(
            scope, query: newest, using: client.handle, baseURL: Stub.baseURL)

        #expect(paths.get().count == drained, "a read for the order alone: \(paths.get())")
        let shown = try #require(members.filteredMembers(for: scope, query: newest))
        #expect(shown.map(\.id) == ["vid-2", "pic-2", "vid-1", "pic-1"])
        #expect(members.filteredState(for: scope, query: newest) == .complete)
    }

    @Test("newest first with nothing drained yet walks the collection once, oldest first")
    func newestFirstFirstShowingWalksOnce() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths, rows: Self.mixed)
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.month("2026-09"))
        let newest = TripMemberQuery(order: .newestFirst)
        await members.drainFiltered(
            scope, query: newest, using: client.handle, baseURL: Stub.baseURL)

        let sent = paths.get()
        #expect(sent.count == 1, "one walk, the drain's: \(sent)")
        #expect(members.state(for: scope) == .complete, "the drain it read is the members'")
        #expect(sent.allSatisfy { TripWire.query($0, "order") == "taken_asc" }, "\(sent)")
        let shown = try #require(members.filteredMembers(for: scope, query: newest))
        #expect(shown.map(\.id) == ["vid-2", "pic-2", "vid-1", "pic-1"])
    }

    @Test("newest first over a capped drain is read from the server, taken_desc")
    func newestFirstOverATruncatedDrainReads() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths, rows: Self.mixed)
        let (_, members) = await seeder.members(memberCap: 2)
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.state(for: scope) == .truncated, "control: the cap stopped the drain")

        let newest = TripMemberQuery(order: .newestFirst)
        await members.drainFiltered(
            scope, query: newest, using: client.handle, baseURL: Stub.baseURL)
        let read = try #require(paths.get().last)
        #expect(TripWire.query(read, "order") == "taken_desc", "\(read)")
        let shown = try #require(members.filteredMembers(for: scope, query: newest))
        #expect(shown.map(\.id) == ["vid-2", "pic-2"], "not the oldest two turned round")
    }

    @Test("a month read newest first stops at the month's first instant")
    func aMonthNewestFirstIsBoundedAtItsStart() async throws {
        let paths = LockedValue<[String]>([])
        // Under taken_desc the bucket opens at September's newest and walks on into August.
        let client = Self.server(
            paths,
            rows: [
                ("aug-vid", "2026-08-30T10:00:00Z", true),
                ("sep-vid", "2026-09-03T10:00:00Z", true),
            ])
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.month("2026-09"))
        let query = TripMemberQuery(filter: .videos, order: .newestFirst)
        await members.drainFiltered(
            scope, query: query, using: client.handle, baseURL: Stub.baseURL)
        let shown = try #require(members.filteredMembers(for: scope, query: query))
        #expect(shown.map(\.id) == ["sep-vid"])
    }

    @Test("an answer to an earlier choice that lands after the choice changed is dropped")
    func aStaleChoiceLandsNowhere() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let calls = LockedValue(0)
        let client = CollectionScopeDrainTests.held(
            entered: entered, release: release, calls: calls
        ) { _ in
            Stub.json("[\(Self.item("vid-1", "2026-09-03T10:00:00Z", mime: "video/mp4"))]")
        }
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let videos = TripMemberQuery(filter: .videos)
        let first = Task {
            await members.drainFiltered(
                scope, query: videos, using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        let images = TripMemberQuery(filter: .images)
        let second = Task {
            await members.drainFiltered(
                scope, query: images, using: client.handle, baseURL: Stub.baseURL)
        }
        await second.value
        release.open()
        await first.value
        #expect(members.filteredMembers(for: scope, query: videos) == nil)
        #expect(members.filteredMembers(for: scope, query: images) != nil, "control")
    }

    @Test("a filtered read the server refuses is recorded as failed, not as no read")
    func aFailedReadIsRecorded() async throws {
        let client = CollectionScopeDrainTests.bounded { _, _, _ in
            Stub.detail("boom", status: .internalServerError)
        }
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let videos = TripMemberQuery(filter: .videos)
        await members.drainFiltered(
            scope, query: videos, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.filteredFailed(for: scope, query: videos))
        #expect(members.filteredMembers(for: scope, query: videos) == nil)
        #expect(members.lastError != nil, "the failure was swallowed")
        #expect(!members.filteredFailed(for: scope, query: TripMemberQuery(filter: .images)))
    }

    @Test("leaving the collection lets its filtered read go")
    func forgetDropsTheFilteredRead() async throws {
        let paths = LockedValue<[String]>([])
        let client = Self.server(paths, rows: Self.mixed)
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let videos = TripMemberQuery(filter: .videos)
        await members.drainFiltered(
            scope, query: videos, using: client.handle, baseURL: Stub.baseURL)
        #expect(members.filteredMembers(for: scope, query: videos) != nil, "control")
        members.forget(scope)
        #expect(members.filteredMembers(for: scope, query: videos) == nil)
        #expect(members.filteredState(for: scope, query: videos) == .notLoaded)
    }

    @Test("leaving the collection while newest first waits on its drain sends nothing more")
    func forgetDuringTheNewestFirstDrainEndsTheRead() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let calls = LockedValue(0)
        let client = CollectionScopeDrainTests.held(
            entered: entered, release: release, calls: calls
        ) { _ in
            Stub.json("[\(Self.item("pic-1", "2026-09-02T10:00:00Z", mime: "image/jpeg"))]")
        }
        let (_, members) = await seeder.members()
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let newest = TripMemberQuery(order: .newestFirst)
        let showing = Task {
            await members.drainFiltered(
                scope, query: newest, using: client.handle, baseURL: Stub.baseURL)
        }
        await entered.wait()
        members.forget(scope)
        release.open()
        await showing.value
        #expect(calls.get() == 1, "the forgotten collection was read again")
        #expect(members.filteredMembers(for: scope, query: newest) == nil)
        #expect(members.filteredState(for: scope, query: newest) == .notLoaded)
        #expect(members.members(for: scope).isEmpty)
    }
}
