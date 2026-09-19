import MemosCore
import Testing

// The vectors are the SPA's own: frontend/src/lib/places/__tests__/markers.spec.ts (memos-ng
// a29c2e1) — its `badgeText` and `syncMarkers` cases, copied literally. The SPA's pin specs carry
// a clustering id as well; the map here produces its own clusters, so the field is absent and the
// cases are otherwise unchanged. Its `pinsFor` cases are not carried, because that function is
// not ported: it reads one map library's tile query, and inventing iOS vectors for it would be
// inventing the behaviour they claim to pin.
@Suite("PlaceClustering")
struct PlaceClusteringTests {
    @Test("hides the badge for a single photo")
    func noBadgeForOne() {
        // A "1" on every lone pin is noise: the thumbnail already says one photo.
        #expect(PlaceClustering.badgeText(count: 1) == nil)
        #expect(PlaceClustering.badgeText(count: 0) == nil)
    }

    @Test("shows the exact count up to 99 and caps at 99+ above it")
    func badgeBound() {
        // The bound itself is the observable: 99 is still exact, 100 is already capped. A pin
        // reading "100" would not fit inside itself.
        #expect(PlaceClustering.badgeText(count: 2) == "2")
        #expect(PlaceClustering.badgeText(count: 99) == "99")
        #expect(PlaceClustering.badgeText(count: 100) == "99+")
        #expect(PlaceClustering.badgeText(count: 101) == "99+")
        #expect(PlaceClustering.badgeText(count: 4213) == "99+")
    }

    private let cluster = PinSpec(
        key: "c:1",
        latitude: 1,
        longitude: 1,
        count: 3,
        uid: "a",
        uids: []
    )
    private let single = PinSpec(
        key: "p:2",
        latitude: 2,
        longitude: 2,
        count: 1,
        uid: "b",
        uids: ["b"]
    )

    @Test("adds every pin when nothing is on the map yet")
    func addsEverything() {
        let diff = PlaceClustering.sync(current: [:], desired: [cluster, single])

        #expect(diff.added == [cluster, single])
        #expect(diff.updated == [])
        #expect(diff.removed == [])
    }

    @Test("removes the pins the new set no longer holds")
    func removesWhatIsGone() {
        let current = ["c:1": cluster, "p:2": single]

        let diff = PlaceClustering.sync(current: current, desired: [cluster])

        #expect(diff.removed == ["p:2"])
        #expect(diff.added == [])
    }

    @Test("updates a pin whose photos changed while its lead, count and place did not")
    func updatesOnMembership() {
        // One photo deleted and another taken at the same spot between two syncs: [a,b] becomes
        // [a,c] with the same lead, the same count and the same coordinate. Judged on count, lead
        // and place alone the pin looks untouched, and the tap then hands the drawer the photo
        // that is gone instead of the one that arrived.
        let before = PinSpec(
            key: "p:1",
            latitude: 1,
            longitude: 1,
            count: 2,
            uid: "a",
            uids: ["a", "b"]
        )
        var after = before
        after.uids = ["a", "c"]

        let diff = PlaceClustering.sync(current: ["p:1": before], desired: [after])

        #expect(diff.updated == [after])
        #expect(diff.added == [])
        #expect(diff.removed == [])
    }

    @Test("leaves a pin holding the same photos in the same order alone")
    func noRepaintForAnIdenticalPin() {
        // The repaint is the frame budget: membership that did not move must not cost one.
        let pin = PinSpec(
            key: "p:1",
            latitude: 1,
            longitude: 1,
            count: 2,
            uid: "a",
            uids: ["a", "b"]
        )
        var same = pin
        same.uids = ["a", "b"]

        let diff = PlaceClustering.sync(current: ["p:1": pin], desired: [same])

        #expect(diff.updated == [])
        #expect(diff.added == [])
        #expect(diff.removed == [])
    }

    @Test("updates a pin whose count or position moved, and leaves an identical one alone")
    func updatesOnCountOrPlace() {
        // A cluster survives a zoom change while its count and centre do not — repainting only
        // what changed is what keeps the sync inside one frame.
        var moved = cluster
        moved.count = 9
        moved.longitude = 1.5

        let current = ["c:1": cluster, "p:2": single]
        let diff = PlaceClustering.sync(current: current, desired: [moved, single])

        #expect(diff.updated == [moved])
        #expect(diff.added == [])
        #expect(diff.removed == [])
    }

    // `pins(from:)` has no counterpart in the SPA's spec file: it composes the coordinate grouping
    // and the display order, both of which are pinned by their own vectors there, into the shape
    // the map draws. What is asserted here is the composition — which photo a pin wears, how many
    // it says, and in what order it hands them on.

    @Test("one pin per coordinate, wearing the newest photo taken there")
    func oneGroupOnePin() {
        let january = "2026-01-01T00:00:00Z"
        let february = "2026-02-01T00:00:00Z"
        let march = "2026-03-01T00:00:00Z"
        let pins = PlaceClustering.pins(from: [
            placeMarker(uid: "old", latitude: 47.2, longitude: 8.4, takenAt: january),
            placeMarker(uid: "new", latitude: 47.2, longitude: 8.4, takenAt: march),
            placeMarker(uid: "far", latitude: 12.5, longitude: 3.1, takenAt: february),
        ])

        #expect(pins.count == 2)
        #expect(pins[0].key == PlaceGeo.coordKey(47.2, 8.4))
        #expect(pins[0].latitude == 47.2)
        #expect(pins[0].longitude == 8.4)
        #expect(pins[0].count == 2)
        // The lead is the group's NEWEST, not the first one the server happened to send.
        #expect(pins[0].uid == "new")
        #expect(pins[0].uids == ["new", "old"])
        #expect(pins[1].uid == "far")
        #expect(pins[1].count == 1)
    }

    @Test("the pins come back in the order the coordinates were first seen")
    func keepsGroupingOrder() {
        // Not sorted by count, by date or by key: the grouping's order is what the diff and the
        // annotations are applied in, and re-ordering it would make two identical reads look
        // like a set of moves.
        let pins = PlaceClustering.pins(from: [
            placeMarker(uid: "b", latitude: 9, longitude: 9, takenAt: "2026-01-01T00:00:00Z"),
            placeMarker(uid: "a", latitude: 1, longitude: 1, takenAt: "2026-05-01T00:00:00Z"),
            placeMarker(uid: "c", latitude: 1, longitude: 1, takenAt: "2026-06-01T00:00:00Z"),
        ])

        #expect(pins.map(\.key) == [PlaceGeo.coordKey(9, 9), PlaceGeo.coordKey(1, 1)])
        #expect(pins.map(\.count) == [1, 2])
    }

    @Test("no markers is no pins, not one empty pin")
    func nothingToDraw() {
        #expect(PlaceClustering.pins(from: []).isEmpty)
    }
}
