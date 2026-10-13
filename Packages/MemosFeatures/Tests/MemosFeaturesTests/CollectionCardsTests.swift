import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The Collections root's cover cards (MEMNG-783): the name inside the picture, two lines at
/// most; Tags, Months and Years as cards; a trip's tag not listed as a tag; a tag card's cover
/// looked up once.
@MainActor
@Suite("Collection cards", .serialized, .mediaGlobals)
struct CollectionCardsTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "collection-cards").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    /// 2026-10-08T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_791_460_800)

    /// 12 to 28 March 2026 as the span formatter writes it in British English.
    private static var marchSpan: String {
        let first = Date(timeIntervalSince1970: 1_773_316_800)  // 2026-03-12T12:00:00Z
        let last = Date(timeIntervalSince1970: 1_774_699_200)  // 2026-03-28T12:00:00Z
        return CollectionsPresentation.spanText(
            first: first, last: last, locale: Locale(identifier: "en_GB"),
            timeZone: TimeZone(identifier: "UTC")!) ?? "?"
    }

    private static func bucket(_ key: String, _ count: Int, cover: String = "p0") -> String {
        #"{"key":""# + key + #"","count":"# + "\(count)"
            + #","coverUid":""# + cover + #"","tags":[],"coverThumbnailUrl":"/api/attachments/"#
            + cover + #"/thumb"}"#
    }

    private func stores() -> (TripStore, TripMemberStore, LibraryTagStore) {
        let trips = TripStore(identity: alice, root: root)
        return (trips, TripMemberStore(trips: trips), LibraryTagStore())
    }

    private func screen(
        _ stores: (TripStore, TripMemberStore, LibraryTagStore),
        _ wire: CollectionsWire,
        years: LibraryBucketStore? = nil,
        months: LibraryBucketStore? = nil,
        covers: TagCoverStore? = nil
    ) -> some View {
        let access = wire.access
        return NavigationStack {
            CollectionsScreen(
                trips: stores.0, members: stores.1, tags: stores.2, years: years,
                months: months, tagCovers: covers, identity: alice, access: { access },
                openTag: { _ in }, now: { Self.now })
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }

    /// Every accessibility label and value on the window, children included.
    private static func spoken(in node: Any) -> [String] {
        var said: [String] = []
        var stack: [Any] = [node]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if let label = object.accessibilityLabel { said.append(label) }
            if let value = object.accessibilityValue { said.append(value) }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return said
    }

    // MARK: - RED 1: the title wraps inside the cover

    /// The title's line height at the size a test host lays it out in.
    private static var lineHeight: CGFloat {
        UIFont.preferredFont(
            forTextStyle: .headline,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        ).lineHeight
    }

    @Test("a long title wraps to exactly two lines on a 160-point card, one word to one line")
    func theTitleWrapsToTwoLines() {
        let long = Array(repeating: "Lighthouse", count: 12).joined(separator: " ")
        let card = CollectionCard(cover: nil, title: long, count: 3)
        let size = LayoutProbe.size(card, width: LayoutProbe.unbounded, typeSize: .large)
        #expect(size.width == 160, "the card is \(size.width) wide")
        let two = LayoutProbe.size(
            CollectionCard.title(long), width: LayoutProbe.unbounded, typeSize: .large
        ).height
        let one = LayoutProbe.size(
            CollectionCard.title("Lisbon"), width: LayoutProbe.unbounded, typeSize: .large
        ).height
        #expect(abs(two - 2 * Self.lineHeight) < 1, "the long title is \(two) tall")
        #expect(abs(one - Self.lineHeight) < 1, "one word is \(one) tall")
    }

    // MARK: - RED 2: a trip's tag is not a tag card, nor a New trip choice

    private static let gardenTags =
        #"[{"name":"gaggiano","count":5},{"name":"garden","count":7}]"#

    @Test("the root lists one tag card when the other tag is a trip's")
    func aTripsTagIsNoTagCard() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(Self.gardenTags)
        wire.transport.trips.seed("Gaggiano", tag: "gaggiano")
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            let listed = await screen.until {
                !stores.0.trips.isEmpty && screen.element(labelled: "#garden") != nil
            }
            #expect(listed, "precondition: the trip and the garden card are on screen")
            await screen.settle(turns: 10)
            #expect(screen.element(labelled: "#gaggiano") == nil, "the trip's tag has a card")
        }
    }

    @Test("the New trip sheet offers only the tag that is not a trip yet")
    func aTripsTagIsNoNewTripChoice() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(Self.gardenTags)
        wire.transport.trips.seed("Gaggiano", tag: "gaggiano")
        let stores = stores()
        await stores.0.refresh(using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        #expect(stores.0.trips.map(\.tag) == ["gaggiano"], "precondition: the trip is listed")
        let sheet = NewTripSheet(
            flow: NewTripFlow(), trips: stores.0, members: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now })
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { screen.element(labelled: "garden") != nil })
            await screen.settle(turns: 10)
            #expect(screen.element(labelled: "gaggiano") == nil, "the sheet offers a trip's tag")
        }
    }

    // MARK: - RED 3: the Months row

    @Test("month cards are titled with the short month and year, newest first, with their counts")
    func monthCardVectors() {
        let october = LibraryBucket(
            key: "2026-10", count: 12, coverUID: "a", coverThumbnailURL: nil)
        let september = LibraryBucket(
            key: "2026-09", count: 4, coverUID: "b", coverThumbnailURL: nil)
        for buckets in [[october, september], [september, october]] {
            let cards = CollectionsPresentation.monthCards(buckets)
            #expect(cards.map(\.title) == ["Oct 2026", "Sep 2026"])
            #expect(cards.map(\.count) == [12, 4])
            #expect(cards.map(\.key) == ["2026-10", "2026-09"])
        }
    }

    // MARK: - RED 4: a tag card's cover

    private func tagCard(
        _ name: String, covers: TagCoverStore, wire: CollectionsWire
    ) -> some View {
        TagCard(
            tag: LibraryTag(name: name, count: 7), covers: covers,
            access: { [access = wire.access] in access }, open: {})
    }

    @Test("two appearances of one tag card look its cover up once")
    func twoAppearancesOneLookup() async {
        let wire = CollectionsWire()
        let covers = TagCoverStore()
        await CollectionsHost.with(tagCard("garden", covers: covers, wire: wire)) { screen in
            let drawn = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p0"), in: screen.window)
            }
            #expect(drawn, "the card never drew its cover: \(wire.transport.sent)")
        }
        await CollectionsHost.with(tagCard("garden", covers: covers, wire: wire)) { screen in
            let drawn = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p0"), in: screen.window)
            }
            #expect(drawn, "the second appearance drew no cover")
        }
        #expect(wire.transport.coverReads(of: "garden") == 1, "\(wire.transport.sent)")
    }

    @Test("two cards of one tag on screen at once share one lookup")
    func overlappingAppearancesJoin() async {
        let wire = CollectionsWire()
        wire.transport.holdCovers()
        let covers = TagCoverStore()
        let pair = VStack {
            tagCard("garden", covers: covers, wire: wire)
            tagCard("garden", covers: covers, wire: wire)
        }
        await CollectionsHost.with(pair) { screen in
            #expect(await screen.until { wire.transport.coverReads(of: "garden") > 0 })
            await screen.settle(turns: 10)
            wire.transport.releaseCovers()
            #expect(await screen.until { covers.cover(for: "garden") != nil })
        }
        #expect(wire.transport.coverReads(of: "garden") == 1, "\(wire.transport.sent)")
    }

    @Test("a cover lookup answered 500 leaves the plain tile and says nothing")
    func aFailedLookupIsThePlainTile() async {
        let wire = CollectionsWire()
        wire.transport.failCovers()
        let covers = TagCoverStore()
        await CollectionsHost.with(tagCard("garden", covers: covers, wire: wire)) { screen in
            #expect(await screen.until { covers.covers["garden"] == TagCoverStore.Cover.none })
            #expect(
                CollectionsHost.identified(CollectionCard.coverIdentifier(nil), in: screen.window))
            let said = Self.spoken(in: screen.window)
            #expect(said.contains("#garden"), "the card left: \(said)")
            let error = said.filter { $0.localizedCaseInsensitiveContains("error") }
            #expect(error.isEmpty, "the card said \(error)")
        }
        #expect(wire.transport.coverReads(of: "garden") == 1, "\(wire.transport.sent)")
    }

    @Test("a month card draws its bucket's cover and looks nothing up")
    func aMonthCardLooksNothingUp() async {
        let wire = CollectionsWire()
        wire.transport.answerTags("[]")
        wire.transport.answerMonths("[\(Self.bucket("2026-10", 12, cover: "m10"))]")
        let months = LibraryBucketStore()
        let covers = TagCoverStore()
        let view = screen(stores(), wire, months: months, covers: covers)
        await CollectionsHost.with(view) { screen in
            let shown = await screen.until { screen.element(labelled: "Oct 2026") != nil }
            #expect(shown, "the month card never appeared: \(wire.transport.sent)")
            let cover = CollectionCard.coverIdentifier("m10")
            #expect(CollectionsHost.identified(cover, in: screen.window), "no bucket cover")
            await screen.settle(turns: 10)
        }
        #expect(wire.transport.coverReads() == 0, "\(wire.transport.sent)")
    }

    // MARK: - RED 5: no span on any card

    @Test("a card takes a cover, a title and a count, and nothing on the root says a span")
    func noSpanOnTheRoot() async {
        // Compile-time: the card's whole initialiser.
        let card: CollectionCard = CollectionCard(cover: nil, title: "Lisbon", count: 3)
        #expect(card.title == "Lisbon")
        let wire = CollectionsWire()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026", count: 3)
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            let drained = await screen.until {
                stores.0.trips.first.flatMap { stores.1.summary(for: $0) } != nil
            }
            #expect(drained, "precondition: the trip's members were read")
            #expect(await screen.until { screen.says("Portugal 2026") })
            await screen.settle(turns: 10)
            let said = Self.spoken(in: screen.window)
            let span = Self.marchSpan
            #expect(!said.contains { $0.contains(span) }, "the root says the span: \(said)")
        }
    }
}
