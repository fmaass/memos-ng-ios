import Foundation
import MemosAPI

/// The per-day memo counts behind the activity card.
///
/// `GET /api/stats/heatmap` answers with a flat `{"YYYY-MM-DD": count}` covering ALL of the
/// account's history — the endpoint takes no window, so the window is the view's to choose
/// (`HeatmapPresentation`). This store's whole job is to hold the last answer the server gave, and
/// to make sure the answer it holds is the LATEST one.
///
/// Two things load it: the screen appearing or being pulled, and a memo arriving or being deleted.
/// Those overlap in the app — a delete finishes while a pull is still in the air — so this store
/// is fenced rather than serialised (doctrine §3.1). Serialising them with a `guard !isLoading`
/// would drop the load that knows about the delete and keep the one that does not.
@MainActor
@Observable
public final class HeatmapStore {
    /// Days to memo counts, keyed exactly as the server keys them.
    public private(set) var counts: [String: Int] = [:]
    public private(set) var isLoading = false
    public private(set) var lastError: String?

    /// Which load is the current one. A monotonic attempt id, taken before the request goes out
    /// and checked before anything is written: an answer to a question a later load has already
    /// re-asked describes a heatmap that is one memo out of date, and writing it would put a
    /// just-deleted day's square back.
    private var attempt = 0

    public init() {}

    public func load(using client: any APIProtocol) async {
        attempt += 1
        let mine = attempt
        isLoading = true
        do {
            let loaded: [String: Int]
            switch try await client.statsHeatmapApiStatsHeatmapGet(.init()) {
            case .ok(let ok):
                loaded = try ok.body.json.additionalProperties
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
            // Superseded: a later load owns the state now, including `isLoading`, which is why
            // this returns rather than falling through to clear it.
            guard mine == attempt else {
                MemosLog.api.info("GET /api/stats/heatmap answered for a load that was overtaken")
                return
            }
            counts = loaded
            lastError = nil
        } catch {
            guard mine == attempt else { return }
            // The counts already on screen stay. A heatmap that empties itself because one
            // refresh failed says the household wrote nothing, which is a worse lie than a
            // heatmap that is a few minutes stale.
            //
            // A cancellation is not a refresh that failed — see `StoreFailure` (MEMNG-180).
            if let apiError = StoreFailure.reportable(error) {
                lastError = apiError.errorDescription
            }
        }
        isLoading = false
    }
}
