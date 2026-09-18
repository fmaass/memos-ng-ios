import Foundation
import MemosCore
import Testing

// The vectors are the SPA's own: frontend/src/lib/places/__tests__/geo.spec.ts (memos-ng a29c2e1),
// lines 32-97 for the box and the grouping and lines 99-184 for the fit insets. They are copied
// input for input and expectation for expectation, because a value the two clients disagree on is
// a map that frames a different first view or splits a pin the other keeps whole.
//
// The one case with no counterpart there is `coordKeyMutationPair`, and the test says why.

/// One built marker, the SPA's `__tests__/fixtures.ts` equivalent: every case varies only the
/// fields it reads. Shared with PlaceOrderTests, as the fixture is shared there.
func placeMarker(
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
        takenAt: placeDate(takenAt),
        thumbnailURL: URL(string: "https://example.invalid/assets/\(uid)/thumb"),
        previewURL: URL(string: "https://example.invalid/assets/\(uid)/preview"),
        webURL: URL(string: "https://example.invalid/assets/\(uid)/web"),
        posterURL: URL(string: "https://example.invalid/assets/\(uid)/poster"),
        blurhash: nil
    )
}

func placeDate(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

@Suite("PlaceGeo")
struct PlaceGeoTests {
    @Test("has no box for no markers, because there is nothing to fit to")
    func noBox() {
        #expect(PlaceGeo.bbox([]) == nil)
    }

    @Test("pads a single pin into a box a fit can use")
    func padsSinglePin() throws {
        // A zero-area box has no scale to solve for; a fixed minimum span keeps the first view at
        // the pin instead of at an accidental zoom.
        let box = try #require(PlaceGeo.bbox([placeMarker(latitude: 47.2, longitude: 8.4)]))

        // The span is written out rather than read from `minBBoxSpan`: a test that takes its
        // expectation from the very constant under test moves with it and can observe nothing.
        #expect(abs((box.east - box.west) - 0.01) < 1e-10)
        #expect(abs((box.north - box.south) - 0.01) < 1e-10)
        #expect(abs((box.east + box.west) / 2 - 8.4) < 1e-10)
        #expect(abs((box.north + box.south) / 2 - 47.2) < 1e-10)
    }

    @Test("spans every pin when they are spread out")
    func spansEveryPin() {
        let box = PlaceGeo.bbox([
            placeMarker(latitude: 47.2, longitude: 8.4),
            placeMarker(latitude: 47.6, longitude: 8.9),
            placeMarker(latitude: 47.4, longitude: 8.1),
        ])

        #expect(box == PlaceBBox(west: 8.1, south: 47.2, east: 8.9, north: 47.6))
    }

    @Test("pads only the degenerate axis when every pin shares one coordinate")
    func padsOnlyTheDegenerateAxis() throws {
        let box = try #require(
            PlaceGeo.bbox([
                placeMarker(latitude: 47.2, longitude: 8.4),
                placeMarker(latitude: 47.6, longitude: 8.4),
            ])
        )

        #expect(abs((box.east - box.west) - 0.01) < 1e-10)
        #expect(box.south == 47.2)
        #expect(box.north == 47.6)
    }

    @Test("collapses identical coordinates into one group, input order preserved")
    func collapsesIdenticalCoordinates() {
        let groups = PlaceGeo.groupByCoordinate([
            placeMarker(uid: "a", latitude: 47.2, longitude: 8.4),
            placeMarker(uid: "b", latitude: 47.2, longitude: 8.4),
            placeMarker(uid: "c", latitude: 47.6, longitude: 8.9),
        ])

        #expect(groups.count == 2)
        #expect(groups[0].markers.map(\.uid) == ["a", "b"])
        #expect(groups[0].key == PlaceGeo.coordKey(47.2, 8.4))
        #expect(groups[1].markers.map(\.uid) == ["c"])
    }

    @Test("keeps coordinates apart below the rounding precision")
    func keepsCoordinatesApart() {
        let groups = PlaceGeo.groupByCoordinate([
            placeMarker(uid: "a", latitude: 47.2, longitude: 8.4),
            placeMarker(uid: "b", latitude: 47.2000004, longitude: 8.4),
            placeMarker(uid: "c", latitude: 47.2001, longitude: 8.4),
        ])

        // 7th decimal is ~1 cm: the same spot. The 4th decimal is ~10 m: two spots.
        #expect(groups.count == 2)
        #expect(groups[0].markers.map(\.uid) == ["a", "b"])
    }

    /// This pair has no counterpart in the SPA's spec and must not be "simplified" away, because
    /// it is the only case that can observe the rounding precision itself. The spec's own grouped
    /// pair is 47.2 against 47.2000004, which collapses at six decimals and still collapses at
    /// four or five, and its separated pair differs in the fourth decimal and stays separated
    /// either way — so neither one changes its answer if the precision is loosened. These two
    /// latitudes are 0.000005 degrees apart, about 55 cm: six decimals keep them apart, five
    /// collapse them into one group.
    @Test("holds the coordinate key to six decimals, not five")
    func coordKeyMutationPair() {
        let groups = PlaceGeo.groupByCoordinate([
            placeMarker(uid: "a", latitude: 47.2000012, longitude: 8.4),
            placeMarker(uid: "b", latitude: 47.2000062, longitude: 8.4),
        ])

        #expect(groups.count == 2)
        #expect(groups.map(\.key) == ["47.200001,8.400000", "47.200006,8.400000"])
    }

    /// Parity vectors read from the browser's own `toFixed(6)`, which the SPA's spec does not
    /// carry yet. They are the two places a printf conversion parts company with it: an exactly
    /// representable halfway value, which printf rounds to even and `toFixed` takes up, and
    /// negative zero, which printf signs and `toFixed` does not — while a merely tiny negative
    /// keeps its sign in both. A key that differs by one digit splits a pin the browser keeps
    /// whole, or joins two it keeps apart, which is the same defect read from either end.
    @Test("rounds and signs a coordinate key exactly as the browser does")
    func coordKeyMatchesToFixed() {
        #expect(PlaceGeo.coordKey(0.0078125, -0.0078125) == "0.007813,-0.007813")
        #expect(PlaceGeo.coordKey(-0.0, 0.0) == "0.000000,0.000000")
        #expect(PlaceGeo.coordKey(-1e-9, 1e-9) == "-0.000000,0.000000")
        #expect(PlaceGeo.coordKey(47.2000012, 8.4) == "47.200001,8.400000")
    }

    /// Parity vectors read the same way, for coordinates that are NEAR a halfway value rather
    /// than on one: an ordinary seven-decimal coordinate ending in a 5 lands a fraction of a
    /// millionth above or below the tie, and which side it lands on is a property of the binary
    /// number, not of the digits someone typed. `toFixed` reads that binary number, so anything
    /// here that reads an approximation of it instead can round the wrong way. The first four sit
    /// above their tie, the next four below it, and the last two are the same pair signed.
    @Test("rounds a coordinate that is near a halfway value the way the browser does")
    func coordKeyMatchesToFixedNearTies() {
        #expect(PlaceGeo.coordKey(1.0000005, 0) == "1.000001,0.000000")
        #expect(PlaceGeo.coordKey(0.0000015, 0) == "0.000002,0.000000")
        #expect(PlaceGeo.coordKey(46.9479745, 0) == "46.947975,0.000000")
        #expect(PlaceGeo.coordKey(179.9999995, 0) == "180.000000,0.000000")
        #expect(PlaceGeo.coordKey(47.3769875, 0) == "47.376987,0.000000")
        #expect(PlaceGeo.coordKey(8.0000015, 0) == "8.000001,0.000000")
        #expect(PlaceGeo.coordKey(8.5417235, 0) == "8.541723,0.000000")
        #expect(PlaceGeo.coordKey(100.0000005, 0) == "100.000000,0.000000")
        #expect(PlaceGeo.coordKey(-46.9479745, 0) == "-46.947975,0.000000")
        #expect(PlaceGeo.coordKey(-47.3769875, 0) == "-47.376987,0.000000")
    }

    // The overlay is drawn on top of the map pane, so the pixels it covers are pixels a fit will
    // happily put a pin in. On the web at 1440x900 that put 2 of 8 pins at y 826 behind a bar
    // occupying y 812-884, where nothing could click them.
    private let pane = PaneRect(top: 56, bottom: 900, left: 240, right: 1440)

    @Test("reserves the overlay it is given, on the bottom side only")
    func reservesTheOverlay() {
        let bar = PaneRect(top: 812, bottom: 884, left: 256, right: 1424)

        let insets = PlaceGeo.fitInsets(pane: pane, overlay: bar)

        #expect(insets.bottom == PlaceGeo.fitPadding + (pane.bottom - bar.top))
        #expect(insets.top == PlaceGeo.fitPadding)
        #expect(insets.left == PlaceGeo.fitPadding)
        #expect(insets.right == PlaceGeo.fitPadding)
    }

    @Test("reserves what a taller or a shorter overlay actually occupies, not a fixed number")
    func reservesWhatIsOccupied() {
        // The bar is a different height on a phone and grows again when its controls wrap, so the
        // reservation is measured on every fit.
        let shallow = PlaceGeo.fitInsets(
            pane: pane,
            overlay: PaneRect(top: 852, bottom: 892, left: 8, right: 382)
        )
        let deep = PlaceGeo.fitInsets(
            pane: pane,
            overlay: PaneRect(top: 760, bottom: 884, left: 8, right: 382)
        )

        #expect(deep.bottom > shallow.bottom)
        #expect(deep.bottom - shallow.bottom == 852 - 760)
    }

    @Test("falls back to the uniform inset when no overlay is on the pane")
    func noOverlay() {
        let base = PlaceGeo.fitPadding

        #expect(
            PlaceGeo.fitInsets(pane: pane, overlay: nil)
                == FitInsets(top: base, right: base, bottom: base, left: base)
        )
    }

    @Test("ignores an overlay that sits clear of the pane")
    func ignoresAnOverlayBelow() {
        // On a phone the in-view grid is BELOW the map rather than over it: it hides no pin and
        // must reserve nothing, or the fit would throw away half the short pane for nothing.
        let below = PaneRect(top: 950, bottom: 1400, left: 0, right: 390)

        #expect(PlaceGeo.fitInsets(pane: pane, overlay: below).bottom == PlaceGeo.fitPadding)
    }

    @Test("ignores an overlay entirely above the pane")
    func ignoresAnOverlayAbove() {
        let above = PaneRect(top: 0, bottom: 40, left: 240, right: 1440)

        #expect(PlaceGeo.fitInsets(pane: pane, overlay: above).bottom == PlaceGeo.fitPadding)
    }

    @Test("ignores an overlay that misses the pane horizontally")
    func ignoresAnOverlayBeside() {
        // A side panel beside the map, at the same height: it overlaps on the y axis and covers
        // no pin at all, so the reservation has to test both axes.
        let beside = PaneRect(top: 700, bottom: 900, left: 0, right: 239)

        #expect(PlaceGeo.fitInsets(pane: pane, overlay: beside).bottom == PlaceGeo.fitPadding)
    }

    @Test("reserves nothing for an overlay anchored at the TOP of the pane")
    func ignoresATopBar() {
        // The contract is deliberately narrow. A top bar overlapping the pane would need the top
        // side reserved instead, and guessing that from a rectangle would silently mis-fit the
        // one case the map actually has.
        let topBar = PaneRect(top: 40, bottom: 120, left: 240, right: 1440)
        let base = PlaceGeo.fitPadding

        #expect(
            PlaceGeo.fitInsets(pane: pane, overlay: topBar)
                == FitInsets(top: base, right: base, bottom: base, left: base)
        )
    }

    @Test("never lets the reservation swallow the pane")
    func neverSwallowsThePane() {
        // A short pane with a tall bar: insets that exceed the pane leave the fit no box to solve
        // for, and the first view lands on nothing instead of on the pins.
        let short = PaneRect(top: 56, bottom: 520, left: 0, right: 390)
        let tall = PaneRect(top: 100, bottom: 512, left: 8, right: 382)

        let insets = PlaceGeo.fitInsets(pane: short, overlay: tall)

        #expect(insets.top + insets.bottom < short.height)
        #expect(insets.bottom > 0)
    }
}
