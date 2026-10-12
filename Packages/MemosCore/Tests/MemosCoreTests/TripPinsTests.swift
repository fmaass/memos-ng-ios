import Foundation
@testable import MemosCore
import Testing

/// The device-local pin of server-backed trips: `<scope>/pins.json`, one pin per scope, with the
/// title and tag the composer chip needs before any list has answered.
@MainActor
@Suite("Trip pins")
struct TripPinsTests {
    private let root = TripWire.root()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func trip(_ uid: String, title: String = "Portugal 2026", tag: String? = "pt") -> Trip {
        Trip(uid: uid, title: title, tag: tag, createdAt: now, updatedAt: now)
    }

    @Test("pins survive a relaunch, are dropped with the scope, the chip row has title and tag")
    func pinsSurviveAndAreScoped() {
        let pins = TripPins(identity: TripWire.alice, root: root)
        pins.pin(trip("t1", tag: "portugal2026"), lastTaken: nil, now: now)

        let relaunched = TripPins(identity: TripWire.alice, root: root)
        let row = relaunched.activePin(now: now)
        #expect(row?.uid == "t1", "the pin did not survive a relaunch")
        #expect(row?.title == "Portugal 2026")
        #expect(row?.tag == "portugal2026")
        #expect(row?.pinnedUntil == now.addingTimeInterval(7 * day))

        relaunched.sessionIdentityChanged(to: TripWire.bob)
        #expect(relaunched.rows.isEmpty, "another scope saw the pin")
        #expect(relaunched.activePin(now: now) == nil)
        relaunched.sessionIdentityChanged(to: TripWire.alice)
        #expect(relaunched.activePin(now: now)?.uid == "t1", "the scope did not get its pin back")

        relaunched.noteTrips([trip("t1", title: "Portugal", tag: "pt26")])
        let renamed = TripPins(identity: TripWire.alice, root: root).activePin(now: now)
        #expect(renamed?.title == "Portugal")
        #expect(renamed?.tag == "pt26")

        // One pin per scope: pinning another trip replaces it.
        relaunched.pin(trip("t2"), lastTaken: nil, now: now)
        #expect(relaunched.rows.map(\.uid) == ["t2"])
    }

    @Test("the seven-day pin extension on noteMembers")
    func noteMembersExtendsThePin() {
        let pins = TripPins(identity: TripWire.alice, root: root)
        let last = now.addingTimeInterval(-30 * day)
        pins.pin(trip("t1"), lastTaken: last, now: now)
        #expect(pins.pinnedUntil(uid: "t1") == last.addingTimeInterval(7 * day))
        #expect(pins.activePin(now: now) == nil, "control: that pin has expired")

        let later = now.addingTimeInterval(-day)
        pins.noteMembers(uid: "t1", firstTaken: last, lastTaken: later, now: now)
        #expect(pins.pinnedUntil(uid: "t1") == later.addingTimeInterval(7 * day))
        #expect(pins.activePin(now: now)?.uid == "t1", "an expired pin was not extended")

        pins.noteMembers(uid: "t1", firstTaken: last, lastTaken: last, now: now)
        #expect(pins.pinnedUntil(uid: "t1") == later.addingTimeInterval(7 * day), "it shortened")

        pins.noteMembers(uid: "t9", firstTaken: last, lastTaken: later, now: now)
        #expect(pins.pinnedUntil(uid: "t9") == nil, "an unpinned trip was pinned")
    }
}
