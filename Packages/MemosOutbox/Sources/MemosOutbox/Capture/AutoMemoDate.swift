import Foundation

/// The memo's Auto date, and what the chip says about it.
public struct AutoMemoDateResult: Sendable, Equatable {
    /// The earliest eligible capture instant, or nil when nothing eligible is attached.
    public var instant: Date?
    /// The winner was a civil time this device resolved — the chip marks it "≈".
    public var approximate: Bool
    /// The inclusive calendar-day count when the earliest and the latest eligible instants fall on
    /// different days in the display zone; 0 when they fall on one.
    public var span: Int

    public init(instant: Date? = nil, approximate: Bool = false, span: Int = 0) {
        self.instant = instant
        self.approximate = approximate
        self.span = span
    }

    /// Nothing eligible was attached. It is deliberately NOT called `none`: in a context that
    /// takes an optional, `.none` is `Optional.none` and the compiler picks that one silently —
    /// which is a nil where a value was meant, and it reads exactly like the value it is not.
    public static let undated = AutoMemoDateResult()
}

/// The Auto memo date and the capture order — pure, and held to the ONE normative artefact
/// `auto-memo-date.json`, which the server's pytest suite and the SPA's vitest suite read as well.
///
/// Two ideas carry the whole thing:
///
///  * an EXACT instant (EXIF with an offset, a QuickTime creationdate) and an APPROXIMATE one
///    (EXIF without an offset, resolved here in the device's zone) compete on equal terms — on
///    their resolved epoch seconds. The only trace of the difference is the "≈" the composer shows
///    when the winner was a resolved civil time;
///  * an item whose capture decision has not SETTLED contributes nothing, and neither does one the
///    file had no date for. Both sort after the dated items, in pick order.
///
/// Nothing here averages anything, and nothing invents a fallback: with no eligible instant the
/// answer is nil and the composer sends no `created_at` at all.
public enum AutoMemoDate {
    /// One item's eligible instant, and whether it had to be resolved to get one.
    public struct Settled: Sendable, Equatable {
        public var instant: Date?
        public var approximate: Bool

        public init(instant: Date? = nil, approximate: Bool = false) {
            self.instant = instant
            self.approximate = approximate
        }
    }

    /// Whole seconds everywhere, on both wires and in every comparison. Floored towards the past,
    /// so a pre-1970 instant floors the way a later one does rather than away from it.
    public static func flooredToSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// The instant a wall-clock reading names in `zone`, or nil when it names none.
    ///
    /// Guess, then VERIFY. The zone's offset is read on both sides of the target as well as at it —
    /// around a DST transition the two sides disagree, and it is that disagreement that produces
    /// the two candidates an overlap has, which a single probe would converge on one of and
    /// silently drop the earlier. Every candidate is then formatted back: a candidate that does not
    /// read back as the civil time asked for is not that civil time. What survives decides the two
    /// edges the rules name — a spring-forward GAP leaves no candidate (nil, and the item counts as
    /// undated), and an autumn OVERLAP leaves two, of which the EARLIER wins.
    public static func resolveCivil(_ civil: String, in zone: TimeZone) -> Date? {
        guard let wall = CivilTime(civil) else { return nil }
        let target = wall.pseudoUTC
        let day: TimeInterval = 86_400
        var candidates: [Date] = []
        for probe in [target.addingTimeInterval(-day), target, target.addingTimeInterval(day)] {
            let offset = TimeInterval(zone.secondsFromGMT(for: probe))
            let guess = target.addingTimeInterval(-offset)
            guard CivilTime(reading: guess, in: zone).pseudoUTC == target else { continue }
            if !candidates.contains(guess) { candidates.append(guess) }
        }
        guard let earliest = candidates.min() else { return nil }
        return flooredToSecond(earliest)
    }

    /// The zone's calendar day of an instant, as days since the epoch — comparable, not displayable.
    private static func calendarDay(of date: Date, in zone: TimeZone) -> Int {
        let wall = CivilTime(reading: date, in: zone)
        return Int(
            (wall.pseudoUTCDay.timeIntervalSince1970 / 86_400).rounded(.down)
        )
    }

    /// The inclusive calendar-day count the instants cover in `zone` — 0 when they all fall on one
    /// day.
    ///
    /// There is no threshold: two instants twenty minutes apart across midnight span two days, and
    /// two nine hours apart on one afternoon span none. The hint is about the CALENDAR, not the
    /// duration.
    public static func spanDays(_ instants: [Date], in zone: TimeZone) -> Int {
        guard instants.count > 1 else { return 0 }
        let days = instants.map { calendarDay(of: $0, in: zone) }
        guard let first = days.min(), let last = days.max(), last != first else { return 0 }
        return last - first + 1
    }

    /// One item's eligible instant, or nothing.
    ///
    /// A `pending` item has no decision yet and so has no instant — which is what makes "settle
    /// before posting" the only way the date can be right.
    public static func settled(_ decision: CaptureDecision, in zone: TimeZone) -> Settled {
        guard let reading = decision.reading else { return Settled() }
        if let exact = reading.instant {
            return Settled(instant: flooredToSecond(exact), approximate: false)
        }
        if let civil = reading.civil, let resolved = resolveCivil(civil, in: zone) {
            return Settled(instant: resolved, approximate: true)
        }
        return Settled()
    }

    /// The memo's Auto date: the EARLIEST eligible capture instant among what is attached, with the
    /// span hint and the approximation flag the chip reads.
    ///
    /// A tie is decided by pick order — the first item that reaches the minimum keeps it — so the
    /// answer does not depend on the comparison's direction.
    public static func autoMemoDate(_ decisions: [CaptureDecision], in zone: TimeZone)
        -> AutoMemoDateResult
    {
        var eligible: [Settled] = []
        for decision in decisions {
            let one = settled(decision, in: zone)
            if one.instant != nil { eligible.append(one) }
        }
        guard var winner = eligible.first else { return .undated }
        for candidate in eligible.dropFirst() where candidate.instant! < winner.instant! {
            winner = candidate
        }
        return AutoMemoDateResult(
            instant: winner.instant,
            approximate: winner.approximate,
            span: spanDays(eligible.compactMap(\.instant), in: zone)
        )
    }

    /// The same answer for anything that carries a capture decision, each item resolved in the zone
    /// it was picked in (`CaptureCarrying.captureZone`) rather than in the zone of the moment.
    public static func autoMemoDate<Item: CaptureCarrying>(_ items: [Item], in zone: TimeZone)
        -> AutoMemoDateResult
    {
        var eligible: [Settled] = []
        for item in items {
            let one = settled(item.capture, in: item.captureZone ?? zone)
            if one.instant != nil { eligible.append(one) }
        }
        guard var winner = eligible.first else { return .undated }
        for candidate in eligible.dropFirst() where candidate.instant! < winner.instant! {
            winner = candidate
        }
        return AutoMemoDateResult(
            instant: winner.instant,
            approximate: winner.approximate,
            span: spanDays(eligible.compactMap(\.instant), in: zone)
        )
    }

    /// The items in CAPTURE ORDER: everything with a settled eligible instant first, ascending by
    /// resolved epoch seconds; everything without one after it, in pick order; ties in pick order.
    ///
    /// This is what the composer shows AND what it sends — the outbox manifest's file array reaches
    /// the wire in array order, and the server persists that as each attachment's `position`, so a
    /// memo reads back the way it looked while it was being written.
    public static func captureOrder<Item: CaptureCarrying>(_ items: [Item], in zone: TimeZone)
        -> [Item]
    {
        var dated: [(item: Item, at: Date, pick: Int)] = []
        var undated: [Item] = []
        for (pick, item) in items.enumerated() {
            if let instant = settled(item.capture, in: item.captureZone ?? zone).instant {
                dated.append((item, instant, pick))
            } else {
                undated.append(item)
            }
        }
        // Sorted on the pair, not on the instant alone: `sort(by:)` is not documented to be
        // stable, so ties would otherwise land in whatever order the algorithm happened to leave
        // them in and the tile row would shuffle on a redraw.
        dated.sort { left, right in
            left.at == right.at ? left.pick < right.pick : left.at < right.at
        }
        return dated.map(\.item) + undated
    }
}

/// A wall-clock reading with no zone attached — the civil times EXIF carries, and the arithmetic
/// that turns them into instants.
///
/// It is deliberately NOT `DateComponents` + `Calendar`: a calendar asked for the date of a civil
/// time in a DST gap answers with the instant AFTER the gap rather than refusing, and a calendar
/// asked for one in an overlap picks an occurrence of its own choosing. Both of those are the two
/// cases the rules actually legislate.
struct CivilTime: Equatable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int

    /// `YYYY-MM-DDTHH:MM[:SS]`, with a space accepted for the T. Nothing else parses.
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = Array(trimmed.utf8)
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard index < digits.count, digits[index] >= 48, digits[index] <= 57 else {
                    return nil
                }
                value = value * 10 + Int(digits[index] - 48)
            }
            return value
        }
        func separator(_ index: Int, _ allowed: [UInt8]) -> Bool {
            index < digits.count && allowed.contains(digits[index])
        }
        guard digits.count == 16 || digits.count == 19,
            let year = number(0..<4), separator(4, [45]),
            let month = number(5..<7), separator(7, [45]),
            let day = number(8..<10), separator(10, [84, 32]),
            let hour = number(11..<13), separator(13, [58]),
            let minute = number(14..<16)
        else { return nil }
        var second = 0
        if digits.count == 19 {
            guard separator(16, [58]), let parsed = number(17..<19) else { return nil }
            second = parsed
        }
        guard month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60
        else { return nil }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        // A day that does not exist is not a date. `Calendar` NORMALISES rather than refusing —
        // 31 February comes back as 3 March — so a reading that was never a moment would otherwise
        // resolve to a real instant on a day nobody photographed anything.
        guard isRealDate else { return nil }
    }

    init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// What `zone` reads on its clock at `instant`.
    init(reading instant: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: instant)
        self.init(
            year: parts.year ?? 0,
            month: parts.month ?? 0,
            day: parts.day ?? 0,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            second: parts.second ?? 0
        )
    }

    /// The reading taken as though it were UTC. It is not an instant anybody should show; it is the
    /// comparable number that "the same clock reading" means.
    var pseudoUTC: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// The same, with the time of day dropped — the calendar DAY as a comparable number.
    var pseudoUTCDay: Date {
        CivilTime(year: year, month: month, day: day, hour: 0, minute: 0, second: 0).pseudoUTC
    }

    /// Whether these components name a day the calendar actually has.
    ///
    /// Asked by ROUND TRIP rather than by counting days in a month: the components are turned into
    /// an instant in UTC and read back, and anything the calendar had to move to make it work comes
    /// back different.
    var isRealDate: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return back.year == year && back.month == month && back.day == day && back.hour == hour
            && back.minute == minute && back.second == second
    }

    /// `YYYY-MM-DDTHH:MM:SS`, the shape the artefact writes a civil time in.
    var text: String {
        String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
    }
}
