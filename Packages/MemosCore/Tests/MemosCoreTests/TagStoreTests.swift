import Foundation
import MemosAPI
import MemosCore
import Testing

/// The store behind the search sheet's tag chips.
///
/// The server is a script under the REAL generated client, as everywhere in this bundle: the
/// request the store builds, the middleware that signs it and the decoding of the tag list are all
/// exercised. A stand-in for the store would prove only that the test agrees with itself.
@MainActor
@Suite("Tag store")
struct TagStoreTests {
    private nonisolated static let travelAndFood =
        #"[{"name":"travel","count":3},{"name":"food","count":1}]"#

    /// Keeps a request open until the test lets it go. `nonisolated static`, because it is called
    /// from inside the scripted transport, which the client runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("a load fills the tags from the server, in the order it sent them")
    func loadPopulatesTags() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Self.travelAndFood)
        }
        let store = TagStore()

        await store.load(using: client)

        #expect(store.tags == [MemoTag(name: "travel", count: 3), MemoTag(name: "food", count: 1)])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
        // Control: this really went to the tags endpoint, built by the generated client.
        #expect(paths.get() == ["/api/tags"])
    }

    /// A row that empties itself because one read failed says the household files nothing under
    /// anything, which is a worse lie than a row that is a few minutes stale.
    @Test("a failed load keeps the chips already on screen")
    func failedLoadKeepsPreviousTags() async {
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            return calls.count == 1
                ? Stub.json(Self.travelAndFood)
                : Stub.empty(.internalServerError)
        }
        let store = TagStore()
        await store.load(using: client)
        #expect(store.tags.count == 2)

        await store.load(using: client)

        #expect(store.tags.count == 2, "a failed load emptied the tags")
        #expect(store.lastError != nil, "the failure was swallowed")
        #expect(!store.isLoading)
        #expect(calls.count == 2, "control: the second load really was attempted")
    }

    /// The fence. Two openings of the sheet overlap when the first is slow, and the older answer
    /// describes a tag list that is one memo out of date.
    @Test("a load overtaken by a later one is dropped")
    func supersededLoadIsDropped() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count == 1 else { return Stub.json(#"[{"name":"food","count":9}]"#) }
            entered.set(true)
            try await Self.hold(until: release)
            // The tags as they stood before the memo was written.
            return Stub.json(#"[{"name":"travel","count":1}]"#)
        }
        let store = TagStore()

        let stale = Task { await store.load(using: client) }
        while !entered.get() {
            await Task.yield()
        }
        await store.load(using: client)
        #expect(store.tags == [MemoTag(name: "food", count: 9)], "the later load did not land")

        release.set(true)
        await stale.value

        #expect(
            store.tags == [MemoTag(name: "food", count: 9)],
            "the superseded load was written anyway"
        )
        #expect(!store.isLoading, "the superseded load cleared a flag it does not own")
        #expect(calls.count == 2, "control: the dropped load is one this store really did make")
    }
}
