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

    @Test("a load fills the tags from the server, in the order it sent them")
    func loadPopulatesTags() async {
        let paths = LockedValue<[String]>([])
        let client = Stub.client { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Self.travelAndFood)
        }
        let store = TagStore()

        await store.load(using: client.handle)

        #expect(store.tags == [MemoTag(name: "travel", count: 3), MemoTag(name: "food", count: 1)])
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
        #expect(store.hasLoaded, "an answered store does not say it has been answered")
        // Control: this really went to the tags endpoint, built by the generated client.
        #expect(paths.get() == ["/api/tags"])
    }

    /// The twin of the heatmap store's case, and for the same reason (MEMNG-175): an account with
    /// no tags and an account whose tags have not arrived hand the row the same empty list.
    @Test("an empty answer is still an answer, and an unanswered store says it has none")
    func anEmptyAnswerIsStillAnAnswer() async {
        let store = TagStore()
        #expect(!store.hasLoaded, "a store nobody has read says it has been answered")

        let client = Stub.client { _, _, _ in Stub.json("[]") }
        await store.load(using: client.handle)

        #expect(store.hasLoaded, "an answered store does not say it has been answered")
        #expect(store.tags.isEmpty)
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
        await store.load(using: client.handle)
        #expect(store.tags.count == 2)

        await store.load(using: client.handle)

        #expect(store.tags.count == 2, "a failed load emptied the tags")
        #expect(store.lastError != nil, "the failure was swallowed")
        #expect(!store.isLoading)
        #expect(calls.count == 2, "control: the second load really was attempted")
    }

    /// The fence. Two openings of the sheet overlap when the first is slow, and the older answer
    /// describes a tag list that is one memo out of date.
    @Test("a load overtaken by a later one is dropped")
    func supersededLoadIsDropped() async {
        let gate = RequestGate()
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count == 1 else { return Stub.json(#"[{"name":"food","count":9}]"#) }
            await gate.enter()
            // The tags as they stood before the memo was written.
            return Stub.json(#"[{"name":"travel","count":1}]"#)
        }
        let store = TagStore()

        let stale = Task { await store.load(using: client.handle) }
        // Both directions are the event itself, never a clock: this returns when the first request
        // has actually reached the gate.
        await gate.entered()
        await store.load(using: client.handle)
        #expect(store.tags == [MemoTag(name: "food", count: 9)], "the later load did not land")

        await gate.release()
        await stale.value

        #expect(
            store.tags == [MemoTag(name: "food", count: 9)],
            "the superseded load was written anyway"
        )
        #expect(!store.isLoading, "the superseded load cleared a flag it does not own")
        #expect(calls.count == 2, "control: the dropped load is one this store really did make")
    }

    /// The banner owns what an unreachable server says, and a sentence the server's own answer left
    /// behind is not about a request that never reached it: left standing, the row explains this
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
        let store = TagStore()
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
    /// air, so the row goes quiet about a 500 that nothing has replaced yet.
    @Test("the answered sentence stands until the request that never arrived has failed")
    func theAnsweredSentenceStandsWhileTheNextLoadIsOut() async {
        let gate = RequestGate()
        let calls = Counter()
        let client = Stub.client { _, _, _ in
            calls.increment()
            guard calls.count > 1 else { return Stub.empty(.internalServerError) }
            await gate.enter()
            throw URLError(.notConnectedToInternet)
        }
        let store = TagStore()
        let session = ReportingSink(for: client.handle)
        store.reports(to: session)

        await store.load(using: client.handle)
        #expect(store.lastError != nil, "the premise: the server's own answer wrote a sentence")

        let inFlight = Task { await store.load(using: client.handle) }
        // The event itself, never a clock: this returns when the second request has actually
        // reached the gate, so what is read below is read with that request still out.
        await gate.entered()
        #expect(
            store.lastError != nil,
            "the answer's sentence went when a request left rather than when one failed"
        )

        await gate.release()
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

/// A request held open until the test lets it go, and the test's own wait for it to get there.
///
/// Both halves are continuations rather than polls. A `while !flag { sleep(1ms) }` answers the same
/// question on an idle machine and, on a loaded one, spends the whole suite's patience finding out;
/// here the transport's arrival RESUMES the test and the test's release RESUMES the transport, so
/// the fence is exercised at whatever speed the host happens to be running at.
private actor RequestGate {
    private var arrived = false
    private var released = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Called from inside the scripted transport: announces the request, then holds it.
    func enter() async {
        arrived = true
        let waiting = arrivals
        arrivals = []
        for waiter in waiting { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Called from the test: returns once the request has reached the gate.
    func entered() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func release() {
        released = true
        let waiting = parked
        parked = []
        for waiter in waiting { waiter.resume() }
    }
}
