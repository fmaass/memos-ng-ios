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
