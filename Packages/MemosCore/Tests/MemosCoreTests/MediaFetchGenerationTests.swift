import Foundation
import Testing

@testable import MemosCore

@Suite("The fetch generation")
struct MediaFetchGenerationTests {
    @Test("a request carries the generation it was made under")
    func aRequestCarriesItsGeneration() throws {
        let url = try #require(URL(string: "https://memos.example.invalid/api/attachments/a/thumb"))
        var request = URLRequest(url: url)
        // Nothing is assumed about a request nobody stamped. A default here is exactly the guess
        // that made the previous fence wrong.
        #expect(MediaFetchGeneration.generation(of: request) == nil)

        MediaFetchGeneration.stamp(&request, generation: 7)

        #expect(MediaFetchGeneration.generation(of: request) == 7)
    }

    @Test("the counter only ever moves forward")
    func theCounterOnlyMovesForward() {
        let clock = MediaFetchGeneration()

        #expect(clock.current == 0)
        #expect(clock.rotate() == 1)
        #expect(clock.rotate() == 2)
        #expect(clock.current == 2)
    }

    /// The half a per-process counter cannot do.
    ///
    /// The response cache is 256 MB on disk and outlives the process. A counter that restarted at
    /// zero on the next launch would hand the account signed in then exactly the keys the previous
    /// account's bytes are already filed under — which is the leak this whole change is about,
    /// arriving by a different door.
    @Test("the generation survives a launch")
    func theGenerationSurvivesALaunch() throws {
        let suite = "media.fetchGeneration.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let beforeTheLaunch = MediaFetchGeneration(defaults: defaults)
        beforeTheLaunch.rotate()
        beforeTheLaunch.rotate()

        // A second instance over the same store is what the next launch reads.
        let afterTheLaunch = MediaFetchGeneration(defaults: defaults)

        #expect(
            afterTheLaunch.current == 2,
            "a relaunch handed the next account the previous account's keys"
        )
    }

    /// Two clocks are two clocks — which is what lets one test rotate without moving another's.
    @Test("an unpersisted clock is nobody else's")
    func anUnpersistedClockIsIsolated() {
        let one = MediaFetchGeneration()
        let other = MediaFetchGeneration()

        one.rotate()

        #expect(one.current == 1)
        #expect(other.current == 0)
    }
}

@MainActor
@Suite("What a rotation does")
struct MediaIdentityRotationTests {
    @Test("a rotation moves the clock every cache is keyed by")
    func aRotationMovesTheClock() {
        let clock = MediaFetchGeneration()
        let identity = MediaIdentity(clock: clock)

        #expect(identity.generation == 0)
        identity.rotate()

        #expect(identity.generation == 1)
        #expect(clock.current == 1, "the identity and the caches read different clocks")
    }

    /// MEMNG-135's own acceptance line. It is reclamation rather than the fence — the entries are
    /// already unnameable once the clock has moved — but leaving 256 MB of an account that has
    /// signed out on the disk is not a thing to do on purpose.
    @Test("a rotation empties the response cache as well as moving the clock")
    func aRotationEmptiesTheResponseCache() {
        let spy = SpyCache(disk: 1024, capacity: 2048)
        let identity = MediaIdentity(clock: MediaFetchGeneration(), cache: { spy })

        identity.rotate()

        #expect(spy.calls.contains("removeAllCachedResponses"))
    }
}
