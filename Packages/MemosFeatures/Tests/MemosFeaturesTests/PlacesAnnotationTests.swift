import Foundation
import MapKit
import MemosCore
import Testing
import UIKit

@testable import MemosFeatures

/// One pin, varying only what a case reads. No thumbnail by default: a pin with a URL would send
/// the annotation view to the process-wide image loader, and everything that touches that loader
/// belongs in its own serialized suite (below).
private func placePin(
    key: String,
    uid: String? = nil,
    count: Int = 1,
    latitude: Double = 47.2,
    longitude: Double = 8.4,
    uids: [String]? = nil,
    takenAt: String = "2026-01-01T00:00:00Z",
    thumbnail: URL? = nil
) -> PlacePin {
    let lead = uid ?? key
    return PlacePin(
        spec: PinSpec(
            key: key,
            latitude: latitude,
            longitude: longitude,
            count: count,
            uid: lead,
            uids: uids ?? [lead]
        ),
        leadTakenAt: ISO8601DateFormatter().date(from: takenAt)!,
        leadThumbnailURL: thumbnail
    )
}

/// Every call the coordinator made, in order.
///
/// The seam is recorded rather than a map inspected because the rules under test are about WHICH
/// change a new set of pins is — a map can only say what it ended up holding, which is the same
/// after a repaint and after a remove-and-re-add.
@MainActor
final class RecordingSink: AnnotationSink {
    enum Call: Equatable {
        case add([String])
        case remove([String])
        case refresh(String)
    }

    private(set) var calls: [Call] = []
    private(set) var added: [PlaceAnnotation] = []
    /// The objects, not their keys: whether a repaint kept the annotation MapKit already holds is
    /// a question about identity.
    private(set) var refreshed: [PlaceAnnotation] = []

    func add(_ annotations: [PlaceAnnotation]) {
        added.append(contentsOf: annotations)
        calls.append(.add(annotations.map(\.pin.spec.key)))
    }

    func remove(_ annotations: [PlaceAnnotation]) {
        calls.append(.remove(annotations.map(\.pin.spec.key)))
    }

    func refresh(_ annotation: PlaceAnnotation) {
        refreshed.append(annotation)
        calls.append(.refresh(annotation.pin.spec.key))
    }
}

@MainActor
@Suite("Places annotations")
struct PlacesAnnotationTests {
    @Test("the first pins to arrive are one addition and nothing else")
    func firstPinsAreOneAdd() {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()

        coordinator.show([placePin(key: "a"), placePin(key: "b", longitude: 8.6)], through: sink)

        #expect(sink.calls == [.add(["a", "b"])])
        #expect(sink.added.count == 2)
        #expect(sink.added.first?.coordinate.latitude == 47.2)
    }

    @Test("a coordinate that lost its last photograph is removed, and nothing else is touched")
    func aDroppedKeyIsOneRemove() {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()
        let a = placePin(key: "a")

        coordinator.show([a, placePin(key: "b", longitude: 8.6)], through: sink)
        coordinator.show([a], through: sink)

        #expect(sink.calls == [.add(["a", "b"]), .remove(["b"])])
    }

    @Test("a pin whose photographs changed is repainted in place, never removed and rebuilt")
    func aChangedPinIsRefreshedInPlace() throws {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()

        coordinator.show([placePin(key: "a", uid: "one", uids: ["one"])], through: sink)
        coordinator.show(
            [placePin(key: "a", uid: "two", count: 2, uids: ["two", "one"])],
            through: sink
        )

        #expect(sink.calls == [.add(["a"]), .refresh("a")])
        let born = try #require(sink.added.first)
        let repainted = try #require(sink.refreshed.first)
        #expect(
            repainted === born,
            "a rebuilt annotation costs the view its thumbnail and makes the pin blink"
        )
        #expect(repainted.pin.spec.count == 2, "the object was handed to the sink still stale")
        #expect(repainted.pin.spec.uid == "two")
    }

    @Test("a pin that did not change produces no call at all")
    func anUnchangedPinIsSilent() {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()
        let a = placePin(key: "a")

        coordinator.show([a], through: sink)
        let afterFirst = sink.calls
        coordinator.show([a], through: sink)

        #expect(sink.calls == afterFirst)
        #expect(sink.calls == [.add(["a"])])
    }

    @Test("a pin that moved carries its new coordinate on the object the map already holds")
    func aMovedPinKeepsItsObject() throws {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()

        coordinator.show([placePin(key: "a", latitude: 47.2)], through: sink)
        coordinator.show([placePin(key: "a", latitude: 47.5)], through: sink)

        let born = try #require(sink.added.first)
        #expect(sink.refreshed.first === born)
        #expect(born.coordinate.latitude == 47.5, "the map learns a move through this property")
    }

    @Test("a pin that did not change still takes the fresh load's thumbnail")
    func anUnchangedPinTakesTheNewThumbnail() throws {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()
        let first = URL(string: "https://memos.example.invalid/a/thumb?exp=1&sig=one")!
        let second = URL(string: "https://memos.example.invalid/a/thumb?exp=2&sig=two")!

        coordinator.show([placePin(key: "a", thumbnail: first)], through: sink)
        let afterFirst = sink.calls
        coordinator.show([placePin(key: "a", thumbnail: second)], through: sink)

        #expect(sink.calls == afterFirst, "an unchanged pin needs no repaint to hold a new URL")
        #expect(sink.added.count == 1, "the pin was rebuilt rather than handed the new URL")
        let born = try #require(sink.added.first)
        #expect(
            born.pin.leadThumbnailURL == second,
            "the annotation kept a signature that lapses while a live one was thrown away"
        )
    }

    /// The one case that needs a live `MKMapView`: everything above is about which change the
    /// coordinator decided on, and this is about the production sink actually performing it.
    ///
    /// The map is built headless, with no window and no location services, and the basemap it
    /// paints is whatever the simulator could fetch — none of which the assertions read. What they
    /// read is the annotation set and the region, which are the map's own state.
    @Test("the production sink puts what the coordinator decided on a real map")
    func theProductionSinkForwardsToALiveMap() {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        mapView.showsUserLocation = false
        let coordinator = PlacesMapCoordinator()
        let sink = MapViewAnnotationSink(mapView: mapView)

        coordinator.show(
            [
                placePin(key: "a", latitude: 47.0, longitude: 8.0),
                placePin(key: "b", latitude: 47.4, longitude: 8.6),
            ],
            through: sink
        )
        let bothKeys = mapView.annotations.compactMap { ($0 as? PlaceAnnotation)?.pin.spec.key }
        #expect(Set(bothKeys) == ["a", "b"])

        coordinator.show([placePin(key: "a", latitude: 47.0, longitude: 8.0)], through: sink)
        #expect(mapView.annotations.compactMap { ($0 as? PlaceAnnotation)?.pin.spec.key } == ["a"])

        coordinator.fitOnce(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 47.2, longitude: 8.3),
                span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.6)
            ),
            on: mapView
        )
        #expect(abs(mapView.region.center.latitude - 47.2) < 0.05)
        #expect(abs(mapView.region.center.longitude - 8.3) < 0.05)

        // Once. A later fit is the map pulling itself back from wherever the reader had just
        // panned it to, so the second call must leave the map where it is.
        coordinator.fitOnce(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 10, longitude: 10),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            ),
            on: mapView
        )
        #expect(abs(mapView.region.center.latitude - 47.2) < 0.05)

        let picture = UIGraphicsImageRenderer(bounds: mapView.bounds).image { context in
            mapView.layer.render(in: context.cgContext)
        }
        if let png = picture.pngData() {
            Attachment.record(png, named: "places-map.png")
        }
    }
}

/// The pin view's two fences, declared where the loader's own tests live.
///
/// `MediaImageLoader.store` and `.transport` are process-wide and suites run in parallel, so an
/// assertion about what the loader answered is only exact inside the suite that owns them — which
/// is why that suite is `.serialized` and why everything touching the loader is declared in it.
/// A test in an extension is a test of that suite: it inherits the isolation, the serialisation
/// and the fresh store the suite's `init()` installs on its own identity.
extension MediaImageLoaderTests {
    @Test("a photograph that arrives after its view was handed another pin is never painted")
    func aRecycledPinViewRefusesALateAnswer() async {
        let transport = GatedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let laterImage = UIImage(data: MediaFixture.png(.blue))!
            MediaImageLoader.store.store(
                laterImage,
                forKey: MediaImageKey(uid: "place-late", tier: MediaTier.thumb.rawValue),
                generation: MediaImageLoader.store.generation
            )

            let view = PlacePinView(
                annotation: PlaceAnnotation(
                    pin: placePin(
                        key: "early",
                        uid: "place-early",
                        thumbnail: MediaFixture.signed(uid: "place-early")
                    )
                ),
                reuseIdentifier: "place"
            )
            await transport.waitUntilStarted()

            // The map hands a recycled view the pin it stands for now, while the photograph it
            // asked for on behalf of the previous one is still on the wire.
            view.annotation = PlaceAnnotation(
                pin: placePin(
                    key: "late",
                    uid: "place-late",
                    thumbnail: MediaFixture.signed(uid: "place-late")
                )
            )
            #expect(
                view.shownImage === laterImage,
                "an already-decoded photograph is painted with nothing awaited"
            )

            await transport.release()
            await view.loading?.value

            #expect(
                view.shownImage === laterImage,
                "the first pin's photograph landed on the pin this view now stands for"
            )
        }
    }

    @Test("a pin refuses a decoded photograph whose signature has lapsed")
    func aPinViewDropsAPictureWhoseSignatureLapsed() async {
        let transport = RefusingTransport()
        await withTransport(transport) {
            let key = MediaImageKey(uid: "place-lapsed", tier: MediaTier.thumb.rawValue)
            let cached = UIImage(data: MediaFixture.png(.red))!
            MediaImageLoader.store.store(
                cached, forKey: key, generation: MediaImageLoader.store.generation
            )
            // It really is there beforehand, or the assertions below say nothing.
            #expect(MediaImageLoader.cachedUIImage(for: key) === cached)

            let view = PlacePinView(
                annotation: PlaceAnnotation(
                    pin: placePin(
                        key: "lapsed",
                        uid: "place-lapsed",
                        // Long past whatever clock the simulator runs on.
                        thumbnail: MediaFixture.signed(uid: "place-lapsed", exp: 1)
                    )
                ),
                reuseIdentifier: "place"
            )

            #expect(
                view.shownImage == nil,
                "a pin painted a photograph the URL it holds can no longer authorise"
            )
            #expect(
                MediaImageLoader.cachedUIImage(for: key) == nil,
                "the decoded picture survived the lapse and paints on the next mount"
            )
            await view.loading?.value
        }
    }

    @Test("a thumbnail asked for by one account is never fetched for the next")
    func aQueuedPinFetchIsAbandonedAcrossARotation() async {
        let transport = ScriptedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let key = MediaImageKey(uid: "place-queued", tier: MediaTier.thumb.rawValue)
            let view = PlacePinView(
                annotation: PlaceAnnotation(
                    pin: placePin(
                        key: "queued",
                        uid: "place-queued",
                        thumbnail: MediaFixture.signed(uid: "place-queued")
                    )
                ),
                reuseIdentifier: "place"
            )

            // Nothing has been awaited since the view read the generation, so the fetch it queued
            // cannot have begun — and the device is somebody else before it can.
            identity.rotate()
            await view.loading?.value

            #expect(
                await transport.calls == 0,
                "a URL the previous account signed was fetched for the one signed in now"
            )
            #expect(
                MediaImageLoader.cachedUIImage(for: key) == nil,
                "the previous account's photograph was filed under this account's number"
            )
            #expect(view.shownImage == nil)
        }
    }

    @Test("a photograph fetched for an account since signed out of is never painted")
    func aPinViewPaintsNothingAcrossARotation() async {
        let transport = GatedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let view = PlacePinView(
                annotation: PlaceAnnotation(
                    pin: placePin(
                        key: "rotated",
                        uid: "place-rotated",
                        thumbnail: MediaFixture.signed(uid: "place-rotated")
                    )
                ),
                reuseIdentifier: "place"
            )
            await transport.waitUntilStarted()

            // The device is somebody else now, mid-fetch.
            identity.rotate()
            await transport.release()
            await view.loading?.value

            // Two lines refuse it and the case holds both: the loader files the answer under the
            // generation that asked for it and hands back nothing, and the view compares the
            // generation it read before the await with the one in force after it.
            #expect(
                view.shownImage == nil,
                "a photograph belonging to the previous account was painted on a pin"
            )
        }
    }
}
