import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The chosen covers of tag, month and year collections (MEMNG-842): the REAL store over the
/// generated client and a scripted transport that answers `/api/collection-covers` and each
/// picture's record as memos-ng 2.5.0 does.
@MainActor
@Suite("Collection covers", .timeLimit(.minutes(1)))
struct CollectionCoverStoreTests {
    nonisolated static let list = "list_collection_covers_api_collection_covers_get"
    nonisolated static let put = "set_collection_cover_api_collection_covers__kind___key__put"
    nonisolated static let meta = CarriedCoverRenewalTests.meta

    static let garden = CollectionCoverStore.Key(kind: .tag, key: "garden")

    /// `GET /api/collection-covers` answering `rows` as `(kind, key, uid)`.
    nonisolated static func listing(_ rows: [(String, String, String)]) -> (
        HTTPResponse, HTTPBody?
    ) {
        let items = rows.map { #"{"kind":"\#($0.0)","key":"\#($0.1)","attachmentUid":"\#($0.2)"}"# }
        return Stub.json("[\(items.joined(separator: ","))]")
    }

    /// The PUT's answer for `uid` on the garden tag.
    nonisolated static func taken(_ uid: String) -> (HTTPResponse, HTTPBody?) {
        Stub.json(#"{"kind":"tag","key":"garden","attachmentUid":"\#(uid)"}"#)
    }

    /// A picture as the viewer hands it over: its own record, signed `sig`.
    static func picture(_ uid: String, sig: String = "v") async throws -> MemoAttachment {
        let client = Stub.client { _, _, _ in CarriedCoverRenewalTests.record(uid, sig: sig) }
        return try await TripMemberStore.attachment(client, uid: uid, baseURL: Stub.baseURL)
    }

    @Test("Use as Cover on a tag shows the picture at once and PUTs it under the tag's key")
    func choosingShowsAtOnceAndWrites() async throws {
        let sent = LockedValue<[String]>([])
        let bodies = LockedValue<[String]>([])
        let client = Stub.client { request, body, operation in
            sent.set(sent.get() + ["\(operation) \(request.method.rawValue) \(request.path ?? "")"])
            let fields = try await Stub.body(body)
            bodies.set(bodies.get() + [fields["attachmentUid"] as? String ?? "-"])
            return Self.taken("p7")
        }
        let store = CollectionCoverStore()
        let p7 = try await Self.picture("p7")
        let write = try #require(store.choose(p7, for: Self.garden, using: client.handle))
        #expect(store.cover(for: Self.garden)?.uid == "p7", "not shown before the write answered")
        try await write.value
        #expect(sent.get() == ["\(Self.put) PUT /api/collection-covers/tag/garden"])
        #expect(bodies.get() == ["p7"])
        #expect(store.cover(of: .tag("garden"))?.thumbnailURL == p7.thumbnailURL)
    }

    @Test(
        "a month and a year are written under their own kind",
        arguments: [("month", "2026-09"), ("year", "2026")])
    func monthsAndYearsWriteTheirKind(_ kind: String, _ key: String) async throws {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(#"{"kind":"\#(kind)","key":"\#(key)","attachmentUid":"p1"}"#)
        }
        let store = CollectionCoverStore()
        let collection: AutomaticCollection.Kind = kind == "month" ? .month(key) : .year(key)
        let target = try #require(CollectionCoverStore.Key(collection))
        let p1 = try await Self.picture("p1")
        let write = try #require(store.choose(p1, for: target, using: client.handle))
        try await write.value
        #expect(paths.get() == ["/api/collection-covers/\(kind)/\(key)"])
        #expect(store.cover(of: collection)?.uid == "p1")
    }

    @Test("the favorites collection has no server kind, so no cover can be chosen for it")
    func favoritesHasNoKey() {
        #expect(CollectionCoverStore.Key(.pictureTag("favorites")) == nil)
        #expect(CollectionCoverStore.Key(.tag("favorites")) != nil, "control")
    }

    @Test("a fresh store — a refresh or a reinstall — reads the chosen covers back from the server")
    func aLoadReadsTheServersCovers() async throws {
        let sent = LockedValue<[String]>([])
        let client = Stub.client { request, _, operation in
            sent.set(sent.get() + [operation])
            if operation == Self.list {
                return Self.listing([
                    ("month", "2026-09", "m1"), ("tag", "garden", "g1"), ("year", "2026", "y1"),
                ])
            }
            let uid = request.path?.split(separator: "/").last.map(String.init) ?? ""
            return CarriedCoverRenewalTests.record(uid, sig: "fresh")
        }
        let store = CollectionCoverStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(of: .tag("garden"))?.uid == "g1")
        #expect(store.cover(of: .month("2026-09"))?.uid == "m1")
        #expect(store.cover(of: .year("2026"))?.uid == "y1")
        #expect(store.cover(of: .tag("garden"))?.thumbnailURL?.query?.contains("sig=fresh") == true)
        #expect(store.cover(of: .tag("other")) == nil, "a collection with no choice keeps its own")
        #expect(sent.get().first == Self.list)
        #expect(sent.get().filter { $0 == Self.meta }.count == 3)
    }

    @Test("a picture the server no longer lists leaves its collection on the default cover")
    func anUnlistedCoverFallsBack() async throws {
        let listed = LockedValue(true)
        let client = Stub.client { request, _, operation in
            if operation == Self.list {
                return Self.listing(listed.get() ? [("tag", "garden", "g1")] : [])
            }
            return CarriedCoverRenewalTests.record("g1", sig: "s")
        }
        let store = CollectionCoverStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(for: Self.garden)?.uid == "g1", "control")
        listed.set(false)
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        #expect(store.cover(for: Self.garden) == nil)
    }

    @Test("a write the server refuses puts the earlier cover back and says why")
    func aFailedWriteRestoresTheEarlierCover() async throws {
        let client = Stub.client { _, _, operation in
            if operation == Self.list { return Self.listing([("tag", "garden", "g1")]) }
            if operation == Self.put {
                return Stub.detail("Attachment not found", status: .notFound)
            }
            return CarriedCoverRenewalTests.record("g1", sig: "s")
        }
        let store = CollectionCoverStore()
        await store.load(using: client.handle, baseURL: Stub.baseURL)
        let p2 = try await Self.picture("p2")
        let write = try #require(store.choose(p2, for: Self.garden, using: client.handle))
        #expect(store.cover(for: Self.garden)?.uid == "p2", "control: shown at once")
        await #expect(throws: TripStore.Failure.server(status: 404)) { try await write.value }
        #expect(TripStore.Failure.server(status: 404).errorDescription != nil, "a sentence to say")
        #expect(store.cover(for: Self.garden)?.uid == "g1")
    }

    @Test("a second choice while the first write is out is refused and sends nothing")
    func overlappingChoicesAreOneRequest() async throws {
        let puts = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, _ in
            puts.set(puts.get() + 1)
            entered.open()
            await release.wait()
            return Self.taken("p1")
        }
        let store = CollectionCoverStore()
        let p1 = try await Self.picture("p1")
        let p2 = try await Self.picture("p2")
        let first = try #require(store.choose(p1, for: Self.garden, using: client.handle))
        await entered.wait()
        #expect(store.isSaving(Self.garden))
        let second = store.choose(p2, for: Self.garden, using: client.handle)
        #expect(second == nil)
        release.open()
        try await first.value
        #expect(puts.get() == 1)
        #expect(store.cover(for: Self.garden)?.uid == "p1")
        #expect(!store.isSaving(Self.garden))
    }

    @Test("a list asked before a choice does not undo the choice when it lands")
    func aStaleListDoesNotUndoAChoice() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { request, _, operation in
            if operation == Self.list {
                entered.open()
                await release.wait()
                return Self.listing([("tag", "garden", "old")])
            }
            if operation == Self.put { return Self.taken("new") }
            let uid = request.path?.split(separator: "/").last.map(String.init) ?? ""
            return CarriedCoverRenewalTests.record(uid, sig: "s")
        }
        let store = CollectionCoverStore()
        let fresh = try await Self.picture("new")
        let reading = Task { await store.load(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        let write = try #require(store.choose(fresh, for: Self.garden, using: client.handle))
        try await write.value
        release.open()
        await reading.value
        #expect(store.cover(for: Self.garden)?.uid == "new")
    }

    @Test("a list that answers after the account changed lands nowhere")
    func anotherAccountsListLandsNowhere() async throws {
        let entered = TripLatch()
        let release = TripLatch()
        let client = Stub.client { _, _, operation in
            if operation == Self.list {
                entered.open()
                await release.wait()
                return Self.listing([("tag", "garden", "g1")])
            }
            return CarriedCoverRenewalTests.record("g1", sig: "s")
        }
        let store = CollectionCoverStore()
        let reading = Task { await store.load(using: client.handle, baseURL: Stub.baseURL) }
        await entered.wait()
        store.sessionIdentityChanged()
        release.open()
        await reading.value
        #expect(store.chosenUid(for: Self.garden) == nil)
    }
}
