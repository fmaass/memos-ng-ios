import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// 12 to 28 March 2026 as British English writes a range of days: the locale's own range, whose
/// en dash stands between two thin spaces (U+2009) — the device's format, not one this app makes.
private let range = "12\u{2009}–\u{2009}28 Mar 2026"

// MARK: - The rules, as pure functions

/// Which tags look like a trip, and what a trip made of one is called.
@MainActor
@Suite("Trip rules")
struct TripRulesTests {
    /// 2026-10-08T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_791_460_800)
    private static let day: TimeInterval = 24 * 60 * 60

    private static func summary(_ first: Date?, _ last: Date?, count: Int = 12) -> TripSummary {
        TripSummary(count: count, firstTaken: first, lastTaken: last, coverUid: nil)
    }

    /// 2026-03-12T12:00:00Z, seven months before `now`.
    private static let march = Date(timeIntervalSince1970: 1_773_316_800)

    @Test("a short span with a recent last picture is suggested")
    func shortAndRecent() {
        let summary = Self.summary(Self.march, Self.march + 16 * Self.day)
        #expect(TripSuggestion.rule(tag: "portugal2026", summary: summary, now: Self.now))
    }

    @Test("a short span whose last picture is over two years old is not")
    func shortAndOld() {
        let old = Self.march - 3 * 365 * Self.day
        let summary = Self.summary(old, old + 16 * Self.day)
        #expect(!TripSuggestion.rule(tag: "portugal2023", summary: summary, now: Self.now))
    }

    @Test("a long span with a recent last picture is not")
    func longAndRecent() {
        let summary = Self.summary(Self.march - 400 * Self.day, Self.march)
        #expect(!TripSuggestion.rule(tag: "family", summary: summary, now: Self.now))
    }

    @Test("a tag with no pictures is not", arguments: [0, 3])
    func noPictures(count: Int) {
        // No picture at all, and a count with no taken date to measure a span on.
        let summary = Self.summary(nil, nil, count: count)
        #expect(!TripSuggestion.rule(tag: "empty", summary: summary, now: Self.now))
    }

    @Test("exactly sixty days is not a trip; a second less is")
    func theSixtyDayBoundary() {
        let exactly = Self.summary(Self.march, Self.march + 60 * Self.day)
        #expect(!TripSuggestion.rule(tag: "long-weekend", summary: exactly, now: Self.now))
        // The control: the boundary is the span, not the dates.
        let under = Self.summary(Self.march, Self.march + 60 * Self.day - 1)
        #expect(TripSuggestion.rule(tag: "long-weekend", summary: under, now: Self.now))
    }

    @Test("two years back to the second is still recent; a second before is not")
    func theRecencyBoundary() {
        let twoYears = Date(timeIntervalSince1970: 1_728_388_800)  // 2024-10-08T12:00:00Z
        let at = Self.summary(twoYears - Self.day, twoYears)
        #expect(TripSuggestion.rule(tag: "lisbon", summary: at, now: Self.now))
        let before = Self.summary(twoYears - Self.day, twoYears - 1)
        #expect(!TripSuggestion.rule(tag: "lisbon", summary: before, now: Self.now))
    }

    @Test("a last picture taken exactly now is suggested; one taken after now is not")
    func theFutureBoundary() {
        let atNow = Self.summary(Self.now - 5 * Self.day, Self.now)
        #expect(TripSuggestion.rule(tag: "today", summary: atNow, now: Self.now))
        // A clock set wrong: short, and recent by every other measure.
        let ahead = Self.summary(Self.now - 5 * Self.day, Self.now + Self.day)
        #expect(!TripSuggestion.rule(tag: "tomorrow", summary: ahead, now: Self.now))
        let aSecondAhead = Self.summary(Self.now - 5 * Self.day, Self.now + 1)
        #expect(!TripSuggestion.rule(tag: "tomorrow", summary: aSecondAhead, now: Self.now))
    }

    @Test("a count of zero is not a trip, however short and recent its dates")
    func aZeroCountWithDates() {
        let empty = Self.summary(Self.march, Self.march + Self.day, count: 0)
        #expect(!TripSuggestion.rule(tag: "emptied", summary: empty, now: Self.now))
        // The control: the same dates with one picture are a trip.
        let one = Self.summary(Self.march, Self.march + Self.day, count: 1)
        #expect(TripSuggestion.rule(tag: "emptied", summary: one, now: Self.now))
    }

    @Test("a tag with no name is never suggested")
    func aNamelessTag() {
        let summary = Self.summary(Self.march, Self.march + Self.day)
        #expect(!TripSuggestion.rule(tag: "  ", summary: summary, now: Self.now))
    }

    @Test(
        "a title is made from the tag",
        arguments: [
            ("portugal2026", "Portugal 2026"),
            ("nyc", "Nyc"),
            ("Trip-2025", "Trip 2025"),
            ("", ""),
            ("2026", "2026"),
            ("road_trip_2024", "Road_trip 2024"),
            // Digits inside the name are not a year: only a trailing run is split off.
            ("trip2026x", "Trip2026x"),
            ("route66west2025", "Route66west 2025"),
        ])
    func titles(tag: String, expected: String) {
        #expect(TripTitle.suggest(tag) == expected)
    }

    @Test("a span is written as the locale writes a range of days")
    func spanText() {
        let gb = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC")!
        let first = Self.march
        #expect(
            CollectionsPresentation.spanText(
                first: first, last: first + 16 * Self.day, locale: gb, timeZone: utc)
                == range)
        // One day is written once; either end missing is no span at all.
        #expect(
            CollectionsPresentation.spanText(first: first, last: first, locale: gb, timeZone: utc)
                == "12 Mar 2026")
        #expect(CollectionsPresentation.spanText(first: nil, last: first) == nil)
        #expect(CollectionsPresentation.spanText(first: first, last: nil) == nil)
    }

    @Test("a card says its span and count, and its count alone without a span")
    func cardDetail() {
        let gb = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC")!
        let summary = Self.summary(Self.march, Self.march + 16 * Self.day, count: 3)
        #expect(
            CollectionsPresentation.cardDetail(summary, locale: gb, timeZone: utc)
                == "\(range) · 3 photos")
        #expect(
            CollectionsPresentation.cardDetail(
                Self.summary(nil, nil, count: 1), locale: gb, timeZone: utc) == "1 photo")
        #expect(CollectionsPresentation.cardDetail(nil, locale: gb, timeZone: utc) == nil)
        #expect(
            CollectionsPresentation.tagDetail(count: 3, span: nil, locale: gb, timeZone: utc)
                == "3 photos")
    }

    @Test("only tags whose span has arrived and passes the rule are suggested")
    func suggested() {
        let tags = [
            LibraryTag(name: "family", count: 40),
            LibraryTag(name: "portugal2026", count: 3),
            LibraryTag(name: "unread", count: 2),
        ]
        let spans = [
            "family": TripTagSpan(firstTaken: Self.march - 900 * Self.day, lastTaken: Self.march),
            "portugal2026": TripTagSpan(
                firstTaken: Self.march, lastTaken: Self.march + 16 * Self.day),
        ]
        let names = CollectionsPresentation.suggested(tags, spans: spans, now: Self.now).map(\.name)
        #expect(names == ["portugal2026"])
    }

    @Test("a card's cover is the member its summary names, and nothing without one")
    func cover() {
        let row = LibraryRow(
            attachment: MemoAttachment(
                uid: "p1", mime: "image/jpeg", status: .ready,
                thumbnailURL: URL(string: "https://memos.example.invalid/t")!),
            takenAt: Self.march, mine: true, filename: "p1.jpg")
        var record = CollectionRecord(
            id: UUID(), kind: .trip, title: "T", tags: ["t"], order: 0, createdAt: Self.march)
        #expect(CollectionsPresentation.cover(of: record, members: [row]) == nil)
        record.lastSummary = TripSummary(count: 1, firstTaken: nil, lastTaken: nil, coverUid: "p1")
        #expect(CollectionsPresentation.cover(of: record, members: [row])?.uid == "p1")
        #expect(CollectionsPresentation.cover(of: record, members: []) == nil)
    }
}

// MARK: - Create, and the tag request

@MainActor
@Suite("New trip flow")
struct NewTripFlowTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "new-trip-flow").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    @Test("choosing a tag fills the title, and a title somebody typed survives another choice")
    func prefill() {
        let flow = NewTripFlow()
        #expect(!flow.canCreate)
        flow.choose("portugal2026")
        #expect(flow.title == "Portugal 2026")
        flow.choose("nyc")
        #expect(flow.title == "Nyc", "an untouched suggestion did not follow the tag")
        flow.title = "Our trip"
        flow.choose("portugal2026")
        #expect(flow.title == "Our trip")
        #expect(flow.canCreate)
    }

    @Test("Create files the trip once; a second Create is refused")
    func createsOnce() {
        let store = CollectionStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose("portugal2026")
        let made = flow.create(in: store)
        #expect(made?.title == "Portugal 2026")
        #expect(made?.tags == ["portugal2026"])
        #expect(flow.failure == nil)
        #expect(flow.create(in: store) == nil, "a second Create was not refused")
        #expect(store.records.count == 1)
        #expect(!flow.canCreate)
    }

    @Test("a Create whose write failed keeps the sheet's flow open, saying so")
    func aFailedWriteIsSaid() {
        struct Refused: Error {}
        let store = CollectionStore(
            identity: alice, root: root, writeBytes: { _, _ in throw Refused() })
        let flow = NewTripFlow()
        flow.choose("portugal2026")
        #expect(flow.create(in: store) == nil)
        #expect(flow.failure == NewTripFlow.notSaved)
        #expect(flow.created == nil)
        #expect(store.records.isEmpty, "precondition: nothing was filed")
        #expect(flow.canCreate, "a failed Create cannot be tried again")
    }

    @Test("signed out, Create files nothing and says so")
    func nobodySignedIn() {
        let store = CollectionStore(identity: nil, root: root)
        let flow = NewTripFlow()
        flow.choose("portugal2026")
        #expect(flow.create(in: store) == nil)
        #expect(flow.failure == NewTripFlow.notSaved)
    }

    @Test("a tag request opens the Library, and is applied to its store once")
    func tagRequest() {
        let jump = LibraryTagJump()
        #expect(LibraryTagJumpRouting.tab(showing: .collections, whenOpening: nil) == .collections)
        jump.request("portugal2026")
        #expect(
            LibraryTagJumpRouting.tab(showing: .collections, whenOpening: jump.pending) == .library)
        let library = MediaLibraryStore()
        #expect(LibraryTagJumpRouting.apply(jump, to: library))
        #expect(library.tag == "portugal2026")
        #expect(jump.pending == nil)
        #expect(!LibraryTagJumpRouting.apply(jump, to: library), "applied twice")
        jump.request("portugal2026")
        #expect(!LibraryTagJumpRouting.apply(jump, to: library), "the same tag read the grid again")
        #expect(jump.pending == nil)
    }
}

// MARK: - The screens, over a scripted transport

/// The Collections root and the New trip sheet, hosted over the real generated client with a
/// scripted transport. Held to the picture layer's suites (`.mediaGlobals`): a card's cover goes
/// through the shared loader.
@MainActor
@Suite("Collections root", .serialized, .mediaGlobals)
struct CollectionsRootRenderTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "collections-root").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    /// 2026-10-08T12:00:00Z.
    private static let now = Date(timeIntervalSince1970: 1_791_460_800)

    private func stores(writeBytes: ((Data, URL) throws -> Void)? = nil)
        -> (CollectionStore, TripMembershipStore, LibraryTagStore)
    {
        let collections =
            if let writeBytes {
                CollectionStore(identity: alice, root: root, writeBytes: writeBytes)
            } else {
                CollectionStore(identity: alice, root: root)
            }
        return (collections, TripMembershipStore(collections: collections), LibraryTagStore())
    }

    private func screen(
        _ stores: (CollectionStore, TripMembershipStore, LibraryTagStore),
        _ wire: CollectionsWire,
        openTag: @escaping (String) -> Void = { _ in }
    ) -> some View {
        let access = wire.access
        return NavigationStack {
            CollectionsScreen(
                collections: stores.0, trips: stores.1, tags: stores.2, subject: "alice",
                access: { access }, openTag: openTag, now: { Self.now })
        }
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
    }

    @Test("with no trip the root says so, and still lists the tags")
    func emptyState() async {
        let wire = CollectionsWire()
        let view = screen(stores(), wire)
        await CollectionsHost.with(view) { screen in
            #expect(await screen.until { screen.says(CollectionsScreen.emptyTitle) })
            #expect(await screen.until { screen.element(labelled: "#portugal2026") != nil })
            #expect(!screen.says(CollectionsScreen.tripsHeader), "a Trips row with no trip")
        }
    }

    @Test("a trip's card shows its title, and its span and count from the scripted membership")
    func oneTripCard() async {
        let wire = CollectionsWire()
        let stores = stores()
        stores.0.create(title: "Portugal 2026", tags: ["portugal2026"])
        #expect(stores.0.records.count == 1, "precondition: the trip is filed")
        await CollectionsHost.with(screen(stores, wire)) { screen in
            #expect(await screen.until { screen.says("\(range) · 3 photos") })
            #expect(screen.says("Portugal 2026"))
            #expect(!screen.says(CollectionsScreen.emptyTitle))
        }
        #expect(stores.0.records.first?.lastSummary?.count == 3)
    }

    @Test("a tag chip opens the Library narrowed to it")
    func aTagChipOpensTheLibrary() async {
        let wire = CollectionsWire()
        let opened = Box<String?>(nil)
        await CollectionsHost.with(screen(stores(), wire) { opened.value = $0 }) { screen in
            #expect(await screen.until { screen.element(labelled: "#family") != nil })
            #expect(screen.press("#family"))
        }
        #expect(opened.value == "family")
    }

    @Test("the sheet suggests the short recent tag under Suggested, and not the long one")
    func theSuggestedSection() async {
        let wire = CollectionsWire()
        let stores = stores()
        let sheet = NewTripSheet(
            flow: NewTripFlow(), collections: stores.0, trips: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now }
        )
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        await CollectionsHost.with(sheet) { screen in
            let suggested = NewTripSheet.suggestedRowID("portugal2026")
            #expect(await screen.until { CollectionsHost.identified(suggested, in: screen.window) })
            #expect(screen.says(NewTripSheet.suggestedHeader))
            // Both spans are read before the section is judged: family's arrived too.
            #expect(await screen.until { screen.says("40 photos · ") })
            let family = NewTripSheet.suggestedRowID("family")
            #expect(!CollectionsHost.identified(family, in: screen.window))
        }
    }

    @Test("Create files the trip and the root shows its card with span and count")
    func theCreateFlow() async {
        let wire = CollectionsWire()
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            #expect(await screen.until { screen.says(CollectionsScreen.emptyTitle) })
            // A toolbar item is installed on a later turn than the first layout.
            let plus = CollectionsScreen.newTripButton
            #expect(await screen.until { screen.element(labelled: plus) != nil })
            let pressed = CollectionsHost.pressBarItem(plus, on: screen)
            #expect(pressed.took, "the + took no press: \(pressed.seen)")
            #expect(await screen.until { screen.element(labelled: "portugal2026") != nil })
            #expect(screen.press("portugal2026"))
            #expect(await screen.until { screen.says("Portugal 2026") }, "the title was not filled")
            #expect(screen.press(NewTripSheet.create), "Create took no press")
            #expect(await screen.until { screen.says("\(range) · 3 photos") })
            #expect(await screen.until { screen.element(labelled: NewTripSheet.create) == nil })
            #expect(!screen.says(CollectionsScreen.emptyTitle))
        }
        #expect(stores.0.records.map(\.title) == ["Portugal 2026"])
        #expect(stores.0.records.map(\.tags) == [["portugal2026"]])
    }

    @Test("a Create that did not reach the store keeps the sheet open with an error line")
    func aFailedCreateStays() async {
        struct Refused: Error {}
        let wire = CollectionsWire()
        let stores = stores(writeBytes: { _, _ in throw Refused() })
        let sheet = NewTripSheet(
            flow: NewTripFlow(), collections: stores.0, trips: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now })
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { screen.element(labelled: "portugal2026") != nil })
            #expect(screen.press("portugal2026"))
            #expect(await screen.until { screen.element(labelled: NewTripSheet.create) != nil })
            #expect(screen.press(NewTripSheet.create))
            #expect(await screen.until { screen.says(NewTripFlow.notSaved) })
            #expect(screen.element(labelled: NewTripSheet.create) != nil, "the sheet went")
        }
        #expect(stores.0.records.isEmpty)
    }

    @Test("an identity change files the trips under the new identity and forgets every read")
    func identityChange() async {
        let bob = TimelineSnapshotIdentity(server: alice.server, subject: "bob")
        let wire = CollectionsWire()
        let collections = CollectionStore(identity: alice, root: root)
        let trips = TripMembershipStore(collections: collections)
        collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.loadTagCounts(using: wire.access.handle)
        await trips.loadSpan(
            ofTag: "portugal2026", using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        #expect(trips.tagCountsLoaded, "precondition: the counts were read")
        #expect(trips.spans["portugal2026"] != nil, "precondition: the span was read")

        CollectionsSession.identityChanged(to: bob, collections: collections, trips: trips)
        #expect(collections.identity == bob)
        #expect(collections.records.isEmpty, "B was shown A's trip")
        #expect(!trips.tagCountsLoaded, "B was shown A's tag counts")
        #expect(trips.spans.isEmpty, "B was shown A's spans")

        CollectionsSession.identityChanged(to: alice, collections: collections, trips: trips)
        #expect(collections.records.map(\.title) == ["Portugal 2026"], "A's trip did not return")
    }

    @Test("a tag chip on the Collections root narrows the Library's grid to that tag")
    func aTagChipReachesTheLibrary() async {
        let transport = CollectionsTransport()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            #expect(await screen.until { screen.element(labelled: "#portugal2026") != nil })
            // The control: nothing has read the grid under the tag before the press.
            #expect(!transport.sent.contains { Self.gridRead($0, tag: "portugal2026") })
            #expect(screen.press("#portugal2026"), "the chip took no press")
            let reached = await screen.until(seconds: 10) {
                transport.sent.contains { Self.gridRead($0, tag: "portugal2026") }
            }
            #expect(reached, "the Library never read its grid under the tag: \(transport.sent)")
        }
    }

    @Test("the grid read a tag chip starts outlives the request being taken, and lands")
    func aTagReadOutlivesItsRequest() async {
        let transport = CollectionsTransport()
        transport.hold(tag: "portugal2026")
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            // Out of `#expect`: a closure in the macro's expansion and one beside it can be given
            // one symbol by the compiler, which then refuses the build.
            let chip = await screen.until { screen.element(labelled: "#portugal2026") != nil }
            #expect(chip, "the chip never appeared")
            #expect(screen.press("#portugal2026"), "the chip took no press")
            let asked = await screen.until(seconds: 10) {
                transport.sent.contains { Self.gridRead($0, tag: "portugal2026") }
            }
            #expect(asked, "the Library never read its grid under the tag: \(transport.sent)")
            // The request was taken before that read began. Turns for the view to act on its
            // emptied request: a read tied to the request would be cancelled here.
            _ = await screen.until(seconds: 1.5) { false }
            // The control: the film is the held read's alone, so nothing has shown it yet.
            #expect(screen.element(labelled: "Video") == nil, "the film came from another read")
            transport.release()
            let landed = await screen.until(seconds: 10) {
                screen.element(labelled: "Video") != nil
            }
            #expect(landed, "the tag's grid never reached the screen")
        }
    }

    @Test("the timeline moves the collections when the session becomes somebody else's, and back")
    func theTimelineMovesTheCollections() async {
        let transport = CollectionsTransport()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        guard let fabian = session.snapshotIdentity, let handle = session.activeHandle else {
            Issue.record("precondition: signed in")
            return
        }
        let (collections, trips) = await tripsRead(as: fabian, using: handle)
        let timeline = TimelineView().environment(session).environment(collections)
            .environment(trips)
        await CollectionsHost.with(timeline) { screen in
            let shown = await Self.timelineShown(on: screen, transport)
            #expect(shown, "precondition: the timeline never read its first page")
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_bob")
            #expect(session.state.user?.subject == "bob", "precondition: bob signed in")
            let moved = await screen.until { collections.identity?.subject == "bob" }
            #expect(moved, "not moved")
            #expect(collections.records.isEmpty, "bob was shown fabian's trip")
            #expect(!trips.tagCountsLoaded, "bob was shown fabian's tag counts")

            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
            let back = await screen.until { collections.identity == fabian }
            #expect(back, "not moved back")
            #expect(collections.records.map(\.title) == ["Portugal 2026"], "the trip is lost")
        }
    }

    @Test("the same subject on another server is another account's collections")
    func aServerChangeMovesTheCollections() async {
        let transport = CollectionsTransport()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        guard let here = session.snapshotIdentity, let handle = session.activeHandle else {
            Issue.record("precondition: signed in")
            return
        }
        let (collections, trips) = await tripsRead(as: here, using: handle)
        let timeline = TimelineView().environment(session).environment(collections)
            .environment(trips)
        await CollectionsHost.with(timeline) { screen in
            let shown = await Self.timelineShown(on: screen, transport)
            #expect(shown, "precondition: the timeline never read its first page")
            await session.signIn(
                serverAddress: "elsewhere.example.invalid", token: "memos_pat_trips")
            guard let there = session.snapshotIdentity else {
                Issue.record("precondition: signed in elsewhere")
                return
            }
            #expect(there.subject == here.subject, "precondition: the same subject")
            #expect(there.server != here.server, "precondition: another server")
            let moved = await screen.until { collections.identity == there }
            #expect(moved, "not moved")
            #expect(collections.records.isEmpty, "the other server was shown this one's trip")
            #expect(!trips.tagCountsLoaded, "the other server was shown this one's tag counts")
        }
    }

    @Test("the identity watch sees a server change under the same subject, with nobody between")
    func theWatchSeesTheWholePair() async {
        let there = TimelineSnapshotIdentity(
            server: URL(string: "https://elsewhere.example.invalid")!, subject: alice.subject)
        let source = IdentitySource(alice)
        let seen = IdentitiesSeen()
        await CollectionsHost.with(IdentityWatchProbe(source: source, seen: seen)) { screen in
            await screen.settle(turns: 4)
            #expect(seen.values.isEmpty, "precondition: the first value is not a change")
            // A session that moves servers WITHOUT passing through nobody: the case no sign-in
            // can drive today, since each passes through signing in, where there is no user.
            source.identity = there
            let moved = await screen.until { seen.values == [there] }
            #expect(moved, "the server change was not seen: \(seen.values)")
            source.identity = nil
            let ended = await screen.until { seen.values == [there, nil] }
            #expect(ended, "signing out was not seen: \(seen.values)")
        }
    }

    /// Whether the hosted timeline is on screen: it has asked for its first page, so its body has
    /// run and its identity watch holds the identity signed in now. A sign-in driven before that
    /// would be the watch's first value, never a change.
    private static func timelineShown(
        on screen: PressProbe.Screen, _ transport: CollectionsTransport
    ) async -> Bool {
        let asked = await screen.until(seconds: 10) {
            transport.sent.contains { $0.hasPrefix("list_memos_api_memos_get ") }
        }
        await screen.settle(turns: 4)
        return asked
    }

    /// A collection store holding one trip under `identity`, and a membership store that has read
    /// the tag counts.
    private func tripsRead(
        as identity: TimelineSnapshotIdentity, using handle: SessionHandle
    ) async -> (CollectionStore, TripMembershipStore) {
        let collections = CollectionStore(identity: identity, root: root)
        let trips = TripMembershipStore(collections: collections)
        collections.create(title: "Portugal 2026", tags: ["portugal2026"])
        await trips.loadTagCounts(using: handle)
        #expect(collections.records.count == 1, "precondition: one trip")
        #expect(trips.tagCountsLoaded, "precondition: the counts were read")
        return (collections, trips)
    }

    /// Whether `sent` is the Library grid's read under `tag`: every kind of file (no `type`), not
    /// a span's one-row read nor a trip's drain, both of which ask for images.
    private static func gridRead(_ sent: String, tag: String) -> Bool {
        let parts = sent.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "list_attachments_api_attachments_get" else {
            return false
        }
        let query = URLComponents(string: parts[1])?.queryItems ?? []
        return query.contains { $0.name == "tag" && $0.value == tag }
            && !query.contains { $0.name == "type" }
    }

    private func signedOutSession(_ transport: CollectionsTransport) -> SessionStore {
        SessionStore(
            credentials: CollectionsCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration, credential: credential, transport: transport)
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            identity: MediaIdentity()
        )
    }

    @Test("a session's identity is its server and its subject, and nothing when signed out")
    func sessionIdentity() async {
        let session = SessionStore(
            credentials: CollectionsCredentials(),
            makeClient: { configuration, credential in
                APIClientFactory.make(
                    configuration: configuration, credential: credential,
                    transport: CollectionsTransport())
            },
            sleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            noticeSleeper: { _ in try await Task.sleep(for: .seconds(3600)) },
            identity: MediaIdentity()
        )
        #expect(session.snapshotIdentity == nil)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        #expect(session.snapshotIdentity?.subject == "fabian")
        #expect(session.snapshotIdentity?.server == session.serverBaseURL)
    }
}

// MARK: - Fixtures

/// The server, scripted: two tags, `portugal2026` three pictures 12–28 March 2026 and `family`
/// forty pictures over seven years.
@MainActor
final class CollectionsWire {
    static let baseURL = URL(string: "https://memos.example.invalid")!
    let transport = CollectionsTransport()
    let access: CollectionsAccess

    init() {
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.baseURL),
            token: { "memos_pat_trips" },
            transport: transport)
        access = CollectionsAccess(
            handle: SessionHandle(client: client, generation: 1), baseURL: Self.baseURL)
    }
}

/// The scripted server itself.
final class CollectionsTransport: ClientTransport, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var requests: [String] = []
    private nonisolated(unsafe) var heldTag: String?
    private nonisolated(unsafe) var released = false

    /// Every request sent so far, as `<operation id> <path and query>`.
    nonisolated var sent: [String] { lock.withLock { requests } }

    /// Holds every grid read under `tag` until `release()`. A held read that is cancelled throws,
    /// as URLSession's does, so a read whose task went away never answers.
    nonisolated func hold(tag: String) {
        lock.withLock { heldTag = tag }
    }

    nonisolated func release() {
        lock.withLock { released = true }
    }

    nonisolated func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        lock.withLock { requests.append("\(operationID) \(path)") }
        switch operationID {
        case "whoami_api_auth_user_get":
            // Whose token it is: `memos_pat_bob` is bob's, every other one fabian's.
            let token = request.headerFields[.authorization] ?? ""
            let subject = token.hasSuffix("memos_pat_bob") ? "bob" : "fabian"
            return Self.json(
                #"{"subject":""# + subject + #"","display_name":""# + subject
                    + #"","email":null,"role":"user","auth_kind":"oidc"}"#
            )
        case "attachment_tags_api_attachments_tags_get":
            return Self.json(
                #"[{"name":"portugal2026","count":3},{"name":"family","count":40}]"#)
        case "list_attachments_api_attachments_get":
            if isHeld(path) {
                while !lock.withLock({ released }) {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            return Self.list(path)
        default:
            return (HTTPResponse(status: .notFound), nil)
        }
    }

    /// Whether `path` is a grid read (every kind, no `type`) under the held tag.
    private nonisolated func isHeld(_ path: String) -> Bool {
        let query = URLComponents(string: path)?.queryItems ?? []
        guard let held = lock.withLock({ heldTag }) else { return false }
        return query.contains { $0.name == "tag" && $0.value == held }
            && !query.contains { $0.name == "type" }
    }

    private nonisolated static func list(_ path: String) -> (HTTPResponse, HTTPBody?) {
        let query = URLComponents(string: path)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        // The grid under `portugal2026` alone holds a film: a tile no other read can put there.
        if value("tag") == "portugal2026", value("type") == nil {
            return json("[\(item("trip-film", taken: "2026-03-14T12:00:00Z", mime: "video/mp4"))]")
        }
        let descending = value("order") == "taken_desc"
        let one = value("limit") == "1"
        let dates: [String]
        if value("tag") == "family" {
            dates = ["2019-01-01T12:00:00Z", "2026-03-01T12:00:00Z"]
        } else {
            dates = ["2026-03-12T12:00:00Z", "2026-03-20T12:00:00Z", "2026-03-28T12:00:00Z"]
        }
        var items = dates.enumerated().map { item("p\($0.offset)", taken: $0.element) }
        if descending { items.reverse() }
        if one { items = Array(items.prefix(1)) }
        return json("[\(items.joined(separator: ","))]")
    }

    private nonisolated static func item(
        _ uid: String, taken: String, mime: String = "image/jpeg"
    ) -> String {
        """
        {"uid":"\(uid)","mime":"\(mime)","status":"ready","blurhash":null,\
        "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
        "renditions":[],"orphan":false,"memoUid":"m-\(uid)",\
        "takenAt":"\(taken)","filename":"\(uid).jpg",\
        "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
        "previewUrl":"/api/attachments/\(uid)/mobile",\
        "webUrl":"/api/attachments/\(uid)/web",\
        "posterUrl":"/api/attachments/\(uid)/poster",\
        "downloadUrl":"/api/attachments/\(uid)/download",\
        "printUrl":"/api/attachments/\(uid)/print"}
        """
    }

    private nonisolated static func json(_ text: String) -> (HTTPResponse, HTTPBody?) {
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(text))
    }
}

private final class CollectionsCredentials: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func set(_ value: String, for account: String) async throws {
        lock.withLock { values[account] = value }
    }

    func string(for account: String) async throws -> String? {
        lock.withLock { values[account] }
    }

    func remove(_ account: String) async throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

/// An identity a test moves by hand, where the watch under test reads it.
@MainActor
@Observable
final class IdentitySource {
    var identity: TimelineSnapshotIdentity?

    init(_ identity: TimelineSnapshotIdentity?) {
        self.identity = identity
    }
}

/// Every identity the watch handed on, in order.
@MainActor
final class IdentitiesSeen {
    var values: [TimelineSnapshotIdentity?] = []
}

/// The identity watch alone, over an identity the test moves.
struct IdentityWatchProbe: View {
    let source: IdentitySource
    let seen: IdentitiesSeen

    var body: some View {
        Color.clear.onSessionIdentityChange(source.identity) { seen.values.append($0) }
    }
}

/// A window attached to the app's scene — a sheet presents only from one — and the press probe's
/// screen over it, with a bounded wait.
@MainActor
enum CollectionsHost {
    static func with(
        _ view: some View, height: CGFloat = 874, _ body: (PressProbe.Screen) async -> Void
    ) async {
        let frame = CGRect(x: 0, y: 0, width: 402, height: height)
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
        let window: UIWindow
        if let scene = scene as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        await body(PressProbe.Screen(host: host, window: window))
        host.presentedViewController?.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
    }

    /// Presses a navigation bar item by its label: its accessibility node first, then the control
    /// under it, then the bar item's own action — a toolbar item is drawn by UIKit, and which of
    /// these answers depends on how the system hosts it. Answers what it found when nothing took.
    static func pressBarItem(
        _ label: String, on screen: PressProbe.Screen
    ) -> (took: Bool, seen: String) {
        let element = screen.element(labelled: label)
        if element?.accessibilityActivate() == true { return (true, "") }
        var view = element as? UIView
        while let next = view {
            if let control = next as? UIControl {
                let event: UIControl.Event =
                    control.allControlEvents.contains(.primaryActionTriggered)
                    ? .primaryActionTriggered : .touchUpInside
                control.sendActions(for: event)
                return (true, "")
            }
            view = next.superview
        }
        var stack: [UIView] = [screen.window]
        while let next = stack.popLast() {
            stack.append(contentsOf: next.subviews)
            guard let bar = next as? UINavigationBar else { continue }
            for item in bar.items ?? [] {
                let buttons = (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? [])
                for button in buttons {
                    guard button.accessibilityLabel == label || button.title == label,
                        let action = button.action
                    else { continue }
                    let application = UIApplication.shared
                    if application.sendAction(action, to: button.target, from: button, for: nil) {
                        return (true, "")
                    }
                }
            }
        }
        return (false, element.map { String(describing: type(of: $0)) } ?? "no element")
    }

    /// Whether any node under `node` carries `identifier`.
    static func identified(_ identifier: String, in node: Any) -> Bool {
        var stack: [Any] = [node]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.responds(to: Selector(("accessibilityIdentifier"))),
                object.value(forKey: "accessibilityIdentifier") as? String == identifier
            {
                return true
            }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return false
    }
}

extension PressProbe.Screen {
    /// Gives the screen turns until `ready` holds, for at most five seconds: a read that never
    /// answers fails the case instead of hanging it.
    func until(seconds: TimeInterval = 5, _ ready: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ready() { return true }
            await settle(turns: 1)
            try? await Task.sleep(for: .milliseconds(10))
        }
        return ready()
    }
}
