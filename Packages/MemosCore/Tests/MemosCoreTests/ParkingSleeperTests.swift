import Foundation
import Testing

/// The parked-wait double the notice and recovery suites stand on.
///
/// Its waits record and park on a task of their own, off the test's turn, so a test that saw a
/// wait recorded can release before that wait has parked. A release that is lost there leaves the
/// wake behind it asleep for good, and the suite above reads the missing effect as a product
/// failure (MEMNG-628: "a success stamped with an ended generation leaves the live session exactly
/// as it was" saw no notice under build-host load).
@Suite("A parked wait the test lets go of")
struct ParkingSleeperTests {
    /// Polls a signal that crosses executors with a bound, so a wait that never ends FAILS rather
    /// than hanging the run.
    private func arrives(_ condition: () -> Bool, tries: Int = 500) async -> Bool {
        for _ in 0..<tries {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("a releaseAll that lands between a wait's recording and its parking still lets it go")
    func releaseAllBeforeParkingReleases() async throws {
        let sleeper = ParkingSleeper()
        let ended = LockedValue<Bool>(false)
        // The interleaving the scheduler only sometimes produces, produced every time: the release
        // arrives after the wait is recorded and before it parks.
        sleeper.betweenRecordingAndParking = { [weak sleeper] in sleeper?.releaseAll() }
        defer {
            sleeper.betweenRecordingAndParking = nil
            // A wait the release missed has parked by now; let it go so nothing is left behind.
            sleeper.releaseAll()
        }

        Task {
            await sleeper.sleep(.seconds(2))
            ended.set(true)
        }

        let recorded = await arrives({ !sleeper.waits.isEmpty })
        try #require(recorded, "the wait was recorded (control: the sleep was asked for)")
        let released = await arrives({ ended.get() })
        #expect(released, "the release that arrived before the wait parked still released it")
    }

    @Test("a releaseAll before any wait was asked for releases nothing that comes later")
    func releaseAllDoesNotReachALaterWait() async throws {
        let sleeper = ParkingSleeper()
        let ended = LockedValue<Bool>(false)
        sleeper.releaseAll()
        defer { sleeper.releaseAll() }

        Task {
            await sleeper.sleep(.seconds(2))
            ended.set(true)
        }

        let recorded = await arrives({ !sleeper.waits.isEmpty })
        try #require(recorded, "the wait was recorded")
        let parkedOn = await arrives({ ended.get() }, tries: 20)
        #expect(!parkedOn, "a wait recorded after the release stays parked until it is let go")
    }
}
