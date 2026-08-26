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
            lastError = nil
        } catch {
            guard mine == attempt else { return }
            // The chips already on screen stay. A tag row that empties itself because one read
            // failed says the household has no tags, which is a worse lie than a stale one.
            let apiError =
                (error as? APIError) ?? .unexpected(description: error.localizedDescription)
            lastError = apiError.errorDescription
        }
        isLoading = false
    }
}
