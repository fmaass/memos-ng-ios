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
    func aBackwardSpanIsRefused() {
        let collections = CollectionStore(identity: alice, root: root)
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        var draft = TripSpanDraft(Self.span)
        draft.end = Self.lisbon(9, 23, 59)
        #expect(draft.span == nil, "a backward span was offered to Save")
        #expect(!draft.save(to: collections, id: record.id))
        #expect(collections.records.first?.span == Self.span, "a refused span was written")
        // The same minute at both ends is a span of that minute.
        draft.end = Self.lisbon(10, 0, 0, 30)
        #expect(draft.span?.end == Self.lisbon(10, 0, 0, 59))
    }

    @Test("moving the end by one minute on the sheet changes the trip's count on the next drain")
    func oneMinuteOnTheSheet() async {
        let wire = SpanWire(newestFirst: [
            ("after", Self.lisbon(20, 14, 1, 30)),
            ("last", Self.lisbon(20, 14, 0, 30)),
            ("first", Self.lisbon(10, 10, 0)),
            ("eve", Self.lisbon(9, 22, 0)),
        ])
        let collections = CollectionStore(identity: alice, root: root)
        let record = collections.create(title: "Lisbon", tags: [], span: Self.span)
        let trips = TripMembershipStore(collections: collections)
        await trips.drain(record, using: wire.handle, baseURL: SpanWire.baseURL)
        #expect(collections.records.first?.lastSummary?.count == 2, "control: 14:01 is out")

        var draft = TripSpanDraft(Self.span)
        draft.end = Self.lisbon(20, 14, 1)
        #expect(draft.save(to: collections, id: record.id), "the sheet's span was not written")
        let moved = collections.records.first ?? record
        await trips.drain(moved, using: wire.handle, baseURL: SpanWire.baseURL)

        #expect(collections.records.first?.lastSummary?.count == 3, "the minute changed nothing")
        #expect(trips.members(for: moved).map(\.id) == ["first", "last", "after"])
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
        let spanned = CollectionRecord(
            id: UUID(), kind: .trip, title: "Lisbon", tags: [], order: 0,
            createdAt: Self.lisbon(1, 0, 0), span: Self.span)
        #expect(
            TripSpanSheet.opening(spanned, now: Self.lisbon(25, 9, 0), zone: Self.berlin)
                == TripSpanDraft(Self.span))
        let tagged = CollectionRecord(
            id: UUID(), kind: .trip, title: "Portugal", tags: ["portugal2026"], order: 0,
            lastSummary: TripSummary(
                count: 4, firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 18, 0),
                coverUid: nil),
            createdAt: Self.lisbon(1, 0, 0))
        let opened = TripSpanSheet.opening(tagged, now: Self.lisbon(25, 9, 0), zone: Self.lisbon)
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
    func createWaitsForThePrefill() throws {
        let store = CollectionStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        #expect(!flow.canCreate, "Create was offered before the tag's dates arrived")
        #expect(flow.create(in: store) == nil)
        #expect(store.records.isEmpty, "a trip was filed without its dates")

        flow.prefill(
            TripTagSpan(firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 9, 0)),
            of: "portugal2026", zone: Self.lisbon)
        #expect(flow.canCreate)
        let made = try #require(flow.create(in: store))
        #expect(made.span?.start == Self.lisbon(10, 0, 0), "the prefill never reached the record")
    }

    @Test("a tag whose dates never came is filed alone once its own read ends")
    func aFailedDatesReadReleasesCreate() throws {
        let store = CollectionStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        #expect(flow.awaitingDates)
        flow.endDatesRead(of: "nyc")
        #expect(flow.awaitingDates, "another tag's read let Create go")
        flow.endDatesRead(of: "portugal2026")
        #expect(!flow.awaitingDates, "a failed read held Create forever")
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        #expect(!flow.awaitingDates, "the same tag again waited for a read nobody sends")
        let made = try #require(flow.create(in: store))
        #expect(made.tags == ["portugal2026"])
        #expect(made.span == nil)
    }

    @Test("No Dates is a choice: Create needs no prefill, and a late one does not undo it")
    func noDatesIsAChoice() throws {
        let store = CollectionStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose("portugal2026", span: nil, zone: Self.lisbon)
        flow.removeDates()
        #expect(!flow.awaitingDates)
        #expect(flow.canCreate)
        flow.prefill(
            TripTagSpan(firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 9, 0)),
            of: "portugal2026", zone: Self.lisbon)
        #expect(flow.span == nil, "a late prefill overrode No Dates")
        let made = try #require(flow.create(in: store))
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
    func createWithASpan() throws {
        let store = CollectionStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose(
            "portugal2026",
            span: TripTagSpan(firstTaken: Self.lisbon(10, 9, 0), lastTaken: Self.lisbon(20, 9, 0)),
            zone: Self.lisbon)
        let made = try #require(flow.create(in: store))
        #expect(made.tags == ["portugal2026"])
        #expect(made.span?.start == Self.lisbon(10, 0, 0))

        let datesOnly = NewTripFlow()
        #expect(!datesOnly.canCreate)
        datesOnly.addDates(now: Self.lisbon(12, 15, 0), zone: Self.lisbon)
        datesOnly.title = "A weekend"
        #expect(datesOnly.canCreate)
        let weekend = try #require(datesOnly.create(in: store))
        #expect(weekend.tags.isEmpty)
        #expect(weekend.span?.start == Self.lisbon(12, 0, 0))
    }

    @Test("a span that ends before it starts keeps Create off")
    func aBackwardSpanKeepsCreateOff() {
        let store = CollectionStore(identity: alice, root: root)
        let flow = NewTripFlow()
        flow.choose("portugal2026")
        flow.addDates(now: Self.lisbon(12, 15, 0), zone: Self.lisbon)
        flow.span?.end = Self.lisbon(11, 0, 0)
        #expect(!flow.canCreate)
        #expect(flow.create(in: store) == nil)
        #expect(store.records.isEmpty)
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
            instant: TripMembershipStore.journalInstant(of:))
        #expect(sections.map(\.day) == [Self.lisbon(11, 0, 0), Self.lisbon(13, 0, 0)])
        // The timeline's own grouping keys on the date, as it always has.
        let timeline = TimelineGrouping.sections(for: [photos], calendar: calendar)
        #expect(timeline.map(\.day) == [Self.lisbon(25, 0, 0)])
    }
}

/// A server whose library is `newestFirst`, answered whole to every `taken_desc` read.
@MainActor
private final class SpanWire {
    static let baseURL = URL(string: "https://memos.example.invalid")!
    let handle: SessionHandle

    init(newestFirst rows: [(uid: String, taken: Date)]) {
        let client = APIClientFactory.make(
            configuration: ServerConfiguration(baseURL: Self.baseURL),
            token: { "memos_pat_trips" },
            transport: SpanTransport(rows: rows))
        handle = SessionHandle(client: client, generation: 1)
    }
}

private struct SpanTransport: ClientTransport {
    let rows: [(uid: String, taken: Date)]

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let items = rows.map { row in
            let uid = row.uid
            return """
                {"uid":"\(uid)","mime":"image/jpeg","status":"ready","blurhash":null,\
                "width":1000,"height":800,"mine":true,"hasPrint":false,"hasLegacyPrint":false,\
                "renditions":[],"orphan":false,"memoUid":"m-\(uid)",\
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
