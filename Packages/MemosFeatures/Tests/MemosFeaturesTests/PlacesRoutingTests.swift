import Foundation
import MapKit
import MemosCore
import Testing
import UIKit

@testable import MemosFeatures

private func routedMarker(
    uid: String,
    takenAt: String,
    latitude: Double,
    longitude: Double
) -> PlaceMarker {
    PlaceMarker(
        uid: uid,
        memoUID: "memo-\(uid)",
        mime: "image/jpeg",
        mine: true,
        width: 4000,
        height: 3000,
        latitude: latitude,
        longitude: longitude,
        takenAt: ISO8601DateFormatter().date(from: takenAt)!,
        thumbnailURL: URL(string: "https://example.invalid/assets/\(uid)/thumb"),
        previewURL: URL(string: "https://example.invalid/assets/\(uid)/preview"),
        webURL: URL(string: "https://example.invalid/assets/\(uid)/web"),
        posterURL: URL(string: "https://example.invalid/assets/\(uid)/poster"),
        downloadURL: URL(string: "https://example.invalid/assets/\(uid)/download"),
        blurhash: nil
    )
}

private func routedPin(_ marker: PlaceMarker, key: String) -> PlacePin {
    PlacePin(
        spec: PinSpec(
            key: key,
            latitude: marker.latitude,
            longitude: marker.longitude,
            count: 1,
            uid: marker.uid,
            uids: [marker.uid]
        ),
        leadTakenAt: marker.takenAt,
        leadImageURL: nil
    )
}

private func zurichMarker() -> PlaceMarker {
    routedMarker(uid: "zurich", takenAt: "2026-01-01T00:00:00Z", latitude: 47.37, longitude: 8.54)
}

private func osloMarker() -> PlaceMarker {
    routedMarker(uid: "oslo", takenAt: "2026-01-02T00:00:00Z", latitude: 59.91, longitude: 10.75)
}

/// What the coordinator handed out, in order.
@MainActor
private final class RoutedCalls {
    var actions: [PlaceTapAction] = []
}

/// A map on a real screen, laid out and rendering, with the two annotation view classes the
/// screen registers. Clustering is the map's own work and it only does it for a map that is
/// actually showing something, so the cases that need a cluster need a window.
@MainActor
private func hostedMap() -> (UIWindow, MKMapView) {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
    let mapView = MKMapView(frame: window.bounds)
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
    window.addSubview(mapView)
    window.isHidden = false
    return (window, mapView)
}

/// The four corners of a box — the coordinates the outermost pins sit on, which is what the
/// opening view has to leave room around.
private func corners(of region: MKCoordinateRegion) -> [CLLocationCoordinate2D] {
    let north = region.center.latitude + region.span.latitudeDelta / 2
    let south = region.center.latitude - region.span.latitudeDelta / 2
    let west = region.center.longitude - region.span.longitudeDelta / 2
    let east = region.center.longitude + region.span.longitudeDelta / 2
    return [
        CLLocationCoordinate2D(latitude: north, longitude: west),
        CLLocationCoordinate2D(latitude: north, longitude: east),
        CLLocationCoordinate2D(latitude: south, longitude: west),
        CLLocationCoordinate2D(latitude: south, longitude: east),
    ]
}

/// A region tight enough that the map keeps the centre it was given.
private func routedRegion(latitude: Double, longitude: Double) -> MKCoordinateRegion {
    MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )
}

/// Lets the map get on with it until `until` is true, or until the budget runs out.
@MainActor
private func settle(_ window: UIWindow, until done: () -> Bool = { false }) {
    for _ in 0..<20 {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if done() { return }
    }
}

/// The cases that put pins on a map, declared where the loader's own tests live.
///
/// A map on a screen builds a view per pin, and `PlacePinView` reads the process-wide loader
/// before it so much as looks at its URL. Everything that touches that loader belongs in the one
/// serialized suite that owns it — the reason `PlacesAnnotationTests` already declares its pin
/// cases here — or these run beside its own cases and both sides read a store the other is
/// replacing. The case above hosts a map with no pins on it and reaches no loader, so it stays
/// with the rest of the routing rules.
extension MediaImageLoaderTests {
    @Test("a tap on a pin opens its photograph, and a second tap opens it again")
    func aTapOnAPinOpensItsPhotograph() throws {
        let zurich = zurichMarker()
        let (window, mapView) = hostedMap()
        let coordinator = PlacesMapCoordinator()
        let calls = RoutedCalls()
        coordinator.markers = [zurich]
        coordinator.onTap = { calls.actions.append($0) }
        mapView.delegate = coordinator
        coordinator.show(
            [routedPin(zurich, key: "z")],
            through: MapViewAnnotationSink(mapView: mapView)
        )
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54),
                span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
            ),
            animated: false
        )
        settle(window)
        let annotation = try #require(
            mapView.annotations.compactMap { $0 as? PlaceAnnotation }.first
        )

        mapView.selectAnnotation(annotation, animated: false)
        settle(window) { !calls.actions.isEmpty }
        guard case .viewer(let selection) = try #require(calls.actions.first) else {
            Issue.record("one photograph opened something other than the viewer")
            return
        }
        #expect(selection.pages.map(\.id) == ["zurich"])
        #expect(
            mapView.selectedAnnotations.isEmpty,
            "the pin stayed selected, so tapping it again is not a tap"
        )

        mapView.selectAnnotation(annotation, animated: false)
        settle(window) { calls.actions.count > 1 }
        #expect(calls.actions.count == 2, "the same pin could not be opened twice")
        window.isHidden = true
    }

    @Test("a tap on a cluster lists every photograph its members stand for")
    func aTapOnAClusterListsEveryMembersPhotographs() throws {
        let (window, mapView, coordinator, calls, markers) = clusteredMap()
        let cluster = try #require(
            firstCluster(on: mapView, window: window),
            "a map on a screen never clustered neighbouring pins"
        )
        let members = cluster.memberAnnotations.compactMap { $0 as? PlaceAnnotation }
        #expect(
            members.count == cluster.memberAnnotations.count,
            "the members came back as something other than the annotations the map was given"
        )
        // Which pins, not how many: a cluster standing for a different set of coordinates would
        // list the right number of photographs from the wrong places.
        #expect(
            members.map(\.pin.spec.key).sorted() == ["k0", "k1", "k2", "k3"],
            "the cluster held pins other than the four the map was given"
        )

        mapView.selectAnnotation(cluster, animated: false)
        settle(window) { !calls.actions.isEmpty }
        guard case .sheet(let sheet) = try #require(calls.actions.first) else {
            Issue.record("a cluster opened something other than the sheet")
            return
        }
        #expect(sheet.markers.map(\.uid) == Array(markers.map(\.uid).reversed()))
        #expect(sheet.canZoomIn, "a cluster seen from kilometres up could not be zoomed apart")
        #expect(coordinator.markers.count == markers.count)
        window.isHidden = true
    }

    @Test("zooming in on a cluster brings the map down to what its members cover")
    func zoomingInFramesTheMembers() throws {
        let (window, mapView, coordinator, calls, _) = clusteredMap()
        let cluster = try #require(firstCluster(on: mapView, window: window))
        mapView.selectAnnotation(cluster, animated: false)
        settle(window) { !calls.actions.isEmpty }
        guard case .sheet(let sheet) = try #require(calls.actions.first) else {
            Issue.record("a cluster opened something other than the sheet")
            return
        }
        let before = mapView.region.span.latitudeDelta

        coordinator.zoomIn(to: sheet.members)
        settle(window) { mapView.region.span.latitudeDelta < before / 2 }
        #expect(
            mapView.region.span.latitudeDelta < before / 2,
            "the map stayed where it was, so Zoom In did nothing"
        )
        #expect(abs(mapView.region.center.latitude - 47.37) < 0.05)
        window.isHidden = true
    }

    /// Four pins a few metres apart on a map that is showing half a degree: near enough that the
    /// map has to draw them as one thing.
    private func clusteredMap() -> (
        UIWindow, MKMapView, PlacesMapCoordinator, RoutedCalls, [PlaceMarker]
    ) {
        let markers = (0..<4).map { index in
            routedMarker(
                uid: "m\(index)",
                takenAt: "2026-01-0\(index + 1)T00:00:00Z",
                latitude: 47.37 + Double(index) * 0.0002,
                longitude: 8.54 + Double(index) * 0.0002
            )
        }
        let (window, mapView) = hostedMap()
        let coordinator = PlacesMapCoordinator()
        let calls = RoutedCalls()
        coordinator.markers = markers
        coordinator.onTap = { calls.actions.append($0) }
        coordinator.attach(to: mapView)
        mapView.delegate = coordinator
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ),
            animated: false
        )
        coordinator.show(
            markers.enumerated().map { routedPin($1, key: "k\($0)") },
            through: MapViewAnnotationSink(mapView: mapView)
        )
        return (window, mapView, coordinator, calls, markers)
    }

    private func firstCluster(on mapView: MKMapView, window: UIWindow) -> MKClusterAnnotation? {
        var clusters: [MKClusterAnnotation] = []
        settle(window) {
            clusters = mapView.annotations.compactMap { $0 as? MKClusterAnnotation }
            return !clusters.isEmpty
        }
        return clusters.first
    }

    @Test("a map that replaces another is given every pin, and its own opening view")
    func aReplacementMapIsFilledAfresh() {
        let zurich = zurichMarker()
        let oslo = osloMarker()
        let pins = [routedPin(zurich, key: "z"), routedPin(oslo, key: "o")]
        let coordinator = PlacesMapCoordinator()

        // The map the screen started with: every pin installed, and the opening view taken.
        let (firstWindow, first) = hostedMap()
        coordinator.attach(to: first)
        coordinator.show(pins, through: MapViewAnnotationSink(mapView: first))
        coordinator.fitOnce(routedRegion(latitude: 47.37, longitude: 8.54), on: first)
        firstWindow.isHidden = true

        // A failed reload took the map off the screen and Retry put one back: same coordinator,
        // same pins, a map that holds nothing yet.
        let (secondWindow, second) = hostedMap()
        coordinator.attach(to: second)
        coordinator.show(pins, through: MapViewAnnotationSink(mapView: second))
        coordinator.fitOnce(routedRegion(latitude: 59.91, longitude: 10.75), on: second)

        #expect(
            second.annotations.compactMap { ($0 as? PlaceAnnotation)?.pin.spec.key }.sorted()
                == ["o", "z"],
            "the replacement map came up empty, the pins being recorded as already installed"
        )
        #expect(
            abs(second.region.center.latitude - 59.91) < 0.05,
            "the replacement map was never framed, the opening view being recorded as taken"
        )

        // The same map attached again is not a replacement: re-installing every pin would remove
        // and re-add each one, which is the blink the diff exists to prevent.
        let recorder = RecordingSink()
        coordinator.attach(to: second)
        coordinator.show(pins, through: recorder)
        #expect(recorder.calls.isEmpty, "attaching the same map again repainted the whole map")
        secondWindow.isHidden = true
    }

    /// The margin is written out here rather than asked of `PlacePinGeometry`, which is the thing
    /// under test: on a roomy pane, half a square of air on every side, and above it the square
    /// itself, the pointer it stands on and its badge, because a pin is drawn wholly above the
    /// coordinate it marks.
    @Test("the map opens with the outermost pins inside the margin their drawing needs")
    func theOpeningViewLeavesAirAroundTheOutermostPins() {
        let fixtures: [(String, MKCoordinateRegion)] = [
            (
                "wide and shallow, the horizontal axis binding",
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54),
                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 2)
                )
            ),
            (
                "tall and narrow, the vertical axis binding",
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54),
                    span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 0.1)
                )
            ),
        ]
        // The map may show MORE than it was asked for, to fill a pane of another shape, so what is
        // asserted is that no corner lies OUTSIDE the inset frame — never that one sits on it. A
        // point either way is the projection rounding.
        let slack: CGFloat = 1

        for (fixture, box) in fixtures {
            let (window, mapView) = hostedMap()
            let coordinator = PlacesMapCoordinator()
            coordinator.fitOnce(box, on: mapView)
            settle(window)

            for corner in corners(of: box) {
                let point = mapView.convert(corner, toPointTo: mapView)
                #expect(point.x >= 52 - slack, "\(fixture): a pin is cut off on the left")
                #expect(
                    point.x <= mapView.bounds.width - 52 + slack,
                    "\(fixture): a pin is cut off on the right"
                )
                #expect(point.y >= 92 - slack, "\(fixture): a pin is cut off at the top")
                #expect(
                    point.y <= mapView.bounds.height - 26 + slack,
                    "\(fixture): a pin is cut off at the bottom"
                )
            }

            // Containment alone is met by a map of the whole world. On the axis that binds, the
            // box has to reach across most of the frame the margins leave: MapKit widens the OTHER
            // axis to fill the pane, never this one, so the larger of the two shares is the test.
            let points = corners(of: box).map { mapView.convert($0, toPointTo: mapView) }
            let across = points.map(\.x)
            let down = points.map(\.y)
            let reach = max(
                ((across.max() ?? 0) - (across.min() ?? 0)) / (mapView.bounds.width - 52 - 52),
                ((down.max() ?? 0) - (down.min() ?? 0)) / (mapView.bounds.height - 92 - 26)
            )
            #expect(reach >= 0.5, "\(fixture): the map opened far wider than its pins need")
            window.isHidden = true
        }
    }

    @Test("the opening view is taken once, whichever arrives second: the region or the pane")
    func theOpeningViewWaitsForWhicheverArrivesSecond() {
        // The map the screen builds has no size yet, so the region is normally the one that waits.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let coordinator = PlacesMapCoordinator()
        let mapView = MKMapView(frame: .zero)
        mapView.showsUserLocation = false
        let container = PlacesMapContainer(mapView: mapView, coordinator: coordinator)
        coordinator.attach(to: mapView)
        coordinator.fitOnce(routedRegion(latitude: 47.37, longitude: 8.54), on: mapView)
        #expect(!coordinator.hasFitted, "a pane with no size was framed, margin and all")

        container.frame = window.bounds
        window.addSubview(container)
        window.isHidden = false
        settle(window, until: { coordinator.hasFitted })
        #expect(coordinator.hasFitted, "the pane was laid out and the map was never framed")
        #expect(
            abs(mapView.region.center.latitude - 47.37) < 0.5,
            "the map was framed on something other than the region it was given"
        )

        // The reader pans away, and a rotation lays the pane out again: not a second opening view.
        mapView.setCenter(CLLocationCoordinate2D(latitude: 10, longitude: 10), animated: false)
        container.frame = CGRect(x: 0, y: 0, width: 500, height: 390)
        settle(window)
        #expect(
            abs(mapView.region.center.latitude - 10) < 0.5,
            "a later layout pulled the map back to its opening view"
        )
        window.isHidden = true

        // The other order: a map put onto a screen that is already laid out knows its size before
        // anybody tells it what to frame.
        let laidOut = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let second = PlacesMapCoordinator()
        let secondMap = MKMapView(frame: .zero)
        secondMap.showsUserLocation = false
        let secondContainer = PlacesMapContainer(mapView: secondMap, coordinator: second)
        secondContainer.frame = laidOut.bounds
        laidOut.addSubview(secondContainer)
        laidOut.isHidden = false
        settle(laidOut)
        #expect(!second.hasFitted, "a map with nothing to frame yet took its opening view")

        second.fitOnce(routedRegion(latitude: 59.91, longitude: 10.75), on: secondMap)
        #expect(second.hasFitted, "the region reached a laid-out pane and nothing was framed")
        #expect(
            abs(secondMap.region.center.latitude - 59.91) < 0.5,
            "the map was framed on something other than the region it was given"
        )
        laidOut.isHidden = true
    }
}
