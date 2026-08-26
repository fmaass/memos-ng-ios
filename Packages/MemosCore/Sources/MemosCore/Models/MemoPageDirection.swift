import Foundation

/// Which way along the timeline one page is read.
///
/// The list has only ever paged one way: `created_before` fixes a ceiling, the cursor walks down
/// from it, and every page is older than the last. That is the whole of what a plain timeline
/// needs — its ceiling is now — but it is exactly half of what an ANCHORED list needs. A list
/// taken to a day in June has a ceiling in June and everything written since is above it, off the
/// top, unreachable by a cursor that only descends (MEMNG-179).
///
/// The server can express the other direction and always could: `GET /api/memos` takes
/// `created_after` (`Memo.created_at > created_after`, `app/services/memos.py:322-323`) and a
/// `sort` whose keyset cursor flips with it — ascending compares
/// `created_at > cursor OR (created_at == cursor AND id > cursor_id)` (`:342-361`). So this is not
/// a client-side simulation of paging; it is the same paging, read the other way up.
public enum MemoPageDirection: Sendable, Equatable, CaseIterable {
    /// Backwards from the anchor, newest of what is left first — the direction this list has
    /// always read.
    case older
    /// Forwards from the newest memo already loaded, towards now. Oldest of what is above first,
    /// so the page that arrives is the one directly ABOVE the list rather than the newest memo in
    /// the account with a hole under it.
    case newer

    /// What this direction puts in `sort`, or nil to leave the parameter off entirely.
    ///
    /// The older direction sends NOTHING. `-created_at` is the server's own default, so sending
    /// it would be the same request with an extra parameter on it — and "the same request" is
    /// meant literally here: the plain timeline's page is asserted as the exact parameter set
    /// `{limit}` (`TimelineStoreTests.anEmptyQuerySendsCursorAndLimitOnly`), and that assertion is
    /// what keeps this feature from quietly rewriting every request the app makes.
    public var sort: String? {
        switch self {
        case .older: nil
        case .newer: "created_at"
        }
    }
}

extension MemoQuery {
    /// This query as the parameters of ONE page, read in a direction, from a bound.
    ///
    /// Reading towards now DROPS `created_before`. The anchor's ceiling is the very thing being
    /// climbed over: kept, it would AND with `created_after` into a window that is empty by
    /// construction, and the newer page would come back empty for ever.
    ///
    /// `bound` is an instant rather than a day because it is the newest memo already loaded, not
    /// a date anybody chose — the page above the list is the page above the list's own top row,
    /// whatever day that row happens to fall on. A nil bound asks for the oldest memos the rest
    /// of the query matches, which is what an anchored list with nothing in it at all needs.
    public func parameters(
        in calendar: Calendar,
        direction: MemoPageDirection,
        after bound: Date? = nil
    ) -> Parameters {
        var parameters = self.parameters(in: calendar)
        guard direction == .newer else { return parameters }
        parameters.createdBefore = nil
        parameters.createdAfter = bound
        parameters.sort = direction.sort
        return parameters
    }
}
