import Foundation
import MemosAPI

/// The timeline: one cursor-paginated page at a time.
///
/// The cursor comes from the server (`nextCursor`) rather than from an offset the client keeps:
/// memos are created and pinned while a reader scrolls, and an offset would silently skip or
/// repeat rows. `nextCursor == nil` is the server saying there is no next page — the only end
/// condition this store trusts.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var memos: [Memo] = []
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var lastError: String?
    public private(set) var hasMore = true

    private var nextCursor: String?
    private let pageSize: Int
    private let onUnauthorized: @MainActor @Sendable () async -> Void

    public init(
        pageSize: Int = 20,
        onUnauthorized: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.pageSize = pageSize
        self.onUnauthorized = onUnauthorized
    }

    public func refresh(using client: any APIProtocol, baseURL: URL) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await Self.page(client, cursor: nil, limit: pageSize, baseURL: baseURL)
            memos = page.memos
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            lastError = nil
        } catch {
            await report(error)
        }
    }

    public func loadMore(using client: any APIProtocol, baseURL: URL) async {
        guard !isLoadingMore, !isLoading, hasMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await Self.page(
                client, cursor: cursor, limit: pageSize, baseURL: baseURL
            )
            // A cursor page can overlap the one before it when a memo moved; appending blindly
            // would show the same memo twice and break SwiftUI's identity.
            let known = Set(memos.map(\.uid))
            memos += page.memos.filter { !known.contains($0.uid) }
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            lastError = nil
        } catch {
            await report(error)
        }
    }

    /// True once the reader is close enough to the end that the next page should already be on its
    /// way. Pure, so the trigger is unit-tested rather than inferred from a scroll position.
    public func shouldLoadMore(after index: Int, lookahead: Int = 3) -> Bool {
        guard hasMore, !isLoadingMore, !isLoading, nextCursor != nil else { return false }
        return index >= memos.count - lookahead
    }

    private func report(_ error: any Error) async {
        let apiError = (error as? APIError) ?? .unexpected(description: error.localizedDescription)
        lastError = apiError.errorDescription
        if apiError == .unauthorized { await onUnauthorized() }
    }

    static func page(
        _ client: any APIProtocol,
        cursor: String?,
        limit: Int,
        baseURL: URL
    ) async throws -> (memos: [Memo], nextCursor: String?) {
        let response = try await client.listMemosApiMemosGet(
            .init(query: .init(cursor: cursor, limit: limit))
        )
        switch response {
        case .ok(let ok):
            let list = try ok.body.json
            let count = list.items.count
            let more = list.nextCursor != nil
            MemosLog.api.info(
                "GET /api/memos -> 200, \(count, privacy: .public) memos, more: \(more)"
            )
            return (list.items.map { Memo($0, baseURL: baseURL) }, list.nextCursor)
        case .unprocessableContent:
            throw APIError.server(status: 422)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
