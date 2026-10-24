import CoreLocation
import Foundation
import MemosCore

/// A request to show the Places map at one picture's place, made from a screen that is not
/// Places: the Info sheet's Open in Places (MEMNG-869).
///
/// The map, its store and its markers belong to the Places tab, so the request travels, as
/// `MemoJump` and `LibraryTagJump` do: the sheet asks, the tab bar switches, and Places moves its
/// own map. It carries the picture's coordinate as its record holds it and the picture's uid, so
/// Places can centre on the picture's own pin when its map holds one.
@MainActor
@Observable
final class PlacesFocus {
    struct Request: Equatable, Sendable {
        let uid: String
        let latitude: Double
        let longitude: Double
    }

    /// The place somebody asked for, until Places has moved its map there. `nil` at rest.
    private(set) var pending: Request?

    init() {}

    func request(_ request: Request) {
        pending = request
    }

    /// Takes the request, once: the first caller gets it and every later one nil, so a request is
    /// never applied twice.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// Where a focus request goes, decided outside the views that act on it.
enum PlacesFocusRouting {
    /// How much ground the focused map shows around the picture, edge to edge.
    static let span: CLLocationDistance = 1500

    /// Which tab the app shows: Places while a focus is pending, else whatever was on screen.
    static func tab(
        showing current: MainTab, whenFocusing request: PlacesFocus.Request?
    ) -> MainTab {
        request == nil ? current : .places
    }

    /// Where the map centres: the picture's own pin when the map holds it — the place the reader
    /// will find it on — else the coordinate its record carries.
    static func center(
        for request: PlacesFocus.Request, in markers: [PlaceMarker]
    ) -> CLLocationCoordinate2D {
        if let marker = markers.first(where: { $0.uid == request.uid }) {
            return CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
        }
        return CLLocationCoordinate2D(latitude: request.latitude, longitude: request.longitude)
    }
}
