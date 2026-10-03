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
        leadImageURL: thumbnail
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
            born.pin.leadImageURL == second,
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
        // WHERE the map was framed is asserted on a map that is on a screen, where a coordinate
        // can be converted to a point and the margin around the outermost pins can be measured.
        // Here the opening view is only captured, as the thing a second fit must not move.
        let opened = mapView.region

        // Once. A later fit is the map pulling itself back from wherever the reader had just
        // panned it to, so the second call must leave the map where it is.
        coordinator.fitOnce(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 10, longitude: 10),
                span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
            ),
            on: mapView
        )
        #expect(mapView.region.center.latitude == opened.center.latitude)
        #expect(mapView.region.center.longitude == opened.center.longitude)
        #expect(mapView.region.span.latitudeDelta == opened.span.latitudeDelta)

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
            // Built empty and then given its annotation, the way the production sink meets the
            // view MapKit hands it: the view exists first and learns what it stands for after.
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
            // pass decided is read synchronously; the count is read once the request still out has
            // ended, so the third request a forgotten marker would have caused would have reached
            // the transport by then — and the count says there is no third.
            coordinator.show([pin], through: sink)
            #expect(sink.refreshed.isEmpty, "the pass repainted a pin whose request was still out")

            await transport.releaseAll()
            await view?.loading?.value
            let askedInAll = await transport.calls
            #expect(askedInAll == 2, "a duplicate request went out for a photograph on the wire")
        }
    }

    /// The same two requests, ending in the same wrong order, and what the LAST fence must decide.
    /// Both of them are for the same photograph, so the key the view asked for says nothing: when
    /// the replaced request ends with nothing to show, `requested == key` still holds, and painting
    /// its empty answer takes down the picture the request still out has already put up.
    @Test("a photograph on screen survives the request it replaced ending with nothing")
    func aPaintedPhotographSurvivesTheReplacedRequestEnding() async {
        let transport = HeldTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let uid = "place-repainted"
            let view = PlacePinView(
                annotation: PlaceAnnotation(
                    pin: placePin(
                        key: "repainted",
                        uid: uid,
                        thumbnail: MediaFixture.signed(uid: uid)
                    )
                ),
                reuseIdentifier: "place"
            )
            await transport.waitUntilStarted(1)
            let replaced = view.loading

            // Recycled and handed the same pin again: the first request is cancelled and a second
            // goes out for the very same photograph.
            let held = view.annotation
            view.prepareForReuse()
            view.annotation = held
            await transport.waitUntilStarted(2)

            // The request still out answers, and the pin wears its photograph.
            await transport.release(2)
            await view.loading?.value
            let painted = view.shownImage
            #expect(painted != nil, "the request still out never painted what it fetched")

            // And only then the cancelled one ends, with nothing.
            await transport.release(1, refusing: true)
            await replaced?.value

            #expect(
                view.shownImage === painted,
                "the replaced request's empty answer blanked the pin that was showing its photo"
            )
        }
    }

    /// A view built AROUND its annotation learns what it stands for twice: once in the initialiser
    /// and once through the property that initialiser sets. Both calls are kept, because the second
    /// ask never reaches the wire — a request for the same photograph is already out, and `show`
    /// returns on it. This case is what says so, and it holds whether or not the fences change.
    @Test("a view built around its annotation asks for its photograph once")
    func aViewBuiltAroundItsAnnotationAsksOnce() async {
        let transport = GatedTransport(payload: MediaFixture.png(.red))
        await withTransport(transport) {
            let uid = "place-built"
            let view = PlacePinView(
                annotation: PlaceAnnotation(
                    pin: placePin(key: "built", uid: uid, thumbnail: MediaFixture.signed(uid: uid))
                ),
                reuseIdentifier: "place"
            )
            await transport.waitUntilStarted()
            await transport.release()
            await view.loading?.value
            let askedInAll = await transport.requests.count

            #expect(
                askedInAll == 1,
                "a freshly built view put the same photograph on the wire twice"
            )
        }
    }

    /// What the two views say to VoiceOver, asserted where each one learns what it stands for. The
    /// sentence itself is pinned in the presentation suite; what a VIEW has to get right is which
    /// numbers go into it — a cluster speaks the photographs its badge counts, never how many pins
    /// it swallowed, and the date it names is the one whose picture it wears.
    @Test("a pin and a cluster each say how many photographs stand behind them")
    func annotationViewsSpeakWhatTheyStandFor() {
        let lone = placePin(key: "lone", takenAt: "2026-09-12T10:00:00Z")
        let loneView = PlacePinView(
            annotation: PlaceAnnotation(pin: lone), reuseIdentifier: "place"
        )
        #expect(
            loneView.accessibilityLabel
                == PlacesPresentation.spokenLabel(photographs: 1, newest: lone.leadTakenAt)
        )

        let group = placePin(key: "group", count: 3, takenAt: "2026-09-12T10:00:00Z")
        let groupView = PlacePinView(
            annotation: PlaceAnnotation(pin: group), reuseIdentifier: "place"
        )
        #expect(
            groupView.accessibilityLabel
                == PlacesPresentation.spokenLabel(photographs: 3, newest: group.leadTakenAt),
            "a pin holding several photographs says something other than a cluster of that size"
        )

        // Two member pins, of three photographs and four, taken on different days.
        let older = placePin(key: "older", count: 3, takenAt: "2026-09-10T10:00:00Z")
        let newer = placePin(key: "newer", count: 4, takenAt: "2026-09-12T10:00:00Z")
        let clusterView = PlaceClusterView(
            annotation: MKClusterAnnotation(memberAnnotations: [
                PlaceAnnotation(pin: older), PlaceAnnotation(pin: newer),
            ]),
            reuseIdentifier: "cluster"
        )
        #expect(
            clusterView.accessibilityLabel
                == PlacesPresentation.spokenLabel(photographs: 7, newest: newer.leadTakenAt),
            "a cluster counted the pins it swallowed instead of the photographs behind them"
        )
    }

    /// What a pin is drawn as, for a lone pin, a pin holding several photographs and a cluster.
    /// The numbers are written out rather than asked of `PlacePinGeometry`, which is the thing
    /// under test: a 52-point square on an 8-point pointer, the view lifted by half its height so
    /// the pointer's TIP is the point MapKit puts on the coordinate.
    @Test("a pin and a cluster stand on a pointer whose tip is the place they mark")
    func pinViewsStandOnAPointerTippedOnTheirPlace() throws {
        for (kind, view, badge) in pinViewsOfEveryKind() {
            #expect(
                view.bounds.size == CGSize(width: 52, height: 60),
                "\(kind): the view is not the square plus its pointer"
            )
            #expect(
                view.photoFrame == CGRect(x: 0, y: 0, width: 52, height: 52),
                "\(kind): the photograph left the top square"
            )
            #expect(view.centerOffset == CGPoint(x: 0, y: -30), "\(kind): the view is not lifted")
            #expect(
                view.centerOffset.y == -view.bounds.height / 2,
                "\(kind): the coordinate is not at the bottom of the drawing"
            )

            let corners = try outline(of: #require(view.pointerPath, "\(kind): no pointer"))
            let tip = corners.max { $0.y < $1.y }
            #expect(
                tip == CGPoint(x: view.bounds.midX, y: view.bounds.maxY),
                "\(kind): the pointer's tip is not where the coordinate is"
            )
            #expect(
                corners.filter { $0.y == 52 }.map(\.x).sorted() == [17, 35],
                "\(kind): the pointer does not leave the square 18 points wide, centred"
            )
            #expect(view.badgeText == badge, "\(kind): the badge changed with the drawing")
        }
    }

    /// The frame and the pointer are the photograph's white mount in either appearance — a
    /// CGColor taken from a dynamic colour is frozen in the appearance current when the view was
    /// built, which is how the frame used to be black in dark mode. Each kind is built under each
    /// appearance, captured inside a padded window of that appearance (the badge reaches 6 points
    /// above the view), and then the window's appearance is flipped under it.
    @Test("a pin's frame and pointer are white in light and dark, and stay white when it flips")
    func pinViewsWearAWhiteFrameInEitherAppearance() {
        let pictures: [(String, UIColor)] = [
            ("pin-single", .systemOrange), ("pin-counted", .systemTeal),
            ("pin-older", .systemPink), ("pin-newer", .systemIndigo),
        ]
        for (uid, color) in pictures {
            MediaImageLoader.store.store(
                UIImage(data: MediaFixture.png(color, side: 52))!,
                forKey: MediaImageKey(uid: uid, tier: MediaTier.thumb.rawValue),
                generation: MediaImageLoader.store.generation
            )
        }

        let appearances: [(UIUserInterfaceStyle, String)] = [(.light, "light"), (.dark, "dark")]
        for (style, name) in appearances {
            var views: [(String, PlaceAnnotationView, String?)] = []
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                views = pinViewsOfEveryKind()
            }
            let pad: CGFloat = 24
            let cell = CGSize(width: 52 + 2 * pad, height: 60 + 2 * pad)
            let window = UIWindow(
                frame: CGRect(x: 0, y: 0, width: cell.width * 3, height: cell.height)
            )
            window.overrideUserInterfaceStyle = style
            var containers: [UIView] = []
            for (index, (_, view, _)) in views.enumerated() {
                let container = UIView(
                    frame: CGRect(
                        origin: CGPoint(x: CGFloat(index) * cell.width, y: 0),
                        size: cell
                    )
                )
                container.backgroundColor = .systemGray4
                view.frame.origin = CGPoint(x: pad, y: pad)
                container.addSubview(view)
                window.addSubview(container)
                containers.append(container)
            }
            window.isHidden = false
            window.layoutIfNeeded()

            for ((kind, view, _), container) in zip(views, containers) {
                #expect(view.shownImage != nil, "\(kind): captured without its photograph")
                #expect(view.photoBorderWidth == 3, "\(kind) (\(name)): the frame is not 3 points")
                #expect(isWhite(view.photoBorderColor), "\(kind) built \(name): frame not white")
                #expect(isWhite(view.pointerFill), "\(kind) built \(name): pointer not white")
                let picture = UIGraphicsImageRenderer(bounds: container.bounds).image { context in
                    container.layer.render(in: context.cgContext)
                }
                if let png = picture.pngData() {
                    Attachment.record(png, named: "places-\(kind)-\(name).png")
                }
            }

            // The appearance changes under views that already exist.
            let flipped: UIUserInterfaceStyle = style == .light ? .dark : .light
            window.overrideUserInterfaceStyle = flipped
            window.layoutIfNeeded()
            for (kind, view, _) in views {
                #expect(view.traitCollection.userInterfaceStyle == flipped, "\(kind): no flip")
                #expect(isWhite(view.photoBorderColor), "\(kind) flipped from \(name): not white")
                #expect(isWhite(view.pointerFill), "\(kind) flipped from \(name): not white")
            }
            window.isHidden = true
        }
    }
}

/// One view of each kind a map draws, with the badge each one has always carried: a lone pin
/// none, a pin of three photographs "3", a cluster of pins of three and four photographs "7".
/// Without thumbnail URLs, so a view paints only what the loader's cache already holds.
@MainActor
private func pinViewsOfEveryKind() -> [(String, PlaceAnnotationView, String?)] {
    let single = PlacePinView(
        annotation: PlaceAnnotation(pin: placePin(key: "single", uid: "pin-single")),
        reuseIdentifier: "place"
    )
    let counted = PlacePinView(
        annotation: PlaceAnnotation(pin: placePin(key: "counted", uid: "pin-counted", count: 3)),
        reuseIdentifier: "place"
    )
    let cluster = PlaceClusterView(
        annotation: MKClusterAnnotation(memberAnnotations: [
            PlaceAnnotation(
                pin: placePin(
                    key: "older", uid: "pin-older", count: 3, takenAt: "2026-09-10T10:00:00Z"
                )
            ),
            PlaceAnnotation(
                pin: placePin(
                    key: "newer", uid: "pin-newer", count: 4, takenAt: "2026-09-12T10:00:00Z"
                )
            ),
        ]),
        reuseIdentifier: "cluster"
    )
    return [("single", single, nil), ("counted", counted, "3"), ("cluster", cluster, "7")]
}

/// The corners an outline passes through, in order.
private func outline(of path: CGPath) -> [CGPoint] {
    var corners: [CGPoint] = []
    path.applyWithBlock { element in
        switch element.pointee.type {
        case .moveToPoint, .addLineToPoint: corners.append(element.pointee.points[0])
        default: break
        }
    }
    return corners
}

/// Whether a colour is opaque white, whatever colour space it was written in.
@MainActor
private func isWhite(_ color: CGColor?) -> Bool {
    guard let color else { return false }
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard UIColor(cgColor: color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return false
    }
    return [red, green, blue, alpha].allSatisfy { abs($0 - 1) < 0.001 }
}

/// What the opening view has to keep free, from the pin's drawn geometry alone.
@Suite("Places pin margin")
struct PlacePinGeometryTests {
    @Test("a roomy pane keeps the pin's drawing free on every side, plus its air")
    func openingInsetsOnARoomyPane() {
        let insets = PlacePinGeometry.openingInsets(in: CGSize(width: 390, height: 500))
        // Half a square of air all round (26), and above the coordinate the square itself (52),
        // the pointer it stands on (8) and its badge (6) as well, because a pin is drawn entirely
        // above the point it marks.
        #expect(insets.top == 92)
        #expect(insets.bottom == 26)
        #expect(insets.left == 52)
        #expect(insets.right == 52)
    }

    @Test("a pane with less to spare than the margin asks keeps both sides in proportion")
    func openingInsetsShrinkInProportion() {
        // 120 points high, of which 40 stay the map's own: 80 to spend against the 118 asked.
        let insets = PlacePinGeometry.openingInsets(in: CGSize(width: 390, height: 120))
        #expect(abs(insets.top - 92 * 80 / 118) < 1e-9)
        #expect(abs(insets.bottom - 26 * 80 / 118) < 1e-9)
        #expect(insets.top > insets.bottom, "the shrunk margin stopped telling up from down")
        #expect(insets.left == 52, "a roomy axis lost its margin to a cramped one")
        #expect(insets.right == 52)
    }

    @Test("a pane smaller than the map's own minimum spends nothing on the margin")
    func openingInsetsOfAPaneUnderTheMinimum() {
        let insets = PlacePinGeometry.openingInsets(in: CGSize(width: 390, height: 20))
        #expect(insets.top == 0, "a pane too small for a margin was fitted inside out")
        #expect(insets.bottom == 0)
        #expect(insets.left == 52)
    }

    @Test("a pane of no size asks for no margin at all")
    func openingInsetsOfNoPane() {
        let insets = PlacePinGeometry.openingInsets(in: .zero)
        #expect(insets.top == 0)
        #expect(insets.bottom == 0)
        #expect(insets.left == 0)
        #expect(insets.right == 0)
    }
}
