import Foundation
import HTTPTypes
import MemosAPI
import MemosCore
import OpenAPIRuntime
import Testing

@testable import MemosFeatures

/// A trip's dates (MEMNG-737): the Trip Dates sheet's draft, what it writes and refuses, the New
/// trip sheet's prefill from the tag, and the journal's days.
@MainActor
@Suite("Trip dates")
struct TripSpanSheetTests {
    private static let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private let root = FileManager.default.temporaryDirectory
        .appending(path: "trip-dates").appending(path: UUID().uuidString)
    private let alice = TimelineSnapshotIdentity(
        server: URL(string: "https://memos.example.invalid")!, subject: "alice")

    /// An instant on Lisbon's wall clock in July 2026.
    private static func lisbon(
        _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbon
        return calendar.date(
            from: DateComponents(
                year: 2026, month: 7, day: day, hour: hour, minute: minute, second: second))!
    }

    /// 10 July 00:00 to 20 July 14:00, as the sheet writes it: to the end of 14:00's minute.
    private static let span = TripSpan(
        start: lisbon(10, 0, 0), end: lisbon(20, 14, 0, 59), zone: "Europe/Lisbon")

    /// A trip store over `wire`, read back by a real refresh.
    private func store(_ wire: SpanWire) async -> TripStore {
        let store = TripStore(identity: alice, root: root)
        await store.refresh(using: wire.handle, baseURL: SpanWire.baseURL)
        return store
    }

    /// `Lisbon` on `wire`'s server, spanned `Self.span` and with no tag, as a refresh lists it.
    private func lisbonTrip(on wire: SpanWire) async throws -> (TripStore, Trip) {
        let span = Self.span
        wire.trips.seed(
            "Lisbon", spanStart: span.start.formatted(.iso8601),
            spanEnd: span.end.formatted(.iso8601), tz: span.zone)
        let store = await store(wire)
        return (store, try #require(store.trips.first))
    }

    @Test("the sheet writes the start from its minute's first second and the end to its last")
    func toTheMinute() throws {
        let draft = TripSpanDraft(
            start: Self.lisbon(10, 0, 0, 37), end: Self.lisbon(20, 14, 0, 12), zone: Self.lisbon)
        let span = try #require(draft.span)
        #expect(span.start == Self.lisbon(10, 0, 0))
        #expect(span.end == Self.lisbon(20, 14, 0, 59))
        #expect(span.zone == "Europe/Lisbon")
        #expect(span.contains(Self.lisbon(20, 14, 0, 30)))
        #expect(!span.contains(Self.lisbon(20, 14, 1)))
    }

    @Test("the sheet refuses an end before the start, and Save writes nothing")
    func aBackwardSpanIsRefused() async throws {
        let wire = SpanWire()
        let (store, record) = try await lisbonTrip(on: wire)
        var draft = TripSpanDraft(Self.span)
        draft.end = Self.lisbon(9, 23, 59)
        #expect(draft.span == nil, "a backward span was offered to Save")
        let saved = try await draft.save(to: store, uid: record.uid, using: wire.access)
        #expect(saved == nil)
        #expect(wire.trips.calls(TripRows.patch).isEmpty, "a refused span was sent")
        #expect(store.trips.first?.tripSpan == Self.span, "a refused span was written")
        // The same minute at both ends is a span of that minute.
        draft.end = Self.lisbon(10, 0, 0, 30)
        #expect(draft.span?.end == Self.lisbon(10, 0, 0, 59))
    }

    @Test("moving the end by one minute on the sheet changes the trip's count on the next drain")
    func oneMinuteOnTheSheet() async throws {
        let wire = SpanWire(newestFirst: [
            ("after", Self.lisbon(20, 14, 1, 30)),
            ("last", Self.lisbon(20, 14, 0, 30)),
            ("first", Self.lisbon(10, 10, 0)),
            ("eve", Self.lisbon(9, 22, 0)),
        ])
        let (collections, record) = try await lisbonTrip(on: wire)
        let trips = TripMemberStore(trips: collections)
        await trips.drain(record, using: wire.handle, baseURL: SpanWire.baseURL)
        #expect(trips.summary(for: record)?.count == 2, "control: 14:01 is out")

        var draft = TripSpanDraft(Self.span)
        draft.end = Self.lisbon(20, 14, 1)
        let saved = try await draft.save(to: collections, uid: record.uid, using: wire.access)
        #expect(saved != nil, "the sheet's span was not written")
        let moved = collections.trips.first ?? record
        await trips.drain(moved, using: wire.handle, baseURL: SpanWire.baseURL)

        #expect(trips.summary(for: moved)?.count == 3, "the minute changed nothing")
        #expect(trips.members(for: moved).map(\.id) == ["first", "last", "after"])
    }

    @Test("a backward span is never sent; one minute is a span; Remove Dates takes it away")
    func theStoreRefusesABackwardSpan() async throws {
        let wire = SpanWire()
        let (store, record) = try await lisbonTrip(on: wire)
        var backward = TripSpanDraft(Self.span)
        backward.end = Self.span.start.addingTimeInterval(-60)
        _ = try await backward.save(to: store, uid: record.uid, using: wire.access)
        #expect(wire.trips.calls(TripRows.patch).isEmpty, "a backward span was sent")
        #expect(store.trips.first?.tripSpan == Self.span, "a backward span was written")

        var instant = TripSpanDraft(Self.span)
        instant.end = instant.start
        _ = try await instant.save(to: store, uid: record.uid, using: wire.access)
        let minute = TripSpan(
            start: Self.span.start, end: Self.span.start.addingTimeInterval(59),
            zone: Self.span.zone)
        #expect(store.trips.first?.tripSpan == minute, "a one-minute span is a span")
        try await TripSpanSheet.removeDates(of: record.uid, in: store, using: wire.access)
        #expect(store.trips.first?.tripSpan == nil, "the span was not taken away")
        let reread = await self.store(wire)
        #expect(reread.trips.first?.tripSpan == nil, "the server kept the span")
    }

    @Test("another zone keeps the wall clock the owner chose")
    func anotherZoneKeepsTheWallClock() throws {
        var draft = TripSpanDraft(Self.span)
        draft.move(to: Self.berlin)
        let span = try #require(draft.span)
        #expect(span.zone == "Europe/Berlin")
        // Berlin runs an hour ahead of Lisbon: the same 00:00 is an hour earlier.
        #expect(span.start == Self.lisbon(9, 23, 0))
        #expect(span.end == Self.lisbon(20, 13, 0, 59))
    }

    @Test("Trip Dates opens on the trip's span, else on the days its pictures span")
    func theSheetOpensOnTheTrip() {
        let made = Self.lisbon(1, 0, 0)
        let spanned = Trip(
            uid: "spanned", title: "Lisbon", spanStart: Self.span.start, spanEnd: Self.span.end,
            tz: Self.span.zone, createdAt: made, updatedAt: made)
        #expect(
            TripSpanSheet.opening(
                spanned, summary: nil, now: Self.lisbon(25, 9, 0), zone: Self.berlin)
                == TripSpanDraft(Self.span))
        let tagged = Trip(
            uid: "tagged", title: "Portugal", tag: "portugal2026", memberCount: 4,
            createdAt: made, updatedAt: made)
        let drained = TripMemberSummary(
            count: 4, firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 18, 0),
            cover: nil)
        let opened = TripSpanSheet.opening(
            tagged, summary: drained, now: Self.lisbon(25, 9, 0), zone: Self.lisbon)
        let days = TripSpan.days(
            from: Self.lisbon(10, 9, 0), to: Self.lisbon(20, 18, 0), in: Self.lisbon)
        #expect(opened.span == days)
    }

    // MARK: - the New trip sheet

    @Test("choosing a tag prefills its days in the phone's zone; an edited span survives a choice")
    func theNewTripPrefill() {
        let flow = NewTripFlow()
        let portugal = TripTagSpan(
            firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 18, 0))
        flow.choose("portugal2026", span: portugal, zone: Self.lisbon)
        #expect(flow.span?.span?.start == Self.lisbon(10, 0, 0))
        #expect(flow.span?.span?.end == Self.lisbon(20, 23, 59, 59))

        // Another tag whose span has not arrived: the last tag's days go, and come back for it.
        flow.choose("nyc", span: nil, zone: Self.lisbon)
        #expect(flow.span == nil, "the last tag's days stayed on another tag")
        flow.prefill(portugal, of: "nyc", zone: Self.lisbon)
        #expect(flow.span?.span?.start == Self.lisbon(10, 0, 0), "an arriving span was not taken")

        flow.span?.end = Self.lisbon(20, 14, 0)
        let edited = flow.span
        flow.choose("portugal2026", span: portugal, zone: Self.lisbon)
        #expect(flow.span == edited, "an edited span was overwritten")
    }

    @Test("Create waits for the chosen tag's dates, and files them once they arrive")
    func createWaitsForThePrefill() async throws {
        let wire = SpanWire()
        let store = await store(wire)
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        #expect(!flow.canCreate, "Create was offered before the tag's dates arrived")
        #expect(await flow.create(in: store, using: wire.access) == nil)
        #expect(store.trips.isEmpty, "a trip was filed without its dates")
        #expect(wire.trips.calls(TripRows.create).isEmpty, "a trip was sent without its dates")

        flow.prefill(
            TripTagSpan(firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 9, 0)),
            of: "portugal2026", zone: Self.lisbon)
        #expect(flow.canCreate)
        let made = try #require(await flow.create(in: store, using: wire.access))
        #expect(made.spanStart == Self.lisbon(10, 0, 0), "the prefill never reached the record")
    }

    @Test("a tag whose dates never came is filed alone once its own read ends")
    func aFailedDatesReadReleasesCreate() async throws {
        let wire = SpanWire()
        let store = await store(wire)
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        #expect(flow.awaitingDates)
        flow.endDatesRead(of: "nyc")
        #expect(flow.awaitingDates, "another tag's read let Create go")
        flow.endDatesRead(of: "portugal2026")
        #expect(!flow.awaitingDates, "a failed read held Create forever")
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        #expect(!flow.awaitingDates, "the same tag again waited for a read nobody sends")
        let made = try #require(await flow.create(in: store, using: wire.access))
        #expect(made.tag == "portugal2026")
        #expect(made.span == nil)
    }

    @Test("No Dates is a choice: Create needs no prefill, and a late one does not undo it")
    func noDatesIsAChoice() async throws {
        let wire = SpanWire()
        let store = await store(wire)
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        flow.removeDates()
        #expect(!flow.awaitingDates)
        #expect(flow.canCreate)
        flow.prefill(
            TripTagSpan(firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 9, 0)),
            of: "portugal2026", zone: Self.lisbon)
        #expect(flow.span == nil, "a late prefill overrode No Dates")
        let made = try #require(await flow.create(in: store, using: wire.access))
        #expect(made.span == nil)
    }

    @Test("a tag without dated pictures answers the wait too")
    func anUndatedTagAnswers() {
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        flow.prefill(
            TripTagSpan(firstTaken: nil, lastTaken: nil), of: "portugal2026", zone: Self.lisbon)
        #expect(!flow.awaitingDates)
        #expect(flow.canCreate)
        #expect(flow.span == nil)
    }

    @Test("Create files the tag with its span; dates alone make a trip without a tag")
    func createWithASpan() async throws {
        let wire = SpanWire()
        let store = await store(wire)
        let flow = NewTripFlow()
        flow.choose(
            "portugal2026",
            span: TripTagSpan(firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 9, 0)),
            zone: Self.lisbon)
        let made = try #require(await flow.create(in: store, using: wire.access))
        #expect(made.tag == "portugal2026")
        #expect(made.spanStart == Self.lisbon(10, 0, 0))

        let datesOnly = NewTripFlow()
        #expect(!datesOnly.canCreate)
        datesOnly.addDates(now: Self.lisbon(12, 15, 0), zone: Self.lisbon)
        datesOnly.title = "A weekend"
        #expect(datesOnly.canCreate)
        let weekend = try #require(await datesOnly.create(in: store, using: wire.access))
        #expect(weekend.tag == nil)
        #expect(weekend.spanStart == Self.lisbon(12, 0, 0))
    }

    @Test("a span that ends before it starts keeps Create off")
    func aBackwardSpanKeepsCreateOff() async {
        let wire = SpanWire()
        let store = await store(wire)
        let flow = NewTripFlow()
        flow.choose("portugal2026")
        flow.addDates(now: Self.lisbon(12, 15, 0), zone: Self.lisbon)
        flow.span?.end = Self.lisbon(11, 0, 0)
        #expect(!flow.canCreate)
        #expect(await flow.create(in: store, using: wire.access) == nil)
        #expect(store.trips.isEmpty)
        #expect(wire.trips.calls(TripRows.create).isEmpty, "a backward span was sent")
        flow.removeDates()
        #expect(flow.canCreate, "the tag alone is a trip")
    }

    // MARK: - the journal's days

    @Test("a journal heads a memo with the day of its earliest picture, its own date without one")
    func theJournalsDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.lisbon
        let photos = Memo(
            uid: "photos", owner: "fabian", mine: true, content: "", visibility: .protected,
            pinned: false, createdAt: Self.lisbon(25, 9, 0), updatedAt: Self.lisbon(25, 9, 0),
            attachments: [
                MemoAttachment(
                    uid: "a", mime: "image/jpeg", status: .ready,
                    captureInstant: Self.lisbon(12, 8, 0)),
                MemoAttachment(
                    uid: "b", mime: "image/jpeg", status: .ready,
                    captureInstant: Self.lisbon(11, 8, 0)),
            ])
        let words = Memo(
            uid: "words", owner: "fabian", mine: true, content: "", visibility: .protected,
            pinned: false, createdAt: Self.lisbon(13, 9, 0), updatedAt: Self.lisbon(13, 9, 0))
        let sections = TimelineGrouping.sections(
            for: [photos, words], calendar: calendar,
            instant: TripMemberStore.journalInstant(of:))
        #expect(sections.map(\.day) == [Self.lisbon(11, 0, 0), Self.lisbon(13, 0, 0)])
        // The timeline's own grouping keys on the date, as it always has.
        let timeline = TimelineGrouping.sections(for: [photos], calendar: calendar)
        #expect(timeline.map(\.day) == [Self.lisbon(25, 0, 0)])
    }
}

/// A server holding trips on the collection routes, whose library is `newestFirst`: a trip's
/// members are the pictures taken inside its span, and so is its count.
@MainActor
private final class SpanWire {
    static let baseURL = URL(string: "https://memos.example.invalid")!
    let transport: SpanTransport
    let access: CollectionsAccess
    var handle: SessionHandle { access.handle }
    var trips: TripRows { transport.trips }

    init(newestFirst rows: [(uid: String, taken: Date)] = []) {
        transport = SpanTransport(rows: rows)
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.baseURL),
            token: { "memos_pat_trips" },
            transport: transport)
        access = CollectionsAccess(
            handle: SessionHandle(client: client, generation: 1), baseURL: Self.baseURL)
    }
}

private nonisolated final class SpanTransport: ClientTransport, @unchecked Sendable {
    let rows: [(uid: String, taken: Date)]
    let trips: TripRows

    init(rows: [(uid: String, taken: Date)]) {
        self.rows = rows
        trips = TripRows(counter: { row in
            Self.within(start: row.spanStart, end: row.spanEnd, of: rows).count
        })
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let rows = rows
        if let answered = try await trips.answer(
            request, body: body, operationID: operationID,
            listing: { query in
                let inside = Self.within(start: query["spanStart"], end: query["spanEnd"], of: rows)
                return Self.page(inside.reversed())
            })
        {
            return answered
        }
        return Self.page(rows)
    }

    /// The rows taken inside the span its ends spell, newest first; none without a span.
    static func within(
        start: String?, end: String?, of rows: [(uid: String, taken: Date)]
    ) -> [(uid: String, taken: Date)] {
        guard let first = instant(start), let last = instant(end) else { return [] }
        return rows.filter { first <= $0.taken && $0.taken <= last }
    }

    static func instant(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: text) ?? fractional.date(from: text)
    }

    static func page(_ rows: [(uid: String, taken: Date)]) -> (HTTPResponse, HTTPBody?) {
        let items = rows.map { row in
            let uid = row.uid
            return """
                {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
                "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
                "webReady":true,\
                "renditions":[],"tags":[],"orphan":false,"memoUid":"m-\(uid)",\
                "takenAt":"\(row.taken.formatted(.iso8601))","filename":"\(uid).jpg",\
                "thumbnailUrl":"/api/attachments/\(uid)/thumb",\
                "previewUrl":"/api/attachments/\(uid)/mobile",\
                "webUrl":"/api/attachments/\(uid)/web",\
                "posterUrl":"/api/attachments/\(uid)/poster",\
                "downloadUrl":"/api/attachments/\(uid)/download",\
                "printUrl":"/api/attachments/\(uid)/print"}
                """
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody("[\(items.joined(separator: ","))]"))
    }
}
