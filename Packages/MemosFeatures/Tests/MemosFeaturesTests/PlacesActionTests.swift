import Foundation
import MapKit
import MemosCore
import Testing

@testable import MemosFeatures

/// One built marker, with every tier set: a marker with nothing to render is not a page at all,
/// and these cases are about ORDER, not about what the viewer drops.
private func marker(
    uid: String,
    takenAt: String,
    latitude: Double = 47.2,
    longitude: Double = 8.4
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

private func pin(
    key: String,
    uids: [String],
    latitude: Double = 47.2,
    longitude: Double = 8.4,
    leadTakenAt: String = "2026-01-01T00:00:00Z"
) -> PlacePin {
    PlacePin(
        spec: PinSpec(
            key: key,
            latitude: latitude,
            longitude: longitude,
            count: uids.count,
            uid: uids[0],
            uids: uids
        ),
        leadTakenAt: ISO8601DateFormatter().date(from: leadTakenAt)!,
        leadThumbnailURL: nil
    )
}

/// What a tap on the map opens, and what the grid under it holds.
///
/// Every case goes through the function the view calls, not through `PlaceOrder`: the ordering
/// vector is already pinned in MemosCore, so a test that sorted a list itself would prove only
/// that the sort still works while the screen handed the viewer something else entirely.
@MainActor
@Suite("What a tap on the map opens")
struct PlacesActionTests {
    private let three = [
        marker(uid: "oldest", takenAt: "2026-01-01T00:00:00Z"),
        marker(uid: "middle", takenAt: "2026-01-02T00:00:00Z"),
        marker(uid: "newest", takenAt: "2026-01-03T00:00:00Z"),
    ]

    @Test("opens the tapped photo where it sits in the order the reader was looking at")
    func opensTheTappedPhotoInTheDisplayedOrder() throws {
        let selection = try #require(PlacesPresentation.open("oldest", in: three))

        #expect(selection.pages.map(\.id) == ["newest", "middle", "oldest"])
        #expect(selection.startIndex == 2)
    }

    @Test("leaves a photo opened from the map undeletable")
    func leavesThePhotoUndeletable() throws {
        // A delete from the map would be a store mutation nothing here performs, so the
        // capability is not claimed.
        #expect(try #require(PlacesPresentation.open("newest", in: three)).deletable == false)
    }

    @Test("a pin holding one photograph opens it")
    func aLonePinOpensTheViewer() throws {
        let action = PlacesPresentation.tap(pin: pin(key: "k", uids: ["middle"]), in: three)

        guard case .viewer(let selection) = try #require(action) else {
            Issue.record("a pin of one photograph opened a list instead of the photograph")
            return
        }
        #expect(selection.startPage.id == "middle")
    }

    @Test("a pin holding several photographs lists them, and offers no zoom that could split them")
    func aSharedCoordinateListsWithoutZoom() throws {
        let action = PlacesPresentation.tap(
            pin: pin(key: "k", uids: ["oldest", "middle", "newest"]),
            in: three
        )

        guard case .sheet(let sheet) = try #require(action) else {
            Issue.record("a pin of several photographs opened the viewer on one of them")
            return
        }
        #expect(sheet.markers.map(\.uid) == ["newest", "middle", "oldest"])
        #expect(
            sheet.canZoomIn == false,
            "zooming cannot separate photographs that share one coordinate"
        )
    }

    @Test("a cluster lists every member's photographs in ONE order, not member by member")
    func aClusterListsEverythingInOneOrder() {
        let markers = [
            marker(uid: "a1", takenAt: "2026-01-05T00:00:00Z"),
            marker(uid: "a2", takenAt: "2026-01-03T00:00:00Z"),
            marker(uid: "a3", takenAt: "2026-01-01T00:00:00Z"),
            marker(uid: "b1", takenAt: "2026-01-04T00:00:00Z", longitude: 8.5),
            marker(uid: "b2", takenAt: "2026-01-02T00:00:00Z", longitude: 8.5),
        ]

        let sheet = PlacesPresentation.clusterTap(
            members: [
                pin(key: "a", uids: ["a1", "a2", "a3"]),
                pin(key: "b", uids: ["b1", "b2"], longitude: 8.5),
            ],
            in: markers,
            cameraDistance: 50_000
        )

        #expect(sheet.markers.map(\.uid) == ["a1", "b1", "a2", "b2", "a3"])
    }

    @Test("a cluster seen from well above the floor can still be zoomed apart")
    func aClusterAboveTheFloorOffersZoom() {
        // 0.0045 degrees is about 500 m — far below any degree threshold, and plainly worth
        // zooming to. Whether zooming helps is a question about the camera, not about an angle.
        let markers = [
            marker(uid: "a", takenAt: "2026-01-02T00:00:00Z", latitude: 47.2),
            marker(uid: "b", takenAt: "2026-01-01T00:00:00Z", latitude: 47.2045),
        ]
        let members = [
            pin(key: "a", uids: ["a"], latitude: 47.2),
            pin(key: "b", uids: ["b"], latitude: 47.2045),
        ]

        let sheet = PlacesPresentation.clusterTap(
            members: members,
            in: markers,
            cameraDistance: 20_000
        )

        #expect(sheet.canZoomIn)
        #expect(sheet.markers.map(\.uid) == ["a", "b"], "control: the list is there either way")
    }

    @Test("the same cluster at the camera floor lists everything and offers no zoom")
    func aClusterAtTheFloorOffersNoZoom() {
        let markers = [
            marker(uid: "a", takenAt: "2026-01-02T00:00:00Z", latitude: 47.2),
            marker(uid: "b", takenAt: "2026-01-01T00:00:00Z", latitude: 47.2045),
        ]
        let members = [
            pin(key: "a", uids: ["a"], latitude: 47.2),
            pin(key: "b", uids: ["b"], latitude: 47.2045),
        ]

        let sheet = PlacesPresentation.clusterTap(
            members: members,
            in: markers,
            cameraDistance: PlacesPresentation.minimumCameraDistance
        )

        #expect(sheet.canZoomIn == false)
        #expect(sheet.markers.count == 2, "the sheet still lists everything at the limit")
    }

    @Test("the grid holds the markers the region shows, newest first")
    func theGridHoldsWhatTheRegionShows() {
        let markers = [
            marker(uid: "in-old", takenAt: "2026-01-01T00:00:00Z", latitude: 47.2, longitude: 8.4),
            marker(uid: "out", takenAt: "2026-01-04T00:00:00Z", latitude: 47.2, longitude: 20),
            marker(uid: "in-new", takenAt: "2026-01-03T00:00:00Z", latitude: 47.3, longitude: 8.5),
        ]
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.25, longitude: 8.45),
            span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)
        )

        let grid = PlacesPresentation.grid(markers, in: PlacesPresentation.box(of: region))

        #expect(grid.map(\.uid) == ["in-new", "in-old"])
    }

    @Test("a region across the antimeridian holds the markers on both sides of it")
    func theGridSpansTheAntimeridian() {
        let markers = [
            marker(uid: "east", takenAt: "2026-01-01T00:00:00Z", latitude: 0, longitude: -179.5),
            marker(uid: "west", takenAt: "2026-01-02T00:00:00Z", latitude: 0, longitude: 178),
            marker(uid: "behind", takenAt: "2026-01-03T00:00:00Z", latitude: 0, longitude: 176.9),
        ]
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 179),
            span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4)
        )

        let grid = PlacesPresentation.grid(markers, in: PlacesPresentation.box(of: region))

        #expect(grid.map(\.uid) == ["west", "east"])
    }
}
