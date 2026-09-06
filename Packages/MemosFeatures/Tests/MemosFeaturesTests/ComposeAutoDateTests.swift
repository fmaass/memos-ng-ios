import Foundation
import MemosOutbox
import Testing

@testable import MemosFeatures

/// The date the memo takes, and the order its pictures go in — as the composer decides both.
///
/// The arithmetic itself is held to the vendored artefact in `MemosOutboxTests`; what is held here
/// is the composer's part: that the control shows what was decided, that a chosen date wins, that
/// an edit is never on Auto, and that adding, removing and late-arriving reads all move the answer.
/// A zone a test can move between two picks.
@MainActor
final class ZoneBox {
    var value: TimeZone
    init(_ value: TimeZone) { self.value = value }
}

@MainActor
@Suite("The Auto memo date in the composer")
struct ComposeAutoDateTests {
    static let zone = TimeZone(identifier: "Europe/Berlin")!
    static let locale = Locale(identifier: "en_GB")

    static func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    static func media(_ name: String) -> PickedMedia {
        PickedMedia(url: URL(filePath: "/tmp/\(name)"), filename: name, mime: "image/heic")
    }

    /// An imports object whose files answer by name — the seam that lets a test say "this one was
    /// taken at one o'clock" without producing a photograph that was.
    static func imports(_ readings: [String: CaptureReading]) -> ComposeImports {
        ComposeImports(zone: zone, readCapture: { readings[$0.filename] ?? .empty })
    }

    static func exact(_ text: String) -> CaptureReading {
        CaptureReading(instant: instant(text), civil: nil, source: .exif)
    }

    static func civil(_ text: String) -> CaptureReading {
        CaptureReading(instant: nil, civil: text, source: .exif)
    }

    // MARK: - what the chip says

    @Test("the chip carries the resolved date, and says so is automatic")
    func theChipShowsTheResolvedDate() async {
        let imports = Self.imports(["a.heic": Self.exact("2026-01-01T13:00:00Z")])
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(Self.media("a.heic")) }
        await settleTasks()

        let title = MemoDateChoice.autoTitle(imports.autoDate, locale: Self.locale)
        #expect(title.hasPrefix("Auto · "))
        #expect(title.contains("Jan"))
        #expect(!title.contains("≈"), "an exact instant was marked approximate")
        #expect(!title.contains("spans"))
    }

    @Test("a civil time that had to be resolved is marked with a tilde and nothing else")
    func anApproximateWinnerIsMarked() async {
        let imports = Self.imports(["a.heic": Self.civil("2026-01-01T13:00:00")])
        await imports.load(["a"], stamp: imports.selected()) { _ in .file(Self.media("a.heic")) }
        await settleTasks()

        #expect(imports.autoDate.instant == Self.instant("2026-01-01T12:00:00Z"))
        #expect(imports.autoDate.approximate)
        #expect(MemoDateChoice.autoTitle(imports.autoDate, locale: Self.locale).contains("≈"))
    }

    @Test("pictures from different days say how many the memo spans")
    func theSpanIsShown() async {
        let imports = Self.imports([
            "a.heic": Self.exact("2026-01-01T13:00:00Z"),
            "b.heic": Self.exact("2026-01-03T09:00:00Z"),
        ])
        await imports.load(["a", "b"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await settleTasks()

        #expect(imports.autoDate.span == 3)
        #expect(
            MemoDateChoice.autoTitle(imports.autoDate, locale: Self.locale)
                .contains("spans 3 days"))
    }

    @Test("with nothing dated attached, Auto is the moment of writing and says so")
    func autoWithNothingDated() {
        #expect(MemoDateChoice.autoTitle(.undated, locale: Self.locale) == "Auto · now")
        #expect(
            MemoDateChoice.spokenValue(for: nil, auto: .undated, locale: Self.locale)
                == "Automatic: the time of writing")
    }

    @Test("what a screen reader hears never leaves the mode or the approximation unsaid")
    func theSpokenValue() {
        let auto = AutoMemoDateResult(
            instant: Self.instant("2026-01-01T12:00:00Z"), approximate: true, span: 2)
        let spoken = MemoDateChoice.spokenValue(for: nil, auto: auto, locale: Self.locale)
        #expect(spoken.hasPrefix("Automatic: approximately "))
        #expect(spoken.contains("spanning 2 days"))
        // A chosen date is not automatic anything.
        let chosen = MemoDateChoice.spokenValue(
            for: Self.instant("2020-05-05T05:05:00Z"), auto: auto, locale: Self.locale)
        #expect(!chosen.contains("Automatic"))
    }

    // MARK: - Auto, Manual, and back

    @Test("a chosen date wins over Auto, and clearing it hands the answer back")
    func autoThenManualThenAuto() {
        let auto = AutoMemoDateResult(instant: Self.instant("2026-01-01T13:00:00Z"))
        let picked = Self.instant("2001-02-03T04:05:00Z")

        #expect(ComposeDate.resolved(chosen: nil, auto: auto) == auto.instant)
        #expect(ComposeDate.resolved(chosen: picked, auto: auto) == picked)
        // One tap on Auto in the picker puts the chosen date back to nil.
        #expect(ComposeDate.resolved(chosen: nil, auto: auto) == auto.instant)
        // And with nothing dated attached, Auto resolves to nothing at all: the outbox stamps the
        // moment of writing rather than this sheet inventing a date.
        #expect(ComposeDate.resolved(chosen: nil, auto: .undated) == nil)
    }

    @Test("an edit opens on the memo's own date and is never offered Auto")
    func anEditIsAlwaysManual() {
        let attached = AutoMemoDateResult(instant: Self.instant("2026-01-01T13:00:00Z"))
        let memoDate = Self.instant("2024-06-01T08:00:00Z")

        #expect(ComposeDate.auto(isEdit: true, from: attached) == nil)
        #expect(
            ComposeDate.resolved(
                chosen: memoDate, auto: ComposeDate.auto(isEdit: true, from: attached))
                == memoDate,
            "a file added on an edit re-dated the memo")
        // The control: a NEW memo does get the Auto side.
        #expect(ComposeDate.auto(isEdit: false, from: attached) == attached)
    }

    @Test("the pill shows the memo's date on an edit, and the Auto chip on a new memo")
    func thePillFollowsTheMode() {
        let auto = AutoMemoDateResult(instant: Self.instant("2026-01-01T13:00:00Z"))
        let memoDate = Self.instant("2024-06-01T08:00:00Z")

        #expect(
            MemoDatePill(date: memoDate, auto: nil).title == MemoDateChoice.pillTitle(for: memoDate)
        )
        #expect(MemoDatePill(date: nil, auto: auto).title?.hasPrefix("Auto · ") == true)
        // Down to a glyph the pill says nothing at all, in either mode.
        #expect(MemoDatePill(date: nil, auto: auto, spelling: .glyph).title == nil)
    }

    @Test("the date the submission carries is the resolved one, and the outbox stamps it")
    func theResolvedDateReachesTheSubmission() {
        let auto = AutoMemoDateResult(instant: Self.instant("2026-01-01T13:00:00Z"))
        let submission = ComposeSubmission(
            content: "the walk",
            visibility: nil,
            createdAt: ComposeDate.resolved(chosen: nil, auto: auto)
        )

        #expect(submission.createdAt == auto.instant)
        // `capturedAt` is the one step where a chosen date could be silently dropped.
        #expect(submission.capturedAt(now: Date()) == auto.instant)
        // And with no eligible instant the absence survives all the way, so the queue stamps the
        // moment of writing rather than a date this sheet made up.
        let undated = ComposeSubmission(content: "", visibility: nil, createdAt: nil)
        let now = Self.instant("2026-09-06T00:00:00Z")
        #expect(undated.capturedAt(now: now) == now)
    }

    // MARK: - the order

    @Test("the tiles and the files are in capture order, not pick order")
    func theOrderIsCaptureOrder() async {
        let imports = Self.imports([
            "b.heic": Self.exact("2026-01-01T15:00:00Z"),
            "a.heic": Self.exact("2026-01-01T13:00:00Z"),
            "d.heic": Self.exact("2026-01-01T14:00:00Z"),
        ])
        // Picked b, a, c (undated), d — the artefact's own `captureOrder` case.
        await imports.load(["b", "a", "c", "d"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await settleTasks()

        #expect(imports.attachments.map(\.filename) == ["a.heic", "d.heic", "b.heic", "c.heic"])
        #expect(imports.ordered.map(\.label) == ["a.heic", "d.heic", "b.heic", "c.heic"])
    }

    @Test("an item that settles late moves to its place and can re-date the memo")
    func aLateCompletionReordersAndRedates() async {
        let gate = ReadGate(Self.exact("2026-01-01T12:00:00Z"))
        let imports = ComposeImports(
            zone: Self.zone,
            readCapture: { media in
                media.filename == "late.heic"
                    ? await gate.read(media)
                    : Self.exact("2026-01-01T14:00:00Z")
            })

        await imports.load(["late", "early"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await gate.waitUntilStarted()
        await settleTasks()
        // Before the late one settles: it is undated, so it sorts last and the other one dates the
        // memo.
        #expect(imports.attachments.map(\.filename) == ["early.heic", "late.heic"])
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T14:00:00Z"))

        await gate.release()
        await settleTasks()

        #expect(imports.attachments.map(\.filename) == ["late.heic", "early.heic"])
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T12:00:00Z"))
    }

    @Test("removing the earliest hands the date to what is left, and the order follows")
    func removingTheMinimumMovesTheDate() async {
        let imports = Self.imports([
            "a.heic": Self.exact("2026-01-01T13:00:00Z"),
            "b.heic": Self.exact("2026-01-01T14:00:00Z"),
        ])
        await imports.load(["a", "b", "c"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await settleTasks()
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T13:00:00Z"))

        imports.remove(id: imports.items.first { $0.label == "a.heic" }!.id)

        #expect(imports.autoDate.instant == Self.instant("2026-01-01T14:00:00Z"))
        #expect(imports.attachments.map(\.filename) == ["b.heic", "c.heic"])
    }

    /// F1b's tie-break is PICK order, and pick order is one order for the whole list. A photograph
    /// taken before two were picked comes first — grouping the camera's items after the library's
    /// would put it last among the undated ones, which is not the order anybody made.
    @Test("undated items keep one pick order across the camera and the library")
    func undatedItemsShareOnePickOrder() async {
        let imports = Self.imports([:])
        imports.captured(Self.media("IMG_0001.heic"))
        await imports.load(["a", "b"], stamp: imports.selected()) { item in
            .file(Self.media("\(item).heic"))
        }
        await settleTasks()

        #expect(
            imports.attachments.map(\.filename) == ["IMG_0001.heic", "a.heic", "b.heic"],
            "the capture was grouped after the pick instead of keeping its place")
        // And a capture taken AFTER a pick still comes after it.
        imports.captured(Self.media("IMG_0002.heic"))
        await settleTasks()
        #expect(
            imports.attachments.map(\.filename)
                == ["IMG_0001.heic", "a.heic", "b.heic", "IMG_0002.heic"])
    }

    /// The zone is a fact about the MOMENT OF PICKING, not about the composer: a phone can be
    /// picked up in another country, or its setting corrected, between two picks in one sheet. Each
    /// item keeps the zone it was picked in, so nothing already on screen re-resolves.
    @Test("each pick is stamped with the zone as it read at that moment")
    func theZoneIsSampledAtEachPick() async throws {
        let berlin = Self.zone
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu") ?? .gmt
        let now = ZoneBox(berlin)
        // The same wall-clock reading for every file: what differs is only where it was picked.
        let imports = ComposeImports(
            zone: berlin,
            zoneAtPick: { now.value },
            readCapture: { _ in CaptureReading(civil: "2026-01-01T13:00:00", source: .exif) })

        await imports.load(["here"], stamp: imports.selected()) { _ in
            .file(Self.media("here.heic"))
        }
        await settleTasks()

        // The phone moves, and a second item is attached.
        now.value = kathmandu
        imports.captured(Self.media("there.heic"))
        await settleTasks()

        let picked = try #require(imports.items.first { $0.label == "here.heic" })
        let captured = try #require(imports.items.first { $0.label == "there.heic" })
        #expect(picked.captureZone == berlin, "the first item's zone moved with the device")
        #expect(captured.captureZone == kathmandu, "the second item did not take the new zone")
        // One reading, two zones, two instants — and Kathmandu (+05:45) is the earlier of them, so
        // that is the date the memo takes.
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T07:15:00Z"))
    }

    /// The same, between two PICKS rather than a pick and a capture: the picker is the way most
    /// files arrive, and a second selection lands in whatever zone the phone is in by then.
    @Test("two picks either side of a zone change each keep their own")
    func twoPicksKeepTheirOwnZones() async throws {
        let berlin = Self.zone
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu") ?? .gmt
        let now = ZoneBox(berlin)
        let imports = ComposeImports(
            zone: berlin,
            zoneAtPick: { now.value },
            readCapture: { _ in CaptureReading(civil: "2026-01-01T13:00:00", source: .exif) })

        await imports.load(["first"], stamp: imports.selected()) { _ in
            .file(Self.media("first.heic"))
        }
        await settleTasks()
        let firstItem = try #require(imports.items.first)
        #expect(firstItem.captureZone == berlin)
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T12:00:00Z"))

        // The phone moves. A pick REPLACES what was picked, so this is the whole list now.
        now.value = kathmandu
        await imports.load(["second"], stamp: imports.selected()) { _ in
            .file(Self.media("second.heic"))
        }
        await settleTasks()

        let secondItem = try #require(imports.items.first)
        #expect(secondItem.captureZone == kathmandu, "the second pick took the composer's old zone")
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T07:15:00Z"))
    }

    @Test("a camera capture sorts by its own instant, like anything else")
    func aCaptureSortsByItsInstant() async {
        let imports = Self.imports([
            "picked.heic": Self.exact("2026-01-01T15:00:00Z"),
            "IMG_0001.heic": Self.exact("2026-01-01T09:00:00Z"),
        ])
        await imports.load(["picked"], stamp: imports.selected()) { _ in
            .file(Self.media("picked.heic"))
        }
        imports.captured(Self.media("IMG_0001.heic"))
        await settleTasks()

        #expect(imports.attachments.map(\.filename) == ["IMG_0001.heic", "picked.heic"])
        #expect(imports.autoDate.instant == Self.instant("2026-01-01T09:00:00Z"))
    }
}
