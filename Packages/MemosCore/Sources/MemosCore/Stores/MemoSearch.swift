import Foundation
import MemosAPI

/// Everything a search has to say, as one value.
///
/// It is a value rather than a set of flags on the search itself because the same answer is said
/// in two places — the sheet the term is typed into, and the results screen pushed from it — and a
/// sentence written twice is a sentence that drifts. `title` and `detail` are the whole of the
/// copy; nothing that renders a search writes its own.
public enum MemoSearchOutcome: Sendable, Equatable {
    /// Nothing has been typed. The sheet is an invitation, not a result.
    case idle
    /// Something has been typed, but not enough of it to send.
    case tooShort(minimum: Int)
    case searching
    /// At least one memo. HOW MANY is deliberately not carried: the list is cursor-paginated, so
    /// the count on hand is the first page's, and "20 memos" over a list that has more is a number
    /// that is simply wrong.
    case matched
    case noMatches
    case failed(String)

    /// Why a search that found nothing is not the same as a memo that is gone.
    ///
    /// The server matches whole words — `to_tsvector('simple', content) @@
    /// plainto_tsquery('simple', q)` (memos-ng `app/services/memos.py:318-321`) — with no stemming
    /// and no prefix wildcard, so `trav` finds nothing at all while `travelling` sits in the list.
    /// Without this sentence that reads as a broken search.
    public static let wholeWordHint =
        "Memos are matched on whole words, so “trav” does not find “travelling”."

    public var title: String? {
        switch self {
        case .idle: "Search your memos"
        case .tooShort: "Keep typing"
        case .searching: "Searching…"
        case .matched: "Show results"
        case .noMatches: "No memos matched"
        case .failed: "Search failed"
        }
    }

    public var detail: String? {
        switch self {
        case .idle: Self.wholeWordHint
        case .tooShort(let minimum): "A search needs at least \(minimum) characters."
        case .searching: nil
        case .matched: nil
        case .noMatches: Self.wholeWordHint
        case .failed(let why): why
        }
    }
}

/// The search sheet's field, and the list it fills.
///
/// It owns a `TimelineStore` of its OWN rather than filtering the timeline's. The home list is
/// scrolled — often a long way — and a filter applied in place spends that scroll position to show
/// a result, then spends it again to take the filter off. A second store keeps both lists, and the
/// results screen is a push over a timeline that has not moved.
///
/// Two rules decide what reaches the network, and both exist because a search field is typed into
/// rather than submitted:
///
/// - **A minimum.** One character matches most of a household's memos; the request is a round trip
///   whose answer is noise. The field says so (`MemoSearchOutcome.tooShort`) instead of looking
///   broken.
/// - **A pause.** Every keystroke would otherwise be its own request, and the answers would race —
///   the one for `tra` landing after the one for `travel` and replacing it. So a keystroke
///   CANCELS the one waiting: one pause, one request, and it is the last term that goes.
///
/// The pause and the request it becomes are ONE task, which is what makes a cleared field able to
/// stop either of them with the same `cancel()`. Cancelling mid-request also cancels the transport,
/// so the failure that unwinds out of it belongs to a query the store has already moved off —
/// `TimelineStore`'s lineage fence drops it rather than putting "cancelled" on screen.
@MainActor
@Observable
public final class MemoSearch {
    /// Below this, nothing is sent. Two, because one character is not a search.
    public static let minimumTermLength = 2
    /// The web client's own debounce, so the two surfaces feel the same: memos-ng
    /// `frontend/src/components/FilterBar.vue:66` sets 300 ms on the free-text field.
    public static let coalescingPause = Duration.milliseconds(300)

    /// What is in the field, exactly as it was typed — trimming happens on the way to the wire,
    /// not on the way to the screen.
    public private(set) var term = ""
    public private(set) var outcome: MemoSearchOutcome = .idle
    /// The results, as their own list. Public because the results screen reads and pages it.
    public let results: TimelineStore

    private let client: any APIProtocol
    private let baseURL: URL
    private let pause: Duration
    /// How the debounce waits — the real `Task.sleep` in the app, a clock a test can hold
    /// still. It is injected because the whole point of the pause is that a keystroke
    /// arriving DURING it cancels the request, and a test cannot prove that against a wall
    /// clock it does not control: it has to be able to keep a task parked in the pause while
    /// it delivers the next keystroke.
    private let sleep: @Sendable (Duration) async -> Void
    /// The pause and the request it turns into. One task, so one `cancel()` reaches both.
    private var work: Task<Void, Never>?
    /// The query the work in flight was scheduled for, so a keystroke that changes nothing the
    /// server would see — a trailing space, the same word retyped — does not re-ask.
    private var asked: MemoQuery?

    public init(
        client: any APIProtocol,
        baseURL: URL,
        coalescing: Duration = MemoSearch.coalescingPause,
        pageSize: Int = 20,
        calendar: Calendar = .current,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onUnauthorized: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.client = client
        self.baseURL = baseURL
        self.pause = coalescing
        self.sleep = sleep
        self.results = TimelineStore(
            pageSize: pageSize,
            calendar: calendar,
            onUnauthorized: onUnauthorized
        )
    }

    /// What the field now holds.
    ///
    /// Called on every keystroke, including the one that empties it: clearing is not a separate
    /// operation, it is the term becoming nothing, and it has to stop the search for the same
    /// reason a shorter term must never start one.
    public func typed(_ raw: String) {
        term = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumTermLength else {
            stop()
            outcome = trimmed.isEmpty ? .idle : .tooShort(minimum: Self.minimumTermLength)
            return
        }
        let query = MemoQuery(term: trimmed)
        guard query != asked else { return }
        asked = query
        outcome = .searching
        work?.cancel()
        work = Task { [self] in
            await self.sleep(self.pause)
            // The keystroke after this one cancelled the pause; the term it carries is the one
            // that gets a request.
            guard !Task.isCancelled else { return }
            results.setQuery(query)
            await results.refresh(using: client, baseURL: baseURL)
            // Cancelled DURING the request — the field was cleared or retyped while it was out.
            // Saying anything now would be an answer to a question nobody is still asking.
            guard !Task.isCancelled else { return }
            outcome = Self.answer(from: results)
        }
    }

    /// Runs a query the FIELD did not produce — a tag chip today, the month scrubber next.
    ///
    /// There is no pause. The debounce exists because a field is typed into one character at a
    /// time; a chip is tapped once, and a tap that sat still for 300 ms would read as a chip that
    /// did not work.
    ///
    /// `showing` is what the field then holds, so the sheet says what it found results FOR.
    /// Editing it from there is an ordinary text search again, which is honest: the field is a
    /// field, not a token — and the tag it was standing in for is on the wire as `tag`, not `q`.
    public func run(_ query: MemoQuery, showing text: String) {
        // An empty query is the WHOLE timeline. Run as a search it would put every memo the
        // account can see behind "Show results" as though each one had matched — which is exactly
        // what a blank or space-only tag becomes, because `MemoQuery` normalises it away.
        guard !query.isEmpty else { return }
        term = text
        guard query != asked else { return }
        asked = query
        outcome = .searching
        work?.cancel()
        work = Task { [self] in
            results.setQuery(query)
            await results.refresh(using: client, baseURL: baseURL)
            // Cancelled during the request — the sheet was dismissed, or another chip tapped.
            guard !Task.isCancelled else { return }
            outcome = Self.answer(from: results)
        }
    }

    /// Waits for whatever this search has in flight: the pause, and the request it becomes.
    ///
    /// The results screen awaits it before it decides between a list and an empty state, so a
    /// push that lands mid-search does not paint "no memos matched" over a search still running.
    public func settled() async {
        await work?.value
    }

    /// Cancels the pause and the request it had become, and forgets what it was for — but
    /// leaves the loaded rows where they are.
    ///
    /// This is the whole of what dismissing the sheet HAS to do: a debounced or in-flight
    /// task that outlived the sheet would go on to write a result into a model nobody is
    /// looking at any more. It is separate from `stop` because the sheet has one close that
    /// is not an abandonment — a hand-off to the results screen, which has just adopted this
    /// store — and resetting the store there would empty the list the reader is walking into
    /// and cost it the cursor its next page needs.
    public func cancelInFlight() {
        work?.cancel()
        asked = nil
    }

    /// Abandons the search entirely: cancels it AND resets the store to the plain timeline.
    ///
    /// `setQuery` is what makes the cancellation safe rather than merely fast: it moves the
    /// store's lineage, so a page or a failure already on its way answers a query nobody is
    /// reading and is dropped on arrival (`TimelineStore.refresh`) instead of landing over an
    /// empty field. Used by a cleared field and by every sheet close that is not a hand-off.
    public func stop() {
        cancelInFlight()
        results.setQuery(.empty)
        // Back to the blank sheet. An abandoned search left reading `.searching` is a state
        // nothing would ever move off — the reopened sheet builds a fresh search, but the
        // model should not sit in a lie in the meantime. The hand-off path deliberately does
        // NOT come through here: its `.matched` is what the results screen reads.
        outcome = .idle
    }

    /// What the store's own state means to a person who typed a word.
    ///
    /// An empty page is an ANSWER — the query ran, the server replied, nothing matched — and the
    /// only thing that makes it a failure is a failure.
    private static func answer(from results: TimelineStore) -> MemoSearchOutcome {
        if let error = results.lastError { return .failed(error) }
        return results.memos.isEmpty ? .noMatches : .matched
    }
}
