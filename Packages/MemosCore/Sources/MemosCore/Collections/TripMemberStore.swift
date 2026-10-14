import Foundation
import MemosAPI
import Observation

/// A trip's members as the server's member route answers them for the caller, and the Removed
/// list computed from them.
///
/// **Members are drained.** `GET /api/collections/{uid}/attachments?order=taken_asc&limit=60`, no
/// `type`, page after page following `X-Next-Cursor` to an empty cursor (`complete`) or to
/// `memberCap` (`truncated`). A drain is fenced by its lineage — the trip store's revision, the
/// session generation and the uid — and by the token of its slot: a page answered after any of
/// them moved is dropped whole. A second drain of the same lineage joins the one on the wire.
///
/// **The Removed list is exact or unavailable.** There is no route that lists a trip's
/// exclusions, so they are the candidates minus the members: the candidates are the Library's
/// listing under the trip's tag (only when it has one) and the span's walk down the untagged
/// taken-order listing (only when it has a span; the one permitted untagged request); a trip with
/// neither has none and sends nothing. The subtraction is made only over a COMPLETE member drain
/// that belongs to the current revision; otherwise the answer is `unavailable`. Nothing is read
/// until asked, and every mutation, refresh or identity change drops what was computed.
@MainActor
@Observable
public final class TripMemberStore {
    public static let pageSize = 60
    public static let memberCap = 2000

    /// What the last drain could not do.
    public internal(set) var lastError: String?

    /// A drain that applied, with the lineage it belongs to: shown and reused only while that
    /// lineage is the current one.
    private struct Drained {
        var lineage: Lineage
        var rows: [LibraryRow]
        var complete: Bool
    }

    private struct Lineage: Equatable {
        var revision: Int
        var session: Int
        var uid: String
    }

    let trips: TripStore
    let pageSize: Int
    public let memberCap: Int
    let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    var session: (any SessionReporting)?
    private var drained: [String: Drained] = [:]
    private var flights: [String: (lineage: Lineage, token: Int, task: Task<Void, Never>)] = [:]
    private var removedResults: [String: (lineage: Lineage, state: TripRemovedState)] = [:]
    private var removedFlights: [String: (lineage: Lineage, token: Int, task: Task<Void, Never>)] =
        [:]
    private var nextToken = 0

    /// Test seam: awaited as a Removed read starts executing, before it reads anything.
    @ObservationIgnored var onRemovedStart: (@MainActor (String) async -> Void)?

    // The journal, the New trip sheet's reads and Select's Delete (MEMNG-754), ported from the
    // device-local membership store; their logic is in `TripMemberStore+Journal.swift`.

    /// The count of every tag, every kind of file, in the server's order, for the New trip sheet.
    public internal(set) var tagCounts: [LibraryTag] = []
    /// Whether `tagCounts` is an answer, so the sheet can tell "no tag has a picture" from "not
    /// read yet".
    public internal(set) var tagCountsLoaded = false
    /// The span of every tag the sheet has asked about, by tag.
    public internal(set) var spans: [String: TripTagSpan] = [:]
    /// A delete run is out: the Trip screen's toolbar takes no second tap meanwhile.
    public internal(set) var isDeleting = false
    var journals: [String: TripJournal] = [:]
    /// What the last journal load of each trip could not do, by uid.
    var journalErrors: [String: String] = [:]
    var journalFlights: [String: TripJournalFlight] = [:]
    var countsInFlight = false
    /// A span joins only reads issued before the same deletes; its token keeps an old read's end
    /// from clearing a newer read's slot.
    var spansInFlight:
        [String: (generation: Int, credential: Int, deletionRevision: Int, token: Int)] = [:]
    /// The callers that joined a span read, by its token; let go when it ends or on a reset.
    @ObservationIgnored var spanJoiners: [Int: [CheckedContinuation<Void, Never>]] = [:]
    /// The pictures Delete took: absent from every trip's members and journal, so a page read
    /// before the delete cannot put one back. A screen hands them to a viewer open over them.
    public internal(set) var deleted: Set<String> = []
    /// A count or extremum cannot subtract deleted ids: `forget` advances this fence so an
    /// answer issued before the delete is dropped whole, even though the trip revision stays.
    var deletionRevision = 0
    /// The exclusions this app wrote and the server acknowledged, by trip and picture, each with
    /// the token it was recorded under; what overrides one is `noteAcknowledged`'s rule.
    var ownExclusions: [String: [String: Int]] = [:]
    /// Bumped by `sessionIdentityChanged()`: everything read before it belongs to somebody else.
    var generation = 0
    var journalToken = 0
    /// Seams for tests: a journal load, or a span read, joining one already in flight.
    @ObservationIgnored var onJournalJoin: (@MainActor () -> Void)?
    @ObservationIgnored var onSpanJoin: (@MainActor () -> Void)?

    public init(
        trips: TripStore,
        pageSize: Int = TripMemberStore.pageSize,
        memberCap: Int = TripMemberStore.memberCap,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.trips = trips
        self.pageSize = pageSize
        self.memberCap = memberCap
        self.onUnauthorized = onUnauthorized
        trips.onInvalidate.append { [weak self] uid in self?.invalidate(uid: uid) }
        trips.onReconcile.append { [weak self] uid, handle, baseURL in
            await self?.drain(uid: uid, using: handle, baseURL: baseURL)
        }
        trips.onAcknowledged.append { [weak self] kind, uid, picture in
            self?.noteAcknowledged(kind, trip: uid, picture: picture)
        }
    }

    /// Names the session this store's transport outcomes belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    // MARK: - Members

    public func state(for trip: Trip) -> TripMemberState {
        if flights[trip.uid] != nil { return .draining }
        guard let held = held(trip.uid) else { return .notLoaded }
        return held.complete ? .complete : .truncated
    }

    /// The drained members, oldest taken first, less what this app has taken out of the trip
    /// (`stillMembers`); empty until a drain of the current lineage has applied.
    public func members(for trip: Trip) -> [LibraryRow] {
        stillMembers(held(trip.uid)?.rows ?? [], of: trip)
    }

    /// Of `rows`, read as `trip`'s members at some moment, the ones still its members as far as
    /// this app knows: less every picture Delete took and every exclusion from the trip this app
    /// wrote and the server acknowledged (`noteAcknowledged`). A drain read before either can land
    /// after it, and a screen keeps the rows it last showed while no read lands; both are read
    /// through here, so neither shows the picture again.
    public func stillMembers(_ rows: [LibraryRow], of trip: Trip) -> [LibraryRow] {
        let removed = ownExclusions[trip.uid] ?? [:]
        guard !deleted.isEmpty || !removed.isEmpty else { return rows }
        return rows.filter { !deleted.contains($0.id) && removed[$0.id] == nil }
    }

    /// The server's count, the drained rows' taken extrema, and the cover: the chosen one while it
    /// is a member, else the first member. Nil before a drain has applied.
    public func summary(for trip: Trip) -> TripMemberSummary? {
        guard held(trip.uid) != nil else { return nil }
        let rows = members(for: trip)
        let dates = rows.compactMap(\.takenAt)
        let chosen = trip.cover.flatMap { cover in rows.first { $0.id == cover.id } }
        return TripMemberSummary(
            count: trip.memberCount,
            firstTaken: dates.min(),
            lastTaken: dates.max(),
            cover: chosen ?? rows.first
        )
    }

    /// Reads the trip's members. Joins a drain of the same lineage already on the wire.
    public func drain(_ trip: Trip, using handle: SessionHandle, baseURL: URL) async {
        await drain(uid: trip.uid, using: handle, baseURL: baseURL)
    }

    func drain(uid: String, using handle: SessionHandle, baseURL: URL) async {
        let lineage = Lineage(revision: trips.revision, session: handle.generation, uid: uid)
        if let running = flights[uid], running.lineage == lineage {
            await running.task.value
            return
        }
        nextToken += 1
        let token = nextToken
        let task = Task { await self.runDrain(lineage, token: token, handle, baseURL) }
        flights[uid] = (lineage, token, task)
        await task.value
    }

    private func runDrain(
        _ lineage: Lineage, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if flights[lineage.uid]?.token == token { flights[lineage.uid] = nil } }
        var rows: [LibraryRow] = []
        var cursor: String?
        var complete = true
        do {
            repeat {
                let page = try await Self.page(
                    handle.client, uid: lineage.uid, cursor: cursor, limit: pageSize,
                    baseURL: baseURL)
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                guard stillCurrent(lineage), flights[lineage.uid]?.token == token else {
                    MemosLog.api.info("a trip's member page answered for a moved revision")
                    return
                }
                rows = MediaLibraryStore.merged(rows, with: page.items, filter: .all)
                cursor = page.nextCursor
                if rows.count >= memberCap, rows.count > memberCap || cursor != nil {
                    complete = false
                    rows = Array(rows.prefix(memberCap))
                    break
                }
            } while cursor != nil
        } catch {
            await report(error, handle: handle) {
                self.stillCurrent(lineage) && self.flights[lineage.uid]?.token == token
            }
            return
        }
        let landed = Lineage(revision: trips.revision, session: lineage.session, uid: lineage.uid)
        drained[lineage.uid] = Drained(lineage: landed, rows: rows, complete: complete)
        contradict(uid: lineage.uid, listed: rows, askedAt: token)
        lastError = nil
    }

    // MARK: - The app's own exclusions (MEMNG-793)

    /// Records an exclusion the server acknowledged, or ends one at Add Back's acknowledgement.
    ///
    /// Which source wins when: the record is this app's own knowledge, the drain is the server's.
    /// The record is kept apart from the drain, so nothing that drops a drain — a list, a pin, a
    /// write's invalidation — drops it, and the journal leaves the picture out while it stands,
    /// drained or not. It ends at Add Back's acknowledgement, or when a drain ASKED FOR AFTER it
    /// was recorded lists the picture: the server has it back, from another device, and its later
    /// word wins (`contradict`). A drain asked for earlier answered about the trip before the
    /// exclusion and says nothing against it; a later one that does not list the picture agrees,
    /// and the record stays, because the next list or pin drops that drain again. A change of
    /// identity drops it with everything else the outgoing session read.
    func noteAcknowledged(_ kind: TripStore.BatchKind, trip uid: String, picture: String) {
        switch kind {
        case .exclude:
            nextToken += 1
            ownExclusions[uid, default: [:]][picture] = nextToken
        case .include:
            ownExclusions[uid]?[picture] = nil
            if ownExclusions[uid]?.isEmpty == true { ownExclusions[uid] = nil }
        }
    }

    /// Ends the record of each picture a drain of `uid` asked for at `token` lists, when the
    /// record is older than the drain (`noteAcknowledged`).
    private func contradict(uid: String, listed rows: [LibraryRow], askedAt token: Int) {
        guard var own = ownExclusions[uid] else { return }
        for row in rows where (own[row.id] ?? .max) < token { own[row.id] = nil }
        ownExclusions[uid] = own.isEmpty ? nil : own
    }

    // MARK: - Remove and add back

    /// Removes the pictures from the trip on the server, as one batch under the trip's slot, then
    /// reads the record and drains the members again — whatever the batch did.
    @discardableResult
    public func remove(
        _ uids: [String], from trip: Trip, using handle: SessionHandle, baseURL: URL
    ) async throws -> TripBatchOutcome {
        try await batch(.exclude, uids, trip, handle, baseURL)
    }

    /// Gives a removed picture back to the trip, the same way.
    @discardableResult
    public func addBack(
        _ uid: String, to trip: Trip, using handle: SessionHandle, baseURL: URL
    ) async throws -> TripBatchOutcome {
        try await batch(.include, [uid], trip, handle, baseURL)
    }

    /// The trip store's batch: its re-drain of the members is this store's reconciler, run inside
    /// the batch's slot (`TripStore.onReconcile`).
    private func batch(
        _ kind: TripStore.BatchKind, _ uids: [String], _ trip: Trip, _ handle: SessionHandle,
        _ baseURL: URL
    ) async throws -> TripBatchOutcome {
        try await trips.batch(kind, uids, on: trip.uid, using: handle, baseURL: baseURL)
    }

    // MARK: - Removed

    /// The Removed list of the current lineage; one computed under an earlier revision or session
    /// is not shown.
    ///
    /// A picture Delete took is left out of an exact list here, as it is read, so one computed
    /// before the delete and one whose candidates were read before it and landed after it alike
    /// never offer it: the delete moves no revision, and the picture is no candidate on the server
    /// any more, so the list without it is still exact (criterion 5). Every reader comes through
    /// here; the list is not filtered again when it is stored.
    public func removedState(for trip: Trip) -> TripRemovedState {
        if let result = removedResults[trip.uid], current(result.lineage) {
            guard case .exact(let rows) = result.state, !deleted.isEmpty else {
                return result.state
            }
            return .exact(rows.filter { !deleted.contains($0.id) })
        }
        return removedFlights[trip.uid] != nil ? .loading : .notRequested
    }

    /// Computes the Removed list (see the type's doc). Joins one of the same lineage.
    public func removed(for trip: Trip, using handle: SessionHandle, baseURL: URL) async {
        let lineage = Lineage(revision: trips.revision, session: handle.generation, uid: trip.uid)
        if let running = removedFlights[trip.uid], running.lineage == lineage {
            await running.task.value
            return
        }
        nextToken += 1
        let token = nextToken
        removedResults[trip.uid] = nil
        let task = Task { await self.runRemoved(trip, lineage, token: token, handle, baseURL) }
        removedFlights[trip.uid] = (lineage, token, task)
        await task.value
    }

    private func runRemoved(
        _ trip: Trip, _ lineage: Lineage, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        let uid = trip.uid
        defer { if removedFlights[uid]?.token == token { removedFlights[uid] = nil } }
        if let onRemovedStart { await onRemovedStart(uid) }
        guard trip.tag != nil || trip.span != nil else {
            // The trip as it was issued has no criteria. That answer belongs to the issuing
            // lineage alone: a change that ran before this task did has dropped its slot.
            guard removedFlights[uid]?.token == token, stillCurrent(lineage) else { return }
            removedResults[uid] = (lineage, .exact([]))
            return
        }
        if !reusable(uid, handle) { await drain(uid: uid, using: handle, baseURL: baseURL) }
        guard removedFlights[uid]?.token == token, sessionCurrent(handle) else { return }
        // Members and candidates are both read at `base`: the drain's lineage, which the
        // candidates' revision must still be when they land. The trip is taken as it stands there.
        let base = trips.revision
        let current = trips.trips.first { $0.uid == uid } ?? trip
        let candidates: [LibraryRow]?
        do {
            candidates = try await self.candidates(of: current, handle, baseURL) {
                self.removedFlights[uid]?.token == token && self.sessionCurrent(handle)
            }
        } catch {
            await report(error, handle: handle) { self.removedFlights[uid]?.token == token }
            return
        }
        guard removedFlights[uid]?.token == token, sessionCurrent(handle) else { return }
        guard let candidates, let held = drained[uid], held.complete,
            held.lineage == Lineage(revision: base, session: handle.generation, uid: uid),
            trips.revision == base
        else {
            removedResults[uid] = (stamp(uid, handle), .unavailable)
            return
        }
        // A picture this app took out is no member, whatever a drain read before it says.
        let members = Set(stillMembers(held.rows, of: current).map(\.id))
        let gone = candidates.filter { !members.contains($0.id) }
        removedResults[uid] = (stamp(uid, handle), .exact(Self.oldestFirst(gone)))
    }

    /// The tag's listing and the span's walk, each picture once; nil when either ran past the cap
    /// (the list would not be exact) or the read stopped owning its slot.
    private func candidates(
        of trip: Trip, _ handle: SessionHandle, _ baseURL: URL, owned: () -> Bool
    ) async throws -> [LibraryRow]? {
        var rows: [LibraryRow] = []
        if let tag = trip.tag {
            var cursor: String?
            repeat {
                let page = try await MediaLibraryStore.page(
                    handle.client, filter: .all, order: .oldestFirst, tag: tag, cursor: cursor,
                    limit: pageSize, baseURL: baseURL)
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                guard owned() else { return nil }
                rows = MediaLibraryStore.merged(rows, with: page.items, filter: .all)
                cursor = page.nextCursor
                if rows.count > memberCap { return nil }
            } while cursor != nil
        }
        guard let span = trip.span else { return rows }
        var cursor: String?
        var more = false
        var window: [LibraryRow] = []
        repeat {
            let page = try await MediaLibraryStore.page(
                handle.client, filter: .all, order: .newestFirst, tag: nil, cursor: cursor,
                limit: pageSize, baseURL: baseURL)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            guard owned() else { return nil }
            // Newest first: from the first row taken before the start on, everything is older.
            let before = page.items.firstIndex {
                $0.takenAt.map { $0 < span.lowerBound } ?? false
            }
            let read = page.items[..<(before ?? page.items.endIndex)]
            let inside = read.filter { $0.takenAt.map(span.contains) ?? false }
            window = MediaLibraryStore.merged(window, with: Array(inside), filter: .all)
            if window.count > memberCap { return nil }
            cursor = page.nextCursor
            more = before == nil && cursor != nil
        } while more
        return MediaLibraryStore.merged(rows, with: window, filter: .all)
    }

    // MARK: - Invalidation

    /// Drops what this store holds for trip `uid` (every trip for nil): its members, its Removed
    /// list and the slots of its reads, whose answers are then refused on arrival.
    public func invalidate(uid: String?) {
        guard let uid else {
            drained = [:]
            flights = [:]
            removedResults = [:]
            removedFlights = [:]
            return
        }
        drained[uid] = nil
        flights[uid] = nil
        removedResults[uid] = nil
        removedFlights[uid] = nil
    }

    // MARK: - Helpers

    /// What a drain left for `uid`, while its lineage is the current one.
    private func held(_ uid: String) -> Drained? {
        guard let held = drained[uid], current(held.lineage) else { return nil }
        return held
    }

    /// Whether the drain held for `uid` is complete and of the revision and session `handle`
    /// reads under — the only one a Removed list may subtract.
    private func reusable(_ uid: String, _ handle: SessionHandle) -> Bool {
        guard let held = drained[uid], held.complete else { return false }
        return held.lineage == stamp(uid, handle) && sessionCurrent(handle)
    }

    /// The lineage a result computed now belongs to.
    private func stamp(_ uid: String, _ handle: SessionHandle) -> Lineage {
        Lineage(revision: trips.revision, session: handle.generation, uid: uid)
    }

    /// A cached result's lineage is current while the trip store's revision and the session
    /// generation are the ones it was computed under.
    private func current(_ lineage: Lineage) -> Bool {
        lineage.revision == trips.revision && sessionCurrent(generation: lineage.session)
    }

    private func stillCurrent(_ lineage: Lineage) -> Bool {
        lineage.revision == trips.revision && sessionCurrent(generation: lineage.session)
    }

    private func sessionCurrent(_ handle: SessionHandle) -> Bool {
        sessionCurrent(generation: handle.generation)
    }

    private func sessionCurrent(generation: Int) -> Bool {
        guard let session else { return true }
        return session.activeHandle?.generation == generation
    }

    private static func oldestFirst(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.takenAt ?? .distantFuture
            let right = rhs.element.takenAt ?? .distantFuture
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// The Library's funnel, in its order.
    private func report(
        _ error: any Error, handle: SessionHandle, while owned: () -> Bool
    ) async {
        if StoreFailure.reachedServer(error) {
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        }
        guard sessionCurrent(handle) else { return }
        if let reason = StoreFailure.transportFailure(error) {
            if owned() { lastError = nil }
            session?.noteTransportFailure(reason, issuedUnder: handle.generation)
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle),
                owned()
            {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else { return }
        if owned() { lastError = apiError.errorDescription }
    }

    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
    }

    /// One page of the member route: every kind, oldest taken first.
    static func page(
        _ client: any APIProtocol, uid: String, cursor: String?, limit: Int, baseURL: URL
    ) async throws -> (items: [LibraryRow], nextCursor: String?) {
        let input = Operations.ListMembersApiCollectionsUidAttachmentsGet.Input(
            path: .init(uid: uid),
            query: .init(limit: limit, cursor: cursor, order: .takenAsc)
        )
        switch try await client.listMembersApiCollectionsUidAttachmentsGet(input) {
        case .ok(let ok):
            let rows = try ok.body.json
            return (rows.map { LibraryRow($0, baseURL: baseURL) }, ok.headers.xNextCursor)
        case .notFound: throw APIError.notFound
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }
}
