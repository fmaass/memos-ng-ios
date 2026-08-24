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

    // MARK: - writes

    /// Creates a memo and puts it where the server would have.
    ///
    /// Tags are not a field: the server derives them from the hashtags in the content, so a
    /// separate tag input here would be a second source of truth that the next edit silently
    /// overrules.
    ///
    /// A `nil` visibility is left OUT of the request rather than guessed at, so the server applies
    /// the account's own default — the app has no business deciding who can see a memo.
    @discardableResult
    public func create(
        content: String,
        visibility: MemoVisibility? = nil,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        do {
            let response = try await client.createMemoApiMemosPost(
                .init(body: .json(.init(content: content, visibility: visibility?.generated)))
            )
            switch response {
            case .created(let created):
                let memo = Memo(try created.body.json, baseURL: baseURL)
                memos.insert(memo, at: Self.insertionIndex(for: memo, in: memos))
                lastError = nil
                return true
            // Declared since the strict linking contract: the server refuses to create a memo
            // whose uploads it cannot link, rather than quietly dropping them. This path never
            // asks for uploads — the outbox owns anything with files — so a 409 here is the
            // server disagreeing with a request this store did not make.
            case .conflict:
                throw APIError.server(status: 409)
            // A keyed create that lost a race and stored nothing. This path sends no key, so it
            // cannot safely repeat itself either; it reports and lets the person decide.
            case .serviceUnavailable:
                throw APIError.server(status: 503)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            await report(error)
            return false
        }
    }

    /// Replaces a memo's content with what the editor produced.
    @discardableResult
    public func edit(
        uid: String,
        content: String,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        await patch(uid: uid, .init(content: content), using: client, baseURL: baseURL)
    }

    /// Changes who can see a memo.
    @discardableResult
    public func setVisibility(
        _ visibility: MemoVisibility,
        uid: String,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        await patch(
            uid: uid, .init(visibility: visibility.generated), using: client, baseURL: baseURL
        )
    }

    /// Pins or unpins through the server's own routes rather than by patching the flag: pinning
    /// is the server's decision to make (it also reorders), and a PATCH would only describe it.
    @discardableResult
    public func setPinned(
        _ pinned: Bool,
        uid: String,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        do {
            // Each response is switched on rather than reached through the generated throwing
            // accessors: those throw an untyped "unexpected status" error, and a 401 that does not
            // arrive as `APIError.unauthorized` never reaches the rule that ends the session.
            let json: Components.Schemas.MemoOut
            if pinned {
                switch try await client.pinMemoApiMemosUidPinPost(.init(path: .init(uid: uid))) {
                case .ok(let ok): json = try ok.body.json
                case .unprocessableContent: throw APIError.server(status: 422)
                case .undocumented(let statusCode, _): throw APIError.fromStatus(statusCode)
                }
            } else {
                switch try await client.unpinMemoApiMemosUidUnpinPost(
                    .init(path: .init(uid: uid))
                ) {
                case .ok(let ok): json = try ok.body.json
                case .unprocessableContent: throw APIError.server(status: 422)
                case .undocumented(let statusCode, _): throw APIError.fromStatus(statusCode)
                }
            }
            // Pinning is also a MOVE: the list is pinned-first, so the updated memo re-enters at
            // the position its new flag earns. (Fine-grained recency ordering is the server's;
            // the next refresh settles it.)
            let updated = Memo(json, baseURL: baseURL)
            if let position = memos.firstIndex(where: { $0.uid == updated.uid }) {
                memos.remove(at: position)
                memos.insert(updated, at: Self.insertionIndex(for: updated, in: memos))
            }
            lastError = nil
            return true
        } catch {
            await report(error)
            return false
        }
    }

    /// Deletes a memo. The row goes when the server says it is gone, not before: a delete that
    /// failed and left the row on screen is recoverable, one that vanished optimistically is not.
    @discardableResult
    public func delete(uid: String, using client: any APIProtocol) async -> Bool {
        do {
            let response = try await client.deleteMemoApiMemosUidDelete(
                .init(path: .init(uid: uid))
            )
            switch response {
            case .noContent:
                memos.removeAll { $0.uid == uid }
                lastError = nil
                return true
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            await report(error)
            return false
        }
    }

    /// Ticks or unticks the Nth rendered checkbox of a memo.
    ///
    /// This one IS optimistic, and it is the only one: a checkbox that waits for a round trip
    /// before it moves feels broken, and the change is a single character that can be put back
    /// exactly. The new content comes from the same pure `toggleTask` the SPA uses, so the app
    /// and the web app cannot disagree about which line a tap meant.
    @discardableResult
    public func toggleTask(
        at index: Int,
        in uid: String,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        guard let position = memos.firstIndex(where: { $0.uid == uid }) else { return false }
        let original = memos[position]
        let toggled = MemosCore.toggleTask(original.content, at: index)
        guard toggled != original.content else { return false }

        memos[position].content = toggled
        do {
            let response = try await client.patchMemoApiMemosUidPatch(
                .init(path: .init(uid: uid), body: .json(.init(content: toggled)))
            )
            switch response {
            case .ok(let ok):
                apply(Memo(try ok.body.json, baseURL: baseURL))
                lastError = nil
                return true
            // The strict linking refusal is declared on the patch too. An edit changes text or
            // visibility and never names an upload, so this is reported rather than recovered
            // from — recovering would mean re-uploading files this call never sent.
            case .conflict:
                throw APIError.server(status: 409)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            // Put the memo back as it was. It is found by uid rather than by the index captured
            // above, because a refresh may have moved it while the request was in flight.
            if let current = memos.firstIndex(where: { $0.uid == uid }) {
                memos[current] = original
            }
            await report(error)
            return false
        }
    }

    private func patch(
        uid: String,
        _ body: Components.Schemas.MemoPatch,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        do {
            let response = try await client.patchMemoApiMemosUidPatch(
                .init(path: .init(uid: uid), body: .json(body))
            )
            switch response {
            case .ok(let ok):
                apply(Memo(try ok.body.json, baseURL: baseURL))
                lastError = nil
                return true
            // The strict linking refusal is declared on the patch too. An edit changes text or
            // visibility and never names an upload, so this is reported rather than recovered
            // from — recovering would mean re-uploading files this call never sent.
            case .conflict:
                throw APIError.server(status: 409)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            await report(error)
            return false
        }
    }

    /// Replaces the loaded copy of a memo with the server's, if it is on screen at all.
    private func apply(_ memo: Memo) {
        guard let position = memos.firstIndex(where: { $0.uid == memo.uid }) else { return }
        memos[position] = memo
    }

    /// Where a new memo belongs in a list the server sorts pinned-first, then newest-first. Pure,
    /// so the placement is asserted rather than eyeballed against a running server.
    static func insertionIndex(for memo: Memo, in memos: [Memo]) -> Int {
        guard !memo.pinned else { return 0 }
        return memos.firstIndex { !$0.pinned } ?? memos.count
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
