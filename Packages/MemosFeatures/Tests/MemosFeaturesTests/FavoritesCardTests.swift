import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The Favorites card on the Collections root (MEMNG-868): first in the Tags row, counted from the
/// PICTURE-tag counts alone, absent at zero, untouched by a memo tag or a trip named `favorites`,
/// opening the `.pictureTag("favorites")` collection.
@MainActor
@Suite("Favorites card", .serialized, .mediaGlobals, .timeLimit(.minutes(2)))
struct FavoritesCardTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "favorites-card").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    private static func tags(_ pairs: [(String, Int)]) -> [LibraryTag] {
        pairs.map { LibraryTag(name: $0.0, count: $0.1) }
    }

    private static func trip(_ tag: String) -> Trip {
        let made = Date(timeIntervalSince1970: 1_791_460_800)
        return Trip(uid: "t-\(tag)", title: "T", tag: tag, createdAt: made, updatedAt: made)
    }

    // MARK: - the row

    @Test("the card stands first with the picture-tag count N while the memo tags have none")
    func presentFirstFromPictureTags() {
        let row = CollectionsPresentation.tagRow(
            memoTags: Self.tags([("garden", 4), ("porto", 2)]),
            pictureTags: Self.tags([("sunsets", 9), ("favorites", 7)]),
            excluding: [])
        #expect(row.first == .favorites(count: 7), "\(row)")
        #expect(row.count == 3, "\(row)")
    }

    @Test("no card at zero, nor with no entry, while a memo tag favorites: 5 exists")
    func absentAtZero() {
        let memo = Self.tags([("favorites", 5), ("garden", 4)])
        for pictureTags in [Self.tags([("favorites", 0)]), [], Self.tags([("sunsets", 3)])] {
            let row = CollectionsPresentation.tagRow(
                memoTags: memo, pictureTags: pictureTags, excluding: [])
            #expect(
                row == [.tag(LibraryTag(name: "favorites", count: 5)), .tag(memo[1])],
                "\(pictureTags) → \(row)")
        }
    }

    @Test("a trip tagged favorites neither hides the card nor feeds it")
    func aTripNamedFavoritesIsIgnored() {
        let excluded = CollectionsPresentation.tripTags(
            [Self.trip("favorites")], listFailed: false)
        let memo = Self.tags([("favorites", 5), ("garden", 4)])
        let shown = CollectionsPresentation.tagRow(
            memoTags: memo, pictureTags: Self.tags([("favorites", 2)]), excluding: excluded)
        #expect(shown == [.favorites(count: 2), .tag(memo[1])], "\(shown)")
        let none = CollectionsPresentation.tagRow(
            memoTags: memo, pictureTags: [], excluding: excluded)
        #expect(none == [.tag(memo[1])], "a trip's tag fed the card: \(none)")
    }

    @Test("the other tag cards keep their order and their exclusions behind the card")
    func otherTagsUnchanged() {
        let memo = Self.tags([("zeta", 1), ("alpha", 9), ("lisbon", 3), ("mid", 5)])
        let excluded: Set<String> = ["lisbon"]
        let row = CollectionsPresentation.tagRow(
            memoTags: memo, pictureTags: Self.tags([("favorites", 1)]), excluding: excluded)
        let without = CollectionsPresentation.tagRow(
            memoTags: memo, pictureTags: [], excluding: excluded)
        let expected = CollectionsPresentation.tags(memo, excluding: excluded).map {
            CollectionsPresentation.TagRowCard.tag($0)
        }
        #expect(Array(row.dropFirst()) == expected, "\(row)")
        #expect(without == expected, "\(without)")
        #expect(expected.map(\.id) == ["tag:zeta", "tag:alpha", "tag:mid"])
    }

    @Test("the card's route is the .pictureTag(\"favorites\") collection, titled Favorites")
    func theRouteIsThePictureTag() {
        let route = CollectionsScreen.favoritesRoute(
            count: 4, cover: nil, zone: TimeZone(identifier: "UTC")!, under: alice)
        guard case .automatic(let collection) = route.scope else {
            Issue.record("not an automatic collection: \(route.scope)")
            return
        }
        #expect(collection.kind == .pictureTag("favorites"))
        #expect(collection.count == 4)
        #expect(route.scope.title == "Favorites")
        #expect(route.scope.tag == nil, "the favorites grid would read a memo tag")
    }

    // MARK: - rendered

    private func screen(
        _ wire: CollectionsWire, pictureTags: PictureTagStore, covers: TagCoverStore,
        favorites: FavoriteStore? = nil
    ) -> some View {
        let trips = TripStore(identity: alice, root: root)
        let access = wire.access
        return NavigationStack {
            CollectionsScreen(
                trips: trips, members: TripMemberStore(trips: trips), tags: LibraryTagStore(),
                tagCovers: covers, pictureTags: pictureTags, favorites: favorites,
                identity: alice, access: { access })
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }

    @Test("rendered: the heart card leads the Tags row with the picture-tag count, its cover read")
    func renderedFirst() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(#"[{"name":"garden","count":2}]"#)
        wire.transport.answerPictureTags(#"[{"name":"favorites","count":3}]"#)
        let pictureTags = PictureTagStore()
        let covers = TagCoverStore()
        await CollectionsHost.with(screen(wire, pictureTags: pictureTags, covers: covers)) {
            screen in
            #expect(await screen.until { screen.element(labelled: "Favorites") != nil })
            #expect(await screen.until { screen.element(labelled: "#garden") != nil })
            let card = screen.element(labelled: "Favorites")
            let tag = screen.element(labelled: "#garden")
            #expect(card?.accessibilityValue == bucketCountLabel(3))
            #expect(
                (card?.accessibilityFrame.minX ?? .infinity) < (tag?.accessibilityFrame.minX ?? 0),
                "the Favorites card is not first")
            #expect(await screen.until { covers.answer(for: .pictureTag("favorites")) != nil })
        }
        let lookups = wire.transport.sent.filter { $0.contains("pictureTag=favorites") }
        #expect(lookups.count == 1, "\(lookups)")
        #expect(
            lookups.allSatisfy {
                $0.contains("limit=1")
                    && $0.range(of: "[?&]tag=", options: .regularExpression) == nil
            }, "\(lookups)")
    }

    @Test("rendered: no heart card at zero while a memo tag favorites: 5 has its own card")
    func renderedAbsentAtZero() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(#"[{"name":"favorites","count":5}]"#)
        wire.transport.answerPictureTags(#"[{"name":"favorites","count":0}]"#)
        let pictureTags = PictureTagStore()
        await CollectionsHost.with(
            screen(wire, pictureTags: pictureTags, covers: TagCoverStore())
        ) { screen in
            #expect(await screen.until { screen.element(labelled: "#favorites") != nil })
            #expect(await screen.until { pictureTags.loadedFilter == .all })
            await screen.settle(turns: 10)
            #expect(screen.element(labelled: "Favorites") == nil, "a card at zero")
        }
    }

    /// Codex r1: a read that ends still stale — B landed during it, forcing the store's one
    /// retry, and C during that retry — must still be followed by one more read. A reload keyed
    /// on the stale flag's false-to-true edge sees it stay true and never reads again.
    @Test("rendered: three commits over one read and its retry end in one more read and the truth")
    func aReadThatEndsStaleIsReadAgain() async {
        let wire = CollectionsWire()
        wire.transport.answerTags("[]")
        let one = #"[{"name":"favorites","count":1}]"#
        let none = #"[{"name":"favorites","count":0}]"#
        wire.transport.scriptPictureTags([one, none, one, none])
        let favorites = FavoriteStore()
        let pictureTags = PictureTagStore()
        pictureTags.follow(favorites)
        let handle = wire.access.handle
        let base = CollectionsWire.baseURL
        await CollectionsHost.with(
            screen(wire, pictureTags: pictureTags, covers: TagCoverStore(), favorites: favorites)
        ) { screen in
            wire.transport.releasePictureTagRead()
            #expect(await screen.until { screen.element(labelled: "Favorites") != nil })
            // A: unfavorite pA — the second read goes out and is held.
            await favorites.setFavorite(
                uid: "pA", to: false, shownTags: ["favorites"], using: handle, baseURL: base
            ).value
            #expect(await screen.until { wire.transport.pictureTagReads == 2 })
            // B lands while it is out: its answer is behind, so the store reads once more.
            await favorites.setFavorite(
                uid: "pB", to: true, shownTags: [], using: handle, baseURL: base
            ).value
            await screen.settle(turns: 10)
            wire.transport.releasePictureTagRead()
            #expect(await screen.until { wire.transport.pictureTagReads == 3 })
            // C lands during that retry: the retry's answer is behind as well.
            await favorites.setFavorite(
                uid: "pB", to: false, shownTags: ["favorites"], using: handle, baseURL: base
            ).value
            await screen.settle(turns: 10)
            wire.transport.releasePictureTags()
            #expect(
                await screen.until { screen.element(labelled: "Favorites") == nil },
                "the card still counts a favorite that is gone")
            await screen.settle(turns: 10)
        }
        #expect(favorites.revision == 3)
        #expect(pictureTags.tags.first { $0.name == "favorites" }?.count == 0)
        #expect(wire.transport.pictureTagReads == 4, "one follow-up read, not one per commit")
    }
}
