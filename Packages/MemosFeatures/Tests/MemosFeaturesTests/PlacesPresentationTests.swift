import Foundation
import MapKit
import MemosCore
import Testing

@testable import MemosFeatures

/// One built marker; every case varies only the fields it reads. The MemosCore suites have the
/// same helper against the same type — the two bundles cannot share a file, and a fixture is not
/// an abstraction worth a third target.
private func placeMarker(
    uid: String = "att-1",
    latitude: Double = 47.2,
    longitude: Double = 8.4,
    takenAt: String = "2026-01-01T00:00:00Z"
) -> PlaceMarker {
    PlaceMarker(
        uid: uid,
        memoUID: "memo-1",
        mime: "image/jpeg",
        mine: true,
        width: 4000,
        height: 3000,
        latitude: latitude,
        longitude: longitude,
        takenAt: ISO8601DateFormatter().date(from: takenAt)!,
        thumbnailURL: URL(string: "https://example.invalid/assets/\(uid)/thumb"),
        previewURL: nil,
        webURL: nil,
        posterURL: nil,
        blurhash: nil
    )
}

private func pin(uid: String, count: Int, takenAt: String) -> PlacePin {
    PlacePin(
        spec: PinSpec(
            key: "\(uid)-key",
            latitude: 47.2,
            longitude: 8.4,
            count: count,
            uid: uid,
            uids: [uid]
        ),
        leadTakenAt: ISO8601DateFormatter().date(from: takenAt)!,
        leadThumbnailURL: nil
    )
}

@MainActor
@Suite("Places presentation")
struct PlacesPresentationTests {
    @Test("each pin carries the lead photograph's date and thumbnail, not just its uid")
    func pinsCarryTheirLead() {
        let pins = PlacesPresentation.pins(for: [
            placeMarker(uid: "old", takenAt: "2026-01-01T00:00:00Z"),
            placeMarker(uid: "new", takenAt: "2026-03-01T00:00:00Z"),
            placeMarker(uid: "far", latitude: 47.9, longitude: 8.9),
        ])
        #expect(pins.count == 2)
        #expect(pins[0].spec.uid == "new", "the newest photo at a coordinate leads its pin")
        #expect(pins[0].spec.count == 2)
        #expect(pins[0].leadTakenAt == ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")!)
        #expect(pins[0].leadThumbnailURL?.absoluteString.hasSuffix("/assets/new/thumb") == true)
        #expect(pins[1].spec.uid == "far")
    }

    @Test("the map opens on the box every pin fits in")
    func fitRegionSpansEveryPin() throws {
        let region = try #require(
            PlacesPresentation.fitRegion(for: [
                placeMarker(uid: "sw", latitude: 47.0, longitude: 8.0),
                placeMarker(uid: "ne", latitude: 47.4, longitude: 8.6),
            ])
        )
        #expect(abs(region.center.latitude - 47.2) < 1e-9)
        #expect(abs(region.center.longitude - 8.3) < 1e-9)
        #expect(abs(region.span.latitudeDelta - 0.4) < 1e-9)
        #expect(abs(region.span.longitudeDelta - 0.6) < 1e-9)
    }

    @Test("one pin still opens at a scale, on the photo rather than beside it")
    func fitRegionOfOnePinHasASpan() throws {
        let region = try #require(PlacesPresentation.fitRegion(for: [placeMarker()]))
        #expect(abs(region.center.latitude - 47.2) < 1e-9)
        #expect(abs(region.span.latitudeDelta - PlaceGeo.minBBoxSpan) < 1e-9)
        #expect(abs(region.span.longitudeDelta - PlaceGeo.minBBoxSpan) < 1e-9)
    }

    @Test("nothing to fit to is no region, so the screen shows its own state instead")
    func fitRegionOfNothingIsNil() {
        #expect(PlacesPresentation.fitRegion(for: []) == nil)
    }

    @Test("a screen that has not settled once is still waiting, not empty")
    func pendingIsNotEmpty() {
        let store = PlacesStore()
        #expect(store.markers.isEmpty)
        #expect(
            PlacesPresentation.state(of: store) == .pending,
            "an empty state read off the markers alone claims the library has no places while the read is still in flight"
        )
        #expect(PlacesPresentation.notice(for: .pending, error: nil) == nil)
    }

    @Test("a cluster's badge counts photographs, not the pins it swallowed")
    func clusterBadgeSumsPhotos() {
        let members = [
            pin(uid: "a", count: 3, takenAt: "2026-01-01T00:00:00Z"),
            pin(uid: "b", count: 4, takenAt: "2026-01-02T00:00:00Z"),
        ]
        #expect(PlacesPresentation.clusterBadge(for: members) == "7")
    }

    @Test("a lone pin says how many photos are behind it, and says nothing when there is one")
    func pinBadgeCountsTheGroup() {
        let lone = pin(uid: "a", count: 1, takenAt: "2026-01-01T00:00:00Z").spec
        let group = pin(uid: "a", count: 3, takenAt: "2026-01-01T00:00:00Z").spec

        #expect(PlacesPresentation.pinBadge(for: lone) == nil)
        #expect(PlacesPresentation.pinBadge(for: group) == "3")
    }

    /// The one sentence a pin and a cluster both speak, asserted against a pinned locale and time
    /// zone: the date is laid out by the reader's locale, so a case that did not pin them would be
    /// asserting the machine it ran on.
    @Test("what a pin or a cluster says aloud: its photographs, and when the newest was taken")
    func spokenLabelNamesPhotographsAndTheNewestDate() {
        let taken = ISO8601DateFormatter().date(from: "2026-09-12T10:00:00Z")!
        let locale = Locale(identifier: "en_GB")
        let zone = TimeZone(identifier: "UTC")!

        #expect(
            PlacesPresentation.spokenLabel(
                photographs: 1, newest: taken, locale: locale, timeZone: zone
            ) == "Photo, 12 Sep 2026"
        )
        #expect(
            PlacesPresentation.spokenLabel(
                photographs: 14, newest: taken, locale: locale, timeZone: zone
            ) == "14 photos, newest 12 Sep 2026"
        )
    }

    @Test("a cluster wears the newest lead photograph of its members")
    func clusterLeadIsTheNewest() {
        let lead = PlacesPresentation.clusterLead(of: [
            pin(uid: "a", count: 1, takenAt: "2026-01-01T00:00:00Z"),
            pin(uid: "c", count: 1, takenAt: "2026-05-01T00:00:00Z"),
            pin(uid: "b", count: 1, takenAt: "2026-03-01T00:00:00Z"),
        ])
        #expect(lead?.spec.uid == "c")
    }

    @Test("two members taken at the same moment settle on the smaller uid, every time")
    func clusterLeadBreaksTiesOnUID() {
        let members = [
            pin(uid: "b", count: 1, takenAt: "2026-05-01T00:00:00Z"),
            pin(uid: "a", count: 1, takenAt: "2026-05-01T00:00:00Z"),
        ]
        #expect(PlacesPresentation.clusterLead(of: members)?.spec.uid == "a")
        #expect(PlacesPresentation.clusterLead(of: members.reversed())?.spec.uid == "a")
        #expect(PlacesPresentation.clusterLead(of: []) == nil)
    }

    @Test("each state says its own thing, and a map in hand says nothing at all")
    func noticesTellTheStatesApart() {
        #expect(PlacesPresentation.notice(for: .ready, error: nil) == nil)
        #expect(PlacesPresentation.notice(for: .empty, error: nil)?.title == "No places yet")
        let failed = PlacesPresentation.notice(for: .error, error: "the server said no")
        #expect(failed?.message == "the server said no")
        #expect(PlacesPresentation.notice(for: .error, error: nil)?.message.isEmpty == false)
    }

    /// The card has no cause to name when the store left none. A read that never reached the
    /// server is said once, by the session's banner, and this card underneath it would be saying
    /// it twice; a refusal that did not end the session was the server answering, so the same
    /// sentence would be false. Either way the card describes the LOAD and stops there.
    @Test("with no sentence of its own the card says what failed and invents no cause")
    func theErrorCardNamesNoCause() throws {
        let card = try #require(PlacesPresentation.notice(for: .error, error: nil))

        #expect(!card.message.isEmpty, "a card with nothing in it is not a notice")
        for claim in ["reach", "server", "connection", "offline", "network"] {
            #expect(
                card.message.range(of: claim, options: .caseInsensitive) == nil,
                "the card said \"\(card.message)\" where the store deliberately said nothing"
            )
        }
        #expect(
            PlacesPresentation.notice(for: .error, error: "the server returned 500")?.message
                == "the server returned 500",
            "a sentence the store did supply was replaced by the fallback"
        )
    }
}
