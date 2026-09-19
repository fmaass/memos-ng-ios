import Foundation
import Testing

@testable import MemosCore

/// When the "can't reach the server" notice is allowed on screen.
///
/// The whole point of deciding this in a function is that the clock is an argument: every vector
/// below is a moment the app can really be in, written out rather than waited for.
@Suite("When the unreachable notice shows")
struct UnreachableNoticeTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let delay = Duration.seconds(2)

    @Test("a confirmed session says nothing, however long ago it was stamped")
    func verifiedNeverShows() {
        #expect(
            UnreachableNotice.shows(
                .verified, unverifiedSince: start, now: start.addingTimeInterval(60),
                after: delay) == false)
    }

    /// A slow but working launch: the check is in flight, and the app has nothing to report yet.
    @Test("a check still in flight says nothing, however long it takes")
    func verifyingNeverShows() {
        #expect(
            UnreachableNotice.shows(
                .verifying, unverifiedSince: start, now: start.addingTimeInterval(60),
                after: delay) == false)
    }

    @Test("an unverified session nobody timed says nothing")
    func unstampedNeverShows() {
        #expect(
            UnreachableNotice.shows(
                .unverified("can't reach it"), unverifiedSince: nil,
                now: start.addingTimeInterval(60), after: delay) == false)
    }

    @Test("inside the window the notice is still held back")
    func insideTheWindowStaysQuiet() {
        #expect(
            UnreachableNotice.shows(
                .unverified("can't reach it"), unverifiedSince: start,
                now: start.addingTimeInterval(1.9), after: delay) == false)
    }

    /// The boundary is inclusive: the wake fires at exactly the delay, and a notice that could not
    /// be shown at the instant it was armed for would need a second wake to arrive at all.
    @Test("at exactly the delay the notice shows")
    func theBoundaryIsInclusive() {
        #expect(
            UnreachableNotice.shows(
                .unverified("can't reach it"), unverifiedSince: start,
                now: start.addingTimeInterval(2), after: delay))
    }

    @Test("past the delay the notice shows")
    func pastTheWindowShows() {
        #expect(
            UnreachableNotice.shows(
                .unverified("can't reach it"), unverifiedSince: start,
                now: start.addingTimeInterval(5), after: delay))
    }

    /// A phone whose wall clock moved backwards between the stamp and the question — a time-zone
    /// sync, or a manual change. Negative elapsed time is not a reason to say anything.
    @Test("a clock that went backwards shows nothing")
    func aBackwardsClockShowsNothing() {
        #expect(
            UnreachableNotice.shows(
                .unverified("can't reach it"), unverifiedSince: start,
                now: start.addingTimeInterval(-30), after: delay) == false)
    }

    @Test("with no delay at all the stamp alone is enough")
    func aZeroDelayShowsAtOnce() {
        #expect(
            UnreachableNotice.shows(
                .unverified("can't reach it"), unverifiedSince: start, now: start,
                after: .zero))
    }
}
