import CoreGraphics
import Foundation
import MemosCore

/// Which square a finger is over, and what happens while it is there.
///
/// The heatmap stopped being a picture with a tap on it and became a SCRUBBER (MEMNG-178): the
/// date field above it follows the finger across the grid, live, and the timeline is only reloaded
/// when the finger comes off. That makes hit-testing the whole of the interaction, and hit-testing
/// under a finger dragging at speed is not the tap-target problem it looks like — the interesting
/// readings are the ones OUTSIDE the grid, which a tap can never produce and a scrub produces
/// constantly.
///
/// So it is a pure function of a point and a geometry, asserted per edge rather than felt for on a
/// device.
enum HeatmapScrub {
    /// The day under a point in the grid's own coordinate space.
    ///
    /// Two rules make a scrub feel like a scrub rather than a series of taps.
    ///
    /// **Nothing is out of bounds.** A point left of, right of, above or below the grid is clamped
    /// into it rather than refused. A finger sliding along the bottom row inevitably strays below
    /// it, and a scrubber that stopped answering there would drop the date back to nothing halfway
    /// through a drag.
    ///
    /// **The gaps belong to the square on their left.** The grid is squares with 2pt of air
    /// between them; treating that air as "no day" would put a dead stripe between every column,
    /// which at scrubbing speed reads as the field stuttering.
    ///
    /// The short trailing column is the one case that is genuinely empty: the last week of the
    /// window stops on today, so its lower slots stand for days that have not happened. A point
    /// there answers with that column's last real day rather than with nothing.
    static func cell(
        at point: CGPoint,
        in grid: HeatmapGrid,
        side: CGFloat,
        gap: CGFloat
    ) -> HeatCell? {
        let pitch = side + gap
        guard pitch > 0, !grid.columns.isEmpty else { return nil }
        let column = index(for: point.x, pitch: pitch, count: grid.columns.count)
        let days = grid.columns[column]
        guard !days.isEmpty else { return nil }
        return days[index(for: point.y, pitch: pitch, count: days.count)]
    }

    /// The square a day key stands for, or nil when the grid does not hold that day.
    ///
    /// A date typed into the field can be older than the twelve weeks the grid draws, so "the
    /// chosen day" and "a square on this grid" are not the same thing and the difference has to be
    /// sayable.
    static func cell(for key: String?, in grid: HeatmapGrid) -> HeatCell? {
        guard let key else { return nil }
        return grid.cells.first { $0.date == key }
    }

    /// What VoiceOver reads as the grid's VALUE: the day it is on and what was written that day.
    ///
    /// The grid is one element with a value, not eighty-four elements with labels (HIG, Charting
    /// data): a rotor that stops on every square is a rotor nobody can get past, and each square
    /// is far under the 44pt a target needs anyway — the whole grid is the target.
    static func spoken(_ key: String?, in grid: HeatmapGrid, locale: Locale = .current) -> String? {
        guard let cell = cell(for: key, in: grid) else { return nil }
        return HeatmapDateJump.label(for: cell, locale: locale)
    }

    /// The square one step later (`delta > 0`) or earlier than the chosen one — what an
    /// accessibility adjustment moves to, since a swipe cannot scrub.
    ///
    /// It CLAMPS at both ends rather than wrapping: an adjustment that ran off the oldest square
    /// and reappeared on today would be a jump across twelve weeks that nothing announced.
    static func stepped(from key: String?, by delta: Int, in grid: HeatmapGrid) -> HeatCell? {
        let cells = grid.cells
        guard !cells.isEmpty else { return nil }
        // Nothing chosen, or a day older than the window the grid draws: stepping starts at the
        // end the reader is moving away from, so the first adjustment always lands on a square.
        guard let key, let current = cells.firstIndex(where: { $0.date == key }) else {
            return delta >= 0 ? cells[0] : cells[cells.count - 1]
        }
        return cells[min(max(current + delta, 0), cells.count - 1)]
    }

    /// A coordinate as a slot number, clamped into `0..<count`.
    ///
    /// The clamping happens in floating point, BEFORE the conversion to an integer, because a
    /// drag that leaves the screen entirely can report a coordinate whose slot number does not fit
    /// in an `Int` at all — and `Int(_:)` does not clamp, it traps.
    private static func index(for coordinate: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let slot = (coordinate / pitch).rounded(.down)
        guard slot.isFinite, slot > 0 else { return 0 }
        guard slot < CGFloat(count - 1) else { return count - 1 }
        return Int(slot)
    }
}

/// What a heatmap does under a finger, or nil for one that is only a picture.
///
/// One value rather than three loose closures: a grid with a `move` and no `end` would leave the
/// timeline showing whatever the finger last passed over, which is the failure the debounce
/// exists to prevent, and the type is what makes that combination unsayable.
struct HeatmapScrubbing {
    /// The day the field is on, as the server keys it — the square drawn as selected.
    let selectedKey: String?
    /// The finger has moved onto a day. Called on every reading, including the first: a tap IS a
    /// drag of no distance, so nothing here special-cases one.
    let move: (HeatCell) -> Void
    /// The finger has come off. This is where the query runs.
    let end: () -> Void
}
