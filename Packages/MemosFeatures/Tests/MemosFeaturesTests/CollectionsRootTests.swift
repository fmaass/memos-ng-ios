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

    /// A trip as the server lists it, holding `count` pictures.
    private static func trip(
        count: Int, spanStart: Date? = nil, spanEnd: Date? = nil, cover: LibraryRow? = nil
    ) -> Trip {
        Trip(
            uid: "trip-1", title: "T", tag: "t", spanStart: spanStart, spanEnd: spanEnd,
            cover: cover, memberCount: count, createdAt: march, updatedAt: march)
    }

    @Test("a card says its span and count, and its count alone without a span")
    func cardDetail() {
        let gb = Locale(identifier: "en_GB")
        let utc = TimeZone(identifier: "UTC")!
        let drained = TripMemberSummary(
            count: 3, firstTaken: Self.march, lastTaken: Self.march + 16 * Self.day, cover: nil)
        #expect(
            CollectionsPresentation.tripDetail(
                Self.trip(count: 3), summary: drained, locale: gb, timeZone: utc)
                == "\(range) · 3 photos")
        let undated = TripMemberSummary(count: 1, firstTaken: nil, lastTaken: nil, cover: nil)
        #expect(
            CollectionsPresentation.tripDetail(
                Self.trip(count: 1), summary: undated, locale: gb, timeZone: utc) == "1 photo")
        // Before any drain here: the server's count, with the trip's own span when it has one.
        #expect(
            CollectionsPresentation.tripDetail(
                Self.trip(count: 0), summary: nil, locale: gb, timeZone: utc) == "0 photos")
        let spanned = Self.trip(
            count: 3, spanStart: Self.march, spanEnd: Self.march + 16 * Self.day)
        #expect(
            CollectionsPresentation.tripDetail(spanned, summary: nil, locale: gb, timeZone: utc)
                == "\(range) · 3 photos")
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
        let record = Self.trip(count: 1)
        #expect(CollectionsPresentation.cover(of: record, summary: nil) == nil)
        let drained = TripMemberSummary(count: 1, firstTaken: nil, lastTaken: nil, cover: row)
        #expect(CollectionsPresentation.cover(of: record, summary: drained)?.uid == "p1")
        let empty = TripMemberSummary(count: 0, firstTaken: nil, lastTaken: nil, cover: nil)
        #expect(CollectionsPresentation.cover(of: record, summary: empty) == nil)
        // Before the members are read here, the server's chosen cover.
        #expect(
            CollectionsPresentation.cover(of: Self.trip(count: 1, cover: row), summary: nil)?.uid
                == "p1")
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
        flow.endDatesRead(of: "portugal2026")
        #expect(flow.canCreate)
    }

    /// A flow with `portugal2026` chosen and its dates read: Create is on.
    private func chosen() -> NewTripFlow {
        let flow = NewTripFlow()
        flow.choose("portugal2026")
        flow.endDatesRead(of: "portugal2026")
        return flow
    }

    @Test("Create files the trip once; a second Create is refused")
    func createsOnce() async {
        let wire = CollectionsWire()
        let store = TripStore(identity: alice, root: root)
        let flow = chosen()
        let made = await flow.create(in: store, using: wire.access)
        #expect(made?.title == "Portugal 2026")
        #expect(made?.tag == "portugal2026")
        #expect(flow.failure == nil)
        let again = await flow.create(in: store, using: wire.access)
        #expect(again == nil, "a second Create was not refused")
        #expect(store.trips.count == 1)
        #expect(wire.transport.trips.calls(TripRows.create).count == 1, "a second POST went")
        #expect(!flow.canCreate)
    }

    @Test("a Create whose write failed keeps the sheet's flow open, saying so")
    func aFailedWriteIsSaid() async {
        let wire = CollectionsWire()
        wire.transport.trips.fail([TripRows.create])
        let store = TripStore(identity: alice, root: root)
        let flow = chosen()
        #expect(await flow.create(in: store, using: wire.access) == nil)
        #expect(flow.failure == TripStore.Failure.server(status: 500).errorDescription)
        #expect(flow.failure != nil)
        #expect(flow.created == nil)
        #expect(store.trips.isEmpty, "precondition: nothing was filed")
        #expect(flow.canCreate, "a failed Create cannot be tried again")
    }

    @Test("Create again after a failure re-sends the same request, key and all")
    func aRetryResendsTheFrozenRequest() async throws {
        let wire = CollectionsWire()
        wire.transport.trips.fail([TripRows.create])
        let store = TripStore(identity: alice, root: root)
        let flow = chosen()
        #expect(await flow.create(in: store, using: wire.access) == nil)
        wire.transport.trips.fail([])
        let made = await flow.create(in: store, using: wire.access)
        #expect(made?.title == "Portugal 2026", "the retry filed nothing")
        let posts = wire.transport.trips.calls(TripRows.create)
        try #require(posts.count == 2, "the retry did not reach the server")
        #expect(posts[1].body == posts[0].body, "the retry sent another body")
        #expect(posts[0].object["idempotencyKey"] as? String != nil)
        #expect(store.trips.count == 1)
    }

    @Test("signed out, Create files nothing and says so")
    func nobodySignedIn() async {
        let wire = CollectionsWire()
        let store = TripStore(identity: nil, root: root)
        let flow = chosen()
        #expect(await flow.create(in: store, using: wire.access) == nil)
        #expect(flow.failure == NewTripFlow.notSaved)
        #expect(wire.transport.trips.calls.isEmpty, "a signed-out Create reached the server")
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

    /// MEMNG-757, decision 7: the header says how many trips there are, and nothing else.
    @Test(
        "the header's subtitle is the trip count alone",
        arguments: [(0, "No trips yet"), (1, "1 trip"), (3, "3 trips")]
    )
    func headerSubtitle(count: Int, expected: String) {
        #expect(CollectionsPresentation.headerSubtitle(tripCount: count) == expected)
    }

    /// A failed list has counted nothing: the header never says there is no trip.
    @Test("the header of a failed list with no trip says it was not read, never no trips")
    func headerOfAFailedList() {
        let unread = CollectionsPresentation.headerUnread
        #expect(CollectionsPresentation.headerSubtitle(tripCount: 0, listFailed: true) == unread)
        let none = CollectionsPresentation.headerSubtitle(tripCount: 0, listFailed: false)
        #expect(none == "No trips yet")
        #expect(CollectionsPresentation.headerSubtitle(tripCount: 2, listFailed: true) == "2 trips")
    }

    /// A change to any trip lets every trip's members go, so a card stands on the summary it last
    /// showed while its own trip is read again — but only for the same tag, span and cover.
    @Test("a card keeps its last summary through a re-read, never for a changed trip")
    func aCardKeepsItsSummary() {
        let day = Date(timeIntervalSince1970: 1_773_000_000)
        let trip = Trip(
            uid: "t", title: "Plain", tag: "lisbon", createdAt: day, updatedAt: day)
        let last = TripMemberSummary(count: 3, firstTaken: day, lastTaken: day, cover: nil)
        let held = ["t": HeldTripSummary(trip, last, under: alice)]
        func shown(_ trip: Trip, store: TripMemberSummary? = nil, held: [String: HeldTripSummary])
            -> TripMemberSummary?
        {
            CollectionsPresentation.shownSummary(of: trip, store: store, held: held, under: alice)
        }
        #expect(shown(trip, held: held) == last)
        let fresh = TripMemberSummary(count: 4, firstTaken: nil, lastTaken: nil, cover: nil)
        #expect(shown(trip, store: fresh, held: held) == fresh)
        var retagged = trip
        retagged.tag = "porto"
        #expect(shown(retagged, held: held) == nil)
        var spanned = trip
        spanned.spanStart = day
        spanned.spanEnd = day
        #expect(shown(spanned, held: held) == nil)
        #expect(shown(trip, held: [:]) == nil)
        // The same subject on another server, or nobody, is not the account it was read for.
        let there = TimelineSnapshotIdentity(
            server: URL(string: "https://elsewhere.example.invalid")!, subject: alice.subject)
        let elsewhere = CollectionsPresentation.shownSummary(
            of: trip, store: nil, held: held, under: there)
        #expect(elsewhere == nil, "another server's card took this one's summary")
        let nobody = CollectionsPresentation.shownSummary(
            of: trip, store: nil, held: held, under: nil)
        #expect(nobody == nil, "a card with nobody signed in took a summary")
    }

    /// MEMNG-757: the root's title is the header's, not a bar's, and the + is the header's too —
    /// on no bar that is on screen — and it still opens the New trip sheet.
    @Test("the root's bar has no title, and the header's + opens the New trip sheet")
    func theHeaderCarriesTitleAndPlus() async {
        let wire = CollectionsWire()
        await CollectionsHost.with(screen(stores(), wire)) { screen in
            let plus = CollectionsScreen.newTripButton
            #expect(await screen.until { screen.element(labelled: plus) != nil })
            // `says`, not `element(labelled:)`: the probe's element lookup finds buttons only.
            #expect(screen.says(MainTab.collections.title), "no header title")
            var stack: [UIView] = [screen.window]
            var bars: [UINavigationBar] = []
            while let next = stack.popLast() {
                stack.append(contentsOf: next.subviews)
                if let bar = next as? UINavigationBar { bars.append(bar) }
            }
            let titles = bars.compactMap { $0.topItem?.title }.filter { !$0.isEmpty }
            #expect(titles.isEmpty, "the root's bar is titled \(titles)")
            let frame = screen.element(labelled: plus)?.accessibilityFrame ?? .null
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            let onABar = bars.filter { !$0.isHidden && $0.alpha > 0.01 }
                .contains { $0.convert($0.bounds, to: nil).contains(middle) }
            #expect(!onABar, "the + stands on a navigation bar at \(frame)")
            #expect(screen.press(plus), "the + took no press")
            #expect(await screen.until { screen.element(labelled: NewTripSheet.create) != nil })
        }
    }

    /// The stores the root reads; the trips are whatever the scripted server holds, listed when
    /// the root appears.
    private func stores() -> (TripStore, TripMemberStore, LibraryTagStore) {
        let trips = TripStore(identity: alice, root: root)
        return (trips, TripMemberStore(trips: trips), LibraryTagStore())
    }

    /// What a write the server answered 500 says.
    private static let refused = TripStore.Failure.server(status: 500).errorDescription ?? "?"

    private func screen(
        _ stores: (TripStore, TripMemberStore, LibraryTagStore),
        _ wire: CollectionsWire,
        years: LibraryBucketStore? = nil,
        now: Date = Self.now,
        pushed: Box<[CollectionRoute]>? = nil
    ) -> some View {
        let access = wire.access
        let trail = Binding(
            get: { pushed?.value ?? [] }, set: { pushed?.value = $0 })
        return NavigationStack {
            CollectionsScreen(
                trips: stores.0, members: stores.1, tags: stores.2, years: years,
                identity: alice, access: { access }, now: { now }, trail: trail)
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

    @Test("a trip's card shows its title and the server's count, and the drain's cover")
    func oneTripCard() async {
        let wire = CollectionsWire()
        let stores = stores()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026", count: 3)
        #expect(wire.transport.trips.rows.count == 1, "precondition: the trip is on the server")
        await CollectionsHost.with(screen(stores, wire)) { screen in
            let drained = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p0"), in: screen.window)
            }
            #expect(drained, "the card never drew its first member")
            #expect(Self.value(of: "Portugal 2026", on: screen) == "3 items")
            #expect(!screen.says(CollectionsScreen.emptyTitle))
        }
        let trip = stores.0.trips.first
        #expect(trip.flatMap { stores.1.summary(for: $0)?.count } == 3)
    }

    /// What VoiceOver hears of a card past its title — the ordinary half of the pin's retired
    /// accessibility cases (MEMNG-781): its count, and never a date (MEMNG-783).
    @Test(
        "a card's accessibility value is its count",
        arguments: [(1, "1 item"), (3, "3 items")])
    func cardValueIsItsCount(count: Int, expected: String) async {
        let card = CollectionCard(cover: nil, title: "Lisbon", count: count)
        let value = await PressProbe.withScreen(card, height: 400) { screen in
            _ = await screen.until { Self.value(of: "Lisbon", on: screen) != nil }
            return Self.value(of: "Lisbon", on: screen)
        }
        #expect(value == expected, "the card said \(value ?? "nothing")")
    }

    /// Whether the card titled `title` stands for a trip whose members have been read.
    private static func cardDrained(
        _ title: String, _ stores: (TripStore, TripMemberStore, LibraryTagStore),
        _ screen: PressProbe.Screen
    ) -> Bool {
        guard let trip = stores.0.trips.first(where: { $0.title == title }) else { return false }
        return stores.1.summary(for: trip) != nil && value(of: title, on: screen) != nil
    }

    /// The accessibility value of the node labelled `title`, whatever its traits: a card is one
    /// element whose label is its title.
    private static func value(of title: String, on screen: PressProbe.Screen) -> String? {
        var stack: [Any] = [screen.window]
        while let next = stack.popLast() {
            guard let object = next as? NSObject else { continue }
            if object.accessibilityLabel == title { return object.accessibilityValue ?? "" }
            stack.append(contentsOf: object.accessibilityElements ?? [])
            if let view = object as? UIView { stack.append(contentsOf: view.subviews) }
        }
        return nil
    }

    @Test("a tag card pushes the tag's collection")
    func aTagCardPushesItsCollection() async {
        let wire = CollectionsWire()
        let pushed = Box<[CollectionRoute]>([])
        await CollectionsHost.with(screen(stores(), wire, pushed: pushed)) { screen in
            #expect(await screen.until { screen.element(labelled: "#family") != nil })
            #expect(screen.press("#family"))
        }
        guard case .automatic(let collection)? = pushed.value.last?.scope else {
            Issue.record("no collection was pushed: \(pushed.value.map(\.id))")
            return
        }
        #expect(collection.kind == .tag("family"))
        #expect(collection.title == "#family")
    }

    @Test("the sheet suggests the short recent tag under Suggested, and not the long one")
    func theSuggestedSection() async {
        let wire = CollectionsWire()
        let stores = stores()
        let sheet = NewTripSheet(
            flow: NewTripFlow(), trips: stores.0, members: stores.1,
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

    @Test("Create files the trip and the root shows its card")
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
            #expect(await screen.until { Self.cardDrained("Portugal 2026", stores, screen) })
            #expect(await screen.until { screen.element(labelled: NewTripSheet.create) == nil })
            #expect(!screen.says(CollectionsScreen.emptyTitle))
        }
        #expect(stores.0.trips.map(\.title) == ["Portugal 2026"])
        #expect(stores.0.trips.map(\.tag) == ["portugal2026"])
        #expect(wire.transport.trips.rows.map(\.title) == ["Portugal 2026"])
    }

    @Test("a Create that did not reach the store keeps the sheet open with an error line")
    func aFailedCreateStays() async {
        let wire = CollectionsWire()
        wire.transport.trips.fail([TripRows.create])
        let stores = stores()
        let sheet = NewTripSheet(
            flow: NewTripFlow(), trips: stores.0, members: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now })
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { screen.element(labelled: "portugal2026") != nil })
            #expect(screen.press("portugal2026"))
            #expect(await screen.until { screen.element(labelled: NewTripSheet.create) != nil })
            #expect(screen.press(NewTripSheet.create))
            #expect(await screen.until { screen.says(Self.refused) })
            #expect(
                await screen.until { screen.element(labelled: NewTripSheet.create) != nil },
                "the sheet went")
        }
        #expect(stores.0.trips.isEmpty)
        #expect(wire.transport.trips.rows.isEmpty)
    }

    @Test("Create waits for the chosen tag's own dates read, not for the sweep past it")
    func createWaitsForTheChosenRead() async {
        let wire = CollectionsWire()
        wire.transport.holdSpan(of: "portugal2026")
        wire.transport.holdSpan(of: "family")
        let stores = stores()
        let flow = NewTripFlow()
        let sheet = NewTripSheet(
            flow: flow, trips: stores.0, members: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now })
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { wire.transport.spanReads(of: "portugal2026") > 0 })
            #expect(await screen.until { screen.element(labelled: "family") != nil })
            #expect(screen.press("family"))
            #expect(
                await screen.until { wire.transport.spanReads(of: "family") > 0 },
                "the chosen tag's dates were not asked for")
            wire.transport.releaseSpan(of: "portugal2026")
            #expect(await screen.until { stores.1.spans["portugal2026"] != nil })
            // The sweep has reached the chosen tag, whose own read is still held.
            #expect(
                !(await screen.until(seconds: 1) { flow.canCreate }),
                "Create was offered while the chosen tag's dates were still being read")
            wire.transport.releaseSpan(of: "family")
            #expect(
                await screen.until { flow.span != nil && flow.canCreate },
                "the chosen tag's dates never reached the sheet")
        }
        #expect(stores.0.trips.isEmpty)
    }

    /// A trip store holding the one trip on `wire`'s server, after which every PATCH answers 500.
    private func brokenStore(
        on wire: CollectionsWire, filing span: TripSpan?, tag: String
    ) async throws -> (TripStore, Trip) {
        wire.transport.trips.seed(
            "Portugal 2026", tag: tag, spanStart: span.map { $0.start.formatted(.iso8601) },
            spanEnd: span.map { $0.end.formatted(.iso8601) }, tz: span?.zone, count: 3)
        let broken = TripStore(identity: alice, root: root)
        await broken.refresh(using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        wire.transport.trips.fail([TripRows.patch])
        return (broken, try #require(broken.trips.first))
    }

    @Test("Remove Dates that was not saved keeps the sheet and says so")
    func aFailedRemoveDatesStays() async throws {
        let span = TripSpan(
            start: Self.now, end: Self.now.addingTimeInterval(86_400), zone: "Europe/Lisbon")
        let wire = CollectionsWire()
        let (broken, record) = try await brokenStore(on: wire, filing: span, tag: "portugal2026")
        #expect(record.tripSpan == span, "precondition: the trip was filed with its dates")
        let sheet = TripSpanSheet(
            trip: record, trips: broken, access: { [access = wire.access] in access },
            now: Self.now)
        await CollectionsHost.with(sheet) { screen in
            #expect(
                await screen.until { screen.element(labelled: TripSpanSheet.removeDates) != nil })
            #expect(screen.press(TripSpanSheet.removeDates))
            #expect(
                await screen.until { screen.says(Self.refused) },
                "a removal that was not saved was not said")
            #expect(screen.element(labelled: TripSpanSheet.removeDates) != nil, "the sheet went")
        }
        #expect(broken.trips.first?.tripSpan == span, "control: not written")
        #expect(wire.transport.trips.rows.first?.spanStart != nil, "control: the server kept it")
    }

    @Test("Trip Dates' Save that was not saved keeps the sheet and says so")
    func aFailedSpanSaveStays() async throws {
        let wire = CollectionsWire()
        let (broken, record) = try await brokenStore(on: wire, filing: nil, tag: "portugal2026")
        let sheet = TripSpanSheet(
            trip: record, trips: broken, access: { [access = wire.access] in access },
            now: Self.now)
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { screen.element(labelled: TripSpanSheet.save) != nil })
            #expect(screen.press(TripSpanSheet.save))
            #expect(
                await screen.until { screen.says(Self.refused) },
                "a span that was not saved was not said")
            #expect(screen.element(labelled: TripSpanSheet.save) != nil, "the sheet went")
        }
        #expect(broken.trips.first?.tripSpan == nil, "control: not written")
        #expect(wire.transport.trips.rows.first?.spanStart == nil, "control: the server kept none")
    }

    @Test("an identity change files the trips under the new identity and forgets every read")
    func identityChange() async {
        let bob = TimelineSnapshotIdentity(server: alice.server, subject: "bob")
        let wire = CollectionsWire()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026", count: 3)
        let collections = TripStore(identity: alice, root: root)
        let trips = TripMemberStore(trips: collections)
        await collections.refresh(using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        #expect(collections.trips.count == 1, "precondition: the trip was listed")
        await trips.loadTagCounts(using: wire.access.handle)
        await trips.loadSpan(
            ofTag: "portugal2026", using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        #expect(trips.tagCountsLoaded, "precondition: the counts were read")
        #expect(trips.spans["portugal2026"] != nil, "precondition: the span was read")

        CollectionsSession.identityChanged(to: bob, trips: collections, members: trips)
        #expect(collections.identity == bob)
        #expect(collections.trips.isEmpty, "B was shown A's trip")
        #expect(!trips.tagCountsLoaded, "B was shown A's tag counts")
        #expect(trips.spans.isEmpty, "B was shown A's spans")

        CollectionsSession.identityChanged(to: alice, trips: collections, members: trips)
        await collections.refresh(using: wire.access.handle, baseURL: CollectionsWire.baseURL)
        #expect(collections.trips.map(\.title) == ["Portugal 2026"], "A's trip did not return")
    }

    @Test("a tag chip on the Collections root opens the tag's collection, and the tabs stay")
    func aTagChipOpensItsCollection() async {
        let transport = CollectionsTransport()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            let chip = await screen.until { screen.element(labelled: "#portugal2026") != nil }
            #expect(chip, "the chip never appeared")
            // The control: no collection screen stands before the press.
            #expect(screen.element(labelled: TripMode.journal.title) == nil)
            #expect(screen.press("#portugal2026"), "the chip took no press")
            let opened = await screen.until(seconds: 10) {
                screen.element(labelled: TripMode.journal.title) != nil
            }
            #expect(opened, "the tag's collection never opened")
            #expect(
                !transport.sent.contains { Self.gridRead($0, tag: "portugal2026") },
                "the Library read its grid under the tag")
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
        let (collections, trips) = await tripsRead(as: fabian, using: handle, on: transport)
        let timeline = TimelineView().environment(session).environment(collections)
            .environment(trips)
        await CollectionsHost.with(timeline) { screen in
            let shown = await Self.timelineShown(on: screen, transport)
            #expect(shown, "precondition: the timeline never read its first page")
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_bob")
            #expect(session.state.user?.subject == "bob", "precondition: bob signed in")
            let moved = await screen.until { collections.identity?.subject == "bob" }
            #expect(moved, "not moved")
            #expect(collections.trips.isEmpty, "bob was shown fabian's trip")
            #expect(!trips.tagCountsLoaded, "bob was shown fabian's tag counts")

            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
            let back = await screen.until { collections.identity == fabian }
            #expect(back, "not moved back")
            // The trips are the server's: the next list read under fabian has his trip again.
            if let again = session.activeHandle {
                await collections.refresh(using: again, baseURL: CollectionsWire.baseURL)
            }
            #expect(collections.trips.map(\.title) == ["Portugal 2026"], "the trip is lost")
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
        let (collections, trips) = await tripsRead(as: here, using: handle, on: transport)
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
            #expect(collections.trips.isEmpty, "the other server was shown this one's trip")
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

    /// A trip store holding the one trip `transport` lists under `identity`, and a member store
    /// that has read the tag counts.
    private func tripsRead(
        as identity: TimelineSnapshotIdentity, using handle: SessionHandle,
        on transport: CollectionsTransport
    ) async -> (TripStore, TripMemberStore) {
        transport.trips.seed("Portugal 2026", tag: "portugal2026", count: 3)
        let collections = TripStore(identity: identity, root: root)
        let trips = TripMemberStore(trips: collections)
        await collections.refresh(using: handle, baseURL: CollectionsWire.baseURL)
        await trips.loadTagCounts(using: handle)
        #expect(collections.trips.count == 1, "precondition: one trip")
        #expect(trips.tagCountsLoaded, "precondition: the counts were read")
        return (collections, trips)
    }

    /// Whether `sent` is the Library grid's read under `tag` (`CollectionsTransport.isGridRead`).
    private static func gridRead(_ sent: String, tag: String) -> Bool {
        let parts = sent.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "list_attachments_api_attachments_get" else {
            return false
        }
        let query = URLComponents(string: parts[1])?.queryItems ?? []
        return CollectionsTransport.isGridRead(query, tag: tag)
    }

    private func signedOutSession(_ transport: CollectionsTransport) -> SessionStore {
        CollectionsWire.signedOutSession(transport)
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

extension CollectionsWire {
    /// The app's session over `transport`, signed out: the real store, its client made over the
    /// scripted server, its sleeps an hour long so no retry or notice fires in a case.
    static func signedOutSession(_ transport: CollectionsTransport) -> SessionStore {
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
}

/// The scripted server itself.
final class CollectionsTransport: ClientTransport, @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var requests: [String] = []
    private nonisolated(unsafe) var heldTag: String?
    private nonisolated(unsafe) var released = false
    private nonisolated(unsafe) var noYears = false
    private nonisolated(unsafe) var refusesYears = false
    private nonisolated(unsafe) var holdsYears = false
    private nonisolated(unsafe) var releasedYears: [String] = []
    private nonisolated(unsafe) var answeredYears: [String] = []
    private nonisolated(unsafe) var heldSpans: Set<String> = []
    private nonisolated(unsafe) var tagsAnswer: String?
    private nonisolated(unsafe) var monthsAnswer: String?
    private nonisolated(unsafe) var yearsAnswer: String?
    private nonisolated(unsafe) var coversFail = false
    private nonisolated(unsafe) var coversHeld = false
    /// The trips the server holds; a trip's members are its tag's listing below, and so is its
    /// count: `portugal2026` three, `family` two, less what was removed.
    nonisolated let trips = TripRows(counter: { row in
        let listed = ["portugal2026": 3, "family": 2][row.tag ?? ""] ?? 0
        return max(0, listed - row.exclusions.count)
    })

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

    /// Holds every span read of `tag` — its one first or last picture — until `releaseSpan(of:)`.
    nonisolated func holdSpan(of tag: String) {
        lock.withLock { _ = heldSpans.insert(tag) }
    }

    nonisolated func releaseSpan(of tag: String) {
        lock.withLock { _ = heldSpans.remove(tag) }
    }

    /// How many span reads of `tag` were sent.
    nonisolated func spanReads(of tag: String) -> Int {
        sent.filter { line in
            let path = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            return Self.spanTag(path) == tag
        }.count
    }

    /// The tag a span read is of: one row (`limit=1`) of every kind under a tag; nil for every
    /// other read — a tag card's cover lookup names a kind.
    nonisolated static func spanTag(_ path: String) -> String? {
        let query = URLComponents(string: path)?.queryItems ?? []
        guard query.contains(where: { $0.name == "limit" && $0.value == "1" }),
            !query.contains(where: { $0.name == "type" })
        else { return nil }
        return query.first { $0.name == "tag" }?.value
    }

    /// Answers the tag list with `json` instead of `portugal2026` and `family`.
    nonisolated func answerTags(_ json: String) {
        lock.withLock { tagsAnswer = json }
    }

    /// Answers every month read with `json`; unset, a month read is not found.
    nonisolated func answerMonths(_ json: String) {
        lock.withLock { monthsAnswer = json }
    }

    /// Answers fabian's year reads with `json` instead of 2026 and 2019.
    nonisolated func answerYears(_ json: String) {
        lock.withLock { yearsAnswer = json }
    }

    /// Answers every tag cover lookup 500.
    nonisolated func failCovers() {
        lock.withLock { coversFail = true }
    }

    /// Holds every tag cover lookup until `releaseCovers()`.
    nonisolated func holdCovers() {
        lock.withLock { coversHeld = true }
    }

    nonisolated func releaseCovers() {
        lock.withLock { coversHeld = false }
    }

    /// How many cover lookups of `tag` were sent; every tag's with nil.
    nonisolated func coverReads(of tag: String? = nil) -> Int {
        sent.filter { line in
            let path = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
            guard let read = Self.coverTag(path) else { return false }
            return tag == nil || read == tag
        }.count
    }

    /// The tag a cover lookup is of: one picture (`type=image`, `limit=1`) under a tag; nil for
    /// every other read.
    nonisolated static func coverTag(_ path: String) -> String? {
        let query = URLComponents(string: path)?.queryItems ?? []
        guard query.contains(where: { $0.name == "limit" && $0.value == "1" }),
            query.contains(where: { $0.name == "type" && $0.value == "image" })
        else { return nil }
        return query.first { $0.name == "tag" }?.value
    }

    /// Answers every year read with no year at all.
    nonisolated func answerNoYears() {
        lock.withLock { noYears = true }
    }

    /// Holds every year read until `releaseYears(of:)` names its token's owner. A held read
    /// answers even when its task is cancelled, as a response already on its way does.
    nonisolated func holdYears() {
        lock.withLock { holdsYears = true }
    }

    /// Lets the held year reads of `owner`'s token (`fabian` or `bob`) answer.
    nonisolated func releaseYears(of owner: String) {
        lock.withLock { releasedYears.append(owner) }
    }

    /// Whose year reads have answered, in order.
    nonisolated var yearsAnswered: [String] { lock.withLock { answeredYears } }

    /// Answers every year read 401: the token, as far as that read is concerned, is dead.
    nonisolated func refuseYears() {
        lock.withLock { refusesYears = true }
    }

    nonisolated func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        lock.withLock { requests.append("\(operationID) \(path)") }
        if let answered = try await trips.answer(
            request, body: body, operationID: operationID,
            listing: { query in Self.list(Self.path(query)) })
        {
            return answered
        }
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
            if let answer = lock.withLock({ tagsAnswer }) { return Self.json(answer) }
            return Self.json(
                #"[{"name":"portugal2026","count":3},{"name":"family","count":40}]"#)
        case "attachment_buckets_api_attachments_buckets_get":
            // Years only (MEMNG-720): 2026 three pictures, 2019 forty. Every other size stays
            // unanswered, as it was before the Years row.
            let query = URLComponents(string: path)?.queryItems ?? []
            if query.contains(where: { $0.name == "size" && $0.value == "month" }),
                let months = lock.withLock({ monthsAnswer })
            {
                return Self.json(months)
            }
            guard query.contains(where: { $0.name == "size" && $0.value == "year" }) else {
                return (HTTPResponse(status: .notFound), nil)
            }
            if lock.withLock({ refusesYears }) {
                return (HTTPResponse(status: .unauthorized), nil)
            }
            // Bob has no year; fabian has the two below.
            let token = request.headerFields[.authorization] ?? ""
            let owner = token.hasSuffix("memos_pat_bob") ? "bob" : "fabian"
            while lock.withLock({ holdsYears && !releasedYears.contains(owner) }) {
                if Task.isCancelled {
                    usleep(20_000)
                } else {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            lock.withLock { answeredYears.append(owner) }
            if owner == "bob" || lock.withLock({ noYears }) { return Self.json("[]") }
            if let years = lock.withLock({ yearsAnswer }) { return Self.json(years) }
            let thumb = #""tags":[],"coverThumbnailUrl":"/api/attachments/p0/thumb""#
            return Self.json(
                #"[{"key":"2026","count":3,"coverUid":"p0","# + thumb + "},"
                    + #"{"key":"2019","count":40,"coverUid":"p0","# + thumb + "}]")
        case "list_attachments_api_attachments_get":
            if Self.coverTag(path) != nil {
                while lock.withLock({ coversHeld }) {
                    try await Task.sleep(for: .milliseconds(20))
                }
                if lock.withLock({ coversFail }) {
                    return (HTTPResponse(status: .internalServerError), nil)
                }
            }
            if let tag = Self.spanTag(path) {
                while lock.withLock({ heldSpans.contains(tag) }) {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
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

    /// A member listing's query as the attachment list's path, so it answers as that list does.
    nonisolated static func path(_ query: [String: String]) -> String {
        var components = URLComponents(string: "/api/attachments")
        components?.queryItems = query.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components?.string ?? "/api/attachments"
    }

    /// Whether `path` is a grid read under the held tag.
    private nonisolated func isHeld(_ path: String) -> Bool {
        let query = URLComponents(string: path)?.queryItems ?? []
        guard let held = lock.withLock({ heldTag }) else { return false }
        return Self.isGridRead(query, tag: held)
    }

    /// Whether `query` is the Library grid's read under `tag`: every kind of file (no `type`),
    /// newest first, a page rather than one row. A trip's drain and a span's read name no kind
    /// either (MEMNG-740), so the kind alone no longer tells them apart: the drain reads oldest
    /// first, and a span reads one row.
    nonisolated static func isGridRead(_ query: [URLQueryItem], tag: String) -> Bool {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        return value("tag") == tag && !query.contains { $0.name == "type" }
            && value("order") != "taken_asc" && value("limit") != "1"
    }

    private nonisolated static func list(_ path: String) -> (HTTPResponse, HTTPBody?) {
        let query = URLComponents(string: path)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        // The grid under `portugal2026` alone holds a film: a tile no other read can put there.
        if isGridRead(query, tag: "portugal2026") {
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
        "webReady":true,\
        "renditions":[],"tags":[],"orphan":false,"memoUid":"m-\(uid)",\
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

/// A view over the identity a test moves by hand: `content` is built again for every identity.
struct IdentityHost<Content: View>: View {
    let source: IdentitySource
    @ViewBuilder let content: (TimelineSnapshotIdentity?) -> Content

    var body: some View { content(source.identity) }
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

// MARK: - Use as Cover on the card, and the Years row (MEMNG-720)

extension CollectionsRootRenderTests {
    @Test("the card follows a cover chosen after its drain, and falls back when it leaves the trip")
    func theCardFollowsTheCover() async {
        let wire = CollectionsWire()
        let stores = stores()
        let uid = wire.transport.trips.seed("Portugal 2026", tag: "portugal2026", count: 3)
        let handle = wire.access.handle
        await CollectionsHost.with(screen(stores, wire)) { screen in
            let drained = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p0"), in: screen.window)
            }
            #expect(drained, "precondition: the drained card draws its first member p0")
            // What the trip's viewer's Use as Cover does (`TripView.useAsCover`).
            _ = try? await stores.0.update(
                uid: uid, patch: TripPatch(cover: .set("p2")), using: handle,
                baseURL: CollectionsWire.baseURL)
            let chosen = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p2"), in: screen.window)
            }
            #expect(chosen, "the card kept the cover its drain wrote, not the chosen p2")
            if let record = stores.0.trips.first(where: { $0.uid == uid }) {
                _ = try? await stores.1.remove(
                    ["p2"], from: record, using: handle, baseURL: CollectionsWire.baseURL)
            }
            let fellBack = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p0"), in: screen.window)
            }
            #expect(fellBack, "the card kept an excluded cover instead of the first member")
        }
    }

    @Test("the Years row lists the scripted years with their counts, and a chip pushes its year")
    func theYearsRow() async {
        let wire = CollectionsWire()
        let pushed = Box<[CollectionRoute]>([])
        let years = LibraryBucketStore()
        let view = screen(stores(), wire, years: years, pushed: pushed)
        await CollectionsHost.with(view) { screen in
            #expect(await screen.until { screen.says(CollectionsScreen.yearsHeader) })
            #expect(screen.element(labelled: "2026")?.accessibilityValue == "3 items")
            #expect(screen.element(labelled: "2019")?.accessibilityValue == "40 items")
            #expect(screen.press("2019"), "the chip took no press")
            #expect(pushed.value.map(\.id) == ["year:2019"])
            // An account change empties the store: its years leave the screen with it.
            years.sessionIdentityChanged()
            #expect(await screen.until { !screen.says(CollectionsScreen.yearsHeader) })
            #expect(screen.element(labelled: "2026") == nil, "another account's years stayed")
        }
        let reads = wire.transport.sent.filter { $0.hasPrefix("attachment_buckets") }
        #expect(reads.count == 1, "one year read: \(reads)")
        #expect(reads.first?.contains("size=year") == true)
        #expect(reads.first?.contains("tag=") == false, "the row counts every tag")
    }

    @Test("no years, no Years row")
    func noYearsNoRow() async {
        let wire = CollectionsWire()
        wire.transport.answerNoYears()
        let years = LibraryBucketStore()
        await CollectionsHost.with(screen(stores(), wire, years: years)) { screen in
            #expect(await screen.until { years.loadedRequest != nil }, "the years were not read")
            #expect(await screen.until { screen.element(labelled: "#portugal2026") != nil })
            #expect(!screen.says(CollectionsScreen.yearsHeader), "a Years row with no year")
        }
    }

    @Test(
        "a year chip on the Collections root opens that year's collection",
        arguments: ["2026", "2019"])
    func aYearChipOpensItsCollection(year: String) async {
        let transport = CollectionsTransport()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            let chip = await screen.until { screen.element(labelled: year) != nil }
            #expect(chip, "the Years row never appeared")
            // The control: no collection screen stands before the press.
            #expect(screen.element(labelled: TripMode.journal.title) == nil)
            #expect(screen.press(year), "the chip took no press")
            let opened = await screen.until(seconds: 10) {
                screen.element(labelled: TripMode.journal.title) != nil
            }
            #expect(opened, "\(year)'s collection never opened")
            #expect(screen.element(labelled: "All Years") == nil, "the Library opened in Months")
        }
    }

    @Test("a year read refused 401 under the current credential ends the session")
    func aRefusedYearReadReachesTheSession() async {
        let transport = CollectionsTransport()
        transport.refuseYears()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            let ended = await screen.until(seconds: 10) { session.state.user == nil }
            #expect(ended, "the year read's refusal never reached the session")
        }
        #expect(transport.sent.contains { $0.hasPrefix("attachment_buckets") }, "no year read")
    }

    @Test("a year read still in flight when the account changes never fills the new one's row")
    func aLateYearReadIsDropped() async {
        let transport = CollectionsTransport()
        transport.holdYears()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .collections).environment(session)
        await CollectionsHost.with(tabs) { screen in
            let asked = await screen.until { Self.yearReads(transport) == 1 }
            #expect(asked, "fabian's year read was never sent: \(transport.sent)")
            await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_bob")
            #expect(session.state.user?.subject == "bob", "precondition: bob signed in")
            // Bob's own read stays held: only fabian's late answer can reach the row.
            transport.releaseYears(of: "fabian")
            let answered = await screen.until { transport.yearsAnswered == ["fabian"] }
            #expect(answered, "fabian's held read never answered: \(transport.yearsAnswered)")
            _ = await screen.until(seconds: 1.5) { false }
            #expect(!screen.says(CollectionsScreen.yearsHeader), "fabian's years filled bob's row")
            #expect(screen.element(labelled: "2026") == nil, "fabian's 2026 is on bob's root")
            // Bob's read goes too, so no held read outlives the case.
            transport.releaseYears(of: "bob")
            _ = await screen.until { transport.yearsAnswered.count == 2 }
        }
    }

    private static func yearReads(_ transport: CollectionsTransport) -> Int {
        transport.sent.filter { $0.hasPrefix("attachment_buckets") && $0.contains("size=year") }
            .count
    }

    @Test("a viewer opened from the Library offers no Use as Cover")
    func theLibrarysViewerHasNoCoverAction() async {
        let transport = CollectionsTransport()
        let session = signedOutSession(transport)
        await session.enteredForeground()
        await session.signIn(serverAddress: "memos.example.invalid", token: "memos_pat_trips")
        #expect(session.state.user?.subject == "fabian", "precondition: signed in")
        let tabs = MainTabView(opening: .library).environment(session)
        await CollectionsHost.with(tabs) { screen in
            let tiles = await screen.until { !TripProbe.photos(in: screen.window).isEmpty }
            #expect(tiles, "the Library drew no tile")
            let photos = TripProbe.photos(in: screen.window)
            let pressed = photos.first.map { TripProbe.pressAtOnce($0) } ?? false
            #expect(pressed, "the tile took no press")
            // The control: the viewer is up, its own Close drawn.
            let open = await screen.until(seconds: 10) { screen.element(labelled: "Close") != nil }
            #expect(open, "no viewer opened")
            await screen.settle(turns: 10)
            #expect(
                screen.element(labelled: TripView.useAsCoverButton) == nil,
                "the Library's viewer offers a trip's Use as Cover")
        }
    }
}

/// The root over the server's trips (MEMNG-754): its list, its failure, and Create's one write.
extension CollectionsRootRenderTests {
    @Test("the root lists the server's trips in the server's order, a card each")
    func twoTrips() async {
        let wire = CollectionsWire()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026")
        wire.transport.trips.seed("Family", tag: "family")
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            #expect(await screen.until { screen.says("Portugal 2026") && screen.says("Family") })
            #expect(await screen.until { Self.cardDrained("Portugal 2026", stores, screen) })
            #expect(screen.says(CollectionsScreen.tripsHeader))
            #expect(!screen.says(CollectionsScreen.emptyTitle))
        }
        #expect(stores.0.trips.map(\.title) == ["Portugal 2026", "Family"])
    }

    @Test("a list that failed with nothing to show says so, and Try Again reads it again")
    func aFailedListSaysSo() async {
        let wire = CollectionsWire()
        wire.transport.trips.seed("Portugal 2026", tag: "portugal2026")
        wire.transport.trips.fail([TripRows.list])
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            let retry = CollectionsScreen.retryButton
            #expect(await screen.until { screen.element(labelled: retry) != nil })
            #expect(stores.0.lastError != nil, "precondition: the list failed")
            #expect(!screen.says(CollectionsScreen.emptyTitle), "a failed list read as no trip")
            let unread = CollectionsPresentation.headerUnread
            #expect(screen.says(unread), "the header did not say the list was not read")
            wire.transport.trips.fail([])
            #expect(screen.press(retry), "Try Again took no press")
            #expect(await screen.until { screen.says("Portugal 2026") }, "the retry listed nothing")
            #expect(await screen.until { screen.element(labelled: retry) == nil })
        }
    }

    @Test("Create is busy while it is out, sends one POST, and the return reads the list once")
    func aCreateIsOnePost() async {
        let wire = CollectionsWire()
        wire.transport.trips.hold(TripRows.create)
        let stores = stores()
        await CollectionsHost.with(screen(stores, wire)) { screen in
            #expect(await screen.until { screen.says(CollectionsScreen.emptyTitle) })
            let plus = CollectionsScreen.newTripButton
            #expect(await screen.until { screen.element(labelled: plus) != nil })
            let opened = CollectionsHost.pressBarItem(plus, on: screen)
            #expect(opened.took, "the + took no press")
            #expect(await screen.until { screen.element(labelled: "portugal2026") != nil })
            #expect(screen.press("portugal2026"))
            #expect(await screen.until { screen.says("Portugal 2026") }, "the title was not filled")
            let listed = wire.transport.trips.calls(TripRows.list).count
            #expect(screen.press(NewTripSheet.create), "Create took no press")
            let busy = await screen.until {
                screen.element(labelled: NewTripSheet.create) == nil
                    && screen.says(NewTripSheet.creating)
            }
            #expect(busy, "the sheet was not busy while Create was out")
            let again = screen.press(NewTripSheet.create)
            #expect(!again, "Create took a press while one was out")
            wire.transport.trips.release(TripRows.create)
            #expect(await screen.until { Self.cardDrained("Portugal 2026", stores, screen) })
            #expect(await screen.until { screen.element(labelled: NewTripSheet.create) == nil })
            // A second answer, were one coming, has a second to arrive.
            try? await Task.sleep(for: .seconds(1))
            await screen.settle(turns: 5)
            #expect(wire.transport.trips.calls(TripRows.create).count == 1, "a second POST")
            let reads = wire.transport.trips.calls(TripRows.list).count - listed
            #expect(reads == 1, "the return read the list \(reads) times")
        }
        #expect(stores.0.trips.map(\.title) == ["Portugal 2026"])
    }

    @Test("an identity change while New Trip is up closes it, and Create sends nothing more")
    func anIdentityChangeClosesTheSheet() async {
        let wire = CollectionsWire()
        let stores = stores()
        let flow = NewTripFlow()
        let sheet = NewTripSheet(
            flow: flow, trips: stores.0, members: stores.1,
            access: { [access = wire.access] in access }, now: { Self.now })
        await CollectionsHost.with(sheet) { screen in
            #expect(await screen.until { screen.element(labelled: "portugal2026") != nil })
            #expect(screen.press("portugal2026"))
            #expect(await screen.until { flow.canCreate }, "precondition: Create is on")
            stores.0.sessionIdentityChanged(
                to: TimelineSnapshotIdentity(server: alice.server, subject: "bob"))
            #expect(await screen.until { flow.abandoned }, "the sheet stayed for somebody else")
            #expect(!flow.canCreate)
            #expect(await flow.create(in: stores.0, using: wire.access) == nil)
        }
        #expect(wire.transport.trips.calls(TripRows.create).isEmpty, "a POST went for bob")
    }
}

/// The year request and the root's two requests, as values (MEMNG-720).
@MainActor
@Suite("Library year jump")
struct LibraryYearJumpTests {
    @Test("a year request widens the tag, shows that year in Months, and is applied once")
    func appliedOnce() {
        let jump = LibraryYearJump()
        let scope = LibraryScopeChoice()
        let library = MediaLibraryStore()
        library.setTag("portugal2026")
        #expect(LibraryYearJumpRouting.tab(showing: .collections, whenOpening: nil) == .collections)
        jump.request("2026")
        let tab = LibraryYearJumpRouting.tab(showing: .collections, whenOpening: jump.pending)
        #expect(tab == .library)
        #expect(LibraryYearJumpRouting.apply(jump, to: library, scope: scope), "no re-read")
        #expect(library.tag == nil, "the tag was kept")
        #expect(scope.scope == .months)
        #expect(scope.year == "2026")
        #expect(jump.pending == nil)
        scope.choose(.all)
        #expect(!LibraryYearJumpRouting.apply(jump, to: library, scope: scope), "applied twice")
        #expect(scope.scope == .all, "a taken request moved the scope again")
        #expect(scope.year == nil)
        // With no tag to widen, the scope still moves and nothing is read again.
        jump.request("2019")
        #expect(!LibraryYearJumpRouting.apply(jump, to: library, scope: scope))
        #expect(scope.scope == .months)
        #expect(scope.year == "2019")
    }

    @Test("the latest of a tag, a month and a year request is the one left pending")
    func theLaterRequestWins() {
        let tags = LibraryTagJump()
        let years = LibraryYearJump()
        let months = LibraryMonthJump()
        LibraryJumpRequests.openTag("family", tags: tags, years: years, months: months)
        LibraryJumpRequests.openYear("2026", tags: tags, years: years, months: months)
        #expect(tags.pending == nil, "a tag asked for before the year stayed pending")
        #expect(years.pending == "2026")
        LibraryJumpRequests.openTag("family", tags: tags, years: years, months: months)
        #expect(years.pending == nil, "a year asked for before the tag stayed pending")
        #expect(tags.pending == "family")
        LibraryJumpRequests.openMonth("2026-03", tags: tags, years: years, months: months)
        #expect(tags.pending == nil, "a tag asked for before the month stayed pending")
        #expect(months.pending == "2026-03")
        LibraryJumpRequests.openYear("2019", tags: tags, years: years, months: months)
        #expect(months.pending == nil, "a month asked for before the year stayed pending")
        #expect(years.pending == "2019")
        LibraryJumpRequests.openMonth("2019-01", tags: tags, years: years, months: months)
        #expect(years.pending == nil, "a year asked for before the month stayed pending")
        LibraryJumpRequests.openTag("family", tags: tags, years: years, months: months)
        #expect(months.pending == nil, "a month asked for before the tag stayed pending")
        #expect(tags.pending == "family")
    }
}

// MARK: - The whole identity (MEMNG-754 R1)

extension CollectionsRootRenderTests {
    /// The root over an identity the test moves, as the session's identity reaches it.
    private func switching(
        _ stores: (TripStore, TripMemberStore, LibraryTagStore), _ wire: CollectionsWire,
        _ source: IdentitySource
    ) -> some View {
        let access = wire.access
        return IdentityHost(source: source) { who in
            NavigationStack {
                CollectionsScreen(
                    trips: stores.0, members: stores.1, tags: stores.2, years: nil,
                    identity: who, access: { access }, now: { Self.now })
            }
            .environment(\.locale, Locale(identifier: "en_GB"))
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        }
    }

    /// The same subject on another server is another account: the session's move clears the
    /// trips, and the root reads the other server's list at once — and while that server's
    /// members are still out, no card shows the dates this server's members gave it.
    @Test("the same subject on another server reads the list again, and keeps no card's cover")
    func aServerSwitchReadsTheListAgain() async {
        let wire = CollectionsWire()
        wire.transport.trips.seed("Plain", tag: "portugal2026", count: 3)
        let stores = stores()
        let source = IdentitySource(alice)
        let there = TimelineSnapshotIdentity(
            server: URL(string: "https://elsewhere.example.invalid")!, subject: alice.subject)
        await CollectionsHost.with(switching(stores, wire, source)) { screen in
            let drawn = await screen.until {
                CollectionsHost.identified(CollectionCard.coverIdentifier("p0"), in: screen.window)
            }
            #expect(drawn, "precondition: the card never showed its drained cover")
            let lists = wire.transport.trips.calls(TripRows.list).count
            wire.transport.trips.hold(TripRows.members)
            // As `CollectionsSession` moves the stores, then the identity the screen is given.
            CollectionsSession.identityChanged(to: there, trips: stores.0, members: stores.1)
            source.identity = there
            let reread = await screen.until {
                wire.transport.trips.calls(TripRows.list).count > lists
            }
            #expect(reread, "the other server's list was never read")
            let listed = await screen.until { Self.value(of: "Plain", on: screen) != nil }
            #expect(listed, "the other server's trip was never shown")
            await screen.settle(turns: 10)
            let kept = CollectionsHost.identified(
                CollectionCard.coverIdentifier("p0"), in: screen.window)
            #expect(!kept, "the card kept the first server's drained cover")
            #expect(
                CollectionsHost.identified(CollectionCard.coverIdentifier(nil), in: screen.window))
            wire.transport.trips.release(TripRows.members)
        }
    }
}
