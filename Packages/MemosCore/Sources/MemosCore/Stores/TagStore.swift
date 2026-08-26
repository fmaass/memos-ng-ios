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

    public init() {}

    public func load(using client: any APIProtocol) async {
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
            tags = loaded
            hasLoaded = true
            lastError = nil
        } catch {
            guard mine == attempt else { return }
            // The chips already on screen stay. A tag row that empties itself because one read
            // failed says the household has no tags, which is a worse lie than a stale one.
            //
            // A cancellation is not a read that failed. This store's `.task` is torn down every
            // time the sheet goes away, and the `-999` that unwinds out of it is this app's own
            // doing — `StoreFailure` is where that is decided, once, for every store (MEMNG-180).
            if let apiError = StoreFailure.reportable(error) {
                lastError = apiError.errorDescription
            }
        }
        isLoading = false
    }
}
