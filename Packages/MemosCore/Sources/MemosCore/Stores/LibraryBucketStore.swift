import Foundation
import MemosAPI

/// How wide one date bucket of the Library is.
public enum LibraryBucketSize: String, Sendable, Equatable, CaseIterable, Identifiable {
    case day
    case month
    case year

    public var id: String { rawValue }
}

/// One date bucket of the Library: a calendar day, month or year, how many pictures fall in it,
/// and the newest of them as its cover.
public struct LibraryBucket: Sendable, Equatable, Identifiable {
    /// The server's name for the bucket, which is also its order key.
    public let key: String
    public let count: Int
    public let coverUID: String
    /// Resolved against the server the way a library row's thumbnail is, so a cell can hand it to
    /// the same loader.
    public let coverThumbnailURL: URL?
    public var id: String { key }

    public init(key: String, count: Int, coverUID: String, coverThumbnailURL: URL?) {
        self.key = key
        self.count = count
        self.coverUID = coverUID
        self.coverThumbnailURL = coverThumbnailURL
    }

    init(_ generated: Components.Schemas.AttachmentBucket, baseURL: URL) {
        self.init(
            key: generated.key,
            count: generated.count,
            coverUID: generated.coverUid,
            coverThumbnailURL: URL(string: generated.coverThumbnailUrl, relativeTo: baseURL)?
                .absoluteURL
        )
    }
}

/// Everything a bucket list answers for. Two reads are the same read exactly when these are equal.
public struct LibraryBucketRequest: Sendable, Equatable {
    public let size: LibraryBucketSize
    public let filter: MediaLibraryFilter
    public let tag: String?
    /// "Captured by me" and Visibility (MEMNG-787): the counts are counts under both, so a list
    /// read for one is no answer for another.
    public let mine: Bool
    public let visibility: MediaVisibilityFilter
    public let timeZoneIdentifier: String
}

/// The Library's date buckets (MEMNG-584), read from `GET /api/attachments/buckets`.
///
/// The server counts per calendar day, month or year in the zone it is TOLD, and falls back to its
/// own default when told nothing — so the store always sends one, and exposes it
/// (`timeZoneIdentifier`), because whoever draws a bucket's heading has to name it in the zone
/// that drew the bucket's edges.
///
/// Its fences are `LibraryTagStore`'s, for the same reasons:
///
/// * one read per request at a time — a second `load` for the request already in flight for the
///   same session is REFUSED, not joined and not issued: it returns at once, and the answer already
///   on its way is the one that lands, so two appearances in a row are one request on the wire.
///   `refresh` is the one exception, and it CHAINS rather than overlaps: see there;
/// * a caller whose session has been replaced is refused and sends nothing, and a read in flight
///   for a replaced session answers nobody current: whoever still wants its request waits for it
///   to end and then shares ONE read for the session now current (MEMNG-631);
/// * a read for a different request supersedes the one in flight, whose answer is then dropped (a
///   generation bumped by every read and by `sessionIdentityChanged`, plus the request itself);
/// * an answer for a session that has ended is dropped, so a stale list cannot repopulate a list
///   that was emptied at sign-out;
/// * a failure leaves the previous list standing, and is said the way `MediaLibraryStore` says it.
@MainActor
@Observable
public final class LibraryBucketStore {
    /// In the server's order, newest first.
    public private(set) var buckets: [LibraryBucket] = []
    /// The request `buckets` answers, or nil before any answer — which is what lets a caller tell
    /// "nothing falls in these buckets" from "nothing has been read for them yet".
    public private(set) var loadedRequest: LibraryBucketRequest?
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    /// The zone every read names in `tz`.
    public let timeZoneIdentifier: String

    private var generation = 0
    private var loadingLineage: Lineage?
    /// The newest read claimed, kept after it ends: a waiter that resumes late must still be able
    /// to tell that a read it can stand on was issued — and has perhaps already answered.
    private var latestLineage: Lineage?
    /// Whether `latestLineage`'s read ended cancelled — its issuer's task, or a cancellation coming
    /// back from the transport — and so answered nobody. False while it is on its way.
    private var latestAbandoned = false
    /// Refreshes waiting for the read of one generation to end, however it ends.
    private var readEndWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    public init(
        timeZoneIdentifier: String = libraryTimeZone,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.timeZoneIdentifier = timeZoneIdentifier
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    private struct Lineage: Equatable {
        var generation: Int
        var request: LibraryBucketRequest
        /// The session generation of the handle that issued the read. A newer store generation is
        /// no evidence of whom a read was for; this is.
        var session: Int
    }

    /// Reads the buckets of one size, under one kind and optionally one tag.
    public func load(
        size: LibraryBucketSize,
        filter: MediaLibraryFilter,
        tag: String?,
        mine: Bool = false,
        visibility: MediaVisibilityFilter = .any,
        using handle: SessionHandle,
        baseURL: URL
    ) async {
        let request = LibraryBucketRequest(
            size: size,
            filter: filter,
            tag: tag,
            mine: mine,
            visibility: visibility,
            timeZoneIdentifier: timeZoneIdentifier
        )
        // Join or refuse (MEMNG-631). A caller whose session has been replaced is REFUSED and
        // sends nothing. A duplicate of the read in flight for the SAME session is REFUSED at once,
        // as before: that read answers it. A load that finds its request in flight for a REPLACED
        // session waits for that read to drain and then JOINS one shared read for the current
        // session — the first current waiter to resume sends it, every other one stands on it.
        // A waiter cancelled while it waited leaves without sending or standing. A shared read
        // that ends CANCELLED (its issuer's task was, before or after the claim) answered nobody:
        // the next live waiter sends ONE fresh read and the rest stand on that one. A shared read
        // that FAILS any other way is an answer: the failure is reported once through the usual
        // funnel and stands for every waiter on it, and nothing is sent again — a second request
        // for one ask is a retry nobody asked for, and the next pull is that retry. (A read issued
        // before a refresh began answers it in no outcome, so a refresh still reads after a
        // pending read that failed.)
        guard sessionStillCurrent(handle) else { return }
        if let pending = loadingLineage, pending.request == request,
            pending.session == handle.generation
        {
            return
        }
        await readAfterEarlierReads(request, began: generation, using: handle, baseURL: baseURL)
    }

    /// A pull-to-refresh's read. It differs from `load` only when the same request is already in
    /// flight: that read was asked for before the refresh began, so its counts can predate whatever
    /// else the refresh re-read, and letting it answer for the refresh is how a day showed 12 above
    /// 13 pictures. So the refresh lets it finish — its answer lands or is dropped under the usual
    /// fences — and then sends ONE read of its own. The two follow each other, so there is still
    /// never more than one read of a request on the wire; and a refresh that finds a read issued
    /// after it began (another refresh's) joins that one instead of sending a third.
    ///
    /// It sends nothing if, while it waited, the device changed account or a read for another
    /// request was issued: the screen has moved on, and its buckets are not to be read back over it.
    /// Nor if its session has been replaced, at entry or while it waited: it is refused, and a read
    /// still in flight for a replaced session is waited out but never stood on (MEMNG-631).
    public func refresh(
        size: LibraryBucketSize,
        filter: MediaLibraryFilter,
        tag: String?,
        mine: Bool = false,
        visibility: MediaVisibilityFilter = .any,
        using handle: SessionHandle,
        baseURL: URL
    ) async {
        let request = LibraryBucketRequest(
            size: size,
            filter: filter,
            tag: tag,
            mine: mine,
            visibility: visibility,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let began = generation
        guard sessionStillCurrent(handle) else { return }
        await readAfterEarlierReads(request, began: began, using: handle, baseURL: baseURL)
    }

    /// Sends ONE read of `request` for `handle`'s session once the read of it already in flight
    /// when the caller `began` has ended, however it ended — unless a read it can stand on was
    /// issued meanwhile, which it joins, or the screen moved on, when it sends nothing.
    ///
    /// Standing on a read takes all three: the same request, the same session, issued after the
    /// caller began. Nothing in flight, or a newer generation, proves none of them — the read that
    /// ended may have been a replaced session's, dropped at its fence. And it must have ANSWERED: a
    /// read that ended cancelled is a turn that passes to the next live waiter, never an answer.
    private func readAfterEarlierReads(
        _ request: LibraryBucketRequest,
        began: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) async {
        while let pending = loadingLineage, pending.request == request {
            await readEnds(pending.generation)
            // The caller may have been cancelled, or its session replaced, while it waited: then
            // it is refused, and neither sends a read nor stands on one.
            guard !Task.isCancelled, sessionStillCurrent(handle) else { return }
            // Another waiter of the same session got there first: join its read if it is still on
            // its way — waited out on the next pass, where how it ended is judged — and stand on
            // it if it has answered.
            if let shared = latestLineage, shared.generation > began, shared.request == request,
                shared.session == handle.generation, !latestAbandoned
            {
                if loadingLineage == shared { continue }
                return
            }
            // Nothing was issued, and the account did not change, while it waited — or the newest
            // read, of this request for this session, ended cancelled and answered nobody: its
            // turn, and its read is the one the other live waiters stand on.
            if generation == pending.generation || abandonedTurn(of: request, for: handle) {
                break
            }
            // Something else was. A read of this request that it cannot stand on is waited out on
            // the next pass; anything else — a read for another request, or the account changing,
            // which moves the generation too — means the screen has moved on.
            guard loadingLineage?.request == request else { return }
        }
        await read(request, using: handle, baseURL: baseURL)
    }

    /// Whether the newest thing this store did is a read of `request` for `handle`'s session that
    /// ended cancelled — a turn nobody took.
    private func abandonedTurn(
        of request: LibraryBucketRequest,
        for handle: SessionHandle
    ) -> Bool {
        guard latestAbandoned, let latest = latestLineage else { return false }
        return latest.generation == generation && latest.request == request
            && latest.session == handle.generation
    }

    /// A lapsed cover's read: the list the cover was drawn from, read again for fresh signatures.
    ///
    /// Refused at entry, before anything is claimed or sent, unless everything the ask was issued
    /// under is still what this store is showing: the session, `request` as the list on screen,
    /// and `uid` among its covers. Refused too while a read for ANOTHER request is on its way —
    /// the screen has moved on, and that read, not this one, is what replaces these covers (with
    /// fresh signatures of its own). Only a refresh of the list on screen is ever sent, and a
    /// refresh never supersedes a read for another request.
    public func rereadCovers(
        of request: LibraryBucketRequest,
        holding uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async {
        guard sessionStillCurrent(handle), loadedRequest == request,
            buckets.contains(where: { $0.coverUID == uid }),
            loadingLineage.map({ $0.request == request }) ?? true
        else { return }
        await refresh(
            size: request.size,
            filter: request.filter,
            tag: request.tag,
            mine: request.mine,
            visibility: request.visibility,
            using: handle,
            baseURL: baseURL
        )
    }

    /// How many callers are parked until some read ends. A test seam, read-only: it lets a test
    /// know a waiter has registered before it lets the read that waiter is parked on end.
    var parkedReaders: Int { readEndWaiters.values.reduce(0) { $0 + $1.count } }

    private func readEnds(_ generation: Int) async {
        await withCheckedContinuation { waiter in
            readEndWaiters[generation, default: []].append(waiter)
        }
    }

    private func read(
        _ request: LibraryBucketRequest,
        using handle: SessionHandle,
        baseURL: URL
    ) async {
        // A replaced session claims nothing: its read would supersede the current session's and
        // could only be dropped itself. Asked here, with nothing awaited between the question and
        // the claim below, so no path into this function gets past it.
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a bucket read for a session that has ended is not sent")
            return
        }
        let client = handle.client
        // A read for another request supersedes whatever is in flight: that answer is for buckets
        // nobody is showing any more.
        generation += 1
        let lineage = Lineage(generation: generation, request: request, session: handle.generation)
        loadingLineage = lineage
        latestLineage = lineage
        latestAbandoned = false
        isLoading = true
        var abandoned = false
        defer {
            if latestLineage == lineage { latestAbandoned = abandoned }
            if loadingLineage == lineage {
                loadingLineage = nil
                isLoading = false
            }
            for waiter in readEndWaiters.removeValue(forKey: lineage.generation) ?? [] {
                waiter.resume()
            }
        }
        do {
            let rows = try await Self.buckets(client, request: request, baseURL: baseURL)
            guard isCurrent(lineage) else {
                MemosLog.api.info("GET /api/attachments/buckets answered a request that moved on")
                return
            }
            guard sessionStillCurrent(handle) else {
                MemosLog.api.info("a bucket list for a session that has ended is not applied")
                return
            }
            buckets = rows
            loadedRequest = request
            lastError = nil
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            // Cancelled before an answer arrived, whichever side noticed: an answer for nobody.
            abandoned = Task.isCancelled || StoreFailure.isCancellation(error)
            guard isCurrent(lineage) else {
                MemosLog.api.info("GET /api/attachments/buckets failed for a request that moved on")
                return
            }
            await report(error, issuedUnder: handle)
        }
    }

    /// Empties the list because this device is signed in as somebody else: the outgoing account's
    /// buckets are not the incoming one's, and a read in flight was asked for by somebody else.
    public func sessionIdentityChanged() {
        buckets = []
        loadedRequest = nil
        lastError = nil
        loadingLineage = nil
        latestLineage = nil
        latestAbandoned = false
        isLoading = false
        generation += 1
    }

    /// Whether nothing — no other read, no change of account — has been issued since `lineage`'s.
    private func isCurrent(_ lineage: Lineage) -> Bool { lineage.generation == generation }

    /// The same funnel, in the same order, as `LibraryTagStore.report`.
    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        if let failure = StoreFailure.transportFailure(error) {
            lastError = nil
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle) {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        lastError = apiError.errorDescription
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
    }

    static func buckets(
        _ client: any APIProtocol,
        request: LibraryBucketRequest,
        baseURL: URL
    ) async throws -> [LibraryBucket] {
        let response = try await client.attachmentBucketsApiAttachmentsBucketsGet(
            .init(
                query: .init(
                    size: apiSize(request.size),
                    _type: request.filter.apiType,
                    tz: request.timeZoneIdentifier,
                    tag: request.tag,
                    mine: apiMine(request.mine),
                    visibility: request.visibility.apiVisibility
                )
            )
        )
        switch response {
        case .ok(let ok):
            let rows = try ok.body.json
            MemosLog.api.info(
                "GET /api/attachments/buckets -> 200, \(rows.count, privacy: .public) buckets"
            )
            return rows.map { LibraryBucket($0, baseURL: baseURL) }
        case .unprocessableContent:
            throw APIError.server(status: 422)
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }

    // Each case named on both sides rather than bridged through the raw value, so a size the
    // contract stops offering is a compile error here and not a request the server refuses.
    private static func apiSize(
        _ size: LibraryBucketSize
    ) -> Operations.AttachmentBucketsApiAttachmentsBucketsGet.Input.Query.SizePayload {
        switch size {
        case .day: .day
        case .month: .month
        case .year: .year
        }
    }
}
