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
        coalescing: Duration = pause,
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

    /// A person types a word; the app must not ask the server about every prefix of it. The pause
    /// is the web client's 300 ms, and each keystroke replaces the one waiting rather than queuing
    /// behind it.
    @Test("typing coalesces into one request")
    func typingCoalescesIntoOneRequest() async {
        let paths = LockedValue<[String]>([])
        let search = Self.search { request, _, _ in
            paths.set(paths.get() + [request.path ?? ""])
            return Stub.json(Stub.memoList(["a"], nextCursor: nil))
        }

        // Four keystrokes with nothing awaited between them: one person typing, not four searches.
        for term in ["tr", "tra", "trav", "trave"] {
            search.typed(term)
        }
        await search.settled()

        #expect(paths.get().count == 1, "typing sent \(paths.get().count) requests")
        #expect(
            Self.sent(paths.get()[0])["q"] == ["trave"],
            "the one request that went carried a term the field had already moved past"
        )

        // Positive control: a term typed after the pause is its own request. The rule is a pause,
        // not a cap of one request per search — without this a store that sent nothing at all
        // after the first search would pass the assertion above.
        search.typed("holiday")
        await search.settled()
        #expect(paths.get().count == 2, "a second search after the pause was swallowed")
        #expect(Self.sent(paths.get()[1])["q"] == ["holiday"])
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
            "the empty state does not explain whole-word matching: "
                + (search.outcome.detail ?? "nil")
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
}
