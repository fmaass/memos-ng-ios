import Foundation
import MemosAPI

/// The account's tags and their counts, behind the chips the search sheet offers.
///
/// It is the heatmap store's twin and deliberately so: one read, held until a newer one replaces
/// it, fenced by a monotonic attempt id rather than serialised behind an `isLoading` guard —
/// serialising would drop the load that knows about the memo just written and keep the one that
/// does not (doctrine §3.1). What it does NOT do is refresh itself: the sheet that draws these
/// chips reads them when it opens, which is the only moment anybody is looking.
@MainActor
@Observable
public final class TagStore {
    /// Exactly what the server sent, in the order it sent it. Ordering and capping are the
    /// drawing surface's decisions (`TagChipsPresentation`), not this store's.
    public private(set) var tags: [MemoTag] = []
    public private(set) var isLoading = false
    /// Whether the server has ever answered this store — the difference between "no tags" and "no
    /// tags YET". `tags` is empty in both cases and `isLoading` is false before a load starts as
    /// well as after a cancelled one, so a row that reads either of those alone draws a household
    /// with a hundred tags as one with none (MEMNG-175).
    public private(set) var hasLoaded = false
    public private(set) var lastError: String?

    /// Which load is the current one — taken before the request goes out and checked before
    /// anything is written, so an answer to a question a later load has already re-asked cannot
    /// put a deleted tag back.
    private var attempt = 0

    /// Where a failure that never reached the server goes instead of `lastError`.
    ///
    /// Named by the owner rather than taken at construction, because this store is a view's
    /// `@State` initial value and there is no environment to read when that is built.
    private var session: (any SessionReporting)?

    public init() {}

    /// Whether the session that ISSUED an operation is still the one this device is running — the
    /// same rule, for the same reason, as `TimelineStore.sessionStillCurrent`.
    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    public func load(using handle: SessionHandle) async {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        attempt += 1
        let mine = attempt
        isLoading = true
        do {
            let loaded: [MemoTag]
            switch try await client.listTagsApiTagsGet(.init()) {
            case .ok(let ok):
                loaded = try ok.body.json.map(MemoTag.init)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
            // Superseded: a later load owns the state now, including `isLoading`, which is why
            // this returns rather than falling through to clear it.
            guard mine == attempt else {
                MemosLog.api.info("GET /api/tags answered for a load that was overtaken")
                return
            }
            if sessionStillCurrent(handle) {
                tags = loaded
                hasLoaded = true
                lastError = nil
                // Tags that arrived are the session's to act on, as a question and not an answer
                // (`noteTransportSuccess`).
                session?.noteTransportSuccess(issuedUnder: handle.generation)
            } else {
                MemosLog.api.info("an answer for a session that has ended is not applied")
            }
        } catch {
            guard mine == attempt else { return }
            // The chips already on screen stay. A tag row that empties itself because one read
            // failed says the household has no tags, which is a worse lie than a stale one.
            //
            // A cancellation is not a read that failed. This store's `.task` is torn down every
            // time the sheet goes away, and the `-999` that unwinds out of it is this app's own
            // doing — `StoreFailure` is where that is decided, once, for every store (MEMNG-180).
            //
            // Neither is a server that never answered. That one belongs to the session, which says
            // it once in a banner; saying it here as well is a second copy of the same sentence
            // over a row nobody can do anything about.
            // Fenced like every other apply point: an answer for a session that has ended is
            // not this one's to speak about — see `TimelineStore.report`. It falls THROUGH rather
            // than returning, because the spinner below is this call's own and nobody else is
            // coming to take it down.
            if !sessionStillCurrent(handle) {
                MemosLog.api.info("a failure for a session that has ended is not reported")
            } else if let failure = StoreFailure.transportFailure(error) {
                // And a sentence an earlier answer left must not stand in for this one: the banner
                // owns what an unreachable server says, and a stale "the server returned 500" under
                // it would be the row explaining this failure with the last one's words.
                lastError = nil
                session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            } else if let refusal = StoreFailure.refusal(error) {
                // One more arm in the chain and deliberately no `return`: the spinner below is this
                // call's own. A refusal of a credential this device has already replaced is not
                // this row's news, and "sign in again" over a session that renewed a second ago is
                // a false instruction.
                if session?.stillNamesCurrentCredential(refusal) ?? true {
                    lastError = refusal.errorDescription
                }
            } else if let apiError = StoreFailure.reportable(error) {
                lastError = apiError.errorDescription
            }
        }
        isLoading = false
    }
}
