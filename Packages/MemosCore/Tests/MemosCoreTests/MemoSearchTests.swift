import Foundation
import MemosAPI
import MemosCore
import Testing

/// What the search sheet's field does to the network.
///
/// Everything here runs against the REAL generated client over a scripted transport, so a claim
/// about "reaching the network" is a claim about a request that was or was not built — not about a
/// stand-in agreeing with the test that wrote it. The coalescing pause is injected rather than
/// waited out: what matters is that a keystroke arriving during the pause replaces the one before
/// it, and that is the same behaviour at 30 ms as at the shipped 300.
@MainActor
@Suite("Search sheet")
struct MemoSearchTests {
    /// Short enough that a suite does not sit through the shipped pause four times over, long
    /// enough that a request really does have to wait for it.
    private static let pause = Duration.milliseconds(30)

    private static func search(
        coalescing: Duration = Self.pause,
        handler: @escaping StubTransport.Handler
    ) -> MemoSearch {
        MemoSearch(
            client: Stub.client(handler: handler),
            baseURL: Stub.baseURL,
            coalescing: coalescing
        )
    }

    private static func sent(_ path: String) -> [String: [String]] {
        var parsed: [String: [String]] = [:]
        for item in URLComponents(string: path)?.queryItems ?? [] {
            parsed[item.name, default: []].append(item.value ?? "")
        }
        return parsed
    }

    /// Keeps a scripted request open until the test lets it go. `nonisolated`, because the
    /// transport runs off the main actor.
    private nonisolated static func hold(until release: LockedValue<Bool>) async throws {
        while !release.get() {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// A term below the minimum is not a short search, it is no search: `q=t` over a household's
    /// memos matches almost everything, and the request is a round trip whose answer nobody can
    /// use. The minimum is stated by the presentation as well, so the field says why nothing is
    /// happening rather than looking broken.
    @Test("a term shorter than the minimum never reaches the network")
    func aTermUnderTheMinimumIsNeverSent() async {
        let paths = LockedValue<[String]>([])
        let search = Self.search { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        search.typed("t")
        await search.settled()

        #expect(paths.get().isEmpty, "a one-character term reached the server")
        #expect(search.outcome == .tooShort(minimum: MemoSearch.minimumTermLength))
        #expect(MemoSearch.minimumTermLength == 2)
        #expect(
            search.outcome.detail?.contains("2") == true,
            "the presentation does not say what the minimum is: \(search.outcome.detail ?? "nil")"
        )

        // A term that is only spaces is not a search either, however long it is.
        search.typed("     ")
        await search.settled()
        #expect(paths.get().isEmpty, "a term of spaces reached the server")

        // Positive control: the same field, one real character longer, DOES reach it — so the
        // silence above is the minimum and not a search that never works.
        search.typed("tr")
        await search.settled()
        #expect(paths.get().count == 1, "the term at the minimum was not sent")
        #expect(Self.sent(paths.get()[0])["q"] == ["tr"])
    }

    /// A person types a word; the app must not ask the server about every prefix of it. The
    /// coalescing is DRIVEN here, not timed: the debounce sleeps against an injected clock the
    /// test holds still, so each keystroke's task genuinely PARKS in the pause and the next
    /// keystroke cancels a task that is really waiting — which is the only thing the pause buys.
    ///
    /// The zero-pause control at the end is what makes this test able to fail: the SAME code with
    /// the pause removed lets every keystroke race to its own request. So one request with the
    /// pause and one-per-keystroke without it is proof the pause is load-bearing — an earlier
    /// version of this test typed synchronously and would have passed with the debounce deleted,
    /// because the cancel alone coalesces keystrokes that never got to run (Codex review of
    /// f5699b0).
    @Test("typing coalesces into one request")
    func typingCoalescesIntoOneRequest() async {
        // The pin the injected clock below cannot provide: the mechanics inject their own
        // pause, so this one line is what fails if the SHIPPED default is regressed to zero —
        // the pause the app actually runs (`TimelineView` constructs `MemoSearch` without an
        // override, so it is `coalescingPause`).
        #expect(
            MemoSearch.coalescingPause > .zero,
            "the shipped debounce pause was regressed to zero — typing would not coalesce"
        )

        let paths = LockedValue<[String]>([])
        let gate = DebounceGate()
        let search = MemoSearch(
            client: Stub.client { request, _, _ in
                paths.set(paths.get() + [request.path ?? ""])
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            },
            baseURL: Stub.baseURL,
            coalescing: .milliseconds(300),
            sleep: { await gate.sleep($0) }
        )

        let terms = ["tr", "tra", "trav", "trave"]
        for (index, term) in terms.enumerated() {
            search.typed(term)
            // Wait until this keystroke's task has entered the debounce and parked, so the next
            // keystroke cancels a task that is genuinely waiting. A bounded spin, so a build that
            // deleted the sleep entirely fails on the request count below instead of hanging here.
            var spins = 0
            while await gate.entries() < index + 1 {
                await Task.yield()
                spins += 1
                if spins > 100_000 { break }
            }
        }
        await gate.releaseAll()
        await search.settled()

        #expect(paths.get().count == 1, "typing sent \(paths.get().count) requests")
        #expect(
            Self.sent(paths.get()[0])["q"] == ["trave"],
            "the one request that went carried a term the field had already moved past"
        )

        // Control: the SAME setup with a zero pause. The debounce is what coalesces, so with none
        // every keystroke reaches the server — one request per key, not one for the word. This
        // both proves the assertion above is not vacuous and is the red the review asked for,
        // made permanent: it fails the moment the pause stops holding tasks back.
        let zeroPaths = LockedValue<[String]>([])
        let zeroGate = DebounceGate()
        let zero = MemoSearch(
            client: Stub.client { request, _, _ in
                zeroPaths.set(zeroPaths.get() + [request.path ?? ""])
                return Stub.json(Stub.memoList(["a"], nextCursor: nil))
            },
            baseURL: Stub.baseURL,
            coalescing: .zero,
            sleep: { await zeroGate.sleep($0) }
        )
        for (index, term) in terms.enumerated() {
            zero.typed(term)
            // Wait for THIS keystroke's request to land before the next, so nothing coalesces by
            // accident of timing: with no pause each key really does get its own request.
            var spins = 0
            while zeroPaths.get().count < index + 1 {
                await Task.yield()
                spins += 1
                if spins > 100_000 { break }
            }
        }
        await zero.settled()
        #expect(
            zeroPaths.get().count == terms.count,
            """
            without the pause the keystrokes still coalesced to \(zeroPaths.get().count); \
            the coalescing assertion above would then pass with the debounce disabled
            """
        )
    }

    /// Clearing the field is how a person takes a search back, and the answer to a search nobody
    /// is waiting for must not arrive over the top of it. The request is cancelled where it
    /// stands: the field is empty again immediately, and the page it would have published never
    /// lands.
    @Test("a cleared field cancels the in-flight search")
    func clearingCancelsTheRequestInFlight() async {
        let entered = LockedValue<Bool>(false)
        let paths = LockedValue<[String]>([])
        let search = Self.search { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            entered.set(true)
            // Long enough that a test which finishes before it can only have cancelled it.
            try await Task.sleep(for: .seconds(30))
            return Stub.json(Stub.memoList(["late"], nextCursor: nil))
        }

        search.typed("travel")
        while !entered.get() {
            await Task.yield()
        }

        let started = ContinuousClock.now
        search.typed("")
        await search.settled()
        let waited = ContinuousClock.now - started

        #expect(waited < .seconds(5), "the cleared field waited for the answer it had abandoned")
        #expect(search.results.memos.isEmpty, "a cancelled search still published its page")
        // An abandoned request is not a failure to report: a cancellation surfacing as an error
        // would put "the operation was cancelled" on screen for someone who simply cleared a field.
        #expect(search.results.lastError == nil, "a cancelled search reported an error")
        #expect(search.outcome == .idle)
        // Positive control: the request really was in flight, so the cancellation cancelled
        // something rather than arriving before anything had started.
        #expect(paths.get().count == 1)
    }

    /// Nothing found is an answer, not a fault — and because the server matches WHOLE WORDS
    /// (`to_tsvector('simple', content) @@ plainto_tsquery('simple', q)`, `app/services/memos.py`),
    /// the answer has to say so before a person concludes the memo is gone.
    @Test("an empty result reads as no memos matched, not as an error")
    func anEmptyResultIsNotAnError() async {
        let search = Self.search { _, _, _ in
            Stub.json(Stub.page([], nextCursor: nil))
        }

        search.typed("travel")
        await search.settled()

        #expect(search.results.memos.isEmpty)
        #expect(search.results.lastError == nil, "an empty page was reported as a failure")
        #expect(search.outcome == .noMatches)
        #expect(search.outcome.title == "No memos matched")
        #expect(
            search.outcome.detail?.contains("whole words") == true,
            "the empty state does not explain whole-word matching: \(search.outcome.detail ?? "")"
        )

        // Positive control, one: a page that HAS a memo does not read as empty.
        let found = Self.search { _, _, _ in
            Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        found.typed("travel")
        await found.settled()
        #expect(found.outcome == .matched)

        // Positive control, two: a search that really did fail reads as a failure. Without it,
        // "no memos matched" could be what this search says about everything.
        let broken = Self.search { _, _, _ in
            Stub.empty(.internalServerError)
        }
        broken.typed("travel")
        await broken.settled()
        #expect(broken.outcome != .noMatches, "a 500 was reported as an empty result")
        #expect(broken.results.lastError != nil)
    }

    /// Dismissing the sheet has to ABANDON the search, not merely hide it. A debounced or
    /// in-flight task that outlived the sheet would go on to write a result into a model nobody is
    /// looking at any more — the very thing `TimelineView`'s `onDismiss` now guards against by
    /// calling this. Tested at the model, where the guarantee actually lives: the view wiring is
    /// one line that funnels every close through it.
    @Test("dismissing abandons the search in flight and mutates nothing after")
    func dismissingAbandonsThePendingSearch() async {
        let entered = LockedValue<Bool>(false)
        let release = LockedValue<Bool>(false)
        let search = Self.search { _, _, _ in
            entered.set(true)
            try await Self.hold(until: release)
            return Stub.json(Stub.memoList(["late"], nextCursor: nil))
        }

        search.typed("travel")
        while !entered.get() {
            await Task.yield()
        }

        // The sheet goes away — Done, or a swipe UIKit performs without telling the app.
        search.stop()
        await search.settled()
        // Let the abandoned request finish: it must change nothing, because the store's lineage
        // moved out from under it when the search was abandoned.
        release.set(true)
        for _ in 0..<50 {
            await Task.yield()
        }

        #expect(search.results.memos.isEmpty, "an abandoned search still published its page")
        #expect(search.results.lastError == nil, "an abandoned search reported an error")
        #expect(search.outcome == .idle)

        // Control: the SAME search NOT dismissed does complete — so the emptiness above is the
        // abandonment and not a search that never works.
        let control = Self.search { _, _, _ in
            Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }
        control.typed("travel")
        await control.settled()
        #expect(control.outcome == .matched)
        #expect(control.results.memos.map(\.uid) == ["a"])
    }

    /// A tag chip is not a word. It goes out as `tag`, not as `q`, and that is the difference
    /// between the memos FILED under #travel and the memos that happen to contain the word.
    @Test("a tag chip searches by tag, not by text")
    func aTagChipSendsATagFilter() async {
        let paths = LockedValue<[String]>([])
        let search = Self.search { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        search.run(MemoQuery(tags: ["travel"]), showing: "#travel")
        await search.settled()

        #expect(search.term == "#travel", "the field does not say what it found results for")
        #expect(search.outcome == .matched)
        #expect(search.results.memos.map(\.uid) == ["a"])
        let requests = paths.get().map { Self.sent($0) }
        #expect(requests.count == 1)
        #expect(requests.first?["tag"] == ["travel"])
        #expect(requests.first?["q"] == nil, "a tag went out as a text search")
    }

    /// The refusal that matters. A blank tag normalises to the EMPTY query, which IS the plain
    /// timeline — run as a search it would put every memo the account can see behind "Show
    /// results" as though each one had matched.
    @Test("a query that asks for everything is never run as a search")
    func anEmptyQueryIsRefused() async {
        let paths = LockedValue<[String]>([])
        let search = Self.search { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        search.run(MemoQuery(tags: ["   "]), showing: "#   ")
        await search.settled()

        #expect(paths.get().isEmpty, "the whole timeline was fetched as a search")
        #expect(search.outcome == .idle)
        #expect(search.term.isEmpty, "the field was written for a search that never ran")

        // Positive control: a real tag through the very same call does reach the network.
        search.run(MemoQuery(tags: ["travel"]), showing: "#travel")
        await search.settled()
        #expect(paths.get().count == 1)
    }
}

/// A clock the debounce is driven against, so a test can keep a task parked in the pause while it
/// delivers the next keystroke. It counts entries (a keystroke reached the pause) and parks every
/// positive-duration sleep until released; a zero pause returns at once, exactly as `Task.sleep`
/// does, which is what lets the control prove the pause is load-bearing.
private actor DebounceGate {
    private var entered = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        entered += 1
        if duration == .zero { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func entries() -> Int { entered }

    func releaseAll() {
        let waiters = parked
        parked = []
        for waiter in waiters { waiter.resume() }
    }
}
