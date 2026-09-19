import Foundation

/// The list the viewer opens on, and which slide in it the tapped photo is.
nonisolated public struct ViewerTarget: Sendable, Equatable {
    public var list: [PlaceMarker]
    public var index: Int
}

/// What order the photos are in — and therefore which slide a tap opens.
///
/// Ported from the SPA's `frontend/src/lib/places/order.ts`. The grid shows newest first while
/// the map hands out whatever order the server returned, so the tapped photo is carried by uid
/// and the viewer is opened on the very list the person just looked at. A position in the
/// unsorted set would open a different photo, and "Show in memo" would then jump to that other
/// photo's memo.
nonisolated public enum PlaceOrder {
    public static func newestFirst(_ markers: [PlaceMarker]) -> [PlaceMarker] {
        // The tie-break on the input position is not decoration: Swift's sort is not stable, so
        // two photos taken in the same second could otherwise swap places between two identical
        // calls and move the slide a tap opens. The SPA's sort is stable and needs no such line.
        markers.enumerated()
            .sorted { left, right in
                if left.element.takenAt != right.element.takenAt {
                    return left.element.takenAt > right.element.takenAt
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// The displayed order, and the slide the tapped photo occupies in it. A uid that is no
    /// longer in the set opens the first slide rather than nothing.
    public static func viewerTarget(_ markers: [PlaceMarker], uid: String) -> ViewerTarget {
        let list = newestFirst(markers)
        let index = list.firstIndex { $0.uid == uid } ?? 0
        return ViewerTarget(list: list, index: index)
    }
}
