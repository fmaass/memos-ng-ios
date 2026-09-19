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

        await store.load(using: client.handle)

        #expect(store.counts == ["2026-08-24": 1, "2026-08-25": 2])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
        // Control: this really went to the heatmap endpoint, built by the generated client.
        #expect(paths.get() == ["/api/stats/heatmap"])
    }

    /// The one fact the card cannot work out for itself (MEMNG-175): an account that has written
    /// nothing and an account whose counts have not arrived hand it the SAME empty map, and
    /// `isLoading` is false on both sides of a load. Drawing the first over the second is how the
    /// first open of the search sheet came to say "No memos in the last 12 weeks".
    @Test("an empty answer is still an answer, and an unanswered store says it has none")
    func anEmptyAnswerIsStillAnAnswer() async {
        let release = LockedValue<Bool>(false)
        let client = Stub.client { _, _, _ in
            try await Self.hold(until: release)
            return Stub.json("{}")
        }
        let store = HeatmapStore()
        #expect(!store.hasLoaded, "a store nobody has read says it has been answered")

        let reading = Task { await store.load(using: client.handle) }
        while !store.isLoading {
            await Task.yield()
        }
        #expect(!store.hasLoaded, "a store answered nothing yet while its read was still out")
        #expect(store.counts.isEmpty)

        release.set(true)
        await reading.value

        // The emptiness is now the news rather than the absence of it — the same counts, the
        // opposite meaning.
        #expect(store.hasLoaded, "an answered store does not say it has been answered")
        #expect(store.counts.isEmpty)
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
        await store.load(using: client.handle)
        #expect(store.counts == ["2026-08-20": 4])

        await store.load(using: client.handle)

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

        let stale = Task { await store.load(using: client.handle) }
        while !entered.get() {
            await Task.yield()
        }
        await store.load(using: client.handle)
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

        let inFlight = Task { await store.load(using: client.handle) }
        while !entered.get() {
            await Task.yield()
        }
        release.set(true)
        await inFlight.value

        #expect(store.counts == ["2026-08-01": 9])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
    }

    /// The banner owns what an unreachable server says, and a sentence the server's own answer left
    /// behind is not about a request that never reached it: left standing, the card explains this
    /// failure with the last one's words — and the sheet reads that sentence as a section that has
    /// something to say.
    @Test("a load that never reached the server takes the last answer's sentence down")
    func transportFailureClearsTheAnsweredSentence() async {
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count > 1 else { return Stub.empty(.internalServerError) }
            throw URLError(.notConnectedToInternet)
        }
        let store = HeatmapStore()
        let session = ReportingSink(for: client.handle)
        store.reports(to: session)

        await store.load(using: client.handle)
        #expect(store.lastError != nil, "the premise: the server's own answer wrote a sentence")

        await store.load(using: client.handle)

        #expect(store.lastError == nil, "a server that never answered kept the 500's words")
        #expect(session.transportFailures == [.offline], "the session was never told")
        #expect(!store.isLoading, "the transport arm stopped falling through to the spinner")
    }

    /// The witness against the cheaper rule that passes the case above. Clearing the sentence when
    /// a load BEGINS blanks an answer the server really gave while the next request is still in the
    /// air, so the card goes quiet about a 500 that nothing has replaced yet.
    @Test("the answered sentence stands until the request that never arrived has failed")
    func theAnsweredSentenceStandsWhileTheNextLoadIsOut() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count > 1 else { return Stub.empty(.internalServerError) }
            entered.set(true)
            try await Self.hold(until: release)
            throw URLError(.notConnectedToInternet)
        }
        let store = HeatmapStore()
        let session = ReportingSink(for: client.handle)
        store.reports(to: session)

        await store.load(using: client.handle)
        #expect(store.lastError != nil, "the premise: the server's own answer wrote a sentence")

        let inFlight = Task { await store.load(using: client.handle) }
        while !entered.get() {
            await Task.yield()
        }
        #expect(
            store.lastError != nil,
            "the answer's sentence went when a request left rather than when one failed"
        )

        release.set(true)
        await inFlight.value

        #expect(store.lastError == nil, "a server that never answered kept the 500's words")
        #expect(
            session.transportFailures == [.offline],
            "control: the held request really did fail at the transport"
        )
    }
}

/// The session as the reporting stores see it, held still so a test can read back what it was told.
///
/// The protocol rather than a whole `SessionStore` (`SessionReporting`): what is asserted here is
/// that the failure reached the sink at all, and a session brings a sign-in, a credential and a
/// verification state that say nothing about that.
private final class ReportingSink: SessionReporting {
    let activeHandle: SessionHandle?
    nonisolated let sessionIncarnation = SessionEpoch()
    private(set) var transportFailures: [ServerReachability.Reason] = []

    init(for handle: SessionHandle) { activeHandle = handle }

    func stillNamesCurrentCredential(_ refusal: CredentialRefusal) -> Bool { true }

    func noteTransportFailure(
        _ failure: ServerReachability.Reason,
        issuedUnder generation: Int
    ) {
        transportFailures.append(failure)
    }

    func noteTransportSuccess(issuedUnder generation: Int) {}
}
