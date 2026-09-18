import Foundation
import MapKit
import MemosCore

/// One pin, with the two things about its lead photograph a map view needs and `PinSpec` does not
/// carry: when that photograph was taken, and where its thumbnail lives.
///
/// The date is not decoration — it is what decides which member of a MapKit cluster lends the
/// cluster its picture, and a cluster is handed nothing but its member annotations.
nonisolated struct PlacePin: Equatable, Sendable, Identifiable {
    var spec: PinSpec
    var leadTakenAt: Date
    var leadThumbnailURL: URL?

    var id: String { spec.key }
}

/// What the Places screen says when it has no map to show: the three parts a
/// `ContentUnavailableView` is made of, carried as a value so a test can read it back.
nonisolated struct PlacesNotice: Equatable, Sendable {
    let title: String
    let symbol: String
    let message: String
}

/// Every decision the Places screen and its map make that is not drawing.
///
/// The same split `MediaLibraryPresentation` makes, and for the same reason: neither a SwiftUI
/// body nor an `MKMapView` can be run in a unit test, and which region the map opens on, which
/// photograph a cluster wears and which of the four states the reader is shown are all things a
/// test must be able to state.
nonisolated enum PlacesPresentation {
    /// The pins the map should be showing, each carrying its lead photograph.
    ///
    /// The grouping itself is `PlaceClustering.pins(from:)` — this only puts the lead marker's
    /// date and thumbnail back beside the spec it was chosen for.
    static func pins(for markers: [PlaceMarker]) -> [PlacePin] {
        var leads: [String: PlaceMarker] = [:]
        leads.reserveCapacity(markers.count)
        for marker in markers { leads[marker.uid] = marker }
        return PlaceClustering.pins(from: markers).compactMap { spec in
            guard let lead = leads[spec.uid] else { return nil }
            return PlacePin(
                spec: spec,
                leadTakenAt: lead.takenAt,
                leadThumbnailURL: lead.thumbnailURL
            )
        }
    }

    /// The region the map opens on: the box every pin fits in, padded on any axis that collapsed.
    ///
    /// Nil when there is nothing to fit to, so the caller shows its empty state rather than a
    /// region invented for it.
    static func fitRegion(for markers: [PlaceMarker]) -> MKCoordinateRegion? {
        guard let box = PlaceGeo.bbox(markers) else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (box.south + box.north) / 2,
                longitude: (box.west + box.east) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: box.north - box.south,
                longitudeDelta: box.east - box.west
            )
        )
    }

    /// What a lone pin's badge says.
    static func pinBadge(for spec: PinSpec) -> String? {
        PlaceClustering.badgeText(count: spec.count)
    }

    /// What a cluster's badge says: the PHOTOGRAPHS behind it, not the pins it swallowed. Two
    /// member pins of three and four photos read seven — a reader counts pictures, and "2" would
    /// be an answer to a question nobody asked.
    static func clusterBadge(for members: [PlacePin]) -> String? {
        PlaceClustering.badgeText(count: members.reduce(0) { $0 + $1.spec.count })
    }

    /// Which member lends a cluster its photograph: the newest lead photo, and on a tie the
    /// smaller uid, so the same set of members always produces the same picture.
    static func clusterLead(of members: [PlacePin]) -> PlacePin? {
        members.max { left, right in
            left.leadTakenAt != right.leadTakenAt
                ? left.leadTakenAt < right.leadTakenAt
                : left.spec.uid > right.spec.uid
        }
    }

    /// Which of the four states the screen is in.
    ///
    /// Asked of the store's own `status` and of nothing else: deriving it from the markers alone
    /// tells "no photo here knows where it was taken yet" while the read is still in flight and
    /// again after it failed, which is the defect `PlacesStatus` exists to end.
    @MainActor
    static func state(of store: PlacesStore) -> PlacesStatus {
        store.status
    }

    /// What to say instead of a map, or nil when a map is what the reader gets.
    ///
    /// `.pending` carries no notice either: a screen that has not settled once shows a spinner,
    /// because an empty state shown while the answer is still coming is a claim about the library
    /// that has not been earned.
    static func notice(for status: PlacesStatus, error: String?) -> PlacesNotice? {
        switch status {
        case .ready, .pending:
            nil
        case .empty:
            PlacesNotice(
                title: "No places yet",
                symbol: "mappin.slash",
                message: "No photo here knows where it was taken yet."
            )
        case .error:
            PlacesNotice(
                title: "Places could not be loaded",
                symbol: "exclamationmark.triangle",
                message: error ?? "The server could not be reached."
            )
        }
    }
}
