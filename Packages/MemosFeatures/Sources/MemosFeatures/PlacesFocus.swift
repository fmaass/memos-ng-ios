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

    /// A request as it was asked: numbered, so asking twice for one picture is two values and the
    /// second is still a change for the tab bar and for Places to see (MEMNG-906). Asked again
    /// while the first still waited, an unnumbered request was the same value, and nothing moved.
    struct Pending: Equatable, Sendable {
        let request: Request
        let serial: Int
    }

    /// Why a request was answered without a map, until the reader has dismissed it.
    struct Decline: Equatable, Identifiable, Sendable {
        let id: Int
        let message: String

        static let title = "Place Not Shown"
    }

    /// What Places did with a request.
    enum Answer: Equatable {
        case focus(Request)
        case declined(Decline)
    }

    /// The place somebody asked for, until Places has moved its map there or said why it cannot.
    /// `nil` at rest.
    private(set) var pending: Pending?
    /// The last request Places had no map for, and why; nil once read.
    private(set) var declined: Decline?
    private var asked = 0

    init() {}

    func request(_ request: Request) {
        asked += 1
        pending = Pending(request: request, serial: asked)
    }

    /// Takes the request, once: the first caller gets it and every later one nil, so a request is
    /// never applied twice.
    func take() -> Request? {
        defer { pending = nil }
        return pending?.request
    }

    /// The pending request, answered for a map that is `status`. Never silent: while the first
    /// read is still out it waits, and is answered once the read settles; a map that is there
    /// takes it; an empty or failed map takes it too, and says why there is nothing to show it on.
    func answer(given status: PlacesStatus) -> Answer? {
        guard let serial = pending?.serial else { return nil }
        switch status {
        case .pending:
            return nil
        case .ready:
            return take().map(Answer.focus)
        case .empty, .error:
            _ = take()
            let decline = Decline(id: serial, message: Self.reason(status))
            declined = decline
            return .declined(decline)
        }
    }

    func dismissDecline() { declined = nil }

    private static func reason(_ status: PlacesStatus) -> String {
        status == .empty
            ? "Places has no photos on its map yet, so there is nothing to show this one on."
            : "Places could not be loaded, so there is no map to show it on. Try again from Places."
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
