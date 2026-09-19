import Foundation

/// The box the first view is fitted to, in the map's own degrees.
nonisolated public struct PlaceBBox: Sendable, Equatable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double

    public init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }
}

/// Photos taken from one spot, in input order — they share a single pin at every zoom.
nonisolated public struct CoordinateGroup: Sendable, Equatable, Identifiable {
    public var key: String
    public var latitude: Double
    public var longitude: Double
    public var markers: [PlaceMarker]

    public var id: String { key }
}

/// Only the sides of a rectangle this layer needs, so a test can state one as a literal and the
/// pure functions stay clear of any view geometry type.
nonisolated public struct PaneRect: Sendable, Equatable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    /// Derived rather than carried: a rectangle that could disagree with its own sides would let
    /// a caller reserve for a height the overlay does not have.
    public var height: Double { bottom - top }

    public init(top: Double, bottom: Double, left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

/// What the initial fit must keep free on each side of the map pane.
nonisolated public struct FitInsets: Sendable, Equatable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }
}

/// Pure geometry for the Places map: markers in, groups and boxes out. Ported from the SPA's
/// `frontend/src/lib/places/geo.ts`, which keeps the same rules out of its map component for the
/// same reason they are kept out of a view here — a map canvas cannot be run in a unit test, and
/// every rule that decides what the first view frames and which photos share a pin can be.
nonisolated public enum PlaceGeo {
    /// ~10 cm. Two files from the same spot must land on ONE pin; two houses apart must not.
    private static let coordinateDecimals = 6

    /// The smallest box the first view may be fitted to. One pin — or a column of pins on one
    /// coordinate — spans nothing, and a fit has no scale to solve for, so the map would open at
    /// an arbitrary zoom beside the photo instead of on it.
    public static let minBBoxSpan = 0.01

    /// The breathing room the first view keeps around the outermost pins, per side.
    public static let fitPadding: Double = 50

    /// The least map the first view may be left with once the reservation is taken off it. A pane
    /// shorter than the overlay it carries would otherwise be padded out of existence.
    private static let minFitSpan: Double = 40

    public static func coordKey(_ latitude: Double, _ longitude: Double) -> String {
        "\(fixed(latitude)),\(fixed(longitude))"
    }

    /// One coordinate as the SPA's `toFixed` writes it.
    ///
    /// Neither printf nor `Decimal` can stand in for it, for the same underlying reason: each one
    /// decides on a number that is not the one `toFixed` reads. `%.6f` rounds an exact halfway
    /// value to the EVEN digit (0.0078125 becomes `0.007812`, where the browser says `0.007813`)
    /// and signs negative zero. `Decimal(Double)` rounds correctly in base ten but only on an
    /// APPROXIMATION of the double, and an ordinary seven-decimal coordinate ending in a 5 sits
    /// within about 1e-16 of a halfway value — so a conversion error of that size flips it: the
    /// double nearest 8.5417235 is just BELOW the halfway point and the browser writes
    /// `8.541723`, while the decimal conversion of it lands just above and writes `8.541724`.
    ///
    /// So the digits are computed from the double's own bits, which are exact by definition: the
    /// magnitude is `significand · 2^-shift` with an integer significand, the scaled numerator
    /// `significand · 10^6` is exact in 128 bits (it is below 2^73), and the shift splits it into
    /// the digits and the remainder that decides the rounding. A remainder of exactly half rounds
    /// up, which is the rule the language spec states as "if there are two such n, pick the
    /// larger n". The sign is decided by the same test that spec makes, `< 0`, which negative
    /// zero fails and a value that merely rounds to zero passes. The tests pin both the exact
    /// halfway values and the near-halfway ones, on both sides and both signs.
    private static func fixed(_ value: Double) -> String {
        var power: UInt64 = 1
        for _ in 0..<coordinateDecimals { power *= 10 }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)

        // A coordinate is finite and inside the world. Nothing else can come off the wire — JSON
        // has no literal for an infinity — and such a value is handed back as its own description
        // rather than trapping the arithmetic below, which is sized for this domain. Two distinct
        // doubles still keep distinct text, so no two of them can collapse onto one key.
        guard magnitude.isFinite, magnitude <= 360 else { return "\(sign)\(magnitude)" }

        let bits = magnitude.bitPattern
        let rawExponent = Int((bits >> 52) & 0x7FF)
        let rawSignificand = bits & 0x000F_FFFF_FFFF_FFFF
        // The leading one is implicit in a normal number and absent from a subnormal one.
        let significand = rawExponent == 0 ? rawSignificand : rawSignificand | (1 << 52)
        let shift = 52 - (rawExponent == 0 ? -1022 : rawExponent - 1023)

        let scaled = UInt128(significand) * UInt128(power)
        let whole = scaled >> shift
        // Beyond 128 places the remainder cannot reach half of the shifted unit, and asking for
        // that unit would shift it away to nothing and round everything up.
        let roundsUp = shift < 128 && scaled - (whole << shift) >= UInt128(1) << (shift - 1)
        let units = UInt64(whole) + (roundsUp ? 1 : 0)

        let fraction = String(units % power)
        let padding = String(repeating: "0", count: coordinateDecimals - fraction.count)
        return "\(sign)\(units / power).\(padding)\(fraction)"
    }

    /// Markers grouped by the coordinate they were taken at, groups in first-seen order and each
    /// group's markers in input order — the order the viewer and the drawer then list them in.
    public static func groupByCoordinate(_ markers: [PlaceMarker]) -> [CoordinateGroup] {
        var groups: [CoordinateGroup] = []
        var indexByKey: [String: Int] = [:]
        for marker in markers {
            let key = coordKey(marker.latitude, marker.longitude)
            if let index = indexByKey[key] {
                groups[index].markers.append(marker)
            } else {
                indexByKey[key] = groups.count
                groups.append(
                    CoordinateGroup(
                        key: key,
                        latitude: marker.latitude,
                        longitude: marker.longitude,
                        markers: [marker]
                    )
                )
            }
        }
        return groups
    }

    /// The box every pin fits in, padded on any axis that collapsed. Nil when there are no pins:
    /// there is nothing to fit to, and a caller must show its empty state rather than a region.
    public static func bbox(_ markers: [PlaceMarker]) -> PlaceBBox? {
        guard let first = markers.first else { return nil }
        var west = first.longitude
        var east = first.longitude
        var south = first.latitude
        var north = first.latitude
        for marker in markers.dropFirst() {
            west = min(west, marker.longitude)
            east = max(east, marker.longitude)
            south = min(south, marker.latitude)
            north = max(north, marker.latitude)
        }
        if east - west < minBBoxSpan {
            let mid = (east + west) / 2
            west = mid - minBBoxSpan / 2
            east = mid + minBBoxSpan / 2
        }
        if north - south < minBBoxSpan {
            let mid = (north + south) / 2
            south = mid - minBBoxSpan / 2
            north = mid + minBBoxSpan / 2
        }
        return PlaceBBox(west: west, south: south, east: east, north: north)
    }

    /// One longitude folded into [-180, 180), so that 180 and -180 are one meridian rather than
    /// two numbers a comparison can disagree about.
    private static func wrapped(_ longitude: Double) -> Double {
        let shifted = (longitude + 180).truncatingRemainder(dividingBy: 360)
        return (shifted < 0 ? shifted + 360 : shifted) - 180
    }

    /// The box the map currently shows, from a region stated as plain degrees.
    ///
    /// Plain doubles rather than a region type, so this layer stays free of MapKit and the rule
    /// can be stated in a unit test. Two cases are not the obvious arithmetic. Latitude is CLAMPED
    /// to the poles, because a region centred near one runs past it and a marker cannot be at 91
    /// degrees north to match. A longitude span of a full turn or more is the WHOLE range rather
    /// than two endpoints wrapped onto one meridian — those endpoints would cross and the box
    /// would then hold the sliver the map is not showing instead of the world it is.
    ///
    /// Everything else wraps into [-180, 180), so a region over the antimeridian comes out with
    /// `west > east`. That is a real box here and `markers(_:within:)` reads it, but it is NOT the
    /// shape the initial fit's span arithmetic takes: `bbox` assumes `west <= east` and goes on
    /// assuming it, so a box from this function is never handed to it. `minBBoxSpan` is that fit's
    /// floor and is deliberately not applied here: the region shown is whatever the person
    /// panned to, not something to pad.
    public static func visibleBox(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) -> PlaceBBox {
        let halfLatitude = abs(latitudeDelta) / 2
        let south = max(-90, centerLatitude - halfLatitude)
        let north = min(90, centerLatitude + halfLatitude)

        guard abs(longitudeDelta) < 360 else {
            return PlaceBBox(west: -180, south: south, east: 180, north: north)
        }
        let halfLongitude = abs(longitudeDelta) / 2
        return PlaceBBox(
            west: wrapped(centerLongitude - halfLongitude),
            south: south,
            east: wrapped(centerLongitude + halfLongitude),
            north: north
        )
    }

    /// The markers inside a visible box, in input order — the grid orders them itself.
    ///
    /// Both latitude edges are inclusive: a pin exactly on the edge of what is shown is shown.
    /// Longitude is compared only after the marker has been through the same wrap the box was, so
    /// a marker recorded at 180 and a box edge written as -180 meet as one meridian. A box whose
    /// west is greater than its east is the antimeridian case and holds the two arcs outside the
    /// pair, not the one between them.
    public static func markers(_ markers: [PlaceMarker], within box: PlaceBBox) -> [PlaceMarker] {
        markers.filter { marker in
            guard marker.latitude >= box.south, marker.latitude <= box.north else { return false }
            let longitude = wrapped(marker.longitude)
            if box.west <= box.east {
                return longitude >= box.west && longitude <= box.east
            }
            return longitude >= box.west || longitude <= box.east
        }
    }

    /// What the initial fit must keep free, given the pane and the overlay drawn on top of it.
    ///
    /// An overlay on the map pane covers pixels a uniform inset will happily put a pin under: on
    /// the web at 1440x900 two of eight pins landed behind the timeline bar, where nothing could
    /// click them. The reservation is MEASURED from the overlay on each fit rather than named as
    /// a constant — the bar is a different height on every phone and grows again when it wraps.
    ///
    /// The contract is deliberately narrow: this reserves for a BOTTOM-anchored overlay that
    /// really intersects the pane on BOTH axes, and for nothing else. An overlay clear of the
    /// pane, one beside it, one above it and one anchored at the TOP of it all reserve nothing.
    /// A top bar or a side panel would need a different side reserved, and inferring which from a
    /// rectangle would quietly mis-fit the one overlay the map actually has.
    public static func fitInsets(
        pane: PaneRect,
        overlay: PaneRect?,
        base: Double = fitPadding
    ) -> FitInsets {
        var overlap: Double = 0
        if let overlay {
            let intersects =
                overlay.right > pane.left && overlay.left < pane.right
                && overlay.bottom > pane.top && overlay.top < pane.bottom
            let anchoredBottom = intersects && overlay.bottom > (pane.top + pane.bottom) / 2
            if anchoredBottom {
                overlap = max(0, pane.bottom - max(overlay.top, pane.top))
            }
        }
        let top = min(base, max(0, (pane.height - minFitSpan) / 2))
        let room = pane.height - minFitSpan - top
        return FitInsets(
            top: top,
            right: base,
            bottom: max(0, min(base + overlap, room)),
            left: base
        )
    }
}
