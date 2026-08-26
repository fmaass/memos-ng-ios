import Foundation
import MemosAPI
import MemosCore
import Testing

/// The store behind the activity card.
///
/// The server is a script under the REAL generated client, as everywhere in this bundle: the
/// request the store builds, the middleware that signs it and the decoding of the day map are all
/// exercised. A stand-in for the store would prove only that the test agrees with itself.
@MainActor
@Suite("Heatmap store")
struct HeatmapStoreTests {
    /// Keeps a request open until the test lets it go. `nonisolated static`, because it is called
    /// from inside the scripted transport, which the client runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("a load fills the day counts from the server's own keys")
    func loadPopulatesCounts() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(#"{"2026-08-24":1,"2026-08-25":2}"#)
        }
        let store = HeatmapStore()

        await store.load(using: client)

        #expect(store.counts == ["2026-08-24": 1, "2026-08-25": 2])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
        // Control: this really went to the heatmap endpoint, built by the generated client.
        #expect(paths.get() == ["/api/stats/heatmap"])
    }

    /// A heatmap that empties itself because one refresh failed says the household wrote nothing.
    @Test("a failed load keeps the counts already on screen")
    func failedLoadKeepsPreviousCounts() async {
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            return calls.count == 1
                ? Stub.json(#"{"2026-08-20":4}"#)
                : Stub.empty(.internalServerError)
        }
        let store = HeatmapStore()
        await store.load(using: client)
        #expect(store.counts == ["2026-08-20": 4])

        await store.load(using: client)

        #expect(store.counts == ["2026-08-20": 4], "a failed load emptied the heatmap")
        #expect(store.lastError != nil, "the failure was swallowed")
        #expect(!store.isLoading)
        #expect(calls.count == 2, "control: the second load really was attempted")
    }

    /// The fence. A delete finishes while a pull is still in the air, so two loads genuinely
    /// overlap — and the older answer describes a heatmap that is one memo out of date.
    @Test("a load overtaken by a later one is dropped")
    func supersededLoadIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count == 1 else { return Stub.json(#"{"2026-08-02":3}"#) }
            entered.set(true)
            try await Self.hold(until: release)
            // The heatmap as it stood before the memo was deleted.
            return Stub.json(#"{"2026-08-01":9}"#)
        }
        let store = HeatmapStore()

        let stale = Task { await store.load(using: client) }
        while !entered.get() {
            await Task.yield()
        }
        await store.load(using: client)
        #expect(store.counts == ["2026-08-02": 3], "the later load did not land")

        release.set(true)
        await stale.value

        #expect(store.counts == ["2026-08-02": 3], "the superseded load was written anyway")
        #expect(!store.isLoading, "the superseded load cleared a flag it does not own")
        #expect(calls.count == 2, "control: the dropped load is one this store really did make")
    }

    /// The control the fence needs to be worth anything: with nothing racing it, the very same
    /// held-open load lands exactly as it always did.
    @Test("a load nothing overtook is kept")
    func unopposedLoadIsKept() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(#"{"2026-08-01":9}"#)
        }
        let store = HeatmapStore()

        let inFlight = Task { await store.load(using: client) }
        while !entered.get() {
            await Task.yield()
        }
        release.set(true)
        await inFlight.value

        #expect(store.counts == ["2026-08-01": 9])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
    }
}
