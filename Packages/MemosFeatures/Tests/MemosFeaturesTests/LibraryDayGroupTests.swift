import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The All view's day groups (MEMNG-597, plan page 3929 decision 13, `docs/design/all-by-day-mockup.md`
/// §2): a loaded list cut into Europe/Zurich calendar days under their months, each day given its
/// frames from the A B C B D cycle, one step later than the day before it across months.
@MainActor
@Suite("Library day groups")
struct LibraryDayGroupTests {
    private static let zurich = "Europe/Zurich"
    private static let a: [MosaicSlot] = [.heroLeft, .sideRight, .sideRight]
    private static let b: [MosaicSlot] = [.square, .square, .square]
    private static let c: [MosaicSlot] = [.heroRight, .sideLeft, .sideLeft]

    private static func row(_ uid: String, _ iso: String) throws -> LibraryRow {
        let instant = try #require(ISO8601DateFormatter().date(from: iso), "fixture \(iso)")
        return LibraryRow(
            attachment: MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready),
            takenAt: instant, mine: true, filename: uid)
    }

    @Test("cuts a loaded list into Zurich days under their months and gives each day its frames")
    func cutsIntoZurichDaysWithFrames() throws {
        let items = try [
            // 1 October in Zurich (01:30 CEST), though 30 September in UTC.
            Self.row("o1", "2026-09-30T23:30:00Z"),
            Self.row("o2", "2026-10-01T06:00:00Z"),
            Self.row("o3", "2026-10-01T07:00:00Z"),
            Self.row("s1", "2026-09-30T12:00:00Z"),
            // 27 September at exactly Zurich midnight.
            Self.row("s2", "2026-09-26T22:00:00Z"),
            Self.row("s3", "2026-09-26T23:00:00Z"),
            Self.row("s4", "2026-09-27T08:00:00Z"),
            Self.row("s5", "2026-09-27T09:00:00Z"),
        ]
        let months = MediaLibraryPresentation.daySections(for: items, timeZone: Self.zurich)

        #expect(months.map(\.key) == ["2026-10", "2026-09"])
        #expect(
            months.map { $0.days.map(\.key) } == [["2026-10-01"], ["2026-09-30", "2026-09-27"]])
        let days = months.flatMap(\.days)
        #expect(
            days.map { $0.pictures.map(\.id) } == [
                ["o1", "o2", "o3"], ["s1"], ["s2", "s3", "s4", "s5"],
            ])
        // The day index runs on across the month boundary: 0, 1, 2.
        #expect(days.map(\.dayIndex) == [0, 1, 2])
        // Day 0 of three opens on A; day 1 of one is wide only; day 2 of four opens on C (its
        // step) and leaves a single wide frame.
        #expect(days.map { $0.pictures.map(\.slot) } == [Self.a, [.wide], Self.c + [.wide]])
        #expect(days.map(\.weekday) == ["Thu", "Wed", "Sun"])
        #expect(days.map(\.date) == ["1 Oct", "30 Sep", "27 Sep"])
        // Every picture keeps its index in the WHOLE list.
        #expect(days.flatMap(\.pictures).map(\.index) == Array(0..<8))
        #expect(days[2].headingID == "day:2026-09-27")
        // The lazy stack's rows: each heading, then one row per band, each its own identity.
        #expect(
            months.map { $0.rows.map(\.id) } == [
                ["day:2026-10-01", "o1"], ["day:2026-09-30", "s1", "day:2026-09-27", "s2", "s5"],
            ])
    }

    @Test("a day of two pictures gets two wide frames, one of them each")
    func twoPicturesAreWide() throws {
        let items = try [
            Self.row("x", "2026-09-14T10:00:00Z"), Self.row("y", "2026-09-14T11:00:00Z"),
        ]
        let day = try #require(
            MediaLibraryPresentation.daySections(for: items, timeZone: Self.zurich).first?.days
                .first)
        #expect(day.pictures.map(\.slot) == [.wide, .wide])
        #expect(day.bands.count == 2, "a wide frame is a band alone")
    }

    /// The design's one calendar (`docs/design/photos-library-mockup.md`: "Day and month
    /// boundaries are computed in Europe/Zurich"): a device in New York must not move 23:30Z on 30
    /// September out of 1 October, in the grid's days or in the zone the buckets are counted in.
    @Test("days and bucket reads are cut in Zurich whatever zone the device is in")
    func zurichWhateverTheDevice() throws {
        // The system zone is read from TZ before anything else; `NSTimeZone.default` does not move
        // `TimeZone.current`.
        let device = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", "America/New_York", 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let device { setenv("TZ", device, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        #expect(
            TimeZone.current.identifier == "America/New_York", "control: the device zone stayed")

        let late = try Self.row("late", "2026-09-30T23:30:00Z")
        let months = MediaLibraryPresentation.daySections(for: [late])
        #expect(months.map(\.key) == ["2026-10"], "the device's zone cut the month")
        #expect(
            months.flatMap(\.days).map(\.key) == ["2026-10-01"], "the device's zone cut the day")
        #expect(
            LibraryBucketStore().timeZoneIdentifier == libraryTimeZone,
            "the buckets would be counted in the device's zone")
        #expect(libraryTimeZone == "Europe/Zurich")
    }

    @Test("the bands of a block are read as the geometry reads them")
    func bands() {
        let bands = MediaLibraryPresentation.mosaicBands
        #expect(bands([]) == [])
        #expect(
            bands(Self.a + Self.b + Self.c + Self.b + [.wide]) == [
                0..<3, 3..<6, 6..<9, 9..<12, 12..<13,
            ])
        #expect(bands(Self.a + [.square, .square]) == [0..<3, 3..<5])
        #expect(bands([.wide, .square, .square]) == [0..<1, 1..<3])
        // A hero takes at most two sides of its own; a square row at most three.
        #expect(bands([.heroLeft, .sideRight, .sideRight, .sideRight]) == [0..<3, 3..<4])
        #expect(bands(Array(repeating: .square, count: 4)) == [0..<3, 3..<4])
        #expect(bands([.heroRight, .square]) == [0..<1, 1..<2], "a hero does not take a square")
    }

    /// A trip's grid (MEMNG-740): the list as ONE block, in the order it was handed over, with no
    /// heading row at all, its frames one cycle across the days, and every picture keeping its
    /// index in the whole list.
    @Test("a flat grid is one block of bands with no heading, its frames one cycle across days")
    func flatIsOneBlock() throws {
        let items = try [
            Self.row("a1", "2026-03-12T09:00:00Z"),
            Self.row("a2", "2026-03-12T10:00:00Z"),
            Self.row("b1", "2026-03-14T09:00:00Z"),
            Self.row("c1", "2026-03-16T09:00:00Z"),
            Self.row("c2", "2026-03-16T10:00:00Z"),
        ]
        let rows = MediaLibraryPresentation.flatRows(for: items, timeZone: Self.zurich)
        let bands = rows.compactMap { row -> (LibraryDayBand, LibraryBandPlace)? in
            if case .band(let band, let place) = row { return (band, place) }
            return nil
        }
        #expect(bands.count == rows.count, "a flat grid drew a heading: \(rows.map(\.id))")
        // Five pictures over three days: A, then two squares — one cycle, not a block a day.
        #expect(bands.flatMap { $0.0.pictures.map(\.slot) } == Self.a + [.square, .square])
        #expect(bands.map { $0.0.pictures.map(\.id) } == [["a1", "a2", "b1"], ["c1", "c2"]])
        #expect(bands.flatMap { $0.0.pictures.map(\.index) } == Array(0..<5))
        // One block: rounded at its top and at its foot alone.
        #expect(bands.map { $0.1.first } == [true, false])
        #expect(bands.map { $0.1.last } == [false, true])
        // Each band names the day its first picture was taken on, for the date pill alone.
        #expect(bands.map { $0.1.day } == ["2026-03-12", "2026-03-16"])
    }

    @Test("a flat grid of one picture is one wide band, and of none is no row")
    func flatEdges() throws {
        let one = try Self.row("a1", "2026-03-12T09:00:00Z")
        let picture = LibraryDayPicture(attachment: one.attachment, index: 0, slot: .wide)
        let place = LibraryBandPlace(day: "2026-03-12", dayIndex: 0, first: true, last: true)
        #expect(
            MediaLibraryPresentation.flatRows(for: [one], timeZone: Self.zurich)
                == [.band(LibraryDayBand(pictures: [picture]), place)])
        #expect(MediaLibraryPresentation.flatRows(for: [], timeZone: Self.zurich).isEmpty)
    }

    @Test("a heading counts the whole day's bucket, and nothing while the buckets are unread")
    func dayCount() {
        let buckets = [
            LibraryBucket(key: "2026-09-14", count: 12, coverUID: "c", coverThumbnailURL: nil)
        ]
        #expect(MediaLibraryPresentation.dayCount("2026-09-14", in: buckets) == 12)
        #expect(MediaLibraryPresentation.dayCount("2026-09-13", in: buckets) == nil)
        #expect(MediaLibraryPresentation.dayCount("2026-09-14", in: nil) == nil)
        #expect(MediaLibraryPresentation.dayCount(undatedSectionKey, in: buckets) == nil)
    }

    @Test(
        "the pill shows on a scroll past a heading, hides at the top, and fades only on its own serial"
    )
    func pillModel() {
        let pill = DatePillModel()
        pill.scrolled(to: nil)
        #expect(!pill.shown, "a scroll at the top of the page shows no pill")
        pill.scrolled(to: "2026-09-27")
        #expect(pill.shown && pill.day == "2026-09-27")
        let stale = pill.serial
        pill.scrolled(to: "2026-09-26")
        pill.fade(after: stale)
        #expect(pill.shown, "a fade from before the last scroll hid the pill")
        pill.fade(after: pill.serial)
        #expect(!pill.shown)
        #expect(pill.day == "2026-09-26")
    }

    @Test(
        "the pill's tap opens Months at that month across every year, and a hand choice clears it")
    func showMonthChoice() {
        let choice = LibraryScopeChoice()
        var abandoned = 0
        choice.whenChosenByHand { abandoned += 1 }
        choice.showMonths(of: "2025")
        choice.choose(.all)
        abandoned = 0
        choice.showMonth("2026-09")
        #expect(choice.scope == .months)
        #expect(choice.year == nil, "the pill's month hidden behind a year filter")
        #expect(choice.monthTarget == "2026-09")
        #expect(abandoned == 1, "leaving All by the pill did not abandon a jump still reading")
        choice.choose(.years)
        #expect(choice.monthTarget == nil, "a later choice kept the pill's month")
        choice.showMonth("2026-08")
        choice.consumeMonthTarget()
        #expect(choice.monthTarget == nil)
        // Asked while a year still narrows Months, the pill's month is still shown across every
        // year: the narrowing is the choice's to drop, not its caller's.
        choice.showMonths(of: "2025")
        choice.showMonth("2026-08")
        #expect(choice.year == nil, "the pill's month hidden behind a year filter left in place")
        #expect(choice.monthTarget == "2026-08")
    }
}
