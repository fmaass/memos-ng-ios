import Foundation
import MemosCore
import Testing

// The vectors are the SPA's own: frontend/src/lib/places/__tests__/order.spec.ts (memos-ng
// a29c2e1), all of it. The order the two clients display is the order a tap indexes into, so a
// disagreement here opens a different photo on the phone than in the browser — and "Show in memo"
// then jumps to that other photo's memo.
@Suite("PlaceOrder")
struct PlaceOrderTests {
    private let old = placeMarker(uid: "old", takenAt: "2024-03-01T10:00:00Z")
    private let mid = placeMarker(uid: "mid", takenAt: "2025-06-01T10:00:00Z")
    private let recent = placeMarker(uid: "new", takenAt: "2026-09-01T10:00:00Z")

    @Test("orders by when the photo was taken, newest first, without touching the input")
    func newestFirst() {
        let input = [old, recent, mid]

        #expect(PlaceOrder.newestFirst(input).map(\.uid) == ["new", "mid", "old"])
        #expect(input.map(\.uid) == ["old", "new", "mid"])
    }

    @Test("opens the displayed order on the photo that was tapped, not on its input position")
    func viewerTargetOnTheTappedPhoto() {
        let target = PlaceOrder.viewerTarget([old, recent, mid], uid: "old")

        #expect(target.list.map(\.uid) == ["new", "mid", "old"])
        #expect(target.index == 2)
        #expect(target.list[target.index].uid == "old")
    }

    @Test("opens the newest photo when that is the one tapped")
    func viewerTargetOnTheNewest() {
        let target = PlaceOrder.viewerTarget([old, recent], uid: "new")

        #expect(target.index == 0)
        #expect(target.list[target.index].uid == "new")
    }

    @Test("falls back to the first slide for a uid that is no longer in the set")
    func viewerTargetForAMissingUID() {
        #expect(PlaceOrder.viewerTarget([old, recent], uid: "gone").index == 0)
    }

    /// No counterpart in the SPA's spec, and it is not a parity case: JavaScript's sort is stable
    /// and Swift's is not, so two photos carrying the same instant could swap places between two
    /// identical calls here and move the slide a tap opens. The input order is the tie-break, and
    /// this is the case that holds it.
    @Test("keeps photos taken at the same instant in the order they arrived")
    func stableForEqualInstants() {
        let first = placeMarker(uid: "first", takenAt: "2025-06-01T10:00:00Z")
        let second = placeMarker(uid: "second", takenAt: "2025-06-01T10:00:00Z")

        let asGiven = PlaceOrder.newestFirst([first, second, old])
        let reversed = PlaceOrder.newestFirst([second, first, old])

        #expect(asGiven.map(\.uid) == ["first", "second", "old"])
        #expect(reversed.map(\.uid) == ["second", "first", "old"])
    }
}
