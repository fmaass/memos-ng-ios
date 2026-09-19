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

/// What a tap on a pin or a cluster opens below the map: the photographs behind it, in the order
/// they are listed, and whether zooming in could still do anything about them.
nonisolated struct PlaceSheet: Equatable, Identifiable {
    var markers: [PlaceMarker]
    /// Offered only when the map could still separate what was tapped — see
    /// `PlacesPresentation.minimumCameraDistance`.
    var canZoomIn: Bool
    /// The pins the sheet stands for, kept so Zoom-in can frame their actual extent. Nothing is
    /// re-derived from a coordinate: these are the very objects the map handed over.
    var members: [PlacePin]

    /// The set of pins, which is what makes one sheet a different sheet from another. Tapping the
    /// same pin again reopens the same one, which is the behaviour `sheet(item:)` should have.
    var id: String { members.map(\.id).joined(separator: "|") }
}

/// What a tap on the map turns into. Two outcomes and no third: a pin holding one photograph opens
/// it, and anything holding more opens the list.
///
/// Not `Equatable`: `MediaViewerSelection` is declared under this package's main-actor default
/// isolation, so its conformance is main-actor-isolated and a nonisolated enum cannot carry it.
/// Nothing needs it — a case is read by pattern, and what it carries is compared field by field.
nonisolated enum PlaceTapAction {
    case viewer(MediaViewerSelection)
    case sheet(PlaceSheet)
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

    // MARK: - what a tap opens, and what the grid holds

    /// How close the map may be brought to what it shows, in metres, and therefore when zooming
    /// has nothing left to do.
    ///
    /// A hundred metres is chosen so that a phone can still take two pins about ten metres apart
    /// and put daylight between them: at that distance ten metres is roughly a marker's own width
    /// across a phone screen, which is the point at which two pins stop being one. Going closer
    /// buys nothing: the map has no more detail to give and the pins are already apart, so the
    /// floor is also what makes "can zooming still help?" a question with an answer.
    static let minimumCameraDistance: CLLocationDistance = 100

    /// What a tap on one pin opens.
    ///
    /// Nil when the pin stands for photographs the current read no longer has — the markers were
    /// replaced under it — because opening a viewer on nothing is worse than a tap that does
    /// nothing. A pin of several photographs never offers Zoom-in: they share ONE coordinate, and
    /// no camera distance can put them in different places.
    ///
    /// Main-actor, because building a viewer selection is: `MediaViewerPresentation` lives under
    /// this package's main-actor default isolation. A tap arrives there anyway, since
    /// `MKMapViewDelegate` is main-actor, so nothing is hopped — and the enum itself stays
    /// nonisolated for the rules that decide without a viewer.
    @MainActor
    static func tap(pin: PlacePin, in markers: [PlaceMarker]) -> PlaceTapAction? {
        let resolved = resolve(pin.spec.uids, in: markers)
        guard let only = resolved.first else { return nil }
        if resolved.count == 1 {
            guard let selection = open(only.uid, in: resolved) else { return nil }
            return .viewer(selection)
        }
        return .sheet(
            PlaceSheet(
                markers: PlaceOrder.newestFirst(resolved),
                canZoomIn: false,
                members: [pin]
            )
        )
    }

    /// What a tap on a cluster opens: every photograph of every member pin, in ONE order.
    ///
    /// One order across the combined list rather than per member, because the reader tapped a
    /// place and not a set of pins. Member blocks would put an older photograph above a newer
    /// one
    /// for a reason nothing on screen explains. The leads alone would list two pictures where the
    /// badge just said seven.
    ///
    /// Zoom-in is offered while zooming can still separate the members, which is a fact about the
    /// camera rather than about how far apart they are in degrees: two pins 0.0045 degrees apart
    /// are 500 m and plainly worth zooming to, and any degree threshold would have hidden the
    /// action exactly there. At the floor the sheet still opens and still lists everything; only
    /// the action that could no longer do anything is left off.
    static func clusterTap(
        members: [PlacePin],
        in markers: [PlaceMarker],
        cameraDistance: CLLocationDistance
    ) -> PlaceSheet {
        let resolved = resolve(members.flatMap(\.spec.uids), in: markers)
        return PlaceSheet(
            markers: PlaceOrder.newestFirst(resolved),
            canZoomIn: cameraDistance > 1.1 * minimumCameraDistance,
            members: members
        )
    }

    /// The viewer for one photograph of a list, opened on it in the order the list is shown in.
    ///
    /// The list is ordered here and the photograph is carried by uid, so the viewer opens on the
    /// picture that was under the finger rather than on whatever occupied that position before the
    /// sort. Nil when the uid is not in the list, or when nothing in it can be rendered at all.
    ///
    /// Through the viewer's OWN selection function, so that what counts as viewable and what a
    /// missing uid means are decided in one place for every screen that opens the viewer.
    /// `PlaceOrder.viewerTarget` is the ported statement of the order this is held to — asserted
    /// against this function in the tests rather than called from it.
    @MainActor
    static func open(_ uid: String, in list: [PlaceMarker]) -> MediaViewerSelection? {
        MediaViewerPresentation.viewer(
            for: PlaceOrder.newestFirst(list).map(MemoAttachment.init),
            startingAt: uid
        )
    }

    /// What the grid under the map holds: the markers the visible region contains, newest first.
    static func grid(_ markers: [PlaceMarker], in box: PlaceBBox) -> [PlaceMarker] {
        PlaceOrder.newestFirst(PlaceGeo.markers(markers, within: box))
    }

    /// What the grid holds while the map has not yet said what it shows.
    ///
    /// A map that has never settled has reported no region, and no region is not an empty one:
    /// filtering by it would leave the grid blank under a map full of pins for as long as the
    /// reader left the screen alone. Until the first report the grid is the whole read, in the
    /// same order every later report leaves it in.
    static func visibleGrid(_ markers: [PlaceMarker], in box: PlaceBBox?) -> [PlaceMarker] {
        guard let box else { return PlaceOrder.newestFirst(markers) }
        return grid(markers, in: box)
    }

    /// The visible region as a box the pure layer can read. The only place MapKit's geometry is
    /// converted, which is what keeps `PlaceGeo` free of it.
    static func box(of region: MKCoordinateRegion) -> PlaceBBox {
        PlaceGeo.visibleBox(
            centerLatitude: region.center.latitude,
            centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
    }

    /// The markers a set of pins stands for, in the pins' own order and without duplicates.
    ///
    /// Resolved by uid against the markers in hand. A pin whose photographs are gone contributes
    /// nothing, and nothing is re-derived from a coordinate: a pin IS its list of uids.
    private static func resolve(_ uids: [String], in markers: [PlaceMarker]) -> [PlaceMarker] {
        var byUID: [String: PlaceMarker] = [:]
        byUID.reserveCapacity(markers.count)
        for marker in markers { byUID[marker.uid] = marker }
        var seen = Set<String>()
        return uids.compactMap { uid in
            guard seen.insert(uid).inserted else { return nil }
            return byUID[uid]
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
                // Without a sentence of its own this card has no cause to name: a read that never
                // reached the server is the session banner's to say, once, and a refusal that did
                // not end the session was the server answering. So it describes the load.
                message: error ?? "The last attempt did not finish."
            )
        }
    }
}
