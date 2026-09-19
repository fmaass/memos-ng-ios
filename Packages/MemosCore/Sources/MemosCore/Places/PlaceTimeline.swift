import Foundation

/// One calendar month in the timeline's zone.
nonisolated public struct PlaceBucket: Sendable, Equatable, Identifiable {
    /// `YYYY-MM` in the zone — sortable, and a month's identity in the histogram.
    public var key: String
    public var year: Int
    /// 1…12.
    public var month: Int
    /// Inclusive instant the month starts at, in the zone.
    public var start: Date
    /// Exclusive instant the next month starts at — the two are 743 h or 745 h apart around a
    /// daylight-saving change, which is the whole reason a month is not 30 days here.
    public var end: Date
    public var count: Int

    public var id: String { key }
}

nonisolated public struct PlaceHistogram: Sendable, Equatable {
    public var zone: TimeZone
    /// Contiguous months from the earliest to the latest marker; empty months included, because
    /// the bar draws time proportionally and a gap silently closed up would misplace every year
    /// tick after it.
    public var buckets: [PlaceBucket]
    public var total: Int
    public var maxCount: Int
}

/// How many buckets one step of playback covers.
nonisolated public enum PlaybackSpeed: Int, Sendable, CaseIterable {
    case single = 1
    case double = 2
    case quadruple = 4
}

/// Everything seen so far, or a trailing year.
nonisolated public enum TimelineMode: String, Sendable, CaseIterable {
    case accumulate
    case window12
}

nonisolated public struct TimelineState: Sendable, Equatable {
    /// Index into the histogram's buckets; 0 when there are none.
    public var index: Int
    public var playing: Bool
    public var speed: PlaybackSpeed
    public var mode: TimelineMode
    public var bucketCount: Int
}

nonisolated public enum TimelineAction: Sendable, Equatable {
    case play
    case pause
    case tick
    case seek(index: Int)
    case setSpeed(PlaybackSpeed)
    case setMode(TimelineMode)
}

/// The markers the playhead exposes, plus the ones that arrived in this step.
nonisolated public struct PlayheadView: Sendable, Equatable {
    /// The visible markers, in the order they were given — the caller keeps its own sort.
    public var markers: [PlaceMarker]
    /// Uids visible now that were not visible in the previous state; empty without one.
    public var landing: [String]
}

/// A year's label on the bar, and the buckets it covers so it can be drawn to width.
nonisolated public struct YearTick: Sendable, Equatable {
    public var year: Int
    /// First bucket index of the year — a tick's position is proportional to it.
    public var startIndex: Int
    public var span: Int

    public init(year: Int, startIndex: Int, span: Int) {
        self.year = year
        self.startIndex = startIndex
        self.span = span
    }
}

/// The Places timeline: bucketing and playback as pure functions, ported from the SPA's
/// `frontend/src/lib/places/timeline.ts`.
///
/// Two ideas carry it. A bucket is a CALENDAR MONTH in the household's zone, not a UTC month and
/// not a fixed 30 days — a photo taken at half past midnight on 1 January belongs to January even
/// though UTC still says December. And the reducer is the whole playback contract: nothing here
/// reads a clock or schedules anything, so "reaching the end pauses" is a rule of the reducer and
/// cannot be forgotten by whichever view happens to own the timer.
nonisolated public enum PlaceTimeline {
    /// Buckets and labels are the household's calendar, fixed — not the device's zone (ADR-0007).
    /// Force-unwrapped because the identifier is a name in the system's own zone database: if it
    /// resolved to nothing every bucket would silently be a UTC one.
    public static let zone = TimeZone(identifier: "Europe/Zurich")!

    /// The second mode shows a trailing year rather than everything seen so far.
    public static let windowMonths = 12

    private static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private static func monthKey(of date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return key(year: parts.year ?? 0, month: parts.month ?? 1)
    }

    private static func key(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    /// The instant a month begins at in the zone. Force-unwrapped because the first of a month at
    /// midnight exists in every zone this app is used in: a daylight-saving shift moves a clock
    /// at 02:00 or 03:00 on a Sunday, never at midnight on the first.
    private static func monthStart(year: Int, month: Int, _ calendar: Calendar) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: 1, hour: 0, minute: 0, second: 0)
        )!
    }

    private static func nextMonth(year: Int, month: Int) -> (Int, Int) {
        month == 12 ? (year + 1, 1) : (year, month + 1)
    }

    /// Per-month counts over the markers, as one contiguous run of calendar months.
    public static func buildHistogram(
        _ markers: [PlaceMarker],
        zone: TimeZone = zone
    ) -> PlaceHistogram {
        let calendar = calendar(in: zone)
        var counts: [String: Int] = [:]
        for marker in markers {
            counts[monthKey(of: marker.takenAt, calendar), default: 0] += 1
        }
        let keys = counts.keys.sorted()
        guard let first = keys.first, let last = keys.last else {
            return PlaceHistogram(zone: zone, buckets: [], total: 0, maxCount: 0)
        }

        let opening = first.split(separator: "-").compactMap { Int($0) }
        var year = opening.first ?? 0
        var month = opening.count > 1 ? opening[1] : 1
        var start = monthStart(year: year, month: month, calendar)
        var buckets: [PlaceBucket] = []
        while true {
            let bucketKey = key(year: year, month: month)
            let (nextYear, nextMonthNumber) = nextMonth(year: year, month: month)
            let end = monthStart(year: nextYear, month: nextMonthNumber, calendar)
            buckets.append(
                PlaceBucket(
                    key: bucketKey,
                    year: year,
                    month: month,
                    start: start,
                    end: end,
                    count: counts[bucketKey] ?? 0
                )
            )
            if bucketKey == last { break }
            year = nextYear
            month = nextMonthNumber
            start = end
        }
        return PlaceHistogram(
            zone: zone,
            buckets: buckets,
            total: buckets.reduce(0) { $0 + $1.count },
            maxCount: buckets.reduce(0) { max($0, $1.count) }
        )
    }

    /// The bar's label for a bucket, read in the zone the bucket was cut in. The locale is fixed
    /// for the same reason the zone is: the label names a month of the household's calendar, and
    /// a device set to another region would otherwise disagree with the web about what it is.
    public static func bucketLabel(_ bucket: PlaceBucket, zone: TimeZone = zone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: bucket.start)
    }

    /// The year ticks the bar draws, each with the bucket span it covers.
    public static func yearTicks(_ buckets: [PlaceBucket]) -> [YearTick] {
        var ticks: [YearTick] = []
        for (index, bucket) in buckets.enumerated() {
            if let open = ticks.last, open.year == bucket.year {
                ticks[ticks.count - 1].span += 1
            } else {
                ticks.append(YearTick(year: bucket.year, startIndex: index, span: 1))
            }
        }
        return ticks
    }

    /// The single control's cycle: one tap moves 1x -> 2x -> 4x -> 1x.
    public static func nextSpeed(_ speed: PlaybackSpeed) -> PlaybackSpeed {
        let speeds = PlaybackSpeed.allCases
        let index = speeds.firstIndex(of: speed) ?? 0
        return speeds[(index + 1) % speeds.count]
    }

    /// Paused at the newest bucket — the map opens showing every pin, not an empty world.
    public static func initialState(_ histogram: PlaceHistogram) -> TimelineState {
        TimelineState(
            index: max(histogram.buckets.count - 1, 0),
            playing: false,
            speed: .single,
            mode: .accumulate,
            bucketCount: histogram.buckets.count
        )
    }

    private static func clampIndex(_ index: Int, bucketCount: Int) -> Int {
        min(max(index, 0), max(bucketCount - 1, 0))
    }

    /// The playback contract. Nothing here schedules anything: a tick is one step the caller
    /// drives, so the speed is "how many buckets a step covers", and the end of the range pauses
    /// HERE rather than in whichever view happens to own the timer.
    public static func reduce(_ state: TimelineState, _ action: TimelineAction) -> TimelineState {
        let last = state.bucketCount - 1
        var next = state
        switch action {
        case .play:
            guard last >= 0 else { return state }
            // Pressing play with the playhead parked at the newest bucket (the default) means
            // "replay", not "advance nowhere".
            next.playing = true
            next.index = state.index >= last ? 0 : state.index
        case .pause:
            guard state.playing else { return state }
            next.playing = false
        case .tick:
            guard state.playing else { return state }
            guard last >= 0 else {
                next.playing = false
                return next
            }
            let stepped = state.index + state.speed.rawValue
            if stepped >= last {
                next.index = last
                next.playing = false
            } else {
                next.index = stepped
            }
        case .seek(let index):
            next.index = clampIndex(index, bucketCount: state.bucketCount)
        case .setSpeed(let speed):
            next.speed = speed
        case .setMode(let mode):
            // A mode switch re-reads the same instant in time: the playhead does not move.
            next.mode = mode
        }
        return next
    }

    private static func isVisible(bucketIndex: Int?, in state: TimelineState) -> Bool {
        // A marker the given histogram cannot place is hidden nowhere: a caller that passes a
        // histogram built from another set must not silently lose photos because of it.
        guard let bucketIndex else { return true }
        if state.mode == .window12 {
            return bucketIndex <= state.index && bucketIndex > state.index - windowMonths
        }
        return bucketIndex <= state.index
    }

    /// The markers the playhead exposes, plus the ones that arrived in this step.
    ///
    /// A caller that already built the bar's histogram passes it rather than rebuilding it per
    /// tick; omitted, the buckets are derived from the same markers, so the answer is the same
    /// either way. Without a previous state nothing is "new", which is what a first render wants
    /// — no landing animation on every pin at once.
    public static func applyPlayhead(
        _ markers: [PlaceMarker],
        state: TimelineState,
        previous: TimelineState? = nil,
        histogram: PlaceHistogram? = nil
    ) -> PlayheadView {
        let histogram = histogram ?? buildHistogram(markers)
        let calendar = calendar(in: histogram.zone)
        var indexByKey: [String: Int] = [:]
        for (index, bucket) in histogram.buckets.enumerated() { indexByKey[bucket.key] = index }

        var visible: [PlaceMarker] = []
        var landing: [String] = []
        for marker in markers {
            let bucketIndex = indexByKey[monthKey(of: marker.takenAt, calendar)]
            guard isVisible(bucketIndex: bucketIndex, in: state) else { continue }
            visible.append(marker)
            if let previous, let bucketIndex,
                !isVisible(bucketIndex: bucketIndex, in: previous)
            {
                landing.append(marker.uid)
            }
        }
        return PlayheadView(markers: visible, landing: landing)
    }
}
