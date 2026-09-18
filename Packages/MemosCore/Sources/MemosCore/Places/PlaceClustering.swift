import Foundation

/// One pin the map should be showing.
///
/// The SPA's pin spec carries a clustering id as well, because its clusters are computed by the
/// map library and a tap has to ask that library for the cluster's leaves. Here the map produces
/// its own clusters and hands them back as annotations, so there is no id to carry and none is
/// invented.
nonisolated public struct PinSpec: Sendable, Equatable, Identifiable {
    public var key: String
    public var latitude: Double
    public var longitude: Double
    /// Photos behind this pin.
    public var count: Int
    /// The photo whose thumbnail the pin wears.
    public var uid: String
    /// The attachments on this coordinate, in the order a tap hands them to the drawer.
    public var uids: [String]

    public var id: String { key }

    public init(
        key: String,
        latitude: Double,
        longitude: Double,
        count: Int,
        uid: String,
        uids: [String]
    ) {
        self.key = key
        self.latitude = latitude
        self.longitude = longitude
        self.count = count
        self.uid = uid
        self.uids = uids
    }
}

/// What to add, repaint and drop so the map shows the wanted set — the repaint is the frame
/// budget, and a pin in none of the three is left exactly as it is.
nonisolated public struct PinDiff: Sendable, Equatable {
    public var added: [PinSpec]
    public var updated: [PinSpec]
    public var removed: [String]
}

/// The pin decisions that are not drawing: what a pin's badge says, and what changed since the
/// last frame. Ported from the SPA's `frontend/src/lib/places/markers.ts`.
///
/// Its `pinsFor` is deliberately not ported: it turns one map library's tile query into pin specs
/// — deduplicating features that arrive from several tiles, collapsing same-coordinate points and
/// capping how many nodes a browser document holds. None of those three problems exists here, the
/// coordinate collapse being `PlaceGeo.groupByCoordinate` applied before the annotations are
/// built, so no vectors for it are invented either.
nonisolated public enum PlaceClustering {
    /// Badge text, or nil when the pin carries none: a "1" on every lone pin is noise, because
    /// the thumbnail already says one photo.
    public static func badgeText(count: Int) -> String? {
        if count <= 1 { return nil }
        return count > 99 ? "99+" : String(count)
    }

    /// The photos behind two pins, compared in order. A deletion answered by an arrival at the
    /// same coordinate leaves the lead, the count and the place untouched while the members move
    /// — and the members are what a tap hands the drawer, so an unrefreshed pin would open on a
    /// photo that is gone. Order counts because the drawer lists the photos in it.
    private static func sameUIDs(_ left: [String], _ right: [String]) -> Bool {
        left == right
    }

    public static func sync(current: [String: PinSpec], desired: [PinSpec]) -> PinDiff {
        var added: [PinSpec] = []
        var updated: [PinSpec] = []
        var wanted: Set<String> = []

        for pin in desired {
            wanted.insert(pin.key)
            guard let existing = current[pin.key] else {
                added.append(pin)
                continue
            }
            if existing.count != pin.count || existing.uid != pin.uid
                || existing.longitude != pin.longitude || existing.latitude != pin.latitude
                || !sameUIDs(existing.uids, pin.uids)
            {
                updated.append(pin)
            }
        }

        // Sorted because a dictionary has no order of its own and the caller applies this list to
        // a live map: an unordered answer would make two identical syncs look different.
        let removed = current.keys.filter { !wanted.contains($0) }.sorted()
        return PinDiff(added: added, updated: updated, removed: removed)
    }
}
