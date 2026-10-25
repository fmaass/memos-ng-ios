import Foundation

// The Months view's day mosaic (MEMNG-596, plan decision 9), ported from memos-ng
// `frontend/src/lib/mosaic.ts` with its spec's vectors: per month, the busiest days only, laid out
// in a fixed cycle of frame patterns. Pure, so the pick and the layout are held without a screen.
//
// Decision 9 is amended for the app (MEMNG-607, the owner's answer of 2026-10-23): a month shows
// its NINE busiest days, not six — two heroes and seven small frames, A B C (the first hero at the
// top, the second further down) or its mirror C B A on every other month — and the two heroes
// hold the month's two busiest days, the other seven staying in date order. The web's Months
// mosaic is unchanged, so `mosaicSlots`, `pickDays`' cap and `placeDays` no longer carry
// `mosaic.ts`'s vectors; the All view's `daySlots` still does.

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
/// (`monthMosaicCycle`) or C B A D (`mirroredMonthMosaicCycle`), and the All view's day blocks
/// walk the same four in another order (decision 13).
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

/// The order the first month of the Months view walks the patterns in, and every other month after
/// it: nine days are a hero top left, a row of three and a hero right further down (MEMNG-607);
/// only a month longer than nine reaches the wide frame.
public let monthMosaicCycle: [MosaicPattern] = [.a, .b, .c, .d]

/// The same walk mirrored, for the months in between: the first hero top right, the second further
/// down on the left.
public let mirroredMonthMosaicCycle: [MosaicPattern] = [.c, .b, .a, .d]

/// How many days a Months mosaic shows (MEMNG-607): its two heroes and seven small frames.
public let monthMosaicDayCap = 9

/// The slots of `count` tiles: the Months cycle the month's `offset` picks, the last pattern
/// keeping only the slots there are tiles for.
///
/// The offset is the month's index on screen: an even month walks `monthMosaicCycle`, an odd one
/// `mirroredMonthMosaicCycle`, so consecutive months differ and every month still opens on a hero.
/// Any integer is valid. A count below one is no tiles.
public func mosaicSlots(_ count: Int, offset: Int = 0) -> [MosaicSlot] {
    let cycle = offset.isMultiple(of: 2) ? monthMosaicCycle : mirroredMonthMosaicCycle
    var out: [MosaicSlot] = []
    guard count > 0 else { return out }
    out.reserveCapacity(count)
    var index = 0
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

/// Whether `lhs` is the busier day: more items, a tie going to the later day.
private func isBusier(_ lhs: LibraryBucket, than rhs: LibraryBucket) -> Bool {
    lhs.count != rhs.count ? lhs.count > rhs.count : lhs.key > rhs.key
}

/// The `cap` days with the most items, shown in date order.
///
/// A tie goes to the later day. Keys are `YYYY-MM-DD` strings in the zone the server counted in,
/// so string order IS date order and no calendar is consulted. The buckets are handed back
/// themselves, cover and all. A cap below one shows nothing and counts every day as dropped.
public func pickDays(_ days: [LibraryBucket], cap: Int = monthMosaicDayCap) -> PickedDays {
    let kept = days.sorted(by: isBusier).prefix(max(cap, 0))
    return PickedDays(shown: kept.sorted { $0.key < $1.key }, dropped: days.count - kept.count)
}

/// A month's shown days in the order of its slots (MEMNG-607): the busiest day in the first hero
/// slot, the next busiest in the second, and the other days in the slots between, in the order
/// they came — date order, as `pickDays` hands them.
///
/// Busiest is judged as `pickDays` judges it, so the day that wins a place by a tie also wins the
/// hero by it. One day per slot, in slot order, while there are both: `mosaicMonths` hands one
/// slot per day, and a day left without its hero slot takes the next slot there is rather than
/// being lost.
public func placeDays(_ days: [LibraryBucket], in slots: [MosaicSlot]) -> [LibraryBucket] {
    let heroSlots = slots.filter { $0 == .heroLeft || $0 == .heroRight }.count
    let ranked = days.indices.sorted { isBusier(days[$0], than: days[$1]) }.prefix(heroSlots)
    let heroIndices = Set(ranked)
    var heroes = Array(ranked).makeIterator()
    var rest = days.indices.filter { !heroIndices.contains($0) }.makeIterator()
    var out: [LibraryBucket] = []
    out.reserveCapacity(min(days.count, slots.count))
    for slot in slots {
        let first = slot == .heroLeft || slot == .heroRight ? heroes.next() : rest.next()
        guard let next = first ?? heroes.next() ?? rest.next() else { break }
        out.append(days[next])
    }
    return out
}

/// The order the All view's day blocks walk the patterns in: A B C B D (plan page 3929 decision 13
/// and its 20:05 CEST amendment, `docs/design/all-by-day-mockup.md` §2).
public let dayMosaicCycle: [MosaicPattern] = [.a, .b, .c, .b, .d]

/// The slots of one day's block in the All view (MEMNG-597), ported from memos-ng
/// `frontend/src/lib/mosaic.ts` `daySlots` with its spec's vectors.
///
/// `dayIndex` is the day's place in the whole loaded list, counted across month boundaries, so a
/// day starts the cycle one step later than the day before it and two neighbours never open alike;
/// any integer is valid, wrapped onto the cycle. A pattern is placed whole or not at all: a
/// remainder too short for the next one is squares, a single leftover one wide frame, and a day of
/// one or two pictures is wide frames only. Unlike `mosaicSlots`, no pattern is ever cut short —
/// a day block has no trailing gap to leave, where a month mosaic may.
public func daySlots(_ count: Int, dayIndex: Int = 0) -> [MosaicSlot] {
    guard count > 2 else { return Array(repeating: .wide, count: max(count, 0)) }
    let cycle = dayMosaicCycle
    var out: [MosaicSlot] = []
    out.reserveCapacity(count)
    var index = ((dayIndex % cycle.count) + cycle.count) % cycle.count
    while out.count < count {
        let pattern = cycle[index].slots
        let left = count - out.count
        if left < pattern.count {
            out += left == 1 ? [.wide] : Array(repeating: .square, count: left)
            break
        }
        out += pattern
        index = (index + 1) % cycle.count
    }
    return out
}
