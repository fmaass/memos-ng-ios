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

    /// A screen's standing to read its automatic collection again for a lapsed signature — the
    /// cover its card carried (`renewCover`), its members (`drain(_:under:using:baseURL:)`) and
    /// its journal (`loadJournal(_:under:using:baseURL:)`): the scope it shows, and the token the
    /// store minted for that showing (`coverLease(for:)`). One lease per showing covers all three.
    public struct CoverLease: Sendable, Equatable {
        let scope: String
        let token: Int
    }

    private struct Lineage: Equatable {
        var revision: Int
        var session: Int
        /// The key the lane is held under: the trip's uid, or an automatic scope's id.
        var uid: String
        /// What was asked for. A month's display id is the same in every zone, so its zone and
        /// bounds take part in joining a flight and in showing a drain (MEMNG-817).
        var request: MemberRequest = .trip
    }

    /// What one drain asked the server for.
    private enum MemberRequest: Equatable {
        /// The member route of the trip the key names.
        case trip
        /// The Library's listing under a tag.
        case tag(String)
        /// The Library's listing from a bucket, held to the period's interval.
        case period(bucket: String, CollectionPeriod)
    }

    let trips: TripStore
    let pageSize: Int
    public let memberCap: Int
    let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    var session: (any SessionReporting)?
    private var drained: [String: Drained] = [:]
    /// The unfiltered drain that failed, per key: the lineage that issued it, its request
    /// included. Apart from "not read", so the screen does not take a failure for an invalidation
    /// and ask again by itself; a new drain, a landed one, an invalidation or another lineage ends
    /// it (MEMNG-846).
    private var drainFailures: [String: Lineage] = [:]
    private var flights: [String: (lineage: Lineage, token: Int, task: Task<Void, Never>)] = [:]
    private var removedResults: [String: (lineage: Lineage, state: TripRemovedState)] = [:]
    private var removedFlights: [String: (lineage: Lineage, token: Int, task: Task<Void, Never>)] =
        [:]
    private var nextToken = 0
    /// The pictures automatic collections' cards carried, signed again by `renewCover`, by uid.
    var renewedCovers: [String: MemoAttachment] = [:]
    /// The renewal of each carried picture on the wire: its token is what lets its answer land,
    /// its credential the generation a later ask must share to join it.
    var coverFlights: [String: (token: Int, credential: Int, task: Task<Void, Never>)] = [:]
    /// The live lease of each automatic collection on screen, by scope id (`coverLease(for:)`):
    /// what a lapsed signature's re-read of its cover, members or journal must still hold.
    var coverLeases: [String: Int] = [:]

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
    /// The count read in flight: a read joins none, and is refused only beside one issued under
    /// the same deletion revision; its token keeps an old read's end from clearing a newer slot.
    var countsInFlight: (deletionRevision: Int, token: Int)?
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
        guard let held = held(trip.uid) else { return nil }
        let rows = members(for: trip)
        let dates = rows.compactMap(\.takenAt)
        let chosen = trip.cover.flatMap { cover in rows.first { $0.id == cover.id } }
        return TripMemberSummary(
            count: trip.memberCount,
            firstTaken: dates.min(),
            lastTaken: dates.max(),
            cover: chosen ?? rows.first,
            complete: held.complete
        )
    }

    // MARK: - Members by scope (MEMNG-817)

    /// Where a scope's members stand; a trip's as `state(for:)` says.
    public func state(for scope: CollectionScope) -> TripMemberState {
        if case .trip(let trip) = scope { return state(for: trip) }
        guard let request = Self.request(for: scope) else { return .notLoaded }
        if let flight = flights[scope.id], flight.lineage.request == request { return .draining }
        guard let held = held(scope.id, request: request) else { return .notLoaded }
        return held.complete ? .complete : .truncated
    }

    /// Whether the last drain of `scope`'s members failed under the current lineage and nothing
    /// has asked again since.
    public func drainFailed(for scope: CollectionScope) -> Bool {
        guard let failure = drainFailures[scope.id], let request = Self.request(for: scope),
            failure.request == request
        else { return false }
        return current(failure)
    }

    /// Whether the screen should read `scope`'s members again by itself: nothing held, nothing on
    /// the wire, and no failure of the current lineage standing (`drainFailed(for:)`).
    public func needsDrain(for scope: CollectionScope) -> Bool {
        state(for: scope) == .notLoaded && !drainFailed(for: scope)
    }

    /// A scope's drained members, oldest taken first, less every picture Delete took. A trip's are
    /// `members(for:)`'s, which also leave out what this app removed from it.
    public func members(for scope: CollectionScope) -> [LibraryRow] {
        switch scope {
        case .trip(let trip): return members(for: trip)
        case .automatic:
            guard let request = Self.request(for: scope),
                let held = held(scope.id, request: request)
            else { return [] }
            guard !deleted.isEmpty else { return held.rows }
            return held.rows.filter { !deleted.contains($0.id) }
        }
    }

    /// A trip's summary as `summary(for:)` makes it. An automatic collection has no server count
    /// and no chosen cover: its count is the card's until a drain has read every member, then the
    /// drained rows'; its cover is the one the card carried while it is a drained member or the
    /// drain stopped short of the end (the cover may lie past it), else the newest drained row —
    /// the picture the card would show now, where a trip keeps its oldest.
    public func summary(for scope: CollectionScope) -> TripMemberSummary? {
        let collection: AutomaticCollection
        switch scope {
        case .trip(let trip): return summary(for: trip)
        case .automatic(let automatic): collection = automatic
        }
        guard let request = Self.request(for: scope), let held = held(scope.id, request: request)
        else { return nil }
        return Self.summary(
            of: collection, rows: members(for: scope), complete: held.complete, deleted: deleted)
    }

    /// `summary(for:)`'s rule for an automatic collection, over `rows` — its members as far as this
    /// app knows, every picture Delete took already left out — read by a drain that did or did not
    /// reach the end (`complete`). A screen that holds the members of an earlier drain while it
    /// reads again asks the same rule of what it still holds, so a picture deleted meanwhile
    /// leaves its cover, its count and its span at once. A card's picture that `deleted` names is
    /// carried no more: the cover falls to the newest row, or to none.
    public static func summary(
        of collection: AutomaticCollection, rows: [LibraryRow], complete: Bool,
        deleted: Set<String>
    ) -> TripMemberSummary {
        let dates = rows.compactMap(\.takenAt)
        let carried = collection.cover.flatMap { cover in rows.first { $0.id == cover.uid } }
        var cover = rows.last
        var coverUid = rows.last?.id
        if let carried {
            cover = carried
            coverUid = carried.id
        } else if let card = collection.cover, !complete, !deleted.contains(card.uid) {
            cover = nil
            coverUid = card.uid
        }
        return TripMemberSummary(
            count: complete ? rows.count : collection.count,
            firstTaken: dates.min(),
            lastTaken: dates.max(),
            cover: cover,
            coverUid: coverUid,
            complete: complete
        )
    }

    /// A lapsed signature's re-read of `scope`'s members, for the showing `lease` was minted for.
    /// Nothing starts — no join, no flight — unless `lease` is still the scope's live one, asked
    /// synchronously before `drain(_:using:baseURL:)` takes or joins a slot: a callback the media
    /// table held through its cooldown past the scope's forget, or past a new showing of it, reads
    /// nothing, so no answer can repopulate the members that forget let go.
    public func drain(
        _ scope: CollectionScope, under lease: CoverLease, using handle: SessionHandle,
        baseURL: URL
    ) async {
        guard leaseIsLive(lease, for: scope) else {
            MemosLog.api.info("a collection's members were asked for under a retired lease")
            return
        }
        await drain(scope, using: handle, baseURL: baseURL)
    }

    /// A lapsed signature's re-read of `scope`'s journal, fenced as the leased drain is.
    public func loadJournal(
        _ scope: CollectionScope, under lease: CoverLease, using handle: SessionHandle,
        baseURL: URL
    ) async {
        guard leaseIsLive(lease, for: scope) else {
            MemosLog.api.info("a collection's journal was asked for under a retired lease")
            return
        }
        await loadJournal(scope, using: handle, baseURL: baseURL)
    }

    /// Whether `lease` names `scope` and is still the live lease of it.
    func leaseIsLive(_ lease: CoverLease, for scope: CollectionScope) -> Bool {
        lease.scope == scope.id && coverLeases[lease.scope] == lease.token
    }

    /// Reads a scope's members: a trip's through `drain(_:using:baseURL:)`, an automatic
    /// collection's from the Library's listing, under the same fences. Joins a drain of the same
    /// lineage — key, request, revision and session — already on the wire. A month or year key
    /// that names no period sends nothing.
    public func drain(_ scope: CollectionScope, using handle: SessionHandle, baseURL: URL) async {
        if case .trip(let trip) = scope {
            await drain(trip, using: handle, baseURL: baseURL)
            return
        }
        guard let request = Self.request(for: scope) else { return }
        let lineage = Lineage(
            revision: trips.revision, session: handle.generation, uid: scope.id, request: request)
        if let running = flights[scope.id], running.lineage == lineage {
            await running.task.value
            return
        }
        drainFailures[scope.id] = nil
        nextToken += 1
        let token = nextToken
        let task = Task { await self.runAutomaticDrain(lineage, token: token, handle, baseURL) }
        flights[scope.id] = (lineage, token, task)
        await task.value
    }

    private static func request(for scope: CollectionScope) -> MemberRequest? {
        switch scope {
        case .trip: return .trip
        case .automatic(let collection):
            if case .tag(let name) = collection.kind { return .tag(name) }
            guard let bucket = collection.bucket, let period = collection.period else { return nil }
            return .period(bucket: bucket, period)
        }
    }

    /// The trip drain's walk over `GET /api/attachments`, no `type`, oldest taken first. `bucket=`
    /// only says where the walk STARTS — the listing runs on past the period, and past an empty
    /// bucket into the next — so a period keeps a row only while it was taken before `nextStart`
    /// and asks for no page after the first row that was not.
    private func runAutomaticDrain(
        _ lineage: Lineage, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if flights[lineage.uid]?.token == token { flights[lineage.uid] = nil } }
        var tag: String?
        var bucket: String?
        var period: CollectionPeriod?
        switch lineage.request {
        case .trip: return
        case .tag(let name): tag = name
        case .period(let key, let interval):
            bucket = key
            period = interval
        }
        var rows: [LibraryRow] = []
        var cursor: String?
        var complete = true
        do {
            repeat {
                let page = try await MediaLibraryStore.page(
                    handle.client, filter: .all, order: .oldestFirst, tag: tag, bucket: bucket,
                    timeZone: period?.zone.identifier, cursor: cursor, limit: pageSize,
                    baseURL: baseURL)
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                guard stillCurrent(lineage), flights[lineage.uid]?.token == token else {
                    MemosLog.api.info("a collection's member page answered for a moved revision")
                    return
                }
                var items = page.items
                var next = page.nextCursor
                // An undated row cannot be placed against the bound; the server dates every row
                // (`taken_at_expr` coalesces), so one would be a contract change, and it is kept.
                if let period,
                    let past = items.firstIndex(where: {
                        $0.takenAt.map { $0 >= period.nextStart } ?? false
                    })
                {
                    items = Array(items[..<past])
                    next = nil
                }
                rows = MediaLibraryStore.merged(rows, with: items, filter: .all)
                cursor = next
                if rows.count >= memberCap, rows.count > memberCap || cursor != nil {
                    complete = false
                    rows = Array(rows.prefix(memberCap))
                    break
                }
            } while cursor != nil
        } catch {
            noteDrainFailure(error, lineage, token: token)
            await report(error, handle: handle) {
                self.stillCurrent(lineage) && self.flights[lineage.uid]?.token == token
            }
            return
        }
        var landed = lineage
        landed.revision = trips.revision
        drained[lineage.uid] = Drained(lineage: landed, rows: rows, complete: complete)
        drainFailures[lineage.uid] = nil
        lastError = nil
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
        drainFailures[uid] = nil
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
            noteDrainFailure(error, lineage, token: token)
            await report(error, handle: handle) {
                self.stillCurrent(lineage) && self.flights[lineage.uid]?.token == token
            }
            return
        }
        let landed = Lineage(revision: trips.revision, session: lineage.session, uid: lineage.uid)
        drained[lineage.uid] = Drained(lineage: landed, rows: rows, complete: complete)
        drainFailures[lineage.uid] = nil
        contradict(uid: lineage.uid, listed: rows, askedAt: token)
        lastError = nil
    }

    /// Records the failure of the drain `lineage` issued, taken in this turn before any hop: only
    /// while that drain still owns its slot and its lineage is the current one, so a failure that
    /// outlived an invalidation, a new session or a moved revision records nothing. A transport
    /// failure is recorded as any other — offline, the loop would ask just as often. A refused
    /// credential is not: the session decides it (`report`), and a superseded one is read again
    /// under the credential that replaced it. Nor is a cancellation, which nobody answered.
    private func noteDrainFailure(_ error: any Error, _ lineage: Lineage, token: Int) {
        guard stillCurrent(lineage), flights[lineage.uid]?.token == token,
            !StoreFailure.isCancellation(error), StoreFailure.refusal(error) == nil
        else { return }
        drainFailures[lineage.uid] = lineage
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

    /// Drops what this store holds for trip `uid` (every trip for nil): its members, a failed
    /// drain's record, its Removed list and the slots of its reads, whose answers are then refused
    /// on arrival.
    public func invalidate(uid: String?) {
        guard let uid else {
            drained = [:]
            drainFailures = [:]
            flights = [:]
            removedResults = [:]
            removedFlights = [:]
            return
        }
        drained[uid] = nil
        drainFailures[uid] = nil
        flights[uid] = nil
        removedResults[uid] = nil
        removedFlights[uid] = nil
    }

    /// Drops everything this store holds for `scope`: its members and Removed list as
    /// `invalidate(uid:)` does, and its journal, its sentence and the ownership of its journal
    /// load in flight, so a page or a refusal that outlives the forget writes nothing and the
    /// walk reads no further page. A member revision calls `invalidate(uid:)` alone and leaves
    /// the journal standing — a trip's is fenced by its record's rule, an automatic one's by its
    /// own — but an automatic collection has no record whose removal would fence it, so leaving
    /// a scope is this call. It retires the showing's lease too, so a lapsed signature's callback
    /// held past it — cover, members or journal — starts no read at all.
    public func forget(_ scope: CollectionScope) {
        invalidate(uid: scope.id)
        journals[scope.id] = nil
        journalErrors[scope.id] = nil
        journalFlights[scope.id] = nil
        if case .automatic(let collection) = scope, let uid = collection.cover?.uid {
            renewedCovers[uid] = nil
            coverFlights[uid] = nil
        }
        coverLeases[scope.id] = nil
    }

    // MARK: - A carried cover (MEMNG-817)

    /// `uid` signed again by `renewCover`, while nothing has forgotten it since; nil before.
    public func renewedCover(_ uid: String) -> MemoAttachment? { renewedCovers[uid] }

    /// What lets a screen showing `scope` renew its carried cover, and read its members and its
    /// journal again for a lapsed signature: the live lease of the scope,
    /// minted on the first ask and the same one after, until a forget of the scope or a change of
    /// identity retires it. A screen opened again after that is handed a new one, so an ask that
    /// was taken under the old one — a signature callback the media table held back through its
    /// cooldown — can never start a read the scope's forget let go.
    public func coverLease(for scope: CollectionScope) -> CoverLease {
        if let token = coverLeases[scope.id] { return CoverLease(scope: scope.id, token: token) }
        nextToken += 1
        coverLeases[scope.id] = nextToken
        return CoverLease(scope: scope.id, token: nextToken)
    }

    /// Reads the picture an automatic collection's card carried by itself, for a fresh signature.
    /// The card's picture may lie past the member cap, where no drain ever reaches it, so a drain
    /// cannot re-sign it. Nothing starts unless `lease` is still its scope's live one, asked
    /// before any slot is taken. A renewal of the same picture under the same credential is
    /// joined, never doubled; its answer, a success or a failure alike, lands only while it still
    /// owns its slot, which a change of identity (`sessionIdentityChanged`) or a forget of the
    /// scope takes away, and while the credential that issued it is still the session's.
    public func renewCover(
        uid: String, under lease: CoverLease, using handle: SessionHandle, baseURL: URL
    ) async {
        guard coverLeases[lease.scope] == lease.token else {
            MemosLog.api.info("a carried cover was asked for under a lease that has been retired")
            return
        }
        guard credentialCurrent(handle) else { return }
        if let running = coverFlights[uid], running.credential == handle.generation {
            await running.task.value
            return
        }
        nextToken += 1
        let token = nextToken
        let task = Task { await self.runCoverRenewal(uid, token: token, handle, baseURL) }
        coverFlights[uid] = (token, handle.generation, task)
        await task.value
    }

    private func runCoverRenewal(
        _ uid: String, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if ownsCover(uid, token) { coverFlights[uid] = nil } }
        do {
            let fresh = try await Self.attachment(handle.client, uid: uid, baseURL: baseURL)
            guard ownsCover(uid, token), credentialCurrent(handle) else {
                MemosLog.api.info("a carried cover answered for a read that was let go; dropped")
                return
            }
            renewedCovers[uid] = fresh
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            // A read the scope's forget let go reports nothing: not to the session's decision,
            // not to the transport's health.
            guard ownsCover(uid, token) else {
                MemosLog.api.info("a carried cover failed for a read that was let go; dropped")
                return
            }
            await say(error, issuedUnder: handle, lane: .silent) { self.ownsCover(uid, token) }
        }
    }

    /// Whether the renewal holding `token` still owns `uid`'s slot.
    private func ownsCover(_ uid: String, _ token: Int) -> Bool {
        coverFlights[uid]?.token == token
    }

    /// One picture's own record, its URLs signed now.
    static func attachment(_ client: any APIProtocol, uid: String, baseURL: URL) async throws
        -> MemoAttachment
    {
        let input = Operations.AttachmentMetaApiAttachmentsUidGet.Input(path: .init(uid: uid))
        switch try await client.attachmentMetaApiAttachmentsUidGet(input) {
        case .ok(let ok):
            let meta = try ok.body.json
            return MemoAttachment(
                uid: meta.uid,
                mime: meta.mime,
                status: AttachmentStatus(meta.status),
                blurhash: meta.blurhash,
                width: meta.width,
                height: meta.height,
                duration: meta.duration,
                captureInstant: meta.captureInstant,
                thumbnailURL: URL(string: meta.thumbnailUrl, relativeTo: baseURL)?.absoluteURL,
                previewURL: URL(string: meta.previewUrl, relativeTo: baseURL)?.absoluteURL,
                webURL: URL(string: meta.webUrl, relativeTo: baseURL)?.absoluteURL,
                posterURL: URL(string: meta.posterUrl, relativeTo: baseURL)?.absoluteURL,
                downloadURL: URL(string: meta.downloadUrl, relativeTo: baseURL)?.absoluteURL
            )
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        }
    }

    // MARK: - Helpers

    /// What a drain left for `uid`, while its lineage is the current one and it answered
    /// `request`.
    private func held(_ uid: String, request: MemberRequest = .trip) -> Drained? {
        guard let held = drained[uid], current(held.lineage), held.lineage.request == request
        else { return nil }
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
