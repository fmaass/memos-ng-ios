import Foundation
import MemosAPI

/// How a tie in `created_at` is settled, which is the one part of the server's ordering the app
/// cannot read off a memo.
///
/// memos-ng orders `-created_at` by `created_at DESC, id DESC` (`app/services/memos.py:326-330`,
/// and its cursor carries the same pair, `:43-51`). That `id` is the autoincrement primary key and
/// it is NOT part of `MemoOut`: the only identifier the API sends is `uid`, and a uid is
/// `secrets.token_urlsafe(12)` (`app/services/memos.py:40`) — random, with no relation to the
/// order rows were inserted in. Sorting a tie by uid would therefore INVENT an order rather than
/// mirror one, so the app says only what it actually knows about the memo it is placing.
public enum TimelineTie: Sendable, Equatable {
    /// The server created this memo a moment ago, so it holds the highest id there is and leads at
    /// an identical timestamp — which is what `id DESC` will say on the next page too.
    case justCreated
    /// This memo already existed and its id did not change when its date did. The app is not told
    /// that id, so it does not jump the memo ahead of rows already sitting on that timestamp; a
    /// genuine tie is settled by the next refresh, which is read from the server.
    case alreadyExisted
}

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
                memos = Self.placed(memo, in: memos, tie: .justCreated)
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

    /// Replaces a memo's content with what the editor produced, and — when the editor was given a
    /// date — the display date it carries.
    ///
    /// `createdAt` is left OUT of the request when it is nil rather than sent as the memo's
    /// current value: a PATCH is a partial update, and an edit that did not touch the date has no
    /// business rewriting it. The web app sends the date on every edit because its editor always
    /// holds one; here the absence is what says "unchanged".
    @discardableResult
    public func edit(
        uid: String,
        content: String,
        createdAt: Date? = nil,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        await patch(
            uid: uid,
            .init(content: content, createdAt: createdAt),
            using: client,
            baseURL: baseURL
        )
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
            if memos.contains(where: { $0.uid == updated.uid }) {
                memos = Self.placed(updated, in: memos, tie: .alreadyExisted)
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

    /// Re-reads ONE memo from the server and applies it to the loaded list.
    ///
    /// This is the read half of the tier-ready refresh: a memo posted a moment ago carries
    /// attachments the media worker has not derived yet, and nothing on the client can produce
    /// those tiers — only asking again can. It goes through the same `apply` an edit does, so a
    /// re-read lands in the card that is already on screen instead of appearing as a new row.
    ///
    /// SEAM (phase 5c): this whole polling arrangement is the INTERIM. `GET /api/events` (SSE)
    /// already pushes media-ready events to the SPA; when the app subscribes to it, the poll in
    /// `TierReadinessPoll` goes and this method becomes the handler for one event.
    ///
    /// A failure is deliberately NOT reported into `lastError`: this runs in the background,
    /// behind a screen nobody asked to refresh, and a blip on a poll must not paint an error
    /// banner over a timeline that is working. A 401 is different — it ends the session wherever
    /// it happens — so that one is still handed on.
    @discardableResult
    public func refreshMemo(
        uid: String,
        using client: any APIProtocol,
        baseURL: URL
    ) async -> Bool {
        do {
            let response = try await client.getMemoApiMemosUidGet(.init(path: .init(uid: uid)))
            switch response {
            case .ok(let ok):
                apply(Memo(try ok.body.json, baseURL: baseURL))
                return true
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            let apiError =
                (error as? APIError) ?? .unexpected(description: error.localizedDescription)
            if apiError == .unauthorized { await onUnauthorized() }
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

    /// Replaces the loaded copy of a memo with the server's, if it is on screen at all — and
    /// MOVES it when the server's copy no longer belongs where the old one sat.
    ///
    /// A memo whose display date changed has left the day it was filed under, and the timeline is
    /// cut into days: replacing it in place would leave it printed under the old date, above
    /// memos newer than it, until something else forced a refresh. So it is re-placed — and only
    /// when an ordering key actually moved, because an ordinary content edit must not reshuffle
    /// a list whose exact order came from the server.
    private func apply(_ memo: Memo) {
        guard let position = memos.firstIndex(where: { $0.uid == memo.uid }) else { return }
        let previous = memos[position]
        guard previous.createdAt != memo.createdAt || previous.pinned != memo.pinned else {
            memos[position] = memo
            return
        }
        memos = Self.placed(memo, in: memos, tie: .alreadyExisted)
    }

    /// The loaded list with one memo put where the server's own ordering puts it, replacing any
    /// copy of it that was already there.
    ///
    /// This is the app's single placement rule — a created memo, a pinned one and a re-dated one
    /// all come through here — and it is `public` because the day-grouped timeline built on top
    /// of this layer is only correct while it agrees with it, which is a thing a test should be
    /// able to hold directly rather than infer from a screen.
    public nonisolated static func placed(
        _ memo: Memo,
        in memos: [Memo],
        tie: TimelineTie
    ) -> [Memo] {
        var placed = memos
        placed.removeAll { $0.uid == memo.uid }
        placed.insert(memo, at: insertionIndex(for: memo, in: placed, tie: tie))
        return placed
    }

    /// Where a memo belongs in a list the server sorts pinned-first, then newest-first — `memos`
    /// must NOT already contain it. Pure, so the placement is asserted rather than eyeballed
    /// against a running server.
    ///
    /// A memo backdated past the oldest page read so far belongs on a page nobody has asked for
    /// yet; it lands at the end of what IS loaded and the next refresh files it properly. That is
    /// deliberate: a memo one screen too high is a smaller lie than one that vanishes the moment
    /// its date changes.
    nonisolated static func insertionIndex(
        for memo: Memo,
        in memos: [Memo],
        tie: TimelineTie
    ) -> Int {
        let next = memos.firstIndex { other in
            // The pinned block comes first whatever the dates say; inside a block, newest first.
            if other.pinned != memo.pinned { return !other.pinned }
            if other.createdAt == memo.createdAt { return tie == .justCreated }
            return other.createdAt < memo.createdAt
        }
        return next ?? memos.count
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
