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
    var items: [LibraryRow] { get }
    /// How many rows one request brings back — the size the near-end lookahead is measured in.
    var pageSize: Int { get }
    /// Whether the server has said there is more to read. The viewer needs it for the case a page
    /// answers with nothing it can SHOW: a page of PDFs moves the cursor and leaves the pager
    /// exactly as long as it was, so "did the list grow" cannot be what decides to ask again.
    var hasMore: Bool { get }
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
    public private(set) var items: [LibraryRow] = []
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
    /// Which tag the grid is narrowed to, or nil for every tag (MEMNG-513). Changed only through
    /// `setTag`, for the reason `filter` only changes through `setFilter`. Deliberately NOT
    /// persisted, unlike `order`: a tag left over from last time is a filter silently hiding
    /// pictures, which is the worse failure.
    public private(set) var tag: String?

    private var nextCursor: String?
    /// The page size `nextCursor` was minted under. A continuation is resent "with the same
    /// `type`, `tag`, `limit` and `order`" (the contract's `X-Next-Cursor`), so the size is fixed
    /// when a list's first page is read and travels with its cursor, rather than being whatever
    /// the store would start a list with at the moment the next page is asked for.
    private var nextCursorLimit: Int
    /// Which loaded list this is. Bumped wherever the list stops being the one an unanswered page
    /// was a continuation of: a refresh replacing it, and a filter change discarding it.
    private var generation = 0
    /// Read as well as written: the viewer measures its own near-end lookahead in pages of this
    /// size, so a store built with a different one moves the trigger with it.
    public let pageSize: Int
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    /// Where a failure that never reached the server goes instead of `lastError`, and the seam
    /// this store reads the session's incarnation from — its twin's, for its twin's reason
    /// (`TimelineStore`).
    private var session: (any SessionReporting)?

    /// Which page of the list each held row was read on, and how many pages are held: the map a
    /// reissue walks back through (`reissue(uids:using:baseURL:)`). Kept beside the rows rather
    /// than derived from their offsets, because a page's rows are filtered and de-duplicated on
    /// the way in and an offset says nothing about which cursor page a row came from.
    private var pageOf: [String: Int] = [:]
    private var pagesHeld = 0
    /// Rows whose signed URLs the server refused as expired and no walk has re-read yet. Held
    /// until a walk re-reads them, so one that arrives while a walk is out or cooling down is
    /// still answered rather than dropped.
    private var outstanding: Set<String> = []
    /// The walk on the wire, claimed before its first suspension point so two askers in one turn
    /// of the main actor cannot both start one.
    private var walking: Task<Void, Never>?
    private var cooling = false
    /// What the walk that runs when the cooldown ends is issued under: the latest asker's.
    private var deferred: (handle: SessionHandle, baseURL: URL)?
    private let cooldown: @MainActor @Sendable () async -> Void

    public init(
        pageSize: Int = 60,
        filter: MediaLibraryFilter = .all,
        order: MediaLibraryOrder = .newestFirst,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded },
        reissueCooldown: @escaping @MainActor @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(MediaBudget.refreshCooldown))
        }
    ) {
        self.cooldown = reissueCooldown
        self.pageSize = pageSize
        self.nextCursorLimit = pageSize
        self.filter = filter
        self.order = order
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

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
        forgetPages()
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
        forgetPages()
        nextCursor = nil
        hasMore = true
        lastError = nil
        generation += 1
    }

    /// Narrows the grid to one tag, or widens it back to every tag with nil.
    ///
    /// It resets exactly what a tab change resets, for the same reason: the loaded rows and the
    /// cursor both describe the list under the previous tag, and neither belongs under this one.
    public func setTag(_ tag: String?) {
        guard tag != self.tag else { return }
        self.tag = tag
        items = []
        forgetPages()
        nextCursor = nil
        hasMore = true
        lastError = nil
        generation += 1
    }

    /// Widens the grid back to every tag when the tag list, read for the kind on screen, no longer
    /// names the chosen tag — a tag with no videos is absent under Videos, and a grid narrowed to
    /// it would be an empty tab with no row in the menu to explain it. Answers whether it reset,
    /// so the caller knows to read the grid again.
    ///
    /// Only an ANSWER for this store's own kind decides: a list not read yet, or read for another
    /// kind, says nothing about whether the tag is there.
    @discardableResult
    public func dropTagIfAbsent(from list: LibraryTagStore) -> Bool {
        guard let tag, list.loadedFilter == filter else { return false }
        guard !list.tags.contains(where: { $0.name == tag }) else { return false }
        setTag(nil)
        return true
    }

    /// Empties the grid because this device is signed in as somebody else.
    ///
    /// The tab's view is not torn down and rebuilt on a subject swap — the signed-in root keeps
    /// its state — so a store that kept its rows would show the outgoing account's photographs to
    /// the incoming one. It resets exactly what a tab change resets, and for the same reason: the
    /// cursor is a position inside a list this store is no longer showing, and a page in flight
    /// was asked for by somebody else, so the generation moves and those answers drop on arrival.
    ///
    /// The tab itself stays. Which slice of the library is open is a choice about this screen,
    /// not about the account, and the grid reloads under it either way.
    public func sessionIdentityChanged() {
        items = []
        forgetPages()
        nextCursor = nil
        hasMore = true
        lastError = nil
        generation += 1
    }

    // MARK: - Jumping to a day (MEMNG-587)

    /// How many rows each page of a jump asks for, its first and every continuation after it.
    ///
    /// The server has no cursor that starts at a date, so a day is reached by reading from the
    /// top. Pages of the grid's own size would make that one round trip per sixty pictures; this
    /// makes it one per five hundred, and the list the jump leaves keeps the size its cursor was
    /// minted under (`nextCursorLimit`) until a reload starts a list of the ordinary size.
    public static let jumpPageSize = 500

    /// Where the last jump landed: the row the grid scrolls to. Nil unless the list on screen is
    /// still the one that jump loaded — any change of lineage takes it down with the list, so a
    /// target can never be read out against rows it does not describe, nor applied late.
    public var landing: LibraryLanding? {
        guard let landed, landed.lineage == lineage else { return nil }
        return landed.landing
    }

    /// Which list is on screen: it moves whenever the rows stop being a continuation of the list
    /// before — a refresh, a filter, order or tag change, another signed-in identity, a jump — and
    /// never for a next page of the same list. What the grid holds for one list it judges by this.
    public var listGeneration: Int { generation }

    /// Whether a jump is reading pages for the list on screen.
    public var isJumping: Bool {
        guard let jumping else { return false }
        return jumping.lineage == lineage
    }

    private var landed: (lineage: Lineage, landing: LibraryLanding)?

    /// The jump reading pages now: the lineage it owns and the day it is looking for.
    private struct Jump: Equatable {
        var lineage: Lineage
        var day: String
        var timeZone: String
    }

    private var jumping: Jump?

    /// Reads the library from its first page, in the grid's own direction, until a page brings a
    /// row taken on `day` in `timeZone` — the zone the day bucket was counted in — and then shows
    /// that list with the row as `landing`.
    ///
    /// Nothing reaches the grid before the day is found: the pages are gathered here and applied
    /// together, so a list that runs out without the day leaves the grid exactly as it was, and a
    /// jump that is abandoned leaves nothing behind.
    ///
    /// A jump is a list of its own from its first request, so it moves the generation BEFORE it
    /// asks: whatever else is in flight — an earlier jump, a refresh, a continuation — then answers
    /// a list that has moved on, and so does this jump the moment a later tap, a tab, a direction,
    /// a tag, `abandonJump` or a subject change moves it in turn. The same day asked for again
    /// while it is being read is refused, not reissued: the answer on its way is the one that
    /// lands.
    ///
    /// The direction is the grid's own. Both directions the grid offers are orders of when a
    /// picture was taken, so the jump pages in taken order without turning the library round.
    public func jump(
        toDay day: String,
        in timeZone: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async {
        let client = handle.client
        guard jumping != Jump(lineage: self.lineage, day: day, timeZone: timeZone) else { return }
        generation += 1
        let lineage = self.lineage
        let jump = Jump(lineage: lineage, day: day, timeZone: timeZone)
        jumping = jump
        defer {
            if jumping == jump { jumping = nil }
        }
        let limit = Self.jumpPageSize
        var rows: [LibraryRow] = []
        var rowPages: [String: Int] = [:]
        var pagesRead = 0
        var cursor: String?
        while true {
            do {
                let page = try await Self.page(
                    client,
                    filter: lineage.filter,
                    order: lineage.order,
                    tag: lineage.tag,
                    cursor: cursor,
                    limit: limit,
                    baseURL: baseURL
                )
                guard lineage == self.lineage else {
                    MemosLog.api.info("a jump's page answered for a list that has moved on")
                    return
                }
                guard sessionStillCurrent(handle) else {
                    MemosLog.api.info("a jump's page for a session that has ended is not applied")
                    return
                }
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                rows = Self.merged(
                    rows,
                    with: page.items,
                    filter: lineage.filter,
                    dropping: removed
                )
                for row in rows where rowPages[row.id] == nil { rowPages[row.id] = pagesRead }
                pagesRead += 1
                if let index = firstRowIndex(onDay: day, in: rows, timeZone: timeZone) {
                    items = rows
                    forgetPages()
                    pageOf = rowPages
                    pagesHeld = pagesRead
                    nextCursor = page.nextCursor
                    nextCursorLimit = limit
                    hasMore = page.nextCursor != nil
                    lastError = nil
                    // A new lineage again, for the reason `refresh` takes one: a continuation that
                    // set out before this list was applied must not be merged into it.
                    generation += 1
                    landed = (
                        self.lineage,
                        LibraryLanding(day: day, rowID: rows[index].id, serial: generation)
                    )
                    return
                }
                guard let next = page.nextCursor else {
                    MemosLog.api.info("a jump read the whole list without finding its day")
                    return
                }
                cursor = next
            } catch {
                guard lineage == self.lineage else {
                    MemosLog.api.info("a jump's page failed for a list that has moved on")
                    return
                }
                await report(error, issuedUnder: handle)
                return
            }
        }
    }

    /// Marks `landing` as scrolled to, so a grid built again later, or measured again, does not
    /// bring the reader back to it. Only the landing the caller scrolled to is cleared: a newer one
    /// that arrived meanwhile still stands.
    public func consumeLanding(_ landing: LibraryLanding) {
        guard landed?.landing == landing else { return }
        landed = nil
    }

    /// Drops the jump that is reading, if one is, because the view it was going to land in is no
    /// longer the one on screen. It moves the lineage — the one way this store drops a page in
    /// flight — and does nothing when no jump is reading.
    public func abandonJump() {
        guard isJumping else { return }
        generation += 1
    }

    // MARK: - Deleting the selection (MEMNG-589)

    /// A run of `delete(_:using:)` is out. The spinner on the toolbar's Delete, and the reason a
    /// second run is refused.
    public private(set) var isDeleting = false

    /// The uids this store has watched the server confirm gone. A page read before a delete and
    /// answered after it still lists the file, and merged as it stands it would put a picture back
    /// on the grid that the server no longer has. Never cleared, for the reason
    /// `TimelineStore.removedAttachments` is not: a hard-deleted uid cannot legitimately return.
    private var removed: Set<String> = []

    /// Deletes the chosen pictures, one `DELETE /api/attachments/{uid}` at a time, in the order
    /// they were chosen, through the single-picture endpoint — there is no bulk one, and none is
    /// wanted (the mockup's section 7).
    ///
    /// * ONE handle for the whole run, taken by the caller when the question was answered yes.
    ///   Before each send it is asked whether that session is still the one this device runs; once
    ///   it is not, nothing further is sent, and nothing the run learned is applied — the rows are
    ///   the next account's to read. A DELETE is not a read: an answer discarded afterwards does
    ///   not put the file back, which is why the question comes BEFORE the send.
    /// * A 204 is done, and so is a 404, as `TimelineStore.performAttachmentDelete` decides.
    /// * The first other failure stops the run: no later uid reaches the wire. It is reported the
    ///   way this store reports every failure (`report`) — to the session when the server never
    ///   answered, through the typed funnel when the credential was refused — except that no
    ///   sentence is written over the grid: the screen's toast says what the run did.
    /// * Serialised by REFUSAL, not by joining: a second call while a run is out sends nothing and
    ///   returns nil. A second selection is a different list of files, so there is no run to join
    ///   it to, and two runs side by side would be two deletes on the wire at once.
    ///
    /// - Returns: what the run did, or nil when it was refused.
    public func delete(
        _ uids: [String],
        using handle: SessionHandle
    ) async -> LibraryDeleteOutcome? {
        guard !isDeleting else {
            MemosLog.api.info("a delete asked for while another is running is refused")
            return nil
        }
        isDeleting = true
        defer { isDeleting = false }
        let outcome = await Self.deleteRun(
            uids,
            using: handle,
            stillCurrent: { sessionStillCurrent(handle) },
            succeeded: { session?.noteTransportSuccess(issuedUnder: handle.generation) },
            failed: { await report($0, issuedUnder: handle, writesSentence: false) }
        )
        guard !outcome.stoppedForSessionChange else { return outcome }
        forget(outcome.deleted)
        return outcome
    }

    /// The run itself, without a store's bookkeeping: shared with the Trip screen's Delete
    /// (`TripMemberStore.delete`), so both send the same requests and stop on the same answers.
    /// `stillCurrent` is asked before each send and once after the last answer; `failed` is told
    /// the first failure, after which nothing further is sent.
    static func deleteRun(
        _ uids: [String],
        using handle: SessionHandle,
        stillCurrent: () -> Bool,
        succeeded: () -> Void,
        failed: (any Error) async -> Void
    ) async -> LibraryDeleteOutcome {
        let client = handle.client
        var deleted: [String] = []
        var failure: String?
        var stoppedForSession = false
        for uid in uids {
            guard stillCurrent() else {
                MemosLog.api.info("a delete run outlived its session; nothing further is sent")
                stoppedForSession = true
                break
            }
            do {
                try await deleteOne(uid, client)
                deleted.append(uid)
                succeeded()
            } catch {
                failure = uid
                await failed(error)
                break
            }
        }
        // Asked again after the last answer, whichever way the loop ended: a session that changed
        // while the final request was out, or while a failing one was, is never asked about by the
        // check before a next send, and the run is as stale as one stopped by that check.
        if !stoppedForSession, !stillCurrent() {
            MemosLog.api.info("a delete run's last answer arrived for a session that has ended")
            stoppedForSession = true
        }
        let reached = deleted.count + (failure == nil ? 0 : 1)
        return LibraryDeleteOutcome(
            deleted: deleted,
            failed: failure,
            notAttempted: Array(uids.dropFirst(reached)),
            stoppedForSessionChange: stoppedForSession
        )
    }

    /// The deleted pictures leave the grid, and stay gone (`removed`).
    private func forget(_ uids: [String]) {
        guard !uids.isEmpty else { return }
        removed.formUnion(uids)
        items.removeAll { removed.contains($0.id) }
        outstanding.subtract(uids)
    }

    /// One picture, through the generated client. A 404 says what a 204 says: the file is not on
    /// the server — deleted from the web first, or by a retry whose first answer was lost.
    private static func deleteOne(_ uid: String, _ client: any APIProtocol) async throws {
        let response = try await client.deleteAttachmentApiAttachmentsUidDelete(
            .init(path: .init(uid: uid))
        )
        switch response {
        case .noContent:
            MemosLog.api.info("DELETE /api/attachments/{uid} -> 204")
        case .unprocessableContent:
            throw APIError.server(status: 422)
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            guard statusCode == 404 else { throw APIError.fromStatus(statusCode) }
            MemosLog.api.info("DELETE /api/attachments/{uid} -> 404, already gone")
        }
    }

    /// Which list a page in flight belongs to — the generation, the filter, the direction AND the
    /// tag, because any of them moving makes the answer a continuation of something nobody is
    /// reading any more.
    private struct Lineage: Equatable {
        var generation: Int
        var filter: MediaLibraryFilter
        var order: MediaLibraryOrder
        var tag: String?
    }

    private var lineage: Lineage {
        Lineage(generation: generation, filter: filter, order: order, tag: tag)
    }

    /// Which lineage the first page in flight belongs to, or nil when none is. `isLoading` alone
    /// cannot decide whether a refresh is redundant: the request a superseded filter left in
    /// flight is exactly what somebody changing tabs is waiting for the end of.
    private var loadingLineage: Lineage?

    public func refresh(using handle: SessionHandle, baseURL: URL) async {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // A reload is newer than a jump still reading, so the jump must not land over it: moved
        // here, the jump's pages answer a list that has moved on, whichever answers first.
        if isJumping { generation += 1 }
        let lineage = self.lineage
        let limit = pageSize
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
                tag: lineage.tag,
                cursor: nil,
                limit: limit,
                baseURL: baseURL
            )
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/attachments answered for a list that has moved on")
                return
            }
            guard sessionStillCurrent(handle) else {
                MemosLog.api.info("a page answered for a session that has ended is not applied")
                return
            }
            items = Self.merged([], with: page.items, filter: lineage.filter, dropping: removed)
            forgetPages()
            recordPage(items)
            nextCursor = page.nextCursor
            nextCursorLimit = limit
            hasMore = page.nextCursor != nil
            lastError = nil
            // A page that arrived is the session's to act on, as a question and not an answer —
            // the same report the failure funnel makes, from the side where it went right
            // (`noteTransportSuccess`).
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            // This IS a different list — a new lineage, whose cursor no page in flight shares.
            generation += 1
        } catch {
            // A failure belongs to the request that suffered it. One from a list nobody is reading
            // any more would put an error over a list that loaded perfectly well — and, for a
            // refusal,
            // end the session on the word of a request that has been superseded.
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/attachments failed for a list that has moved on")
                return
            }
            await report(error, issuedUnder: handle)
        }
    }

    /// Reads the page that follows the loaded ones — and reads it again, itself, when the list it
    /// was a continuation of is gone by the time it lands.
    ///
    /// The second read has to happen here: the next page is asked for when the last tile appears,
    /// and a tile already on screen does not appear a second time, so a reader sitting at the end
    /// of the grid would wait for a page this store had decided to throw away.
    public func loadMore(using handle: SessionHandle, baseURL: URL) async {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        guard !isLoadingMore, !isLoading, hasMore, nextCursor != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // The cursor and the lineage are re-read on every pass: after a drop, the page that comes
        // next is the CURRENT list's next page, not the one this call set out to fetch.
        while !isLoading, hasMore, let cursor = nextCursor {
            let lineage = self.lineage
            let limit = nextCursorLimit
            do {
                let page = try await Self.page(
                    client,
                    filter: lineage.filter,
                    order: lineage.order,
                    tag: lineage.tag,
                    cursor: cursor,
                    limit: limit,
                    baseURL: baseURL
                )
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/attachments answered for a list that has moved on")
                    // Never reissued with a client whose session is over — see the same guard in
                    // `TimelineStore.loadMore`.
                    guard sessionStillCurrent(handle) else { return }
                    continue
                }
                guard sessionStillCurrent(handle) else {
                    MemosLog.api.info("a page answered for a session that has ended is not merged")
                    return
                }
                items = Self.merged(
                    items,
                    with: page.items,
                    filter: lineage.filter,
                    dropping: removed
                )
                recordPage(items)
                nextCursor = page.nextCursor
                hasMore = page.nextCursor != nil
                lastError = nil
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                return
            } catch {
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/attachments failed for a list that has moved on")
                    guard sessionStillCurrent(handle) else { return }
                    continue
                }
                await report(error, issuedUnder: handle)
                return
            }
        }
    }

    // MARK: - Reissuing lapsed signatures (MEMNG-623)

    /// Re-reads the pages holding these rows, so their tiles get freshly signed URLs, and changes
    /// nothing else about the list.
    ///
    /// `refresh` cannot be the answer: it reads the first page and REPLACES the list, so a reader
    /// three pages down whose tile lapsed would be thrown back to the top and lose everything
    /// below the first sixty rows. The server has no endpoint that re-signs one attachment, and a
    /// cursor is only valid as the continuation of the page before it, so the pages are walked
    /// again from the first cursor, under the size and lineage this list was read with, and each
    /// held row is replaced IN PLACE by its re-read self. Rows the walk does not reach, and the
    /// order and identity of every row, stay exactly as they were.
    ///
    /// One walk at a time, claimed before anything is awaited: an asker arriving while one is out
    /// joins it, and a row it names that lies beyond the walk's current end extends it. An asker
    /// arriving inside the cooldown after a walk is queued, and one walk runs when the cooldown
    /// ends — so a lapsed row is never dropped, and never waits longer than the cooldown and one
    /// walk.
    ///
    /// An ask issued under a session that is no longer running is refused before it touches
    /// anything: it would otherwise start a walk its own first guard stops, and the cooldown after
    /// that walk would hold back the running session's ask for the same rows.
    public func reissue(uids: [String], using handle: SessionHandle, baseURL: URL) async {
        guard sessionStillCurrent(handle) else { return }
        let held = uids.filter { pageOf[$0] != nil }
        guard !held.isEmpty else { return }
        outstanding.formUnion(held)
        deferred = (handle, baseURL)
        if let walking {
            await walking.value
            return
        }
        guard !cooling else { return }
        await startWalk(using: handle, baseURL: baseURL).value
    }

    /// Whether a walk is on the wire. Read by a test to assert that a second is never started.
    public var isReissuing: Bool { walking != nil }

    private func startWalk(using handle: SessionHandle, baseURL: URL) -> Task<Void, Never> {
        let task = Task { [self] in
            await walk(using: handle, baseURL: baseURL)
            walking = nil
            coolDown()
        }
        walking = task
        return task
    }

    private func coolDown() {
        cooling = true
        Task { [self] in
            await cooldown()
            cooling = false
            guard !outstanding.isEmpty, walking == nil, let deferred,
                let handle = walkableHandle(asked: deferred.handle)
            else { return }
            _ = startWalk(using: handle, baseURL: deferred.baseURL)
        }
    }

    /// The handle a deferred walk runs under: the one it was asked under while that is still the
    /// running session, otherwise the running session's own.
    ///
    /// The obligation is KEPT across a replaced handle rather than dropped: the rows are the same
    /// list's (a changed identity empties the list and every obligation with it, in
    /// `forgetPages`), and they still carry the signatures that lapsed. A walk sent under a handle
    /// already known to be over would be refused by its own first guard, and the cooldown after it
    /// would send the same doomed walk again, for as long as the screen lived. The walk it gets
    /// instead is fenced by the handle it is given, exactly as any other. With no session running,
    /// nothing is sent and the obligation waits for the next asker.
    private func walkableHandle(asked: SessionHandle) -> SessionHandle? {
        guard let session else { return asked }
        if session.activeHandle?.generation == asked.generation { return asked }
        return session.activeHandle
    }

    /// The walk itself. It reads page after page for as long as a row it is looking for can still
    /// be ahead of it — its own page, or the one after, because a picture added at the top since
    /// the list was read pushes every row down — and never past the pages this list holds.
    private func walk(using handle: SessionHandle, baseURL: URL) async {
        let client = handle.client
        let lineage = self.lineage
        let limit = nextCursorLimit
        var cursor: String?
        var index = 0
        // The rows that were owed a reissue when their own page was read.
        var looked: Set<String> = []
        while index < pagesHeld, index == 0 || cursor != nil,
            outstanding.contains(where: { (pageOf[$0] ?? -2) + 1 >= index })
        {
            // Never sent under a client whose session is over.
            guard sessionStillCurrent(handle) else { return }
            looked.formUnion(outstanding.filter { pageOf[$0] == index })
            do {
                let page = try await Self.page(
                    client,
                    filter: lineage.filter,
                    order: lineage.order,
                    tag: lineage.tag,
                    cursor: cursor,
                    limit: limit,
                    baseURL: baseURL
                )
                // The rows this walk set out to re-sign are not the rows on screen any more; the
                // read that replaced them brought fresh signatures of its own.
                guard lineage == self.lineage else {
                    MemosLog.api.info("a reissue page answered for a list that has moved on")
                    outstanding = []
                    return
                }
                // Judged by the session that ISSUED the page, never the one running now: a list
                // the next account is reading must not take this one's rows.
                guard sessionStillCurrent(handle) else {
                    MemosLog.api.info("a reissue page for a session that has ended is not merged")
                    return
                }
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                reissued(page.items)
                cursor = page.nextCursor
                index += 1
            } catch {
                guard lineage == self.lineage else { return }
                await report(error, issuedUnder: handle, writesSentence: false)
                return
            }
        }
        // A row this walk looked for and did not find is no longer where this list says it is; the
        // next refresh is what finds it. A row that arrived after the walk passed its page is
        // still owed one, and the walk after the cooldown is it.
        outstanding.subtract(looked)
    }

    /// A walked page's rows, each replacing the held row with its uid, where it stands.
    private func reissued(_ rows: [LibraryRow]) {
        let fresh = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for position in items.indices {
            guard let row = fresh[items[position].id] else { continue }
            outstanding.remove(row.id)
            guard row != items[position] else { continue }
            items[position] = row
        }
    }

    /// The rows now held and not yet placed are the page just read.
    private func recordPage(_ rows: [LibraryRow]) {
        var placed = false
        for row in rows where pageOf[row.id] == nil {
            pageOf[row.id] = pagesHeld
            placed = true
        }
        if placed { pagesHeld += 1 }
    }

    /// A list replaced or emptied takes its page map, and the rows owed a reissue, with it.
    private func forgetPages() {
        pageOf = [:]
        pagesHeld = 0
        outstanding = []
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
        _ loaded: [LibraryRow],
        with page: [LibraryRow],
        filter: MediaLibraryFilter,
        dropping removed: Set<String> = []
    ) -> [LibraryRow] {
        // A uid this store saw deleted counts as already known, so no page can add it back — and it
        // leaves the rows already gathered too: a jump collects pages before it installs them, and
        // a picture it collected before its delete landed would otherwise ride back in with them.
        var out = loaded.filter { !removed.contains($0.id) }
        var known = Set(out.map(\.id)).union(removed)
        for item in page {
            guard filter.includes(item.attachment.mediaKind) else { continue }
            guard known.insert(item.id).inserted else { continue }
            out.append(item)
        }
        return out
    }

    /// Says what went wrong — unless what went wrong was this app cancelling its own request.
    /// Same rule, same helper, as `TimelineStore.report`: a supersede cancels the transport before
    /// it moves the lineage, so the fence above cannot tell that `-999` from a real failure.
    ///
    /// `writesSentence` false is the delete run's: its toast reports the failure, and a sentence
    /// over the grid as well would say it twice.
    private func report(
        _ error: any Error,
        issuedUnder handle: SessionHandle,
        writesSentence: Bool = true
    ) async {
        // Fenced for the reason `TimelineStore.report` is: a stale refusal reaching `onUnauthorized`
        // ends the session running now, and a stale sentence lands on a grid that never asked.
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        // A server that never answered goes to the session and nowhere else — the same rule, and
        // the same reason, as `TimelineStore.report`.
        if let failure = StoreFailure.transportFailure(error) {
            // And a sentence an earlier answer left must not stand in for this one: the banner owns
            // what an unreachable server says, and a stale "the server returned 500" under it would
            // be the grid explaining this failure with the last one's words.
            lastError = nil
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        // The SESSION owns the verdict; this store owns only what it says about it — the same
        // rule, and the same reason, as `TimelineStore.report`.
        if let refusal = StoreFailure.refusal(error) {
            // And asked again afterwards, with nothing awaited before the write — the same rule,
            // and the same reason, as `TimelineStore.report`.
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle) {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        guard writesSentence else { return }
        lastError = apiError.errorDescription
    }

    /// Whether the session that ISSUED an operation is still the one this device is running — the
    /// same guard, for the same reason, as `TimelineStore.sessionStillCurrent`.
    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    /// The post-await half of the same question — the same rule, for the same reason, as
    /// `TimelineStore.nothingEstablishedSince`.
    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
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
        tag: String?,
        cursor: String?,
        limit: Int,
        baseURL: URL
    ) async throws -> (items: [LibraryRow], nextCursor: String?) {
        let response = try await client.listAttachmentsApiAttachmentsGet(
            .init(
                query: .init(
                    _type: filter.apiType,
                    limit: limit,
                    cursor: cursor,
                    // Written as a member of the generated enum rather than through a name this
                    // file spells out: what the generator calls that type is the generator's to
                    // decide, and this call is the only place the app has to agree with it.
                    order: order == .oldestFirst ? .takenAsc : .takenDesc,
                    tag: tag
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
            return (rows.map { LibraryRow($0, baseURL: baseURL) }, next)
        case .unprocessableContent:
            throw APIError.server(status: 422)
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}

/// Where a jump to a day landed: the day, and the first row loaded on it.
public struct LibraryLanding: Sendable, Equatable {
    /// The day bucket's key that was jumped to.
    public let day: String
    /// The row the grid scrolls to.
    public let rowID: String
    /// Which list this landing belongs to, so the same day jumped to twice is two landings and the
    /// grid scrolls twice.
    public let serial: Int

    public init(day: String, rowID: String, serial: Int) {
        self.day = day
        self.rowID = rowID
        self.serial = serial
    }
}
