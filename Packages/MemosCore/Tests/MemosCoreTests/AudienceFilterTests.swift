import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// "Captured by me" and Visibility (MEMNG-787): `mine=true` and `visibility=` on the Library's
/// list, its date buckets and a trip's member route, each read keyed by its FULL query. The REAL
/// stores, every request through the generated client.
@MainActor
@Suite("Captured by me and Visibility")
struct AudienceFilterTests {
    private nonisolated static func row(_ uid: String, visibility: String? = "PUBLIC") -> String {
        let value = visibility.map { "\"\($0)\"" } ?? "null"
        let memo = visibility == nil ? "null" : "\"memo-\(uid)\""
        return """
            {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
            "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
            "webReady":true,"renditions":[],"tags":[],"orphan":\(visibility == nil),\
            "memoUid":\(memo),"visibility":\(value),\
            "takenAt":"2026-09-14T10:00:00Z","filename":"\(uid).jpg",\
            "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
            "previewUrl":"/api/attachments/\(uid)/mobile",\
            "webUrl":"/api/attachments/\(uid)/web",\
            "posterUrl":"/api/attachments/\(uid)/poster",\
            "downloadUrl":"/api/attachments/\(uid)/download",\
            "printUrl":"/api/attachments/\(uid)/print"}
            """
    }

    private nonisolated static func page(
        _ uids: [String], next: String? = nil
    ) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let next, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = next
        }
        return (response, HTTPBody("[\(uids.map { row($0) }.joined(separator: ","))]"))
    }

    private nonisolated static func day(count: Int) -> (HTTPResponse, HTTPBody?) {
        Stub.json(
            """
            [{"key":"2026-09-14","count":\(count),"coverUid":"c","tags":[],\
            "coverThumbnailUrl":"/api/attachments/c/thumb"}]
            """)
    }

    private nonisolated static func value(_ path: String, _ name: String) -> String? {
        URLComponents(string: path)?.queryItems?.first { $0.name == name }?.value
    }

    private nonisolated static func has(_ path: String, _ name: String) -> Bool {
        URLComponents(string: path)?.queryItems?.contains { $0.name == name } ?? false
    }

    /// Off is the parameter ABSENT, never `mine=false`; Any is `visibility` absent; PRIVATE is
    /// never a choice.
    nonisolated static let wire: [(Bool, MediaVisibilityFilter, String?, String?)] = [
        (false, .any, nil, nil),
        (true, .any, "true", nil),
        (false, .public, nil, "PUBLIC"),
        (true, .justUs, "true", "PROTECTED"),
    ]

    @Test(
        "the Library's first page, its next page and its buckets carry mine and visibility",
        arguments: wire)
    func theLibraryRequests(
        mine: Bool, visibility: MediaVisibilityFilter, sent: String?, shown: String?
    ) async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if operation.hasPrefix("attachment_buckets") { return Self.day(count: 3) }
            return Self.has(path, "cursor") ? Self.page(["b"]) : Self.page(["a"], next: "c1")
        }
        let store = MediaLibraryStore(pageSize: 1)
        store.setMine(mine)
        store.setVisibility(visibility)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        await store.loadMore(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["a", "b"], "control: both pages landed")
        let buckets = LibraryBucketStore(timeZoneIdentifier: "UTC")
        await buckets.load(
            size: .day, filter: .all, tag: nil, mine: mine, visibility: visibility,
            using: client.handle, baseURL: Stub.baseURL)
        let sent3 = paths.get()
        #expect(sent3.count == 3, "\(sent3)")
        for path in sent3 {
            #expect(Self.value(path, "mine") == sent, "mine on the wire: \(path)")
            #expect(Self.has(path, "mine") == (sent != nil), "mine=false is never sent: \(path)")
            #expect(Self.value(path, "visibility") == shown, "visibility: \(path)")
            #expect(Self.has(path, "visibility") == (shown != nil), "\(path)")
        }
        #expect(buckets.loadedRequest?.mine == mine)
        #expect(buckets.loadedRequest?.visibility == visibility)
    }

    @Test("a Library page asked under an earlier audience is dropped when it lands after it moved")
    func aStaleLibraryPageIsDropped() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            if !Self.has(path, "mine") && !Self.has(path, "visibility") {
                entered.open()
                await release.wait()
                return Self.page(["everyone"], next: "stale-cursor")
            }
            return Self.page(["mine-a"])
        }
        let store = MediaLibraryStore(pageSize: 1)
        let first = Task { await store.refresh(using: client.handle, baseURL: Stub.baseURL) }
        #expect(await entered.wait(), "no request was sent")
        store.setMine(true)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        release.open()
        await first.value
        #expect(store.items.map(\.id) == ["mine-a"], "the earlier audience's page landed")
        #expect(!store.hasMore, "the earlier audience's cursor was adopted")

        // Visibility alone moving is a new list too.
        let held = TripLatch()
        let go = TripLatch()
        let second = Stub.client { request, _, _ in
            if Self.value(request.path ?? "", "visibility") == nil {
                held.open()
                await go.wait()
                return Self.page(["any-vis"])
            }
            return Self.page(["just-us"])
        }
        let again = Task { await store.refresh(using: second.handle, baseURL: Stub.baseURL) }
        #expect(await held.wait(), "no request was sent")
        store.setVisibility(.justUs)
        await store.refresh(using: second.handle, baseURL: Stub.baseURL)
        go.open()
        await again.value
        #expect(store.items.map(\.id) == ["just-us"], "the earlier visibility's page landed")
    }

    @Test("the day counts drawn are the bucket answer for the same full query, and no other")
    func theHeadersCountTheFilteredBuckets() async {
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            return Self.day(count: Self.value(path, "mine") == "true" ? 4 : 12)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: "UTC")
        await store.load(
            size: .day, filter: .all, tag: nil, mine: true, visibility: .any,
            using: client.handle, baseURL: Stub.baseURL)
        func shown(mine: Bool, visibility: MediaVisibilityFilter) -> [Int]? {
            bucketsShown(
                for: .all, filter: .all, tag: nil, mine: mine, visibility: visibility,
                timeZoneIdentifier: "UTC", buckets: store.buckets, answering: store.loadedRequest
            )?.map(\.count)
        }
        #expect(shown(mine: true, visibility: .any) == [4], "the headers' count")
        #expect(shown(mine: false, visibility: .any) == nil, "mine's counts drawn for everyone's")
        #expect(shown(mine: true, visibility: .public) == nil, "Any's counts drawn for Public")
    }

    @Test("a bucket answer asked under an earlier audience is dropped; the later one is sent")
    func aStaleBucketAnswerIsDropped() async {
        let entered = TripLatch()
        let release = TripLatch()
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if Self.value(path, "visibility") == nil {
                entered.open()
                await release.wait()
                return Self.day(count: 12)
            }
            return Self.day(count: 2)
        }
        let store = LibraryBucketStore(timeZoneIdentifier: "UTC")
        let first = Task {
            await store.load(
                size: .day, filter: .all, tag: nil, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        await store.load(
            size: .day, filter: .all, tag: nil, mine: false, visibility: .public,
            using: client.handle, baseURL: Stub.baseURL)
        release.open()
        await first.value
        #expect(paths.get().count == 2, "the later audience's read was not sent: \(paths.get())")
        #expect(store.buckets.map(\.count) == [2], "the earlier audience's counts landed")
        #expect(store.loadedRequest?.visibility == .public)
    }

    // MARK: - The trip

    private let seeder = TripSeeder()

    private func seeded() async -> (trip: Trip, members: TripMemberStore) {
        let uid = seeder.server.seed(title: "Portugal 2026", tag: "portugal2026", pictures: [])
        let (trips, members) = await seeder.members()
        let trip =
            trips.trips.first { $0.uid == uid }
            ?? Trip(uid: uid, title: "Portugal 2026", createdAt: .now, updatedAt: .now)
        return (trip, members)
    }

    @Test(
        "a trip's filtered read carries mine and visibility; the default sends today's request",
        arguments: wire)
    func theTripRequest(
        mine: Bool, visibility: MediaVisibilityFilter, sent: String?, shown: String?
    ) async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return TripWire.page([0, 1])
        }
        let (trip, members) = await seeded()
        let query = TripMemberQuery(
            filter: .all, order: .oldestFirst, mine: mine, visibility: visibility)
        #expect(query.isUnfiltered == (sent == nil && shown == nil), "\(query)")
        await members.drainFiltered(trip, query: query, using: client.handle, baseURL: Stub.baseURL)
        let reads = paths.get()
        if query.isUnfiltered {
            #expect(reads.isEmpty, "the default sent a read of its own: \(reads)")
        } else {
            #expect(reads.count == 1, "\(reads)")
            let path = reads.first ?? ""
            #expect(path.hasPrefix("/api/collections/\(trip.uid)/attachments"), "\(path)")
            #expect(TripWire.query(path, "mine") == sent, "mine: \(path)")
            #expect(TripWire.hasQuery(path, "mine") == (sent != nil), "\(path)")
            #expect(TripWire.query(path, "visibility") == shown, "visibility: \(path)")
            #expect(TripWire.hasQuery(path, "visibility") == (shown != nil), "\(path)")
            #expect(members.filteredMembers(for: trip, query: query) != nil, "control: it landed")
        }
        // The unfiltered drain itself: exactly today's request, neither parameter on it.
        await members.drain(trip, using: client.handle, baseURL: Stub.baseURL)
        let drained = paths.get().dropFirst(reads.count)
        #expect(!drained.isEmpty, "control: the drain read")
        let named = drained.contains {
            TripWire.hasQuery($0, "mine") || TripWire.hasQuery($0, "visibility")
        }
        #expect(!named, "the drain named an audience: \(drained)")
    }

    @Test("a trip read for an earlier audience that lands after the change is dropped")
    func aStaleTripAudienceIsDropped() async {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, _ in
            if !TripWire.hasQuery(request.path ?? "", "mine") {
                entered.open()
                await release.wait()
                return TripWire.page([0, 1, 2])
            }
            return TripWire.page([3])
        }
        let (trip, members) = await seeded()
        let everyone = TripMemberQuery(filter: .all, order: .newestFirst)
        let mine = TripMemberQuery(filter: .all, order: .newestFirst, mine: true)
        let first = Task {
            await members.drainFiltered(
                trip, query: everyone, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        await members.drainFiltered(trip, query: mine, using: client.handle, baseURL: Stub.baseURL)
        release.open()
        await first.value
        #expect(members.filteredMembers(for: trip, query: mine)?.map(\.id) == [TripWire.uid(3)])
        #expect(members.filteredMembers(for: trip, query: everyone) == nil, "the stale one stands")
    }

    @Test("a trip's failed read is kept for its own visibility; a renewal under another reads none")
    func theTripFailureAndRenewalKeyOnVisibility() async {
        let calls = LockedValue(0)
        let client = Stub.client { _, _, _ in
            calls.set(calls.get() + 1)
            return (HTTPResponse(status: .serviceUnavailable), nil)
        }
        let (trip, members) = await seeded()
        let open = TripMemberQuery(filter: .all, order: .newestFirst, visibility: .public)
        let shared = TripMemberQuery(filter: .all, order: .newestFirst, visibility: .justUs)
        await members.drainFiltered(trip, query: open, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1)
        #expect(members.filteredFailed(for: trip, query: open), "the failure was not kept")
        let other = members.filteredFailed(for: trip, query: shared)
        #expect(!other, "another visibility reads as failed")
        await members.renewFiltered(
            trip, query: shared, using: client.handle, baseURL: Stub.baseURL)
        #expect(calls.get() == 1, "a renewal under a visibility nobody chose was sent")
    }

    // MARK: - The orphan

    @Test("a row whose visibility is null is an orphan: it lists, and names no memo")
    func anOrphanNamesNoMemo() async {
        let client = Stub.client { _, _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            let rows = [
                Self.row("orphan", visibility: nil), Self.row("owned", visibility: "PROTECTED"),
            ]
            return (response, HTTPBody("[\(rows.joined(separator: ","))]"))
        }
        let store = MediaLibraryStore(pageSize: 2)
        await store.refresh(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.items.map(\.id) == ["orphan", "owned"], "the orphan is not listed")
        #expect(store.items.first?.attachment.memoUID == nil, "an orphan names a memo")
        let owned = store.items.last?.attachment.memoUID
        #expect(owned == "memo-owned", "control: a memo's row names it")
    }
}
