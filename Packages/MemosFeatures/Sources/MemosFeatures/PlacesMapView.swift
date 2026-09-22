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
    /// Whether the view standing for this annotation is still owed its photograph.
    ///
    /// Asked of the sink because an annotation does not know its view: a pin whose fetch came back
    /// with nothing is, in everything the coordinator can see, the pin beside it.
    func isAwaitingPhotograph(_ annotation: PlaceAnnotation) -> Bool
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

    /// The same object and the same place, standing for the same photographs — but read again.
    ///
    /// A read can bring the thumbnail URL back signed afresh, so an annotation kept across a
    /// refresh may be holding a signature that will lapse while the one that replaces it is thrown
    /// away. Taking the new pin costs nothing and is what any later request will ask with.
    /// Separate from `update(to:)` because writing `coordinate` is a KVO notification to the map,
    /// and a pin that did not move must not send one.
    func adopt(_ pin: PlacePin) {
        self.pin = pin
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
    /// Whether this map has had its opening view. Readable so a test can tell a fit that is still
    /// waiting for its pane from one that has been taken.
    private(set) var hasFitted = false
    /// What the opening view will frame, once there is a pane to frame it in.
    private var pendingRegion: MKCoordinateRegion?
    /// The markers a tapped pin is resolved against: a pin is a list of uids, and what those uids
    /// stand for is whatever the last read left in hand.
    var markers: [PlaceMarker] = []
    /// What a tap opened.
    var onTap: ((PlaceTapAction) -> Void)?
    /// The map itself, for the one action that moves it. Weak: the map owns its delegate.
    private weak var mapView: MKMapView?

    /// The map this coordinator speaks for, kept so Zoom-in has something to move.
    ///
    /// The coordinator outlives the map: the screen holds it so a sheet can move the map, while
    /// the map itself is rebuilt whenever it leaves the hierarchy and comes back — a read that
    /// comes back with no placed photograph left replacing it with the empty notice, and a later
    /// one putting a map back, is exactly that. What is recorded below describes ONE map: which
    /// annotation objects are installed on it, and whether it has had its opening view. A
    /// different map holds neither, so the record goes with the map it described and the next pass
    /// adds every pin afresh and frames the new map once. The same map
    /// attached again is not a change — re-installing there would remove and re-add every pin,
    /// which is the blink the diff exists to prevent.
    func attach(to mapView: MKMapView) {
        if mapView !== self.mapView {
            annotations = [:]
            hasFitted = false
            pendingRegion = nil
        }
        self.mapView = mapView
    }

    /// Brings the map down to what a sheet's pins actually cover.
    ///
    /// The annotations themselves, so the map frames their real extent with its own padding. The
    /// initial fit's minimum span plays no part: that floor exists to stop one photograph filling
    /// the world, and here the reader has asked to get closer.
    func zoomIn(to members: [PlacePin]) {
        guard let mapView else { return }
        let targets = members.compactMap { annotations[$0.spec.key] }
        guard !targets.isEmpty else { return }
        mapView.showAnnotations(targets, animated: true)
    }

    /// Where a tap goes: one pin to its own rule, a cluster to the rule about members.
    ///
    /// Deselected first, because a selected annotation that is tapped again is not a selection
    /// change and would open nothing — and the sheet this opens takes the screen anyway, so
    /// nothing on the map is left looking chosen.
    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
        mapView.deselectAnnotation(annotation, animated: false)
        if let place = annotation as? PlaceAnnotation {
            guard let action = PlacesPresentation.tap(pin: place.pin, in: markers) else { return }
            onTap?(action)
        } else if let cluster = annotation as? MKClusterAnnotation {
            // The member objects are the very annotations the map was given, so a member's pin is
            // read off it rather than re-derived from a coordinate.
            let members = cluster.memberAnnotations.compactMap { ($0 as? PlaceAnnotation)?.pin }
            guard !members.isEmpty else { return }
            onTap?(
                .sheet(
                    PlacesPresentation.clusterTap(
                        members: members,
                        in: markers,
                        cameraDistance: mapView.camera.centerCoordinateDistance
                    )
                )
            )
        }
    }

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

        // What the diff cannot see: a pin in no bucket is the same place with the same
        // photographs, read again. Every one of them takes the new pin, whether its thumbnail URL
        // came back signed afresh or exactly as it was — which of the two the read brings is not
        // something this side can tell, and nothing here depends on the answer.
        //
        // One of them is repainted: the pin whose view is showing nothing with no request out.
        // That is what a thumbnail fetch that came back with nothing leaves behind — it caches
        // nothing, so the view is the only record of it — and this pass is the only occasion it
        // ever gets to ask again, now with the URL the annotation has just taken.
        //
        // A pin that HAS its photograph is left alone, and that is the point of asking rather than
        // repainting the lot: the picture it is showing can outlive the decoded entry behind it,
        // and a repaint would then find nothing cached, blank the pin and go back to the network.
        // A pin with a request out is left alone too — its answer is already coming.
        var touched = Set(diff.added.map(\.key))
        touched.formUnion(diff.updated.map(\.key))
        for (key, pin) in wanted where !touched.contains(key) {
            guard let annotation = annotations[key] else { continue }
            annotation.adopt(pin)
            guard pin.leadImageURL != nil, sink.isAwaitingPhotograph(annotation) else {
                continue
            }
            sink.refresh(annotation)
        }
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

    /// The opening view, applied exactly once: what to frame, kept until there is a pane to frame
    /// it in.
    ///
    /// Once, because every later fit would be the map yanking itself back from wherever the
    /// reader had just panned it to. The map is built before anything has been measured, so the
    /// region usually arrives against a pane of no size; a map put back onto a screen that is
    /// already laid out gets its size first instead. Both are the same operation, and whichever
    /// of the two comes second performs it.
    func fitOnce(_ region: MKCoordinateRegion?, on mapView: MKMapView) {
        if let region { pendingRegion = region }
        fitIfReady(on: mapView)
    }

    /// The pane has a size — the other half of the opening view's condition.
    func paneDidLayout(_ mapView: MKMapView) {
        fitIfReady(on: mapView)
    }

    /// The fit itself: the box in map points, with the pin's margin kept free around it, so the
    /// outermost photographs are whole and have air rather than sitting on the frame. Never
    /// animated — this is where the map opens, not somewhere it travels to.
    private func fitIfReady(on mapView: MKMapView) {
        guard !hasFitted, let region = pendingRegion else { return }
        let pane = mapView.bounds.size
        // A pane of no size cannot spare a margin, and MapKit would take the fit all the same.
        guard pane.width > 0, pane.height > 0 else { return }
        hasFitted = true
        pendingRegion = nil
        mapView.setVisibleMapRect(
            PlacesPresentation.mapRect(of: region),
            edgePadding: PlacePinGeometry.openingInsets(in: pane),
            animated: false
        )
    }
}

/// What the map is handed to SwiftUI inside, and the only reason there is a container at all: the
/// moment the pane has a size.
///
/// `layoutSubviews` is that moment, and a containing view is where it can be read — MapKit's own
/// documentation asks not to be subclassed.
final class PlacesMapContainer: UIView {
    let mapView: MKMapView
    /// The coordinator to tell, held strongly because the map holds it weakly as its delegate and
    /// this view lives exactly as long as the map it contains.
    private let coordinator: PlacesMapCoordinator

    init(mapView: MKMapView, coordinator: PlacesMapCoordinator) {
        self.mapView = mapView
        self.coordinator = coordinator
        super.init(frame: .zero)
        addSubview(mapView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PlacesMapContainer is built in code, never from a nib")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        coordinator.paneDidLayout(mapView)
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

    func isAwaitingPhotograph(_ annotation: PlaceAnnotation) -> Bool {
        // Nil for the same reasons as above, and the answer is no: a pin with no view is owed
        // nothing, and the view MapKit builds for it asks for its photograph itself.
        (mapView?.view(for: annotation) as? PlaceAnnotationView)?.isAwaitingPhotograph ?? false
    }
}

/// The map itself.
struct PlacesMapView: UIViewRepresentable {
    let pins: [PlacePin]
    let region: MKCoordinateRegion?
    /// What a tapped pin's uids are resolved against. Defaulted so a preview can show a map with
    /// nothing to open.
    var markers: [PlaceMarker] = []
    /// What a tap opened, for the screen to present.
    var onTap: ((PlaceTapAction) -> Void)?
    /// The coordinator, when the screen needs to keep hold of it — Zoom-in is an action on the map
    /// taken from a sheet the map itself does not present.
    var control: PlacesMapCoordinator?

    func makeCoordinator() -> PlacesMapCoordinator {
        control ?? PlacesMapCoordinator()
    }

    func makeUIView(context: Context) -> PlacesMapContainer {
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
        // How close the map may be brought to what it shows, which is also what makes "can zooming
        // still separate these?" a question with an answer (`PlacesPresentation`).
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: PlacesPresentation.minimumCameraDistance
        )
        context.coordinator.sink = MapViewAnnotationSink(mapView: mapView)
        context.coordinator.attach(to: mapView)
        return PlacesMapContainer(mapView: mapView, coordinator: context.coordinator)
    }

    func updateUIView(_ container: PlacesMapContainer, context: Context) {
        context.coordinator.markers = markers
        context.coordinator.onTap = onTap
        guard let sink = context.coordinator.sink else { return }
        context.coordinator.show(pins, through: sink)
        context.coordinator.fitOnce(region, on: container.mapView)
    }
}
