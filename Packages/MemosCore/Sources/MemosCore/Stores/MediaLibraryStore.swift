import Foundation
import MemosAPI

/// What the full-screen viewer needs of the list it is paging through.
///
/// The viewer is opened over the library grid and swipes through the SAME rows the grid holds, so
/// past the end of what is loaded it has to be able to ask for more. It asks through this rather
/// than through `MediaLibraryStore` itself for one reason: the viewer lives a layer above this one
/// and must be assertable there, and a protocol is what lets a test stand a list of a known length
/// in front of it without a server.
@MainActor
public protocol MediaLibraryPaging: AnyObject {
    var items: [MemoAttachment] { get }
    /// How many rows one request brings back — the size the near-end lookahead is measured in.
    var pageSize: Int { get }
    func shouldLoadMore(after index: Int, lookahead: Int) -> Bool
}

/// The media library: every picture and clip the household can see, one cursor page at a time.
///
/// It is a sibling of `TimelineStore` rather than a reuse of it — the two read different
/// endpoints, hold different rows and end their pages by different means — but the paging RULES
/// are deliberately the same ones, because they were learned the same way:
///
/// * the end of the list is the server saying so, never a short page. `GET /api/attachments`
///   answers with a bare array and puts its continuation token in the `X-Next-Cursor` header
///   (memos-ng `app/routers/assets.py`), so "no header" is the only end condition trusted here.
/// * a page that answers a list nobody is reading any more is DROPPED, cursor and all. A filter
///   change and a pull both genuinely overlap a scroll that is already fetching, and merging a
///   superseded page leaves `nextCursor` walking a lineage nothing is showing.
/// * rows are merged by identity, so a page that overlaps the one before it cannot show a file
///   twice or break SwiftUI's identity.
@MainActor
@Observable
public final class MediaLibraryStore: MediaLibraryPaging {
    public private(set) var items: [MemoAttachment] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var lastError: String?
    public private(set) var hasMore = true
    /// Which slice is being read. Changed only through `setFilter`, which is what resets the
    /// paging with it.
    public private(set) var filter: MediaLibraryFilter
    /// Which end of the library is first. Changed only through `setOrder`, for the same reason
    /// `filter` may only change through `setFilter`: the loaded rows and the cursor both describe
    /// one direction, and neither survives the other one being chosen (MEMNG-190).
    public private(set) var order: MediaLibraryOrder

    private var nextCursor: String?
    /// Which loaded list this is. Bumped wherever the list stops being the one an unanswered page
    /// was a continuation of: a refresh replacing it, and a filter change discarding it.
    private var generation = 0
    /// Read as well as written: the viewer measures its own near-end lookahead in pages of this
    /// size, so a store built with a different one moves the trigger with it.
    public let pageSize: Int
    private let onUnauthorized: @MainActor @Sendable () async -> Void

    public init(
        pageSize: Int = 60,
        filter: MediaLibraryFilter = .all,
        order: MediaLibraryOrder = .newestFirst,
        onUnauthorized: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.pageSize = pageSize
        self.filter = filter
        self.order = order
        self.onUnauthorized = onUnauthorized
    }

    /// Switches tab.
    ///
    /// The loaded rows go at once, which is the OPPOSITE of what `TimelineStore.setQuery` does and
    /// the same thing the SPA's resources view does (its query is keyed on the filter, so the grid
    /// empties and reloads). The two surfaces are not the same case: a timeline under a new filter
    /// still shows memos, a moment out of date; a library still showing photographs under "Videos"
    /// is showing files that do not belong in the tab that is open. Keeping them would be the
    /// wrong tab, not a stale one.
    public func setFilter(_ filter: MediaLibraryFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        items = []
        // The old cursor is a position inside the old tab's rows and describes nothing under this
        // one; `loadMore` reads nothing until a refresh hands it a cursor of this filter's own.
        nextCursor = nil
        hasMore = true
        lastError = nil
        // A page already in flight was a continuation of the tab it set out under.
        generation += 1
    }

    /// Turns the library round.
    ///
    /// It resets exactly what a tab change resets, and for a sharper version of the same reason: a
    /// cursor is a POSITION inside one ordering. Kept across a reversal it would page the wrong way
    /// through the middle of the library, and the rows above it would be the newest files sitting
    /// on top of a grid that now says "Oldest First". So the grid empties and reads its first page
    /// again, from the other end.
    public func setOrder(_ order: MediaLibraryOrder) {
        guard order != self.order else { return }
        self.order = order
        items = []
        nextCursor = nil
        hasMore = true
        lastError = nil
        generation += 1
    }

    /// Which list a page in flight belongs to — the generation, the filter AND the direction,
    /// because any of the three moving makes the answer a continuation of something nobody is
    /// reading any more.
    private struct Lineage: Equatable {
        var generation: Int
        var filter: MediaLibraryFilter
        var order: MediaLibraryOrder
    }

    private var lineage: Lineage {
        Lineage(generation: generation, filter: filter, order: order)
    }

    /// Which lineage the first page in flight belongs to, or nil when none is. `isLoading` alone
    /// cannot decide whether a refresh is redundant: the request a superseded filter left in
    /// flight is exactly what somebody changing tabs is waiting for the end of.
    private var loadingLineage: Lineage?

    public func refresh(using client: any APIProtocol, baseURL: URL) async {
        let lineage = self.lineage
        guard loadingLineage != lineage else { return }
        loadingLineage = lineage
        isLoading = true
        // Only the newest reader clears the flag: a superseded request finishing while the current
        // one is still out would take the spinner down over a list still being read.
        defer {
            if loadingLineage == lineage {
                loadingLineage = nil
                isLoading = false
            }
        }
        do {
            let page = try await Self.page(
                client,
                filter: lineage.filter,
                order: lineage.order,
                cursor: nil,
                limit: pageSize,
                baseURL: baseURL
            )
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/attachments answered for a list that has moved on")
                return
            }
            items = Self.merged([], with: page.items, filter: lineage.filter)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            lastError = nil
            // This IS a different list — a new lineage, whose cursor no page in flight shares.
            generation += 1
        } catch {
            // A failure belongs to the request that suffered it. One from a list nobody is reading
            // any more would put an error over a list that loaded perfectly well — and, on a 401,
            // end the session on the word of a request that has been superseded.
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/attachments failed for a list that has moved on")
                return
            }
            await report(error)
        }
    }

    /// Reads the page that follows the loaded ones — and reads it again, itself, when the list it
    /// was a continuation of is gone by the time it lands.
    ///
    /// The second read has to happen here: the next page is asked for when the last tile appears,
    /// and a tile already on screen does not appear a second time, so a reader sitting at the end
    /// of the grid would wait for a page this store had decided to throw away.
    public func loadMore(using client: any APIProtocol, baseURL: URL) async {
        guard !isLoadingMore, !isLoading, hasMore, nextCursor != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // The cursor and the lineage are re-read on every pass: after a drop, the page that comes
        // next is the CURRENT list's next page, not the one this call set out to fetch.
        while !isLoading, hasMore, let cursor = nextCursor {
            let lineage = self.lineage
            do {
                let page = try await Self.page(
                    client,
                    filter: lineage.filter,
                    order: lineage.order,
                    cursor: cursor,
                    limit: pageSize,
                    baseURL: baseURL
                )
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/attachments answered for a list that has moved on")
                    continue
                }
                items = Self.merged(items, with: page.items, filter: lineage.filter)
                nextCursor = page.nextCursor
                hasMore = page.nextCursor != nil
                lastError = nil
                return
            } catch {
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/attachments failed for a list that has moved on")
                    continue
                }
                await report(error)
                return
            }
        }
    }

    /// True once the reader is close enough to the end of the grid that the next page should
    /// already be on its way. Pure, so the trigger is unit-tested rather than inferred from a
    /// scroll position.
    ///
    /// The lookahead is a whole grid row rather than the timeline's three cards: tiles are small,
    /// several arrive per row, and a trigger that fires on the last tile alone fires when the gap
    /// is already visible.
    public func shouldLoadMore(after index: Int, lookahead: Int = 12) -> Bool {
        guard hasMore, !isLoadingMore, !isLoading, nextCursor != nil else { return false }
        return index >= items.count - lookahead
    }

    /// The loaded rows plus a page of new ones: in the tab's own kinds, each file once, in the
    /// order the server sent them.
    ///
    /// Pure and static so both merges — the refresh's and the next page's — are provably the same
    /// merge, and so the two rules it enforces can be asserted without a network.
    static func merged(
        _ loaded: [MemoAttachment],
        with page: [MemoAttachment],
        filter: MediaLibraryFilter
    ) -> [MemoAttachment] {
        var known = Set(loaded.map(\.uid))
        var out = loaded
        for item in page {
            guard filter.includes(item.mediaKind) else { continue }
            guard known.insert(item.uid).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// Says what went wrong — unless what went wrong was this app cancelling its own request.
    /// Same rule, same helper, as `TimelineStore.report`: a supersede cancels the transport before
    /// it moves the lineage, so the fence above cannot tell that `-999` from a real failure.
    private func report(_ error: any Error) async {
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        lastError = apiError.errorDescription
        if apiError == .unauthorized { await onUnauthorized() }
    }

    /// One page of the library.
    ///
    /// The continuation token is a HEADER here, not a field of the body: the endpoint answers with
    /// a bare array on every page, cursor or not, so `X-Next-Cursor` is where "there is more" is
    /// written and its absence is the end of the list.
    static func page(
        _ client: any APIProtocol,
        filter: MediaLibraryFilter,
        order: MediaLibraryOrder,
        cursor: String?,
        limit: Int,
        baseURL: URL
    ) async throws -> (items: [MemoAttachment], nextCursor: String?) {
        let response = try await client.listAttachmentsApiAttachmentsGet(
            .init(
                query: .init(
                    _type: filter.apiType,
                    limit: limit,
                    cursor: cursor,
                    // Written as a member of the generated enum rather than through a name this
                    // file spells out: what the generator calls that type is the generator's to
                    // decide, and this call is the only place the app has to agree with it.
                    order: order == .oldestFirst ? .asc : .desc
                )
            )
        )
        switch response {
        case .ok(let ok):
            let rows = try ok.body.json
            let next = ok.headers.xNextCursor
            let more = next != nil
            MemosLog.api.info(
                "GET /api/attachments -> 200, \(rows.count, privacy: .public) items, more: \(more)"
            )
            return (rows.map { MemoAttachment($0, baseURL: baseURL) }, next)
        case .unprocessableContent:
            throw APIError.server(status: 422)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
