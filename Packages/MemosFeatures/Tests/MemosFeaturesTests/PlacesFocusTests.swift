import Foundation
import MapKit
import MemosCore
import Testing
import UIKit

@testable import MemosFeatures

/// MEMNG-869: the Info sheet's Open in Places — a focus request Places accepts, the tab switch it
/// causes, and the map it moves.
@MainActor
private func focusSettle(_ window: UIWindow, until done: () -> Bool = { false }) {
    for _ in 0..<20 {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        if done() { return }
    }
}

private func region(_ latitude: Double, _ longitude: Double) -> MKCoordinateRegion {
    MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))
}

private let lisbon = PlacesFocus.Request(uid: "a", latitude: 38.71, longitude: -9.14)

@MainActor
@Suite("Open in Places")
struct PlacesFocusTests {
    @Test("a pending focus puts the app on Places, and nothing pending changes nothing")
    func routing() {
        #expect(PlacesFocusRouting.tab(showing: .library, whenFocusing: lisbon) == .places)
        #expect(PlacesFocusRouting.tab(showing: .library, whenFocusing: nil) == .library)
    }

    @Test("a request is taken once")
    func takenOnce() {
        let focus = PlacesFocus()
        focus.request(lisbon)
        #expect(focus.take() == lisbon)
        #expect(focus.take() == nil)
        #expect(focus.pending == nil)
    }

    @Test("asking again for the same picture is a new request, and still puts the app on Places")
    func aRepeatedRequestIsAChange() {
        let focus = PlacesFocus()
        focus.request(lisbon)
        let first = focus.pending
        // Places never took the first (its first read had no session to go out on): the same
        // picture asked for again has to be a change, or the tab bar never sees it.
        focus.request(lisbon)
        #expect(focus.pending != first, "the second request was the same value as the first")
        #expect(focus.pending?.request == lisbon)
        let tab = PlacesFocusRouting.tab(showing: .library, whenFocusing: focus.pending?.request)
        #expect(tab == .places)
    }

    @Test("a request made while Places is still loading waits, and lands once the map is there")
    func aRequestWaitsForTheMap() {
        let focus = PlacesFocus()
        focus.request(lisbon)
        #expect(focus.answer(given: .pending) == nil)
        #expect(focus.pending?.request == lisbon, "a request was dropped while Places loaded")
        #expect(focus.answer(given: .ready) == .focus(lisbon))
        #expect(focus.pending == nil, "a request applied once is still pending")
        #expect(focus.declined == nil)
        #expect(focus.answer(given: .ready) == nil, "a request was applied twice")
    }

    @Test(
        "a request Places has no map for is answered with why, never taken in silence",
        arguments: [PlacesStatus.empty, .error])
    func aRequestWithNoMapSaysWhy(_ status: PlacesStatus) throws {
        let focus = PlacesFocus()
        focus.request(lisbon)
        let answer = try #require(focus.answer(given: status), "\(status): no answer")
        guard case .declined(let decline) = answer else {
            Issue.record("\(status): focused a map that is not there")
            return
        }
        #expect(focus.declined == decline, "\(status): the notice is not shown")
        #expect(!decline.message.isEmpty)
        #expect(focus.pending == nil)
        focus.dismissDecline()
        #expect(focus.declined == nil)
        // Control: the same request over a map that is there is taken without a notice.
        focus.request(lisbon)
        #expect(focus.answer(given: .ready) == .focus(lisbon))
        #expect(focus.declined == nil)
    }

    @Test("the two notices say which of the two it is")
    func theNoticesDiffer() {
        let focus = PlacesFocus()
        focus.request(lisbon)
        _ = focus.answer(given: .empty)
        let empty = focus.declined?.message
        focus.request(lisbon)
        _ = focus.answer(given: .error)
        let failed = focus.declined?.message
        #expect(empty != nil && failed != nil && empty != failed)
    }

    @Test("the map centres on the picture's own pin when it holds one, else on the record's place")
    func centrePrefersThePin() {
        let pin = PlaceMarker(
            uid: "a", memoUID: "m", mime: "image/jpeg", mine: true, latitude: 38.72,
            longitude: -9.13, takenAt: Date(timeIntervalSince1970: 0))
        let onPin = PlacesFocusRouting.center(for: lisbon, in: [pin])
        #expect(onPin.latitude == 38.72 && onPin.longitude == -9.13)
        let other = PlaceMarker(
            uid: "b", memoUID: "m", mime: "image/jpeg", mine: true, latitude: 1, longitude: 1,
            takenAt: Date(timeIntervalSince1970: 0))
        let offPin = PlacesFocusRouting.center(for: lisbon, in: [other])
        #expect(offPin.latitude == 38.71 && offPin.longitude == -9.14)
    }

    @Test("the Info sheet asks for its picture at the place its record gives")
    func sheetRequest() {
        let request = MediaInfoRows.placesRequest(
            "a", at: MediaInfoRows.Location(latitude: 38.71, longitude: -9.14))
        #expect(request == lisbon)
    }

    @Test("a focus asked before the opening view lands after it; one asked after moves the map")
    func focusMovesTheMap() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        let coordinator = PlacesMapCoordinator()
        let mapView = MKMapView(frame: .zero)
        mapView.showsUserLocation = false
        let container = PlacesMapContainer(mapView: mapView, coordinator: coordinator)
        coordinator.attach(to: mapView)
        coordinator.fitOnce(region(47.37, 8.54), on: mapView)
        // Before the pane has a size: the opening view has not been taken, so the focus waits.
        coordinator.focus(on: region(38.71, -9.14))
        container.frame = window.bounds
        window.addSubview(container)
        window.isHidden = false
        focusSettle(window, until: { coordinator.hasFitted })
        focusSettle(window)
        #expect(coordinator.hasFitted)
        #expect(
            abs(mapView.region.center.latitude - 38.71) < 0.05,
            "the opening view framed over the focus asked for before it")

        // After the opening view: the map moves at once.
        coordinator.focus(on: region(59.91, 10.75))
        focusSettle(window)
        #expect(
            abs(mapView.region.center.latitude - 59.91) < 0.05,
            "a focus asked for after the opening view did not move the map")
        window.isHidden = true
    }
}
