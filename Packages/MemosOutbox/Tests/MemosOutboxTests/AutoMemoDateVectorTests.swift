import Foundation
import MemosOutbox
import Testing

/// The Auto memo date and the capture order, held to the vendored artefact.
///
/// Every case is READ from `auto-memo-date.json`; not one of them is written out again here. That
/// is the whole point of the artefact: the SPA's vitest suite, the server's pytest suite and this
/// one are the same cases, so a rule cannot be changed on one platform and forgotten on another.
@Suite("Auto memo date: the vendored vectors")
struct AutoMemoDateVectorTests {
    static let vectors = AutoMemoDateArtefact.vectors

    @Test("the artefact is the schema this suite reads, with enough cases to be worth anything")
    func artefactShape() {
        #expect(AutoMemoDateArtefact.document.schema == 1)
        #expect(Self.vectors.autoMemoDate.count >= 15)
        #expect(Self.vectors.captureOrder.count >= 6)
        #expect(AutoMemoDateArtefact.document.binaries.count >= 7)
        #expect(AutoMemoDateArtefact.document.rules.contains("EARLIEST"))
    }

    @Test(
        "the memo's Auto date is the earliest eligible instant",
        arguments: AutoMemoDateVectorTests.vectors.autoMemoDate
    )
    func autoDate(_ vector: AutoMemoDateArtefact.DateVector) throws {
        let zone = AutoMemoDateArtefact.zone(vector.zone)
        let answer = AutoMemoDate.autoMemoDate(vector.items.map(\.decision), in: zone)
        let expected = vector.expect.instant.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(answer.instant == expected, "case \(vector.id)")
        #expect(answer.approximate == vector.expect.approximate, "case \(vector.id)")
        #expect(answer.span == vector.expect.span, "case \(vector.id)")
    }

    @Test(
        "the attachments are in capture order",
        arguments: AutoMemoDateVectorTests.vectors.captureOrder
    )
    func order(_ vector: AutoMemoDateArtefact.OrderVector) {
        let zone = AutoMemoDateArtefact.zone(vector.zone)
        let items = vector.items.map { ArtefactItem(id: $0.id, capture: $0.decision) }
        let ordered = AutoMemoDate.captureOrder(items, in: zone).map(\.id)
        #expect(ordered == vector.expect, "case \(vector.id)")
    }

    @Test("the span hint counts calendar days", arguments: AutoMemoDateVectorTests.vectors.span)
    func span(_ vector: AutoMemoDateArtefact.SpanVector) throws {
        let zone = AutoMemoDateArtefact.zone(vector.zone)
        let instants = try vector.instants.map {
            try #require(AutoMemoDateArtefact.instant($0), "unparseable instant in \(vector.id)")
        }
        #expect(AutoMemoDate.spanDays(instants, in: zone) == vector.expect, "case \(vector.id)")
    }

    @Test(
        "a civil time resolves, or does not",
        arguments: AutoMemoDateVectorTests.vectors.civilResolution
    )
    func civil(_ vector: AutoMemoDateArtefact.CivilVector) {
        let zone = AutoMemoDateArtefact.zone(vector.zone)
        let resolved = AutoMemoDate.resolveCivil(vector.civil, in: zone)
        let expected = vector.expect.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(resolved == expected, "case \(vector.id)")
    }

    @Test(
        "the movie header is trusted only inside its range",
        arguments: AutoMemoDateVectorTests.vectors.videoHeader
    )
    func videoHeader(_ vector: AutoMemoDateArtefact.HeaderVector) throws {
        // A fixed "now" so the future case is a decision rather than a race with the clock.
        let now = try #require(AutoMemoDateArtefact.instant("2026-09-06T00:00:00Z"))
        let seconds: Double
        if let given = vector.seconds {
            seconds = given
        } else {
            let days = try #require(vector.daysFromNow, "case \(vector.id) names no seconds")
            seconds =
                now.addingTimeInterval(days * 86_400).timeIntervalSince1970 + 2_082_844_800
        }
        let instant = CaptureTags.videoHeaderInstant(quickTimeSeconds: seconds, now: now)
        let expected = vector.expect.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(instant == expected, "case \(vector.id)")
    }

    @Test(
        "the QuickTime creation date is parsed with its offset",
        arguments: AutoMemoDateVectorTests.vectors.videoCreationDate
    )
    func videoCreationDate(_ vector: AutoMemoDateArtefact.CreationDateVector) {
        let parsed = CaptureTags.quickTimeCreationDate(vector.text)
        let expected = vector.expect.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(parsed == expected, "case \(vector.id)")
    }

    @Test(
        "an EXIF pair is an instant or a civil time",
        arguments: AutoMemoDateVectorTests.vectors.exifStrings
    )
    func exifStrings(_ vector: AutoMemoDateArtefact.ExifVector) {
        let reading = CaptureTags.imageReading(
            dateTimeOriginal: vector.datetime, offset: vector.offset)
        let expected = vector.expect.instant.flatMap(AutoMemoDateArtefact.instant(_:))
        #expect(reading.instant == expected, "case \(vector.id)")
        #expect(reading.civil == vector.expect.civil, "case \(vector.id)")
        #expect(reading.source?.rawValue == vector.expect.source, "case \(vector.id)")
    }

    /// Beyond the artefact, and deliberately: the artefact names ONE zone per case because the
    /// server and the SPA each resolve in one. A phone does not — it can be picked up in another
    /// country between two picks — so the zone travels with the ITEM here, and this is the case
    /// that says so.
    @Test("each item is resolved in the zone it was picked in, not in the zone of the moment")
    func eachItemKeepsItsOwnZone() {
        let berlin = AutoMemoDateArtefact.zone("Europe/Berlin")
        let kathmandu = AutoMemoDateArtefact.zone("Asia/Kathmandu")
        // The same wall-clock reading, picked in two places. In Kathmandu (+05:45) it is the
        // earlier instant by more than four hours.
        let items = [
            ArtefactItem(
                id: "berlin", capture: .settled(CaptureReading(civil: "2026-01-01T13:00:00")),
                captureZone: berlin),
            ArtefactItem(
                id: "kathmandu", capture: .settled(CaptureReading(civil: "2026-01-01T13:00:00")),
                captureZone: kathmandu),
        ]

        let answer = AutoMemoDate.autoMemoDate(items, in: berlin)
        #expect(answer.instant == AutoMemoDateArtefact.instant("2026-01-01T07:15:00Z"))
        #expect(answer.approximate)
        #expect(AutoMemoDate.captureOrder(items, in: berlin).map(\.id) == ["kathmandu", "berlin"])
        // The control: read in ONE zone, the two are the same instant and stay in pick order.
        let flattened = items.map { ArtefactItem(id: $0.id, capture: $0.capture) }
        #expect(
            AutoMemoDate.autoMemoDate(flattened, in: berlin).instant
                == AutoMemoDateArtefact.instant("2026-01-01T12:00:00Z"))
    }

    /// A day that does not exist is not a date. `Calendar` NORMALISES rather than refusing, so
    /// without an explicit round trip this resolves to 3 March and dates a memo by a moment nobody
    /// photographed anything at.
    @Test(
        "a civil time on a day the calendar does not have is rejected",
        arguments: [
            "2026-02-31T13:00:00", "2026-02-30T13:00:00", "2026-04-31T13:00:00",
            "2026-13-01T13:00:00", "2026-00-10T13:00:00",
        ]
    )
    func impossibleDatesAreRejected(_ civil: String) {
        let zone = AutoMemoDateArtefact.zone("Europe/Berlin")
        #expect(AutoMemoDate.resolveCivil(civil, in: zone) == nil, "case \(civil)")
    }

    @Test("the days that do exist still resolve (the control)")
    func realDatesStillResolve() {
        let zone = AutoMemoDateArtefact.zone("Europe/Berlin")
        #expect(AutoMemoDate.resolveCivil("2026-02-28T13:00:00", in: zone) != nil)
        // 2028 is a leap year: 29 February is a real day and must not be refused with the rest.
        #expect(AutoMemoDate.resolveCivil("2028-02-29T13:00:00", in: zone) != nil)
        #expect(AutoMemoDate.resolveCivil("2026-12-31T23:59:59", in: zone) != nil)
    }

    @Test("an EXIF date on a day that does not exist reads as nothing")
    func impossibleExifDatesAreRejected() {
        #expect(
            CaptureTags.imageReading(dateTimeOriginal: "2026:02:31 13:00:00", offset: nil)
                == .empty)
        // The control, one day earlier.
        #expect(
            CaptureTags.imageReading(dateTimeOriginal: "2026:02:28 13:00:00", offset: nil).civil
                == "2026-02-28T13:00:00")
    }

    @Test("an item whose read has not settled contributes nothing to either answer")
    func pendingContributesNothing() throws {
        let zone = AutoMemoDateArtefact.zone("Europe/Berlin")
        let dated = try #require(AutoMemoDateArtefact.instant("2026-01-01T13:00:00Z"))
        let items = [
            ArtefactItem(id: "pending", capture: .pending),
            ArtefactItem(
                id: "dated", capture: .settled(CaptureReading(instant: dated, source: .exif))),
        ]
        #expect(AutoMemoDate.autoMemoDate(items, in: zone).instant == dated)
        // It sorts as undated, which is what makes a pending item's own arrival move it.
        #expect(AutoMemoDate.captureOrder(items, in: zone).map(\.id) == ["dated", "pending"])
    }
}
