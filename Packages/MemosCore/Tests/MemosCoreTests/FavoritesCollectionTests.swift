import Foundation
import HTTPTypes
import MemosAPI
@testable import MemosCore
import OpenAPIRuntime
import Testing

/// The Favorites collection (MEMNG-868): the REAL `TripMemberStore` draining an automatic
/// `.pictureTag("favorites")` scope over `GET /api/attachments?pictureTag=`, fenced WHOLE by the
/// real `FavoriteStore`'s revision, every request through the generated client over a scripted
/// transport.
@MainActor
@Suite("Favorites collection — the picture-tag drain")
struct FavoritesCollectionTests {
    private let seeder = TripSeeder()

    static var favorites: CollectionScope {
        CollectionScopeDrainTests.scope(.pictureTag(FavoriteTag.name))
    }

    /// One listing page of `(uid, picture tags)` rows, with the continuation header when given.
    nonisolated static func page(_ items: [(String, [String])], next: String? = nil) -> (
        HTTPResponse, HTTPBody?
    ) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        if let next, let name = HTTPField.Name("X-Next-Cursor") {
            response.headerFields[name] = next
        }
        let body = items.map { FavoriteFenceTests.listItem($0.0, pictureTags: $0.1) }
        return (response, HTTPBody("[\(body.joined(separator: ","))]"))
    }

    /// A server answering every favorite write 204 and every listing by `answer`, given the
    /// cursor sent and how many listings have been sent, this one included. Every listing's
    /// cursor is recorded, in order.
    nonisolated static func server(
        cursors: LockedValue<[String?]>,
        answer:
            @escaping @Sendable (_ cursor: String?, _ call: Int) async -> (
                HTTPResponse, HTTPBody?
            )
    ) -> any APIProtocol {
        CollectionScopeDrainTests.bounded { request, _, operation in
            if operation == FavoriteStoreTests.put || operation == FavoriteStoreTests.delete {
                return Stub.empty(.noContent)
            }
            #expect(operation == TripWire.library, "not the attachments route: \(operation)")
            let path = request.path ?? ""
            #expect(TripWire.query(path, "pictureTag") == FavoriteTag.name, "\(path)")
            #expect(!TripWire.hasQuery(path, "tag"), "a picture tag sent as a memo tag: \(path)")
            let cursor = TripWire.query(path, "cursor")
            cursors.set(cursors.get() + [cursor])
            return await answer(cursor, cursors.get().count)
        }
    }

    // MARK: - the route

    @Test("the favorites grid drains pictureTag=favorites through the member store, no tag=")
    func theGridDrainsByPictureTag() async {
        let paths = LockedValue<[String]>([])
        let client = CollectionScopeDrainTests.recording(paths) { cursor in
            cursor == "c1"
                ? Self.page([("p3", ["favorites"])])
                : Self.page([("p1", ["favorites"]), ("p2", ["favorites"])], next: "c1")
        }
        let (_, members) = await seeder.members()
        await members.drain(Self.favorites, using: client.handle, baseURL: Stub.baseURL)

        #expect(members.members(for: Self.favorites).map(\.id) == ["p1", "p2", "p3"])
        let sent = paths.get()
        #expect(sent.count == 2, "not one request per page: \(sent)")
        for path in sent {
            #expect(TripWire.query(path, "pictureTag") == "favorites", "\(path)")
            #expect(!TripWire.hasQuery(path, "tag"), "a picture tag sent as a memo tag: \(path)")
            #expect(TripWire.query(path, "order") == "taken_asc", "\(path)")
            #expect(!TripWire.hasQuery(path, "bucket"), "\(path)")
            #expect(!TripWire.hasQuery(path, "type"), "the drain named a kind: \(path)")
        }
    }

    @Test("a picture-tag scope has a member request: it is read, and its state is complete")
    func aPictureTagScopeIsNotNil() async {
        let paths = LockedValue<[String]>([])
        let client = CollectionScopeDrainTests.recording(paths) { _ in
            Self.page([("p1", ["favorites"])])
        }
        let (_, members) = await seeder.members()
        #expect(members.state(for: Self.favorites) == .notLoaded)
        await members.drain(Self.favorites, using: client.handle, baseURL: Stub.baseURL)

        #expect(paths.get().count == 1, "a picture-tag scope sent nothing: \(paths.get())")
        #expect(members.state(for: Self.favorites) == .complete)
        #expect(members.summary(for: Self.favorites)?.count == 1)
    }

    @Test("a picture tag and a memo tag of the same name are two collections")
    func aMemoTagOfTheSameNameIsAnother() {
        let memoTag = CollectionScopeDrainTests.scope(.tag(FavoriteTag.name))
        #expect(Self.favorites.id != memoTag.id)
        #expect(Self.favorites.tag == nil, "a picture tag read as a memo tag")
        #expect(Self.favorites.title == "Favorites")
    }

    @Test("a favorites page answered for a session that has ended is dropped whole")
    func aStaleAnswerIsDropped() async {
        let calls = LockedValue(0)
        let entered = TripLatch()
        let release = TripLatch()
        let client = CollectionScopeDrainTests.held(
            entered: entered, release: release, calls: calls
        ) { call in
            call == 1
                ? Self.page([("p1", ["favorites"])], next: "c1")
                : Self.page([("p2", ["favorites"])])
        }
        let (_, members) = await seeder.members()
        let issued = SessionHandle(client: client, generation: 1)
        let session = TripTestSession(for: issued)
        members.reports(to: session)
        let inFlight = Task {
            await members.drain(Self.favorites, using: issued, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "no request was sent")
        session.activeHandle = SessionHandle(client: client, generation: 2)
        release.open()
        await inFlight.value

        #expect(members.members(for: Self.favorites).isEmpty, "a stale answer was applied")
        #expect(members.state(for: Self.favorites) == .notLoaded)
        #expect(calls.get() == 1, "the stale drain read on: \(calls.get())")
    }

    // MARK: - the whole-drain fence

    @Test("a favorite behind the cursor while page two is out restarts the walk: 1, 2, 1, 2")
    func aFavoriteBehindTheCursorRestarts() async {
        let cursors = LockedValue<[String?]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server(cursors: cursors) { cursor, call in
            if call == 2 {
                entered.open()
                _ = await release.wait()
            }
            if cursor == "c1" { return Self.page([("p3", ["favorites"])]) }
            // p0 is ordered before every row: once favorited, only a first page can answer it.
            return call == 1
                ? Self.page([("p1", ["favorites"]), ("p2", ["favorites"])], next: "c1")
                : Self.page(
                    [("p0", ["favorites"]), ("p1", ["favorites"]), ("p2", ["favorites"])],
                    next: "c1")
        }
        let favorites = FavoriteStore()
        let (_, members) = await seeder.members()
        members.follow(favorites)
        let inFlight = Task {
            await members.drain(Self.favorites, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "page two was never asked for")
        await favorites.setFavorite(
            uid: "p0", to: true, shownTags: [], using: client.handle, baseURL: Stub.baseURL
        ).value
        #expect(favorites.revision == 1, "control: the favorite did not commit")
        release.open()
        await inFlight.value

        #expect(cursors.get() == [nil, "c1", nil, "c1"], "\(cursors.get())")
        #expect(members.members(for: Self.favorites).map(\.id) == ["p0", "p1", "p2", "p3"])
        #expect(members.state(for: Self.favorites) == .complete)
    }

    @Test("an unfavorite of a row already piled while page two is out leaves it out of the grid")
    func anUnfavoriteOfAPiledRowLeavesIt() async {
        let cursors = LockedValue<[String?]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let client = Self.server(cursors: cursors) { cursor, call in
            if call == 2 {
                entered.open()
                _ = await release.wait()
            }
            if cursor == "c1" { return Self.page([("p3", ["favorites"])]) }
            return call == 1
                ? Self.page([("p1", ["favorites"]), ("p2", ["favorites"])], next: "c1")
                : Self.page([("p2", ["favorites"])], next: "c1")
        }
        let favorites = FavoriteStore()
        let (_, members) = await seeder.members()
        members.follow(favorites)
        let inFlight = Task {
            await members.drain(Self.favorites, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "page two was never asked for")
        await favorites.setFavorite(
            uid: "p1", to: false, shownTags: ["favorites"], using: client.handle,
            baseURL: Stub.baseURL
        ).value
        #expect(favorites.revision == 1, "control: the unfavorite did not commit")
        release.open()
        await inFlight.value

        #expect(cursors.get() == [nil, "c1", nil, "c1"], "\(cursors.get())")
        #expect(members.members(for: Self.favorites).map(\.id) == ["p2", "p3"])
    }

    @Test("a favorites drain with no commit during it asks for each page once")
    func noCommitNoRestart() async {
        let cursors = LockedValue<[String?]>([])
        let client = Self.server(cursors: cursors) { cursor, _ in
            cursor == "c1"
                ? Self.page([("p3", ["favorites"])])
                : Self.page([("p1", ["favorites"]), ("p2", ["favorites"])], next: "c1")
        }
        let favorites = FavoriteStore()
        let (_, members) = await seeder.members()
        members.follow(favorites)
        await members.drain(Self.favorites, using: client.handle, baseURL: Stub.baseURL)

        #expect(cursors.get() == [nil, "c1"], "\(cursors.get())")
        #expect(members.members(for: Self.favorites).map(\.id) == ["p1", "p2", "p3"])
    }

    @Test("a memo tag's drain is not restarted by a favorite: only membership by picture tag is")
    func aMemoTagDrainIsNotRestarted() async {
        let paths = LockedValue<[String]>([])
        let entered = TripLatch()
        let release = TripLatch()
        let client = CollectionScopeDrainTests.bounded { request, _, operation in
            if operation == FavoriteStoreTests.put { return Stub.empty(.noContent) }
            let path = request.path ?? ""
            paths.set(paths.get() + [path])
            if TripWire.query(path, "cursor") == "c1" {
                entered.open()
                _ = await release.wait()
                return Self.page([("p3", [])])
            }
            return Self.page([("p1", []), ("p2", [])], next: "c1")
        }
        let favorites = FavoriteStore()
        let (_, members) = await seeder.members()
        members.follow(favorites)
        let scope = CollectionScopeDrainTests.scope(.tag("lisbon"))
        let inFlight = Task {
            await members.drain(scope, using: client.handle, baseURL: Stub.baseURL)
        }
        #expect(await entered.wait(), "page two was never asked for")
        await favorites.setFavorite(
            uid: "p1", to: true, shownTags: [], using: client.handle, baseURL: Stub.baseURL
        ).value
        release.open()
        await inFlight.value

        #expect(paths.get().count == 2, "a memo tag's walk restarted: \(paths.get())")
        let first = members.members(for: scope).first
        #expect(first?.attachment.tags == ["favorites"], "the commit's overlay was lost")
    }
}
