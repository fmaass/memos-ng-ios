import Foundation

// The Months view's day mosaic (MEMNG-596, plan decision 9), ported from memos-ng
// `frontend/src/lib/mosaic.ts` with its spec's vectors: per month, the busiest days only, laid out
// in a fixed cycle of frame patterns. Pure, so the pick and the layout are held without a screen.

/// Where one tile sits in the mosaic's 3-column grid; the screen maps each to a frame.
public enum MosaicSlot: String, Sendable, Equatable, CaseIterable {
    /// Two columns by two rows, on the left.
    case heroLeft = "hero-left"
    /// One square in the right column, beside a `heroLeft`.
    case sideRight = "side-right"
    /// One square in a row of three.
    case square
    /// Two columns by two rows, on the right.
    case heroRight = "hero-right"
    /// One square in the left column, beside a `heroRight`.
    case sideLeft = "side-left"
    /// The full width, 16:9.
    case wide
}

/// The four frame patterns of decision 9, named as the design names them.
///
/// Each pattern names its hero first, so a pattern cut short still leads with its biggest frame.
/// The patterns are separate from the order they are walked in: Months walks A B C D
/// (`monthMosaicCycle`), and the All view's day blocks walk the same four in another order
/// (decision 13).
public enum MosaicPattern: Sendable, Equatable, CaseIterable {
    /// A hero left (2×2) with two squares stacked right.
    case a
    /// A row of three squares.
    case b
    /// A hero right (2×2) with two squares stacked left.
    case c
    /// One full-width 16:9 frame.
    case d

    public var slots: [MosaicSlot] {
        switch self {
        case .a: [.heroLeft, .sideRight, .sideRight]
        case .b: [.square, .square, .square]
        case .c: [.heroRight, .sideLeft, .sideLeft]
        case .d: [.wide]
        }
    }
}

/// The order the Months view walks the patterns in.
public let monthMosaicCycle: [MosaicPattern] = [.a, .b, .c, .d]

/// The slots of `count` tiles: the Months cycle from the pattern `offset` names, the last pattern
/// keeping only the slots there are tiles for.
///
/// The offset is the month's index on screen, so consecutive months open on different frames; any
/// integer is valid, wrapped onto the cycle. A count below one is no tiles.
public func mosaicSlots(_ count: Int, offset: Int = 0) -> [MosaicSlot] {
    let cycle = monthMosaicCycle
    var out: [MosaicSlot] = []
    guard count > 0 else { return out }
    out.reserveCapacity(count)
    var index = ((offset % cycle.count) + cycle.count) % cycle.count
    while out.count < count {
        for slot in cycle[index].slots where out.count < count {
            out.append(slot)
        }
        index = (index + 1) % cycle.count
    }
    return out
}

/// The days a month shows, in date order, and how many it left out.
public struct PickedDays: Sendable, Equatable {
    public let shown: [LibraryBucket]
    public let dropped: Int

    public init(shown: [LibraryBucket], dropped: Int) {
        self.shown = shown
        self.dropped = dropped
    }
}

/// The `cap` days with the most items, shown in date order.
///
/// A tie goes to the later day. Keys are `YYYY-MM-DD` strings in the zone the server counted in,
/// so string order IS date order and no calendar is consulted. The buckets are handed back
/// themselves, cover and all. A cap below one shows nothing and counts every day as dropped.
public func pickDays(_ days: [LibraryBucket], cap: Int = 6) -> PickedDays {
    let kept = days.sorted { lhs, rhs in
        lhs.count != rhs.count ? lhs.count > rhs.count : lhs.key > rhs.key
    }
    .prefix(max(cap, 0))
    return PickedDays(shown: kept.sorted { $0.key < $1.key }, dropped: days.count - kept.count)
}
