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
        /// The Library's listing under a picture's own tag (MEMNG-868), `pictureTag=` and no
        /// `tag=`: the favorites collection.
        case pictureTag(String)
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
    /// it (MEMNG-846). Kept apart from `filteredFailures`, whose shape it shares, because the drain
    /// and the grid's filtered read are two lanes of one key: a filtered ask must not end the
    /// drain's failure, nor a drain the filtered read's.
    private var drainFailures: [String: Lineage] = [:]
    private var flights: [String: (lineage: Lineage, token: Int, task: Task<Void, Never>)] = [:]
    private var removedResults: [String: (lineage: Lineage, state: TripRemovedState)] = [:]
    /// The grid's filtered read of a trip (MEMNG-780), one per trip: the query it answered beside
    /// the drain. Apart from `drained`, which the hero, the Journal, the Map and the Removed list
    /// read, so a filter never moves them.
    private var filteredDrains: [String: (query: TripMemberQuery, drain: Drained)] = [:]
    /// The filtered read on the wire, per trip: its query and the token that owns the slot. A read
    /// of another query takes the slot; the one it took lands nothing.
    private var filteredFlights: [String: FilteredFlight] = [:]
    /// The query the grid last chose for each trip, set in the turn that asks for it: what a
    /// renewal asked under an earlier choice is measured against (`renewFiltered`). An
    /// invalidation keeps it — the grid still shows that choice.
    private var activeQueries: [String: TripMemberQuery] = [:]
    /// The filtered read that failed, per trip: its query and lineage. Apart from "not read", so
    /// the grid does not take a failure for an invalidation and ask again by itself; a new read,
    /// an invalidation or another lineage ends it.
    private var filteredFailures: [String: (lineage: Lineage, query: TripMemberQuery)] = [:]
    /// How many times each scope has been left (`forget`): a filtered ask that awaited the drain
    /// holds the count it started under and goes no further once the scope was left meanwhile,
    /// because `activeQueries` outlives the forget and alone would let it read again (MEMNG-893).
    private var departures: [String: Int] = [:]

    private struct FilteredFlight {
        let lineage: Lineage
        let query: TripMemberQuery
        let token: Int
        let task: Task<Void, Never>
    }
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
    /// The row each of those exclusions took off a drain, kept with it: the one thing an add of
    /// the same picture back cannot read until a drain answers again.
    var excludedRows: [String: [String: LibraryRow]] = [:]
    /// The pictures this app put back into a trip and the server acknowledged, by trip and
    /// picture, each with its row and the token it was recorded under (`keptMembers`).
    var ownInclusions: [String: [String: (row: LibraryRow, token: Int)]] = [:]
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

    /// Follows the favorites ledger (MEMNG-867): a commit reaches every copy of its picture this
    /// store holds — members, filtered members, removed lists, renewed covers and journals — and
    /// every read is stamped with the ledger's revision when it starts, so one that started before
    /// a commit lands with the ledger's tags for that picture rather than its own. Pages pile up
    /// before they land, so the stamp is the run's START: a commit between two pages is newer
    /// than every row piled so far.
    public func follow(_ favorites: FavoriteStore) {
        self.favorites = favorites
        favorites.observe { [weak self] commit in self?.applyFavorite(commit) }
    }

    @ObservationIgnored private weak var favorites: FavoriteStore?

    var favoriteStamp: FavoriteStamp { favorites?.stamp ?? FavoriteStamp(revision: 0) }

    private func fenced(_ rows: [LibraryRow], _ issued: FavoriteStamp) -> [LibraryRow] {
        favorites?.overlay(rows, issuedAt: issued) ?? rows
    }

    func fenced(_ memos: [Memo], _ issued: FavoriteStamp) -> [Memo] {
        favorites?.overlay(memos, issuedAt: issued) ?? memos
    }

    private func applyFavorite(_ commit: FavoriteCommit) {
        func patched(_ rows: [LibraryRow]) -> [LibraryRow] {
            rows.map { row in
                guard row.id == commit.uid else { return row }
                var row = row
                row.attachment.tags = commit.tags
                return row
            }
        }
        for (uid, held) in drained where held.rows.contains(where: { $0.id == commit.uid }) {
            drained[uid]?.rows = patched(held.rows)
        }
        for (uid, held) in filteredDrains
        where held.drain.rows.contains(where: { $0.id == commit.uid }) {
            filteredDrains[uid]?.drain.rows = patched(held.drain.rows)
        }
        for (uid, held) in removedResults {
            guard case .exact(let rows) = held.state, rows.contains(where: { $0.id == commit.uid })
            else { continue }
            removedResults[uid]?.state = .exact(patched(rows))
        }
        renewedCovers[commit.uid]?.tags = commit.tags
        for (uid, journal) in journals
        where journal.memos.contains(where: { memo in
            memo.attachments.contains { $0.uid == commit.uid }
        }) {
            journals[uid]?.memos = journal.memos.map { memo in
                var memo = memo
                for position in memo.attachments.indices
                where memo.attachments[position].uid == commit.uid {
                    memo.attachments[position].tags = commit.tags
                }
                return memo
            }
        }
    }

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

    /// The members a screen keeps while no drain of the current lineage has landed: its last
    /// settled `rows` as `stillMembers` reads them, and each picture this app put back and the
    /// server acknowledged since, at its place in taken order. An add moves the revision, so the
    /// store holds no drain until the one after it answers; when that one fails, the rows the
    /// screen kept are the ones before the picture was put back. The carried row ends when a
    /// drain asked after the add lands, whatever it lists — the server's word then — or when
    /// the picture is taken out again or the identity changes. Never the store's own
    /// `members(for:)`: a drain that landed answered after every add the current revision holds.
    public func keptMembers(_ rows: [LibraryRow], of trip: Trip) -> [LibraryRow] {
        var kept = stillMembers(rows, of: trip)
        guard let carried = ownInclusions[trip.uid] else { return kept }
        let present = Set(kept.map(\.id))
        let added = carried.values.map(\.row)
            .filter { !present.contains($0.id) && !deleted.contains($0.id) }
            .sorted { left, right in
                (left.takenAt ?? .distantFuture, left.id)
                    < (right.takenAt ?? .distantFuture, right.id)
            }
        for row in added {
            let taken = row.takenAt ?? .distantFuture
            let at = kept.firstIndex { ($0.takenAt ?? .distantFuture) > taken } ?? kept.endIndex
            kept.insert(row, at: at)
        }
        return kept
    }

    /// The server's count, the drained rows' taken extrema, and the cover: the chosen one while it
    /// is a member, else a trip's oldest drained member and an album's newest (MEMNG-804) — of
    /// the rows drained, which a capped drain may have cut short. Nil before a drain has applied.
    public func summary(for trip: Trip) -> TripMemberSummary? {
        guard let held = held(trip.uid) else { return nil }
        let rows = members(for: trip)
        let dates = rows.compactMap(\.takenAt)
        let chosen = trip.cover.flatMap { cover in rows.first { $0.id == cover.id } }
        return TripMemberSummary(
            count: trip.memberCount,
            firstTaken: dates.min(),
            lastTaken: dates.max(),
            cover: chosen ?? (trip.kind == .album ? rows.last : rows.first),
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
            if let name = collection.pictureTagName { return .pictureTag(name) }
            guard let bucket = collection.bucket, let period = collection.period else { return nil }
            return .period(bucket: bucket, period)
        }
    }

    /// What a scope's drain reads, and so what its grid shows with nothing chosen (MEMNG-919): a
    /// month's and a year's own pictures — another member's are there only to fill out a trip —
    /// every other scope's everyone's. A month, a year, a tag and Favorites read Public pictures
    /// only (MEMNG-933): a Just us picture is seen inside its trip or album and nowhere else, so a
    /// trip and an album keep `unfiltered`. The filter menu starts on it, and a query equal to it
    /// sends no read of its own.
    public static func drainQuery(for scope: CollectionScope) -> TripMemberQuery {
        request(for: scope).map(drainQuery) ?? .unfiltered
    }

    private static func drainQuery(_ request: MemberRequest) -> TripMemberQuery {
        switch request {
        case .trip: return .unfiltered
        case .period: return .myOwnPublic
        case .tag, .pictureTag: return .everyonePublic
        }
    }

    /// An automatic collection's drain: `walkAutomatic` under its `drainQuery` — every kind,
    /// oldest taken first, a month's and a year's own pictures only — into the members the hero
    /// and the Map read. The Journal reads memos of its own (`loadJournal`).
    private func runAutomaticDrain(
        _ lineage: Lineage, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if flights[lineage.uid]?.token == token { flights[lineage.uid] = nil } }
        let owned = { self.stillCurrent(lineage) && self.flights[lineage.uid]?.token == token }
        let walked: AutomaticWalk?
        do {
            walked = try await walkAutomatic(
                lineage.request, query: Self.drainQuery(lineage.request), handle, baseURL,
                owned: owned)
        } catch {
            noteDrainFailure(error, lineage, token: token)
            await report(error, handle: handle, while: owned)
            return
        }
        guard let walked else { return }
        var landed = lineage
        landed.revision = trips.revision
        drained[lineage.uid] = Drained(
            lineage: landed, rows: fenced(walked.rows, walked.issued), complete: walked.complete)
        drainFailures[lineage.uid] = nil
        lastError = nil
    }

    /// What one walk of an automatic collection read: its rows, whether it reached the end, and
    /// the favorites ledger's revision it is fenced by.
    private struct AutomaticWalk {
        var rows: [LibraryRow]
        var complete: Bool
        var issued: FavoriteStamp
    }

    /// The walk over `GET /api/attachments` under `request`, with `query`'s kind, order, "Captured
    /// by me" and Visibility on the wire (MEMNG-827; the drain's is `drainQuery`). `bucket=` only
    /// says where the walk STARTS — the listing runs on past the period, and past an empty bucket
    /// into the next — so a period keeps a row only while it lies inside the period, in the
    /// direction the walk goes: before `nextStart` oldest first, at or after `start` newest first
    /// (under `taken_desc` the bucket opens at the period's newest). It asks for no page after the
    /// first row that does not.
    ///
    /// A picture tag's walk is fenced WHOLE by the favorites ledger (MEMNG-868): a favorite is
    /// membership here, not just a field of a row, and the keyset cursor means a later page never
    /// answers a row ordered before it — so a picture favorited behind the cursor would never be
    /// read, and one unfavorited among the rows already piled would stay. The walk stamps the
    /// ledger's revision at its start; when a page answers under a newer revision it lets go of
    /// every row and the cursor and walks again from the first page, under the new stamp — once
    /// per answered page however many commits landed while it was out. A walk whose stamp is still
    /// current when its last page answers lands as any other.
    ///
    /// Nil when `owned` no longer holds as a page answers: the slot or the lineage moved.
    private func walkAutomatic(
        _ request: MemberRequest, query: TripMemberQuery, _ handle: SessionHandle, _ baseURL: URL,
        owned: () -> Bool
    ) async throws -> AutomaticWalk? {
        var issued = favoriteStamp
        var tag: String?
        var pictureTag: String?
        var bucket: String?
        var period: CollectionPeriod?
        switch request {
        case .trip: return nil
        case .tag(let name): tag = name
        case .pictureTag(let name): pictureTag = name
        case .period(let key, let interval):
            bucket = key
            period = interval
        }
        var rows: [LibraryRow] = []
        var cursor: String?
        var complete = true
        var walking = true
        while walking {
            let page = try await MediaLibraryStore.page(
                handle.client, filter: query.filter, order: query.order, tag: tag,
                mine: query.mine, visibility: query.visibility, bucket: bucket,
                timeZone: period?.zone.identifier, pictureTag: pictureTag, cursor: cursor,
                limit: pageSize, baseURL: baseURL)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            guard owned() else {
                MemosLog.api.info("a collection's member page answered for a moved revision")
                return nil
            }
            if pictureTag != nil, favoriteStamp != issued {
                MemosLog.api.info("a favorite landed during a picture tag's walk; walk again")
                issued = favoriteStamp
                rows = []
                cursor = nil
                continue
            }
            var items = page.items
            var next = page.nextCursor
            // An undated row cannot be placed against the bound; the server dates every row
            // (`taken_at_expr` coalesces), so one would be a contract change, and it is kept.
            if let period,
                let past = items.firstIndex(where: { row in
                    row.takenAt.map { Self.isOutside($0, period, walking: query.order) } ?? false
                })
            {
                items = Array(items[..<past])
                next = nil
            }
            rows = MediaLibraryStore.merged(rows, with: items, filter: query.filter)
            cursor = next
            if rows.count >= memberCap, rows.count > memberCap || cursor != nil {
                complete = false
                rows = Array(rows.prefix(memberCap))
                break
            }
            walking = cursor != nil
        }
        return AutomaticWalk(rows: rows, complete: complete, issued: issued)
    }

    /// Whether a row taken at `taken` lies past `period`'s end in the direction the walk goes.
    private static func isOutside(
        _ taken: Date, _ period: CollectionPeriod, walking order: MediaLibraryOrder
    ) -> Bool {
        switch order {
        case .oldestFirst: taken >= period.nextStart
        case .newestFirst: taken < period.start
        }
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
        let issued = favoriteStamp
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
        drained[lineage.uid] = Drained(
            lineage: landed, rows: fenced(rows, issued), complete: complete)
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

    // MARK: - The grid's filter (MEMNG-780)

    /// Reads the trip's members as `query` asks — its kind as `type`, its order as `order` —
    /// into the filtered slot, page after page to the cap, as the drain does. The unfiltered
    /// query sends nothing: the grid then shows the drained members, and a filtered read still
    /// out is retired, so its answer lands nowhere. A read of the same lineage and query on the
    /// wire is joined; one of another query takes the slot, and the earlier one's pages are
    /// dropped on arrival.
    public func drainFiltered(
        _ trip: Trip, query: TripMemberQuery, using handle: SessionHandle, baseURL: URL
    ) async {
        activeQueries[trip.uid] = query
        guard !query.isUnfiltered else {
            filteredFlights[trip.uid] = nil
            return
        }
        let lineage = stamp(trip.uid, handle)
        if let running = filteredFlights[trip.uid], running.lineage == lineage,
            running.query == query
        {
            await running.task.value
            return
        }
        filteredFailures[trip.uid] = nil
        nextToken += 1
        let token = nextToken
        let task = Task { await self.runFiltered(lineage, query, token: token, handle, baseURL) }
        filteredFlights[trip.uid] = FilteredFlight(
            lineage: lineage, query: query, token: token, task: task)
        await task.value
    }

    /// A renewal of the filtered read for fresh signatures, asked under `query` (the signed-URL
    /// refresher's, after its unfiltered drain): read only while `query` is still the one the
    /// grid chose, checked in this turn, so a choice made while the drain was out is never
    /// overwritten by the one it replaced. Nothing for the unfiltered query.
    public func renewFiltered(
        _ trip: Trip, query: TripMemberQuery, using handle: SessionHandle, baseURL: URL
    ) async {
        guard !query.isUnfiltered, activeQueries[trip.uid] == query else { return }
        await drainFiltered(trip, query: query, using: handle, baseURL: baseURL)
    }

    /// Whether the grid's read of `query` failed under the current lineage and nothing has asked
    /// again since: then the grid shows the error, not a read that never ends.
    public func filteredFailed(for trip: Trip, query: TripMemberQuery) -> Bool {
        guard let failure = filteredFailures[trip.uid], failure.query == query else { return false }
        return current(failure.lineage)
    }

    /// What the grid shows for `query`: the drained members for the unfiltered one, else the
    /// filtered read of exactly that query and the current lineage, less what this app took out of
    /// the trip (`stillMembers`); nil while there is none.
    public func filteredMembers(for trip: Trip, query: TripMemberQuery) -> [LibraryRow]? {
        if query.isUnfiltered { return held(trip.uid) == nil ? nil : members(for: trip) }
        guard let held = filteredDrains[trip.uid], held.query == query, current(held.drain.lineage)
        else { return nil }
        return stillMembers(held.drain.rows, of: trip)
    }

    /// Where the grid's read for `query` stands; the drain's own state for the unfiltered one.
    public func filteredState(for trip: Trip, query: TripMemberQuery) -> TripMemberState {
        if query.isUnfiltered { return state(for: trip) }
        if let flight = filteredFlights[trip.uid], flight.query == query { return .draining }
        guard let held = filteredDrains[trip.uid], held.query == query, current(held.drain.lineage)
        else { return .notLoaded }
        return held.drain.complete ? .complete : .truncated
    }

    private func runFiltered(
        _ lineage: Lineage, _ query: TripMemberQuery, token: Int, _ handle: SessionHandle,
        _ baseURL: URL
    ) async {
        let uid = lineage.uid
        defer { if filteredFlights[uid]?.token == token { filteredFlights[uid] = nil } }
        let issued = favoriteStamp
        var rows: [LibraryRow] = []
        var cursor: String?
        var complete = true
        do {
            repeat {
                let page = try await Self.page(
                    handle.client, uid: uid, cursor: cursor, limit: pageSize, baseURL: baseURL,
                    query: query)
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                guard stillCurrent(lineage), filteredFlights[uid]?.token == token else {
                    MemosLog.api.info("a trip's filtered page answered for a moved slot")
                    return
                }
                rows = MediaLibraryStore.merged(rows, with: page.items, filter: query.filter)
                cursor = page.nextCursor
                if rows.count >= memberCap, rows.count > memberCap || cursor != nil {
                    complete = false
                    rows = Array(rows.prefix(memberCap))
                    break
                }
            } while cursor != nil
        } catch {
            if stillCurrent(lineage), filteredFlights[uid]?.token == token {
                filteredFailures[uid] = (lineage, query)
            }
            await report(error, handle: handle) {
                self.stillCurrent(lineage) && self.filteredFlights[uid]?.token == token
            }
            return
        }
        let landed = Lineage(revision: trips.revision, session: lineage.session, uid: uid)
        filteredDrains[uid] = (
            query, Drained(lineage: landed, rows: fenced(rows, issued), complete: complete)
        )
        lastError = nil
    }

    // MARK: - An automatic collection's filter (MEMNG-827)

    /// A scope's grid read as `query` asks: a trip's through `drainFiltered(_:query:using:baseURL:)`;
    /// a tag's, a month's, a year's or a picture tag's from the Library's listing under its own
    /// `tag=`, `bucket=` or `pictureTag=`, narrowed by the server with `query`'s kind, order,
    /// "Captured by me" and Visibility (`walkAutomatic`), into the filtered slot. The unfiltered
    /// query sends nothing and retires a read still out. A query that differs from the drain in
    /// its order alone is answered by the drain turned round once the drain has read every member,
    /// so the common newest-first showing costs no second walk; a drain the cap stopped short is no
    /// such answer — its newest rows were never read — and the server is asked. A read of the same
    /// lineage and query on the wire is joined; one of another query takes the slot.
    public func drainFiltered(
        _ scope: CollectionScope, query: TripMemberQuery, using handle: SessionHandle, baseURL: URL
    ) async {
        let key = scope.id
        switch scope {
        case .trip(let trip):
            await drainFiltered(trip, query: query, using: handle, baseURL: baseURL)
            return
        case .automatic: break
        }
        activeQueries[key] = query
        guard let request = Self.request(for: scope), query != Self.drainQuery(request) else {
            filteredFlights[key] = nil
            return
        }
        if query.isOrderOnly(over: Self.drainQuery(request)) {
            // The drain answers an order alone unless the cap stopped it: read it when nothing
            // is held — joining the screen's own drain when that is already on the wire — so a
            // first showing newest first walks the collection once, not twice.
            let departure = departures[key, default: 0]
            if held(key, request: request) == nil {
                await drain(scope, using: handle, baseURL: baseURL)
            }
            guard departures[key, default: 0] == departure, activeQueries[key] == query else {
                return
            }
            if drainAnswers(key, request) {
                filteredFlights[key] = nil
                return
            }
        }
        var lineage = stamp(key, handle)
        lineage.request = request
        if let running = filteredFlights[key], running.lineage == lineage, running.query == query {
            await running.task.value
            return
        }
        filteredFailures[key] = nil
        nextToken += 1
        let token = nextToken
        let task = Task {
            await self.runAutomaticFiltered(lineage, query, token: token, handle, baseURL)
        }
        filteredFlights[key] = FilteredFlight(
            lineage: lineage, query: query, token: token, task: task)
        await task.value
    }

    /// A lapsed signature's re-read of a scope's grid under `query`, for the showing `lease` was
    /// minted for: nothing unless the lease is still live and `query` is still the grid's choice,
    /// both asked in this turn.
    public func renewFiltered(
        _ scope: CollectionScope, under lease: CoverLease, query: TripMemberQuery,
        using handle: SessionHandle, baseURL: URL
    ) async {
        guard leaseIsLive(lease, for: scope), query != Self.drainQuery(for: scope),
            activeQueries[scope.id] == query
        else { return }
        await drainFiltered(scope, query: query, using: handle, baseURL: baseURL)
    }

    /// What a scope's grid shows for `query`: a trip's as `filteredMembers(for:query:)` says; an
    /// automatic collection's drained members for the unfiltered query, the drain turned round
    /// for an order alone while the drain is whole, else the filtered read of exactly that query
    /// and the current lineage — less every picture Delete took. Nil while there is none.
    public func filteredMembers(for scope: CollectionScope, query: TripMemberQuery) -> [LibraryRow]?
    {
        switch scope {
        case .trip(let trip): return filteredMembers(for: trip, query: query)
        case .automatic: break
        }
        guard let request = Self.request(for: scope) else { return nil }
        if query == Self.drainQuery(request) {
            return held(scope.id, request: request) == nil ? nil : members(for: scope)
        }
        if query.isOrderOnly(over: Self.drainQuery(request)), drainAnswers(scope.id, request) {
            return Array(members(for: scope).reversed())
        }
        guard let held = filteredDrains[scope.id], held.query == query,
            current(held.drain.lineage), held.drain.lineage.request == request
        else { return nil }
        guard !deleted.isEmpty else { return held.drain.rows }
        return held.drain.rows.filter { !deleted.contains($0.id) }
    }

    /// Where a scope's grid read for `query` stands; the drain's own state for the unfiltered one.
    public func filteredState(for scope: CollectionScope, query: TripMemberQuery) -> TripMemberState
    {
        switch scope {
        case .trip(let trip): return filteredState(for: trip, query: query)
        case .automatic: break
        }
        guard let request = Self.request(for: scope) else {
            return query.isUnfiltered ? state(for: scope) : .notLoaded
        }
        if query == Self.drainQuery(request) { return state(for: scope) }
        if query.isOrderOnly(over: Self.drainQuery(request)), drainAnswers(scope.id, request) {
            return .complete
        }
        if let flight = filteredFlights[scope.id], flight.query == query { return .draining }
        guard let held = filteredDrains[scope.id], held.query == query,
            current(held.drain.lineage), held.drain.lineage.request == request
        else { return .notLoaded }
        return held.drain.complete ? .complete : .truncated
    }

    /// Whether a scope's grid read of `query` failed under the current lineage and nothing has
    /// asked again since.
    public func filteredFailed(for scope: CollectionScope, query: TripMemberQuery) -> Bool {
        guard let failure = filteredFailures[scope.id], failure.query == query else { return false }
        return current(failure.lineage)
    }

    /// Whether the drain held for `key` read every member of `request`: then an order alone is
    /// answered by it.
    private func drainAnswers(_ key: String, _ request: MemberRequest) -> Bool {
        held(key, request: request)?.complete == true
    }

    private func runAutomaticFiltered(
        _ lineage: Lineage, _ query: TripMemberQuery, token: Int, _ handle: SessionHandle,
        _ baseURL: URL
    ) async {
        let key = lineage.uid
        defer { if filteredFlights[key]?.token == token { filteredFlights[key] = nil } }
        let owned = { self.stillCurrent(lineage) && self.filteredFlights[key]?.token == token }
        let walked: AutomaticWalk?
        do {
            walked = try await walkAutomatic(
                lineage.request, query: query, handle, baseURL, owned: owned)
        } catch {
            if owned() { filteredFailures[key] = (lineage, query) }
            await report(error, handle: handle, while: owned)
            return
        }
        guard let walked else { return }
        var landed = lineage
        landed.revision = trips.revision
        filteredDrains[key] = (
            query,
            Drained(
                lineage: landed, rows: fenced(walked.rows, walked.issued),
                complete: walked.complete)
        )
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
        // An album's removal is recorded as an exclusion is (MEMNG-804): the record is the app's
        // own knowledge of what left a collection, whichever route took it out.
        case .exclude, .removeMember:
            nextToken += 1
            ownExclusions[uid, default: [:]][picture] = nextToken
            endInclusion(of: picture, in: uid)
            let read = drained[uid]?.rows ?? filteredDrains[uid]?.drain.rows ?? []
            if let row = read.first(where: { $0.id == picture }) {
                excludedRows[uid, default: [:]][picture] = row
            }
        case .include:
            ownExclusions[uid]?[picture] = nil
            if ownExclusions[uid]?.isEmpty == true { ownExclusions[uid] = nil }
            // Put back, it is carried until a drain asked after this answers (`keptMembers`).
            guard let row = excludedRows[uid]?.removeValue(forKey: picture) else { return }
            if excludedRows[uid]?.isEmpty == true { excludedRows[uid] = nil }
            nextToken += 1
            ownInclusions[uid, default: [:]][picture] = (row, nextToken)
        }
    }

    private func endInclusion(of picture: String, in uid: String) {
        ownInclusions[uid]?[picture] = nil
        if ownInclusions[uid]?.isEmpty == true { ownInclusions[uid] = nil }
    }

    /// Ends the record of each picture a drain of `uid` asked for at `token` lists, when the
    /// record is older than the drain (`noteAcknowledged`). A put-back picture's carried row ends
    /// at a drain asked after it, listed or not: that drain answered after the add.
    private func contradict(uid: String, listed rows: [LibraryRow], askedAt token: Int) {
        if let carried = ownInclusions[uid] {
            let left = carried.filter { $0.value.token >= token }
            ownInclusions[uid] = left.isEmpty ? nil : left
        }
        guard var own = ownExclusions[uid] else { return }
        for row in rows where (own[row.id] ?? .max) < token {
            own[row.id] = nil
            excludedRows[uid]?[row.id] = nil
        }
        if excludedRows[uid]?.isEmpty == true { excludedRows[uid] = nil }
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
        let issued = favoriteStamp
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
        removedResults[uid] = (
            stamp(uid, handle), .exact(Self.oldestFirst(fenced(gone, issued)))
        )
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
            filteredDrains = [:]
            filteredFlights = [:]
            filteredFailures = [:]
            return
        }
        drained[uid] = nil
        drainFailures[uid] = nil
        flights[uid] = nil
        filteredDrains[uid] = nil
        filteredFlights[uid] = nil
        filteredFailures[uid] = nil
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
        departures[scope.id, default: 0] += 1
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
        let issued = favoriteStamp
        do {
            let fresh = try await Self.attachment(handle.client, uid: uid, baseURL: baseURL)
            guard ownsCover(uid, token), credentialCurrent(handle) else {
                MemosLog.api.info("a carried cover answered for a read that was let go; dropped")
                return
            }
            renewedCovers[uid] = favorites?.overlay(fresh, issuedAt: issued) ?? fresh
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
                downloadURL: URL(string: meta.downloadUrl, relativeTo: baseURL)?.absoluteURL,
                tags: meta.tags ?? []
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

    /// One page of the member route: every kind, oldest taken first — or, for the grid's filter,
    /// the query's kind and order (MEMNG-780). The default is the request this route always had.
    static func page(
        _ client: any APIProtocol, uid: String, cursor: String?, limit: Int, baseURL: URL,
        query: TripMemberQuery = .unfiltered
    ) async throws -> (items: [LibraryRow], nextCursor: String?) {
        // Members of the generated enums, as `MediaLibraryStore.page` writes its order: what the
        // generator calls those types is its own to decide. No kind is the parameter ABSENT.
        let input = Operations.ListMembersApiCollectionsUidAttachmentsGet.Input(
            path: .init(uid: uid),
            query: .init(
                _type: query.filter == .images ? .image : query.filter == .videos ? .video : nil,
                limit: limit, cursor: cursor,
                order: query.order == .newestFirst ? .takenDesc : .takenAsc,
                // Absent unless chosen, so the default is exactly the drain's request (MEMNG-787).
                mine: apiMine(query.mine), visibility: query.visibility.apiVisibility)
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

/// The trip grid's Kind and Sort (MEMNG-780), "Captured by me" and Visibility (MEMNG-787): the
/// Library's choices, read by the server through the member route's `type`, `order`, `mine` and
/// `visibility`. The default — every kind, oldest first, everyone's, any visibility — is the
/// drain itself, so it sends no read of its own. Every part of it is in the filtered read's
/// slot, failure record and renewal check, because they compare the whole value.
public struct TripMemberQuery: Sendable, Hashable {
    public var filter: MediaLibraryFilter
    public var order: MediaLibraryOrder
    public var mine: Bool
    public var visibility: MediaVisibilityFilter

    public init(
        filter: MediaLibraryFilter = .all, order: MediaLibraryOrder = .oldestFirst,
        mine: Bool = false, visibility: MediaVisibilityFilter = .any
    ) {
        self.filter = filter
        self.order = order
        self.mine = mine
        self.visibility = visibility
    }

    /// Every kind, oldest taken first, everyone's, any visibility: what the drain reads.
    public static let unfiltered = TripMemberQuery()

    public var isUnfiltered: Bool { self == .unfiltered }

    /// Every kind, oldest taken first, my own pictures of Public memos: what a month's and a
    /// year's drain reads (MEMNG-919, MEMNG-933).
    public static let myOwnPublic = TripMemberQuery(mine: true, visibility: .public)

    /// Every kind, oldest taken first, everyone's pictures of Public memos: what a tag's and
    /// Favorites' drain reads (MEMNG-933).
    public static let everyonePublic = TripMemberQuery(visibility: .public)

    /// Every kind, everyone's, any visibility, newest first: the drain's members in the other
    /// order, which a whole drain answers turned round (MEMNG-827).
    public var isOrderOnly: Bool { isOrderOnly(over: .unfiltered) }

    /// Whether this is `drain` in another order alone: the drain's members turned round.
    public func isOrderOnly(over drain: TripMemberQuery) -> Bool {
        var turned = drain
        turned.order = order
        return self != drain && turned == self
    }
}
