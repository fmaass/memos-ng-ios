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
@Suite("Collection cards", .serialized, .mediaGlobals, .timeLimit(.minutes(2)))
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

    /// The height of `lines` lines of headline text, measured the way the title is: a font's
    /// line height alone leaves out the spacing SwiftUI puts between two lines.
    private static func referenceHeight(lines: Int) -> CGFloat {
        let text = Array(repeating: "Lighthouse", count: lines).joined(separator: "\n")
        return LayoutProbe.size(
            Text(text).font(.headline), width: LayoutProbe.unbounded, typeSize: .large
        ).height
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
        let twoLines = Self.referenceHeight(lines: 2)
        let oneLine = Self.referenceHeight(lines: 1)
        #expect(twoLines > oneLine + 10, "control: the reference did not break its line")
        #expect(abs(two - twoLines) < 1, "the long title is \(two) tall, two lines \(twoLines)")
        #expect(abs(one - oneLine) < 1, "one word is \(one) tall, one line \(oneLine)")
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
                CollectionsHost.identified(CollectionCard.coverIdentifier("p2"), in: screen.window)
            }
            #expect(drawn, "the card never drew its cover: \(wire.transport.sent)")
        }
        await CollectionsHost.with(tagCard("garden", covers: covers, wire: wire)) { screen in
            let drawn = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p2"), in: screen.window)
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

    // MARK: - The rest of the phase

    private func trip(_ tag: String?) -> Trip {
        let made = Self.now
        return Trip(uid: "t-\(tag ?? "-")", title: "T", tag: tag, createdAt: made, updatedAt: made)
    }

    @Test("a listed trip's tag is left out, in order; nothing is while the list failed")
    func tripTagExclusion() {
        let trips = [trip("gaggiano"), trip(nil), trip("lisbon")]
        let tags = ["garden", "gaggiano", "lisbon", "porto"].map { LibraryTag(name: $0, count: 1) }
        let excluded = CollectionsPresentation.tripTags(trips, listFailed: false)
        #expect(excluded == ["gaggiano", "lisbon"])
        let kept = CollectionsPresentation.tags(tags, excluding: excluded)
        #expect(kept.map(\.name) == ["garden", "porto"])
        #expect(CollectionsPresentation.tripTags(trips, listFailed: true).isEmpty)
        #expect(CollectionsPresentation.tripTags([], listFailed: false).isEmpty)
    }

    @Test("a tag is left out only by its whole name: a longer or differently cased one stays")
    func aTagIsLeftOutByItsWholeName() {
        let excluded = CollectionsPresentation.tripTags(
            [trip("gaggiano"), trip("lisbon")], listFailed: false)
        let tags = ["gaggianos", "gaggi", "Lisbon", "lisbon"].map {
            LibraryTag(name: $0, count: 1)
        }
        let kept = CollectionsPresentation.tags(tags, excluding: excluded)
        #expect(kept.map(\.name) == ["gaggianos", "gaggi", "Lisbon"])
    }

    @Test("with every tag a trip's, the root draws no Tags row")
    func noTagLeftNoRow() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(#"[{"name":"gaggiano","count":5}]"#)
        wire.transport.trips.seed("Gaggiano", tag: "gaggiano")
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            #expect(await screen.until { !stores.0.trips.isEmpty && !stores.2.tags.isEmpty })
            #expect(await screen.until { screen.says("Gaggiano") })
            await screen.settle(turns: 10)
            #expect(!screen.says(CollectionsScreen.tagsHeader), "a Tags row with no card")
        }
    }

    @Test("with every pictured tag a trip's, the sheet says so rather than that none has a photo")
    func everyTagIsATrip() async {
        let wire = CollectionsWire()
        wire.transport.answerTags(#"[{"name":"gaggiano","count":5}]"#)
        wire.transport.trips.seed("Gaggiano", tag: "gaggiano")
        let stores = stores()
        await stores.0.refresh(using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        let sheet = NewTripSheet(
            flow: NewTripFlow(), trips: stores.0, members: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now })
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { screen.says(NewTripSheet.everyTagIsATrip) })
            #expect(!screen.says(NewTripSheet.noTags))
        }
    }

    @Test("a chosen tag that becomes a trip's is dropped with what it filled; a typed title stays")
    func aChosenTagThatBecomesATripIsDropped() {
        let flow = NewTripFlow()
        let first = Date(timeIntervalSince1970: 1_773_316_800)
        let span = TripTagSpan(firstTaken: first, lastTaken: first)
        let utc = TimeZone(identifier: "UTC")!
        flow.choose("garden", span: span, zone: utc)
        #expect(flow.span != nil, "precondition: the span was prefilled")
        flow.drop(["lisbon"])
        #expect(flow.chosenTag == "garden", "a tag that is no trip's was dropped")
        flow.drop(["garden"])
        #expect(flow.chosenTag == nil)
        #expect(flow.title.isEmpty, "the suggested title stayed")
        #expect(flow.span == nil, "the prefilled span stayed")
        #expect(!flow.canCreate)
        flow.choose("porto", zone: utc)
        flow.title = "My own"
        flow.drop(["porto"])
        #expect(flow.chosenTag == nil)
        #expect(flow.title == "My own", "a typed title went with the tag")
    }

    @Test("a tag that becomes a trip's while a Create is out is dropped once that Create fails")
    func aTagExcludedDuringAFailedCreateIsDropped() async {
        let wire = CollectionsWire()
        wire.transport.trips.fail([TripRows.create])
        wire.transport.trips.hold(TripRows.create)
        let store = TripStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose("garden")
        flow.endDatesRead(of: "garden")
        let creating = Task { await flow.create(in: store, using: wire.access) }
        for _ in 0..<1000 where !flow.isCreating { await Task.yield() }
        #expect(flow.isCreating, "precondition: the Create is out")
        flow.drop(["garden"])
        #expect(flow.chosenTag == "garden", "control: a Create out keeps its tag")
        wire.transport.trips.release(TripRows.create)
        #expect(await creating.value == nil, "precondition: the Create failed")
        #expect(flow.chosenTag == nil, "the tag that became a trip's is still chosen")
        #expect(!flow.canCreate, "the tag that became a trip's can be sent again")
    }

    @Test("a month card asks for its month, a year card for its year")
    func monthAndYearCardsAsk() async {
        let wire = CollectionsWire()
        wire.transport.answerTags("[]")
        wire.transport.answerMonths(
            "[\(Self.bucket("2026-10", 12)),\(Self.bucket("2026-09", 4))]")
        let months = LibraryBucketStore()
        let years = LibraryBucketStore()
        let opened = Box<[String]>([])
        let access = wire.access
        let held = stores()
        let view = NavigationStack {
            CollectionsScreen(
                trips: held.0, members: held.1, tags: held.2, years: years,
                months: months, identity: alice, access: { access }, openTag: { _ in },
                openYear: { opened.value.append("year \($0)") },
                openMonth: { opened.value.append("month \($0)") }, now: { Self.now })
        }
        await CollectionsHost.with(view) { screen in
            #expect(await screen.until { screen.element(labelled: "Sep 2026") != nil })
            let value = screen.element(labelled: "Oct 2026")?.accessibilityValue
            #expect(value == "12 items")
            #expect(screen.press("Sep 2026"), "the month card took no press")
            #expect(await screen.until { screen.element(labelled: "2019") != nil })
            #expect(screen.press("2019"), "the year card took no press")
        }
        #expect(opened.value == ["month 2026-09", "year 2019"])
    }

    @Test("a month request widens the tag, shows Months at that month, and is applied once")
    func monthJumpAppliedOnce() {
        let jump = LibraryMonthJump()
        let scope = LibraryScopeChoice()
        let library = MediaLibraryStore()
        library.setTag("portugal2026")
        let resting = LibraryMonthJumpRouting.tab(showing: .collections, whenOpening: nil)
        #expect(resting == .collections)
        jump.request("2026-03")
        let asked = LibraryMonthJumpRouting.tab(showing: .collections, whenOpening: jump.pending)
        #expect(asked == .library)
        #expect(LibraryMonthJumpRouting.apply(jump, to: library, scope: scope), "no re-read")
        #expect(library.tag == nil, "the tag was kept")
        #expect(scope.scope == .months)
        #expect(scope.monthTarget == "2026-03")
        #expect(scope.year == nil)
        #expect(jump.pending == nil)
        scope.choose(.all)
        #expect(!LibraryMonthJumpRouting.apply(jump, to: library, scope: scope), "applied twice")
        #expect(scope.scope == .all, "a taken request moved the scope again")
    }

    @Test("a month card on the Collections root opens the Library in Months")
    func aMonthCardReachesTheLibrary() async {
        let transport = CollectionsTransport()
        transport.answerMonths("[\(Self.bucket("2026-03", 3))]")
        let session = CollectionsWire.signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            let card = await screen.until { screen.element(labelled: "Mar 2026") != nil }
            #expect(card, "the Months row never appeared: \(transport.sent)")
            let library = MainTab.library.title
            let resting = ScopeBarProbe.selectedTitle(in: screen.window)
            #expect(resting != library, "control: the tabs already stood on the Library")
            #expect(screen.press("Mar 2026"), "the card took no press")
            let moved = await screen.until(seconds: 10) {
                ScopeBarProbe.selectedTitle(in: screen.window) == library
            }
            #expect(moved, "the tabs never moved to the Library")
            // The scope row stands in the bar's place once the Library's item is pressed
            // (MEMNG-604); it shows the scope the jump left, and choosing nothing itself.
            #expect(ScopeBarProbe.pressTab(.library, in: screen.window), "no Library item")
            let months = await screen.until(seconds: 10) {
                let control = ScopeBarProbe.control(in: screen.window)
                return control.flatMap(ScopeBarProbe.chosen(in:)) == "Months"
            }
            #expect(months, "not Months: \(ScopeBarProbe.describe(screen.window))")
        }
    }

    /// The verification gate's count: a root open with 3 trips, 6 tags, 12 months and 3 years.
    /// The numbers are information, printed for the record, not a threshold — but a month or year
    /// card that looked a cover up, or a tag card that looked one up twice, fails.
    @Test("a root open with 3 trips, 6 tags, 12 months and 3 years: its requests, counted")
    func requestCount() async {
        let wire = CollectionsWire()
        for tag in ["lisbon", "porto", "faro"] {
            wire.transport.trips.seed(tag.capitalized, tag: tag)
        }
        let names = ["garden", "harbour", "market", "river", "school", "winter"]
        let tags = names.map { #"{"name":""# + $0 + #"","count":4}"# }
        wire.transport.answerTags("[\(tags.joined(separator: ","))]")
        let monthKeys = (1...12).map { String(format: "2026-%02d", $0) }
        wire.transport.answerMonths(
            "[\(monthKeys.reversed().map { Self.bucket($0, 2) }.joined(separator: ","))]")
        wire.transport.answerYears(
            "[\(["2026", "2025", "2024"].map { Self.bucket($0, 9) }.joined(separator: ","))]")
        let stores = stores()
        let months = LibraryBucketStore()
        let years = LibraryBucketStore()
        let covers = TagCoverStore()
        let view = screen(stores, wire, years: years, months: months, covers: covers)
        await CollectionsHost.with(view) { screen in
            let drawn = await screen.until(seconds: 10) {
                screen.element(labelled: "#garden") != nil
                    && screen.element(labelled: "Dec 2026") != nil
                    && screen.element(labelled: "2026") != nil
                    && stores.0.trips.allSatisfy { stores.1.summary(for: $0) != nil }
                    && covers.cover(for: "garden") != nil
            }
            #expect(drawn, "the root never drew its rows: \(wire.transport.sent)")
            await screen.settle(turns: 20)
        }
        let sent = wire.transport.sent
        let buckets = sent.filter { $0.hasPrefix("attachment_buckets") }
        let lookups = wire.transport.coverReads()
        let baseline = sent.count - buckets.count - lookups
        let perTag = names.map { wire.transport.coverReads(of: $0) }
        print(
            "REQUEST-COUNT baseline=\(baseline) buckets=\(buckets.count) "
                + "(month=\(buckets.filter { $0.contains("size=month") }.count) "
                + "year=\(buckets.filter { $0.contains("size=year") }.count)) "
                + "tag-covers=\(lookups) per-tag=\(perTag)")
        #expect(buckets.count == 2, "\(buckets)")
        #expect(perTag.allSatisfy { $0 <= 1 }, "a tag's cover was looked up twice: \(perTag)")
        #expect(lookups >= 1, "no tag card looked its cover up")
    }
}
