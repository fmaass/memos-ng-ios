import MapKit
import MemosCore
import SwiftUI

/// Every change the map's annotations undergo, as three calls.
///
/// The seam exists because `MKMapView` cannot be run in a unit test and the rules that decide
/// WHICH annotation changes are the whole of the map's correctness: with the seam, what the
/// coordinator decided is recordable without a map at all, and the production conformance stays
/// small enough to read.
@MainActor
protocol AnnotationSink: AnyObject {
    func add(_ annotations: [PlaceAnnotation])
    func remove(_ annotations: [PlaceAnnotation])
    /// One annotation whose pin changed in place — the object MapKit already holds, not a
    /// replacement for it.
    func refresh(_ annotation: PlaceAnnotation)
}

/// One pin on the map, as the object MapKit keeps.
///
/// `nonisolated` because MapKit reads an annotation's coordinate wherever it pleases, and
/// `coordinate` is `@objc dynamic` because the map only notices a pin that moved through KVO on
/// exactly that property.
nonisolated final class PlaceAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    private(set) var pin: PlacePin

    init(pin: PlacePin) {
        self.pin = pin
        self.coordinate = CLLocationCoordinate2D(
            latitude: pin.spec.latitude,
            longitude: pin.spec.longitude
        )
    }

    /// The same object, now standing for a different set of photographs.
    ///
    /// Mutating rather than replacing is what keeps a pin's view on screen across a refresh:
    /// removing and re-adding an annotation makes MapKit drop the view and build another, which
    /// costs the thumbnail it had already fetched and makes the pin blink.
    func update(to pin: PlacePin) {
        self.pin = pin
        coordinate = CLLocationCoordinate2D(
            latitude: pin.spec.latitude,
            longitude: pin.spec.longitude
        )
    }
}

/// The map's delegate and the one place that decides what the annotations become.
@MainActor
final class PlacesMapCoordinator: NSObject, MKMapViewDelegate {
    /// One annotation object per `PinSpec.key`, for the lifetime of that key on the map.
    private var annotations: [String: PlaceAnnotation] = [:]
    /// Where every change goes. Held rather than passed on each call so the representable can
    /// install the production one once, and a test can install a recorder instead.
    var sink: (any AnnotationSink)?
    private var hasFitted = false

    /// What the map should be showing now, turned into the changes that get it there.
    func show(_ pins: [PlacePin], through sink: any AnnotationSink) {
        let diff = PlaceClustering.sync(
            current: annotations.mapValues { $0.pin.spec },
            desired: pins.map(\.spec)
        )
        var wanted: [String: PlacePin] = [:]
        wanted.reserveCapacity(pins.count)
        for pin in pins { wanted[pin.spec.key] = pin }
        apply(diff, from: wanted, through: sink)
    }

    /// The diff, applied. A pin in none of the three buckets is not touched and produces no call
    /// at all — that is what makes the sink's record a statement about what CHANGED.
    func apply(_ diff: PinDiff, from pins: [String: PlacePin], through sink: any AnnotationSink) {
        let gone = diff.removed.compactMap { annotations.removeValue(forKey: $0) }
        if !gone.isEmpty { sink.remove(gone) }

        var born: [PlaceAnnotation] = []
        for spec in diff.added {
            guard let pin = pins[spec.key] else { continue }
            let annotation = PlaceAnnotation(pin: pin)
            annotations[spec.key] = annotation
            born.append(annotation)
        }
        if !born.isEmpty { sink.add(born) }

        for spec in diff.updated {
            guard let pin = pins[spec.key], let annotation = annotations[spec.key] else { continue }
            annotation.update(to: pin)
            sink.refresh(annotation)
        }
    }

    /// The opening view, applied exactly once.
    ///
    /// Once, because every later fit would be the map yanking itself back from wherever the
    /// reader had just panned it to.
    func fitOnce(_ region: MKCoordinateRegion?, on mapView: MKMapView) {
        guard !hasFitted, let region else { return }
        hasFitted = true
        mapView.setRegion(region, animated: false)
    }
}

/// The production sink: the three calls, forwarded to a live map and nothing else.
@MainActor
final class MapViewAnnotationSink: AnnotationSink {
    private weak var mapView: MKMapView?

    init(mapView: MKMapView) {
        self.mapView = mapView
    }

    func add(_ annotations: [PlaceAnnotation]) {
        mapView?.addAnnotations(annotations)
    }

    func remove(_ annotations: [PlaceAnnotation]) {
        mapView?.removeAnnotations(annotations)
    }

    func refresh(_ annotation: PlaceAnnotation) {
        // Nil when the pin is off screen or swallowed by a cluster: there is no view to repaint,
        // and the one MapKit builds when it comes back reads the annotation as it stands.
        (mapView?.view(for: annotation) as? PlaceAnnotationView)?.configure()
    }
}

/// The map itself.
struct PlacesMapView: UIViewRepresentable {
    let pins: [PlacePin]
    let region: MKCoordinateRegion?

    func makeCoordinator() -> PlacesMapCoordinator {
        PlacesMapCoordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        // No location services and no usage key: this map shows where the photographs are, not
        // where the reader is.
        mapView.showsUserLocation = false
        mapView.register(
            PlacePinView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier
        )
        let clusterReuseIdentifier = MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        mapView.register(
            PlaceClusterView.self,
            forAnnotationViewWithReuseIdentifier: clusterReuseIdentifier
        )
        context.coordinator.sink = MapViewAnnotationSink(mapView: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        guard let sink = context.coordinator.sink else { return }
        context.coordinator.show(pins, through: sink)
        context.coordinator.fitOnce(region, on: mapView)
    }
}
