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

    /// No views behind this sink, so nothing it holds is waiting for a picture — which leaves the
    /// cases that use it recording exactly what the diff decided, and nothing else.
    func isAwaitingPhotograph(_ annotation: PlaceAnnotation) -> Bool { false }
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

    @Test("a pin that did not change takes the fresh load's thumbnail without being repainted")
    func anUnchangedPinTakesTheNewThumbnail() throws {
        let coordinator = PlacesMapCoordinator()
        let sink = RecordingSink()
        let first = URL(string: "https://memos.example.invalid/a/thumb?exp=1&sig=one")!
        let second = URL(string: "https://memos.example.invalid/a/thumb?exp=2&sig=two")!

        coordinator.show([placePin(key: "a", thumbnail: first)], through: sink)
        coordinator.show([placePin(key: "a", thumbnail: second)], through: sink)

        // One call in all: a URL the pin has not seen is not by itself a reason to repaint, and a
        // repaint would take the picture a loaded pin is showing away from it whenever the decoded
        // entry behind it had been dropped.
        #expect(sink.calls == [.add(["a"])])
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

/// The sink with a view behind it: what the production one does, minus the map.
///
/// `RecordingSink` above says which change the coordinator decided on, which is all the cases up
/// there need. A case about what the PIN then asks the loader for needs the other half — a real
/// `PlacePinView` per key, configured on a refresh exactly as `MapViewAnnotationSink` configures
/// the view MapKit holds.
@MainActor
final class PinViewSink: AnnotationSink {
    private(set) var refreshed: [String] = []
    private(set) var views: [String: PlacePinView] = [:]

    func add(_ annotations: [PlaceAnnotation]) {
        for annotation in annotations {
            // Built empty and then given its annotation, because that asks for the photograph
            // exactly once: a view built AROUND its annotation configures twice, once through the
            // property and once in the initialiser, and a count of requests could not tell that
            // apart from a retry.
            let view = PlacePinView(annotation: nil, reuseIdentifier: "place")
            view.annotation = annotation
            views[annotation.pin.spec.key] = view
        }
    }

    func remove(_ annotations: [PlaceAnnotation]) {
        for annotation in annotations { views.removeValue(forKey: annotation.pin.spec.key) }
    }

    func refresh(_ annotation: PlaceAnnotation) {
        refreshed.append(annotation.pin.spec.key)
        views[annotation.pin.spec.key]?.configure()
    }

    /// The real view's own answer, as the production sink asks it of the view MapKit holds.
    func isAwaitingPhotograph(_ annotation: PlaceAnnotation) -> Bool {
        views[annotation.pin.spec.key]?.isAwaitingPhotograph ?? false
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

    /// The grey square that stays grey. The pin's specs are identical across the reload — same
    /// place, same photographs — so no diff bucket holds it, and here the thumbnail comes back
    /// signed afresh. What gets it asked again is its view: showing nothing, with no request out.
    /// Without that repaint the failure lasts until MapKit happens to rebuild the view.
    @Test("a pin whose photograph never arrived is asked for it again on the next read")
    func aPinThatFetchedNothingIsAskedAgain() async {
        let transport = RefusingTransport()
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-retry"
            let first = MediaFixture.signed(uid: uid, sig: "one")
            let second = MediaFixture.signed(uid: uid, sig: "two")

            coordinator.show([placePin(key: "retry", uid: uid, thumbnail: first)], through: sink)
            await sink.views["retry"]?.loading?.value
            let askedAtMount = await transport.calls
            #expect(askedAtMount == 1, "the pin asked for its photograph once and no more")
            #expect(sink.views["retry"]?.shownImage == nil, "the fetch was supposed to fail")

            // The reload a recovery already performs: the same pin, a freshly signed URL.
            coordinator.show([placePin(key: "retry", uid: uid, thumbnail: second)], through: sink)
            await sink.views["retry"]?.loading?.value
            let askedAfterReload = await transport.calls

            #expect(sink.refreshed == ["retry"], "the pin was left holding its failure")
            #expect(askedAfterReload == 2, "the grey square was never asked about again")
        }
    }

    /// The other half of the same rule, and the reason the repaint is free: a pin that HAS its
    /// photograph reads it back out of the decoded cache, which is keyed on the uid and so survives
    /// the re-signing. No second request, and nothing blinks.
    @Test("a pin already showing its photograph is not sent back to the network by a reload")
    func aLoadedPinIsNotFetchedTwice() async {
        let transport = ScriptedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-loaded"
            let first = MediaFixture.signed(uid: uid, sig: "one")
            let second = MediaFixture.signed(uid: uid, sig: "two")

            coordinator.show([placePin(key: "loaded", uid: uid, thumbnail: first)], through: sink)
            await sink.views["loaded"]?.loading?.value
            let painted = sink.views["loaded"]?.shownImage
            #expect(painted != nil, "the pin was supposed to be holding a photograph")

            coordinator.show([placePin(key: "loaded", uid: uid, thumbnail: second)], through: sink)
            await sink.views["loaded"]?.loading?.value
            let askedInAll = await transport.calls

            #expect(askedInAll == 1, "a photograph in hand was fetched a second time")
            #expect(
                sink.views["loaded"]?.shownImage === painted,
                "the pin dropped the picture it was showing and blinked"
            )
        }
    }

    /// The same grey square, in the case it usually comes from: the connection dropped and the
    /// read a minute later brought the URL back unchanged — a signed URL can be minted identically
    /// for a while, so a new signature is a hint that the picture is worth asking for and never a
    /// condition. Nothing about the pin changed at all here; only what its view is showing can say
    /// the photograph is still owed.
    @Test("a pin whose photograph never arrived is asked again even for the same URL")
    func aPinThatFetchedNothingIsAskedAgainForTheSameURL() async {
        let transport = RecoveringTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-same-url"
            let pin = placePin(key: "same", uid: uid, thumbnail: MediaFixture.signed(uid: uid))

            coordinator.show([pin], through: sink)
            await sink.views["same"]?.loading?.value
            #expect(sink.views["same"]?.shownImage == nil, "the first fetch was supposed to fail")

            // The recovery read: identical specs, the identical URL.
            coordinator.show([pin], through: sink)
            await sink.views["same"]?.loading?.value
            let askedAfterReload = await transport.calls

            #expect(askedAfterReload == 2, "the grey square was never asked about again")
            #expect(
                sink.views["same"]?.shownImage != nil,
                "the photograph was there for the asking and the pin stayed grey"
            )
        }
    }

    /// The other half of the same URL coming back: a pin that HAS its photograph is not asked
    /// about at all. The map does not repaint it, so there is no request to answer and no moment
    /// where the picture it is showing is taken away.
    @Test("a pin already showing its photograph is left alone when the same URL comes back")
    func aLoadedPinIsUntouchedByTheSameURL() async {
        let transport = ScriptedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-held"
            let pin = placePin(key: "held", uid: uid, thumbnail: MediaFixture.signed(uid: uid))

            coordinator.show([pin], through: sink)
            await sink.views["held"]?.loading?.value
            let painted = sink.views["held"]?.shownImage
            #expect(painted != nil, "the pin was supposed to be holding a photograph")

            coordinator.show([pin], through: sink)
            await sink.views["held"]?.loading?.value
            let askedInAll = await transport.calls

            #expect(askedInAll == 1, "a photograph in hand was fetched a second time")
            #expect(
                sink.views["held"]?.shownImage === painted,
                "the pin dropped the picture it was showing and blinked"
            )
            #expect(sink.refreshed.isEmpty, "a pin holding its photograph was repainted")
        }
    }

    /// A map pass lands whenever the screen is re-evaluated, and one can arrive while the pin's
    /// first request is still unanswered. Such a pin is showing nothing but is owed nothing: the
    /// answer is on its way, and asking again — for the same URL or for a freshly signed one —
    /// would put the same bytes on the wire twice and blank the pin in the meantime.
    @Test("a pin with a request already out is not asked a second time")
    func aPinWithAFetchInFlightIsNotAskedAgain() async {
        let transport = GatedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-in-flight"
            let first = MediaFixture.signed(uid: uid, sig: "one")
            let second = MediaFixture.signed(uid: uid, sig: "two")

            coordinator.show([placePin(key: "flight", uid: uid, thumbnail: first)], through: sink)
            await transport.waitUntilStarted()

            // A read bringing the URL back unchanged, while the request is still out.
            coordinator.show([placePin(key: "flight", uid: uid, thumbnail: first)], through: sink)
            #expect(sink.refreshed.isEmpty, "a pin whose request was still out was repainted")

            // And a read that DOES repaint it: one photograph more at the same place puts the pin
            // in the diff's updated bucket, where the repaint is unconditional, with a freshly
            // signed URL and the first request still out.
            coordinator.show(
                [placePin(key: "flight", uid: uid, count: 2, thumbnail: second)],
                through: sink
            )

            await transport.release()
            await sink.views["flight"]?.loading?.value
            let askedInAll = await transport.requests.count

            #expect(
                askedInAll == 1,
                "a second request went out for a photograph already on the wire"
            )
            #expect(
                sink.views["flight"]?.shownImage != nil,
                "the answer already on its way was never painted"
            )
        }
    }

    /// The decoded picture a pin is showing outlives its cache entry: the store drops entries
    /// under memory pressure, and the view keeps the `UIImage` it was handed. A read that brings a
    /// freshly signed URL must not take that picture away — a repaint would find nothing cached,
    /// blank the pin and go back to the network, which is a blink when the fetch succeeds and a
    /// grey square when it does not.
    @Test("a pin keeps the photograph it is showing when its cache entry is gone")
    func aLoadedPinKeepsItsPictureWhenTheCacheEntryIsGone() async {
        let transport = ScriptedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-evicted"
            let first = MediaFixture.signed(uid: uid, sig: "one")
            let second = MediaFixture.signed(uid: uid, sig: "two")

            coordinator.show([placePin(key: "evicted", uid: uid, thumbnail: first)], through: sink)
            await sink.views["evicted"]?.loading?.value
            let painted = sink.views["evicted"]?.shownImage
            #expect(painted != nil, "the pin was supposed to be holding a photograph")

            MediaImageLoader.store.remove(
                forKey: MediaImageKey(uid: uid, tier: MediaTier.thumb.rawValue)
            )

            coordinator.show([placePin(key: "evicted", uid: uid, thumbnail: second)], through: sink)
            await sink.views["evicted"]?.loading?.value
            let askedInAll = await transport.calls

            #expect(sink.refreshed.isEmpty, "a pin holding its photograph was repainted")
            #expect(askedInAll == 1, "a photograph in hand was fetched a second time")
            #expect(
                sink.views["evicted"]?.shownImage === painted,
                "the pin dropped the picture it was showing and blinked"
            )
        }
    }

    /// Two requests from one view, ending in the wrong order. MapKit takes a view back and hands
    /// it out again for the same pin: the first request is cancelled and a second goes out for the
    /// same photograph. When the cancelled one finally ends it must not be taken for the one still
    /// out — a view that has forgotten its live request looks, to the next map pass, exactly like
    /// a pin owed a picture, and the pass puts a duplicate on the wire.
    @Test("a cancelled request does not clear the marker of the one still out")
    func aRemadeRequestSurvivesTheCancelledOneEnding() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let coordinator = PlacesMapCoordinator()
            let sink = PinViewSink()
            let uid = "place-reused"
            let pin = placePin(key: "reused", uid: uid, thumbnail: MediaFixture.signed(uid: uid))

            coordinator.show([pin], through: sink)
            await transport.waitUntilStarted(1)
            let view = sink.views["reused"]
            let cancelled = view?.loading

            // Recycled and handed the same pin again: everything the view held goes, and the
            // annotation assignment asks for the photograph afresh.
            let held = view?.annotation
            view?.prepareForReuse()
            view?.annotation = held
            await transport.waitUntilStarted(2)

            // Now the cancelled one ends, with nothing to show for it.
            await transport.release(1, refusing: true)
            await cancelled?.value

            #expect(
                view?.isAwaitingPhotograph == false,
                "the view forgot the request it still has out"
            )

            // And the next map pass, which is where forgetting it would cost something. What the
            // pass decided is read synchronously; the request count is read once the view's task
            // has finished, so a request it started has certainly reached the transport.
            coordinator.show([pin], through: sink)
            #expect(sink.refreshed.isEmpty, "the pass repainted a pin whose request was still out")

            await transport.releaseAll()
            await view?.loading?.value
            let askedInAll = await transport.calls
            #expect(askedInAll == 2, "a duplicate request went out for a photograph on the wire")
        }
    }
}
