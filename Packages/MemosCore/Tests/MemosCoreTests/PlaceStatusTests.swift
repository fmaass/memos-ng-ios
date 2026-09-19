import MemosCore
import Testing

// The vectors are the SPA's own: frontend/src/lib/places/__tests__/state.spec.ts (memos-ng
// a29c2e1), all of it.
@Suite("PlacesStatus")
struct PlaceStatusTests {
    @Test("is pending while the read is still in flight")
    func pending() {
        // The defect this exists for: an unanswered read looks exactly like an empty library if
        // you only count markers, and the markers answer is over a megabyte.
        #expect(PlacesStatus.of(isPending: true, isError: false, markerCount: 0) == .pending)
    }

    @Test("is an error of its own when the read failed")
    func error() {
        // "Nothing was found" and "I could not look" are different things to tell someone.
        #expect(PlacesStatus.of(isPending: false, isError: true, markerCount: 0) == .error)
    }

    @Test("is empty only once the read has settled with nothing")
    func empty() {
        #expect(PlacesStatus.of(isPending: false, isError: false, markerCount: 0) == .empty)
    }

    @Test("is ready as soon as there are markers")
    func ready() {
        #expect(PlacesStatus.of(isPending: false, isError: false, markerCount: 3) == .ready)
    }

    @Test("keeps the pins on screen while a refresh is in flight")
    func readyDuringRefresh() {
        #expect(PlacesStatus.of(isPending: true, isError: false, markerCount: 3) == .ready)
    }

    @Test("keeps the pins on screen when a refresh fails")
    func readyAfterAFailedRefresh() {
        // The pins already fetched are still true; a failed refresh is no reason to withdraw them.
        #expect(PlacesStatus.of(isPending: false, isError: true, markerCount: 3) == .ready)
    }
}
