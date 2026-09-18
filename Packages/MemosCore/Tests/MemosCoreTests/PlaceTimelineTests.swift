import Foundation
import MemosCore
import Testing

// The vectors are the SPA's own: frontend/src/lib/places/timeline.spec.ts (memos-ng a29c2e1),
// copied instant for instant. The bucket a photo falls in is the household's calendar month, so a
// disagreement between the two clients would show the same photo in a different month.
//
// Two groups of its cases are deliberately not carried. The "undated" ones assert what the SPA
// does with a `taken_at` it cannot parse, which cannot reach `PlaceMarker`: the contract makes
// that field required, non-nullable and a date-time, so an unparsable one fails the decode long
// before a bucket is chosen. And its keyboard cases belong to a desktop bar with arrow keys.

/// Four markers spanning 2025-01 … 2026-03 — fifteen contiguous month buckets, indices 0…14.
private let placeSpan: [PlaceMarker] = [
    placeMarker(uid: "a", takenAt: "2025-01-15T12:00:00Z"),  // bucket 0  (2025-01)
    placeMarker(uid: "b", takenAt: "2025-06-15T12:00:00Z"),  // bucket 5  (2025-06)
    placeMarker(uid: "c", takenAt: "2026-01-15T12:00:00Z"),  // bucket 12 (2026-01)
    placeMarker(uid: "d", takenAt: "2026-03-15T12:00:00Z"),  // bucket 14 (2026-03)
]
private let placeSpanHistogram = PlaceTimeline.buildHistogram(placeSpan)

@Suite("PlaceTimeline")
struct PlaceTimelineTests {
    private func stateAt(
        _ index: Int,
        playing: Bool = false,
        speed: PlaybackSpeed = .single,
        mode: TimelineMode = .accumulate
    ) -> TimelineState {
        var state = PlaceTimeline.initialState(placeSpanHistogram)
        state.index = index
        state.playing = playing
        state.speed = speed
        state.mode = mode
        return state
    }

    @Test("buckets by the Zurich calendar month, not the UTC one, across a year boundary")
    func zurichYearBoundary() {
        // 22:30Z on 31 December is still 23:30 in Zurich (CET, UTC+1); 23:30Z is already 00:30 on
        // 1 January there — the year boundary the household sees, not the one UTC sees.
        let histogram = PlaceTimeline.buildHistogram([
            placeMarker(uid: "old-year", takenAt: "2025-12-31T22:30:00Z"),
            placeMarker(uid: "new-year", takenAt: "2025-12-31T23:30:00Z"),
        ])

        #expect(histogram.buckets.map(\.key) == ["2025-12", "2026-01"])
        #expect(histogram.buckets.map(\.count) == [1, 1])
        #expect(histogram.buckets[1].start == placeDate("2025-12-31T23:00:00Z"))
    }

    @Test("places a marker by Zurich wall time across the spring change")
    func springChange() {
        // 2026-03-29 is the spring-forward Sunday: from then on Zurich is UTC+2, so 22:30Z on
        // 31 March is already 00:30 on 1 April locally.
        let histogram = PlaceTimeline.buildHistogram([
            placeMarker(uid: "march", takenAt: "2026-03-31T21:30:00Z"),
            placeMarker(uid: "april", takenAt: "2026-03-31T22:30:00Z"),
        ])

        #expect(histogram.buckets.map(\.key) == ["2026-03", "2026-04"])
        #expect(histogram.buckets.map(\.count) == [1, 1])
    }

    @Test("places a marker by Zurich wall time across the autumn change")
    func autumnChange() {
        // 2026-10-25 is the fall-back Sunday: Zurich is UTC+1 again, so 23:30Z on 31 October is
        // 00:30 on 1 November locally.
        let histogram = PlaceTimeline.buildHistogram([
            placeMarker(uid: "october", takenAt: "2026-10-31T22:30:00Z"),
            placeMarker(uid: "november", takenAt: "2026-10-31T23:30:00Z"),
        ])

        #expect(histogram.buckets.map(\.key) == ["2026-10", "2026-11"])
        #expect(histogram.buckets.map(\.count) == [1, 1])
    }

    @Test("gives each bucket the Zurich month edges, so the two changed months are 743 h and 745 h")
    func daylightSavingMonthLengths() throws {
        let histogram = PlaceTimeline.buildHistogram([
            placeMarker(uid: "spring", takenAt: "2026-03-15T12:00:00Z"),
            placeMarker(uid: "autumn", takenAt: "2026-10-15T12:00:00Z"),
        ])
        let march = try #require(histogram.buckets.first { $0.key == "2026-03" })
        let october = try #require(histogram.buckets.first { $0.key == "2026-10" })

        // 2026-03-01T00:00 CET = 2026-02-28T23:00Z; 2026-04-01T00:00 CEST = 2026-03-31T22:00Z.
        #expect(march.start == placeDate("2026-02-28T23:00:00Z"))
        #expect(march.end == placeDate("2026-03-31T22:00:00Z"))
        #expect(march.end.timeIntervalSince(march.start) / 3600 == 743)
        // 2026-10-01T00:00 CEST = 2026-09-30T22:00Z; 2026-11-01T00:00 CET = 2026-10-31T23:00Z.
        #expect(october.start == placeDate("2026-09-30T22:00:00Z"))
        #expect(october.end == placeDate("2026-10-31T23:00:00Z"))
        #expect(october.end.timeIntervalSince(october.start) / 3600 == 745)
    }

    @Test("counts every marker into contiguous months, empty months included")
    func contiguousMonths() {
        #expect(placeSpanHistogram.buckets.count == 15)
        #expect(placeSpanHistogram.buckets[0].key == "2025-01")
        #expect(placeSpanHistogram.buckets[14].key == "2026-03")
        let counts = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1]
        #expect(placeSpanHistogram.buckets.map(\.count) == counts)
        #expect(placeSpanHistogram.total == 4)
        #expect(placeSpanHistogram.maxCount == 1)
        #expect(placeSpanHistogram.zone == PlaceTimeline.zone)
    }

    @Test("sums repeated months and reports the tallest bar")
    func repeatedMonths() {
        let histogram = PlaceTimeline.buildHistogram([
            placeMarker(uid: "x", takenAt: "2025-07-01T09:00:00Z"),
            placeMarker(uid: "y", takenAt: "2025-07-20T09:00:00Z"),
            placeMarker(uid: "z", takenAt: "2025-08-02T09:00:00Z"),
        ])

        #expect(histogram.buckets.map(\.count) == [2, 1])
        #expect(histogram.maxCount == 2)
    }

    @Test("has no buckets for an empty marker set")
    func emptySet() {
        let histogram = PlaceTimeline.buildHistogram([])

        #expect(histogram.buckets.isEmpty)
        #expect(histogram.total == 0)
        #expect(histogram.maxCount == 0)
    }

    @Test("labels a bucket by its Zurich month")
    func labels() {
        #expect(PlaceTimeline.bucketLabel(placeSpanHistogram.buckets[0]) == "Jan 2025")
        #expect(PlaceTimeline.bucketLabel(placeSpanHistogram.buckets[14]) == "Mar 2026")
    }

    @Test("groups the buckets into proportional year ticks")
    func ticks() {
        #expect(
            PlaceTimeline.yearTicks(placeSpanHistogram.buckets) == [
                YearTick(year: 2025, startIndex: 0, span: 12),
                YearTick(year: 2026, startIndex: 12, span: 3),
            ]
        )
    }

    @Test("starts paused at the last bucket, 1x, accumulating")
    func initialState() {
        let state = PlaceTimeline.initialState(placeSpanHistogram)

        #expect(state.index == 14)
        #expect(!state.playing)
        #expect(state.speed == .single)
        #expect(state.mode == .accumulate)
        #expect(state.bucketCount == 15)
    }

    @Test("plays from where it stands, and restarts when the playhead is already at the end")
    func play() {
        let resumed = PlaceTimeline.reduce(stateAt(3), .play)
        let replayed = PlaceTimeline.reduce(stateAt(14), .play)

        #expect(resumed.index == 3)
        #expect(resumed.playing)
        #expect(replayed.index == 0)
        #expect(replayed.playing)
    }

    @Test("pauses without moving the playhead")
    func pause() {
        let paused = PlaceTimeline.reduce(stateAt(7, playing: true), .pause)

        #expect(paused.index == 7)
        #expect(!paused.playing)
    }

    @Test("advances one bucket per tick at 1x and speed buckets per tick at 2x and 4x")
    func tickSpeeds() {
        #expect(PlaceTimeline.reduce(stateAt(0, playing: true), .tick).index == 1)
        #expect(PlaceTimeline.reduce(stateAt(0, playing: true, speed: .double), .tick).index == 2)
        let quick = PlaceTimeline.reduce(stateAt(0, playing: true, speed: .quadruple), .tick)
        #expect(quick.index == 4)
    }

    @Test("ignores a tick while paused")
    func tickWhilePaused() {
        let paused = stateAt(3)

        #expect(PlaceTimeline.reduce(paused, .tick) == paused)
    }

    @Test("pauses at the last bucket instead of running past it")
    func tickStopsAtTheEnd() {
        let state = PlaceTimeline.reduce(stateAt(13, playing: true, speed: .quadruple), .tick)

        #expect(state.index == 14)
        #expect(!state.playing)
        #expect(PlaceTimeline.reduce(state, .tick) == state)
    }

    @Test("clamps a seek to the bucket range and keeps everything else")
    func seek() {
        #expect(PlaceTimeline.reduce(stateAt(5), .seek(index: -4)).index == 0)
        #expect(PlaceTimeline.reduce(stateAt(5), .seek(index: 99)).index == 14)

        let sought = PlaceTimeline.reduce(
            stateAt(5, playing: true, speed: .double),
            .seek(index: 9)
        )

        #expect(sought.index == 9)
        #expect(sought.playing)
        #expect(sought.speed == .double)
        #expect(sought.mode == .accumulate)
        #expect(sought.bucketCount == 15)
    }

    @Test("keeps the playhead when the speed or the mode changes")
    func speedAndMode() {
        let playing = stateAt(6, playing: true)
        let faster = PlaceTimeline.reduce(playing, .setSpeed(.quadruple))
        let windowed = PlaceTimeline.reduce(playing, .setMode(.window12))

        #expect(faster.index == 6)
        #expect(faster.playing)
        #expect(faster.speed == .quadruple)
        #expect(windowed.index == 6)
        #expect(windowed.playing)
        #expect(windowed.mode == .window12)
    }

    @Test("does not play an empty timeline")
    func emptyTimeline() {
        let empty = PlaceTimeline.initialState(PlaceTimeline.buildHistogram([]))

        #expect(empty.index == 0)
        #expect(empty.bucketCount == 0)
        #expect(!PlaceTimeline.reduce(empty, .play).playing)
    }

    @Test("cycles the speed control 1x - 2x - 4x - 1x")
    func speedCycle() {
        #expect(PlaceTimeline.nextSpeed(.single) == .double)
        #expect(PlaceTimeline.nextSpeed(.double) == .quadruple)
        #expect(PlaceTimeline.nextSpeed(.quadruple) == .single)
    }

    private func visible(_ state: TimelineState) -> [String] {
        PlaceTimeline.applyPlayhead(placeSpan, state: state).markers.map(\.uid)
    }

    @Test("accumulates every bucket up to and including the playhead")
    func accumulates() {
        #expect(visible(stateAt(0)) == ["a"])
        #expect(visible(stateAt(5)) == ["a", "b"])
        #expect(visible(stateAt(11)) == ["a", "b"])
        #expect(visible(stateAt(14)) == ["a", "b", "c", "d"])
    }

    @Test("shows only the trailing twelve months in the windowed mode")
    func window12() {
        #expect(visible(stateAt(14, mode: .window12)) == ["b", "c", "d"])
        #expect(visible(stateAt(12, mode: .window12)) == ["b", "c"])
        #expect(visible(stateAt(5, mode: .window12)) == ["a", "b"])
    }

    @Test("reports the markers that are new since the previous state as the landing set")
    func landing() {
        let stepped = PlaceTimeline.applyPlayhead(
            placeSpan,
            state: stateAt(5),
            previous: stateAt(4)
        )
        let quiet = PlaceTimeline.applyPlayhead(
            placeSpan,
            state: stateAt(4),
            previous: stateAt(3)
        )
        let windowed = PlaceTimeline.applyPlayhead(
            placeSpan,
            state: stateAt(12, mode: .window12),
            previous: stateAt(5, mode: .window12)
        )

        #expect(stepped.landing == ["b"])
        #expect(quiet.landing == [])
        #expect(windowed.landing == ["c"])
    }

    @Test("lands nothing when there is no previous state")
    func noLandingOnFirstRender() {
        #expect(PlaceTimeline.applyPlayhead(placeSpan, state: stateAt(14)).landing == [])
    }

    @Test("accepts a precomputed histogram and answers identically")
    func precomputedHistogram() {
        let given = PlaceTimeline.applyPlayhead(
            placeSpan,
            state: stateAt(5),
            histogram: placeSpanHistogram
        )

        #expect(given.markers.map(\.uid) == visible(stateAt(5)))
    }
}
