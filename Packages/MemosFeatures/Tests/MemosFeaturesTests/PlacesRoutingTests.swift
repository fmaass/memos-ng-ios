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
        leadThumbnailURL: nil
    )
}

/// What the coordinator handed out, in order.
@MainActor
private final class RoutedCalls {
    var boxes: [PlaceBBox] = []
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

/// Lets the map get on with it until `until` is true, or until the budget runs out.
@MainActor
private func settle(_ window: UIWindow, until done: () -> Bool = { false }) {
    for _ in 0..<20 {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if done() { return }
    }
}

/// What a map that has settled reports, and where a tap on it goes.
///
/// These cases go through a live `MKMapView`: the region report is the map's own delegate call
/// after a move, and a cluster is an object only MapKit makes — a test that built an
/// `MKClusterAnnotation` itself would be asserting about its own object rather than about the one
/// the screen is handed.
@MainActor
@Suite("What the map reports and where a tap on it goes")
struct PlacesRoutingTests {
    private let zurich = routedMarker(
        uid: "zurich",
        takenAt: "2026-01-01T00:00:00Z",
        latitude: 47.37,
        longitude: 8.54
    )
    private let oslo = routedMarker(
        uid: "oslo",
        takenAt: "2026-01-02T00:00:00Z",
        latitude: 59.91,
        longitude: 10.75
    )

    @Test("a settled map reports what it shows, and a later move replaces that report")
    func aMoveReplacesTheReport() throws {
        let (window, mapView) = hostedMap()
        let coordinator = PlacesMapCoordinator()
        let calls = RoutedCalls()
        coordinator.onRegionChange = { calls.boxes.append($0) }
        mapView.delegate = coordinator
        let markers = [zurich, oslo]

        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 47.37, longitude: 8.54),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ),
            animated: false
        )
        settle(window) { !calls.boxes.isEmpty }
        let first = try #require(calls.boxes.last, "a settled map reported nothing")
        #expect(PlacesPresentation.grid(markers, in: first).map(\.uid) == ["zurich"])

        let seen = calls.boxes.count
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 59.91, longitude: 10.75),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ),
            animated: false
        )
        settle(window) { calls.boxes.count > seen }
        let second = try #require(calls.boxes.last)
        #expect(
            PlacesPresentation.grid(markers, in: second).map(\.uid) == ["oslo"],
            "the grid still holds what the map was showing before it was moved"
        )
        window.isHidden = true
    }

    @Test("a tap on a pin opens its photograph, and a second tap opens it again")
    func aTapOnAPinOpensItsPhotograph() throws {
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
}
