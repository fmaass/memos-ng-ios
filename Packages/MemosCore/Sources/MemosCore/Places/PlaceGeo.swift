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
        let format = "%.\(coordinateDecimals)f,%.\(coordinateDecimals)f"
        return String(format: format, latitude, longitude)
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
