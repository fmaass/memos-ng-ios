import Foundation
import MemosAPI
import Observation

/// Where a trip's membership stands on this device.
public enum TripMembershipState: Sendable, Equatable {
    /// Nothing has been drained for the record yet.
    case notLoaded
    /// A drain is reading pages.
    case draining
    /// The server said there is nothing after the last page that was read.
    case complete
    /// The drain stopped at `TripMembershipStore.memberCap` with more still on the server: what
    /// the screens show is the FIRST that many pictures, and they say so.
    case truncated
}

/// The first and last taken date of one tag's pictures, as the New trip sheet shows them.
public struct TripTagSpan: Sendable, Equatable {
    public var firstTaken: Date?
    public var lastTaken: Date?

    public init(firstTaken: Date?, lastTaken: Date?) {
        self.firstTaken = firstTaken
        self.lastTaken = lastTaken
    }
}

/// The members of a trip: every picture and video of every memo carrying the record's tag, oldest
/// first,
/// minus the record's exclusions — and what they add up to.
///
/// **Membership is DRAINED, never derived.** `GET /api/attachments?tag=<t>&order=taken_asc&
/// limit=60` — no `type`: every kind of file, as the Library's All asks (MEMNG-740) — is read page
/// after page, following `X-Next-Cursor` until the server stops sending one, up to `memberCap`
/// files (beyond which the state is `truncated`). A count or an extremum cannot stand in for it:
/// exclusions are device-local, so only the list itself says which files are left and which of
/// them is first. The grid, the viewer, the map and the summary all read the SAME drained list, so
/// an excluded picture is absent from every one.
///
/// **One drain per record, joined.** A second `drain` for a record whose drain is already on the
/// wire — under the same session and the same tag — does not send anything: it JOINS the drain
/// in flight, awaiting the same task, and returns when that one has applied (or dropped) its
/// answer. Two appearances of a card in one turn are one request chain on the wire.
///
/// **Fenced by the generation that issued it.** A drain carries its `SessionHandle` and this
/// store's own generation from its first request to its last; after every page it asks whether
/// both are still the ones running, and a drain whose session ended, or that outlived
/// `sessionIdentityChanged`, is dropped whole — nothing of it is applied, no summary is written,
/// and it reads no further page. A drain applies its list once, at the end, so a half-read
/// membership is never on screen as if it were the trip.
///
/// **Owned by its slot.** Each drain holds a token of its own, the one its record's slot was
/// given when it started, and publishes only while the slot still holds that token: asked before
/// every page is used and before the list is written, and again before its cleanup, so a drain
/// never clears a slot a newer one holds. `forget` empties the slot and cancels the drain in it. A
/// drain asked after a forget never JOINS the forgotten one — there is nothing left to join — it
/// SUPERSEDES it: its own read, in its own slot, while whatever the forgotten one still brings
/// back is refused at its arrival.
///
/// **A refusal is one typed value.** The server refusing the credential arrives as
/// `CredentialRefusal` (`StoreFailure.refusal`) and goes to `onUnauthorized`, the session's one
/// decision rule; the funnel is `MediaLibraryStore.report`'s, in its order.
///
/// **A span is a second rule** (MEMNG-737). A record with a span (`CollectionRecord.span`) also
/// counts every file TAKEN in its window, whatever its memo's tags. There is no server filter for
/// a window, so the span is walked down from the newest file: `GET /api/attachments?order=
/// taken_desc&limit=60`, no tag and no type, page after page — a row taken after the end is
/// skipped, a row in the window is kept, and the walk stops at the first row taken before the
/// start. It costs one request per page of files newer than the start: cheap for the trip under
/// way, a long walk for an old one. The membership is the UNION of the two lanes, each file once
/// (by uid), oldest first, and the exclusions apply to both. A trip may have either rule or both;
/// one with neither sends nothing. The rule — tag AND span — is the drain's lineage: a drain of
/// the same rule joins, a drain of a changed rule supersedes, and a list read under a rule the
/// record no longer has is neither applied nor shown.
///
/// **The New trip sheet reads less.** For one tag without exclusions a count and two extrema are
/// enough, so the sheet never drains: `loadTagCounts` reads `GET /api/attachments/tags` (the
/// length of every kind's list under each tag, a tagged video counted as a member is) and
/// `loadSpan(ofTag:)` reads the first file of `taken_asc` and of `taken_desc`, `limit=1`, neither
/// with a `type`. Each is refused while the same read is already in flight, and fenced the same
/// way.
///
/// **The journal is the trip's memos, oldest first** (MEMNG-718): `GET /api/memos?tag=<t>&sort=
/// created_at` read page after page through the generated client, following the list's
/// `nextCursor`. Ascending is the server's own keyset (`sort` without a leading `-` compares
/// `created_at > cursor` and orders `created_at, id` ascending). A span adds the memos it places in
/// its window: `GET /api/memos?created_after=<start>&sort=created_at`, no tag, to the end of the
/// chain — a memo posted after the trip is still read — each memo kept when its journal instant
/// (`journalInstant(of:)`: its earliest picture's taken instant, its own date only without one)
/// lies in the window. The union is ordered by that instant, so a memo stands in the day its
/// pictures were taken, as the grid has them. A span memo whose every file the owner removed from
/// the trip leaves the journal with them; a memo of the tag keeps its place. It
/// lives beside the membership because it is the same trip's slot: a journal load JOINS one of the
/// same record already in flight under the same session and tag, is fenced by the same generation
/// and session, is dropped by the same `forget` and `sessionIdentityChanged`, publishes nothing for
/// a trip deleted while its pages were out, and stops at `memberCap` memos as `truncated`. Its
/// failures are said per trip in `journalError(for:)`, never in `lastError`, so a journal that
/// could not be read stands over neither the photos nor another trip's journal.
///
/// **A failure is said only by the read that still owns its slot.** Saying a refusal waits for the
/// session's decision; the slot (and the generation) are asked again AFTER that wait, immediately
/// before the sentence is written, so a read forgotten or outlived while the session decided
/// writes nothing — on either lane.
@MainActor
@Observable
public final class TripMembershipStore {
    /// How many rows one page of a drain asks for.
    public static let pageSize = 60
    /// How many members a drain gathers before it stops and says `truncated`.
    public static let memberCap = 2000

    /// What the last drain, or the sheet's last read, could not do — said the way
    /// `MediaLibraryStore` says it.
    public private(set) var lastError: String?
    /// The count of every tag, every kind of file, in the server's order, for the New trip sheet.
    public private(set) var tagCounts: [LibraryTag] = []
    /// Whether `tagCounts` is an answer, so the sheet can tell "no tag has a picture" from "not
    /// read yet".
    public private(set) var tagCountsLoaded = false
    /// The span of every tag the sheet has asked about, by tag.
    public private(set) var spans: [String: TripTagSpan] = [:]

    /// What a trip's membership is read by: its tag, its span, or both — never neither.
    private struct Rule: Equatable {
        var tag: String?
        var span: TripSpan?

        init?(_ record: CollectionRecord) {
            guard record.tags.first != nil || record.span != nil else { return nil }
            tag = record.tags.first
            span = record.span
        }
    }

    private struct Drained {
        var rule: Rule
        var rows: [LibraryRow]
        var truncated: Bool
    }

    /// What a drain in flight was issued under — what a second caller has to match to join it.
    private struct Lineage: Equatable {
        var generation: Int
        var session: Int
        var rule: Rule
    }

    private struct Journal {
        var rule: Rule
        var memos: [Memo]
        /// The memos the tag lane read, which keep their place whatever was removed.
        var tagged: Set<String>
        var truncated: Bool
    }

    /// Which of the two reads a failure belongs to, and so which sentence it writes.
    private enum Lane {
        case membership
        case journal(UUID)
    }

    private var drained: [UUID: Drained] = [:]
    /// The pictures a delete from a trip took (`delete`): absent from every trip's members, so
    /// a page read before the delete cannot put one back.
    private var removed: Set<String> = []
    private var inFlight: [UUID: (lineage: Lineage, token: Int, task: Task<Void, Never>)] = [:]
    private var journals: [UUID: Journal] = [:]
    /// What the last journal load of each trip could not do, by trip.
    private var journalErrors: [UUID: String] = [:]
    private var journalFlights: [UUID: (lineage: Lineage, token: Int, task: Task<Void, Never>)] =
        [:]
    /// The token the next drain's slot is given; never reused.
    private var nextToken = 0
    private var countsInFlight = false
    /// Each tag's span read in flight: the store generation and the credential it was issued
    /// under, and its token, so only that read's own end clears its slot.
    private var spansInFlight: [String: (generation: Int, credential: Int, token: Int)] = [:]
    /// The callers that joined a span read, by its token; let go when it ends or on a reset.
    @ObservationIgnored private var spanJoiners: [Int: [CheckedContinuation<Void, Never>]] = [:]
    /// Bumped by `sessionIdentityChanged`: everything read before it belongs to somebody else.
    private var generation = 0

    /// Called when a caller joins a drain already in flight, before it waits for it. A seam for
    /// tests only: it is how a test knows the second caller has reached the join.
    @ObservationIgnored var onJoin: (@MainActor () -> Void)?
    /// `onJoin`, for a journal load joining one in flight. A seam for tests only.
    @ObservationIgnored var onJournalJoin: (@MainActor () -> Void)?
    /// `onJoin`, for a span read joining one of the same tag in flight. A seam for tests only.
    @ObservationIgnored var onSpanJoin: (@MainActor () -> Void)?

    private let collections: CollectionStore
    private let pageSize: Int
    /// How many members this store gathers before a drain stops as `truncated`.
    public let memberCap: Int
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    /// - Parameters:
    ///   - collections: where a drained summary is written (`setSummary`), and where the record's
    ///     current exclusions and cover are read from when it is.
    ///   - pageSize: rows per page; the contract's cursor travels with the size it was minted at.
    ///   - memberCap: members gathered before the drain stops as `truncated`.
    public init(
        collections: CollectionStore,
        pageSize: Int = TripMembershipStore.pageSize,
        memberCap: Int = TripMembershipStore.memberCap,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.collections = collections
        self.pageSize = pageSize
        self.memberCap = memberCap
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    // MARK: - Membership

    /// Where the record's membership stands.
    public func state(for record: CollectionRecord) -> TripMembershipState {
        if inFlight[record.id] != nil { return .draining }
        guard let drained = drained(record) else { return .notLoaded }
        return drained.truncated ? .truncated : .complete
    }

    /// The record's members, oldest first: the drained list minus the record's exclusions. Empty
    /// until a drain for the record's tag has applied.
    public func members(for record: CollectionRecord) -> [LibraryRow] {
        guard let drained = drained(record) else { return [] }
        let excluded = Set(record.excludedUids)
        return drained.rows.filter { !excluded.contains($0.id) && !removed.contains($0.id) }
    }

    /// What the record's members add up to, or nil before a drain has applied.
    public func summary(for record: CollectionRecord) -> TripSummary? {
        guard drained(record) != nil else { return nil }
        return Self.summary(of: members(for: record), cover: record.coverUid)
    }

    /// The summary over a filtered membership: its count, its taken extrema, and its cover — the
    /// chosen one while it is still a member, else the first member.
    static func summary(of members: [LibraryRow], cover: String?) -> TripSummary {
        let dates = members.compactMap(\.takenAt)
        let chosen = cover.flatMap { uid in members.contains { $0.id == uid } ? uid : nil }
        return TripSummary(
            count: members.count,
            firstTaken: dates.min(),
            lastTaken: dates.max(),
            coverUid: chosen ?? members.first?.id
        )
    }

    /// Reads the record's whole membership and writes its summary to the record. Joins a drain of
    /// the same record already in flight under the same session and rule (see the type's doc).
    public func drain(_ record: CollectionRecord, using handle: SessionHandle, baseURL: URL) async {
        guard let rule = Rule(record) else { return }
        let lineage = Lineage(generation: generation, session: handle.generation, rule: rule)
        if let running = inFlight[record.id], running.lineage == lineage {
            onJoin?()
            await running.task.value
            return
        }
        let id = record.id
        nextToken += 1
        let token = nextToken
        let task = Task {
            await self.run(id, lineage: lineage, token: token, handle: handle, baseURL: baseURL)
        }
        inFlight[id] = (lineage, token, task)
        await task.value
    }

    private func run(
        _ id: UUID, lineage: Lineage, token: Int, handle: SessionHandle, baseURL: URL
    ) async {
        defer {
            if owns(id, token) { inFlight[id] = nil }
        }
        let gathered: (rows: [LibraryRow], truncated: Bool)?
        do {
            gathered = try await gather(id, lineage: lineage, token: token, handle, baseURL)
        } catch {
            guard lineage.generation == generation, owns(id, token) else {
                MemosLog.api.info("a trip's page failed for a list that has moved on")
                return
            }
            // A refusal still reaches the session whatever the rule; a sentence is said only for
            // the rule the trip still has, asked again after the session's decision.
            await report(error, issuedUnder: handle) {
                lineage.generation == self.generation && self.owns(id, token)
                    && self.isLive(id, lineage)
            }
            return
        }
        guard let gathered else {
            MemosLog.api.info("a trip's page answered for a list that has moved on")
            return
        }
        // The record as it is NOW, asked before anything is written: a trip deleted while its pages
        // were out publishes nothing, and an exclusion or a cover chosen meanwhile counts.
        guard owns(id, token), let record = collections.records.first(where: { $0.id == id }),
            Rule(record) == lineage.rule
        else {
            MemosLog.api.info("a trip's drain answered for a trip that is gone")
            return
        }
        drained[id] = Drained(
            rule: lineage.rule, rows: gathered.rows, truncated: gathered.truncated)
        lastError = nil
        session?.noteTransportSuccess(issuedUnder: handle.generation)
        guard let summary = summary(for: record), summary != record.lastSummary else { return }
        collections.setSummary(id: id, summary)
    }

    /// Both lanes of one drain, or nil once a page answered for a list that has moved on: the tag's
    /// files oldest first, then the span's walk newest first, as one list oldest first with each
    /// file once, cut at the cap.
    private func gather(
        _ id: UUID, lineage: Lineage, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async throws -> (rows: [LibraryRow], truncated: Bool)? {
        var rows: [LibraryRow] = []
        if let tag = lineage.rule.tag {
            var cursor: String?
            repeat {
                let page = try await MediaLibraryStore.page(
                    handle.client, filter: .all, order: .oldestFirst, tag: tag, cursor: cursor,
                    limit: pageSize, baseURL: baseURL)
                guard stillCurrent(lineage, handle), owns(id, token), isLive(id, lineage) else {
                    return nil
                }
                rows = MediaLibraryStore.merged(rows, with: page.items, filter: .all)
                cursor = page.nextCursor
                if rows.count >= memberCap {
                    let more = rows.count > memberCap || cursor != nil
                    // Exactly the cap, read through: the span may still add a member past it.
                    if more || lineage.rule.span == nil {
                        return (Array(rows.prefix(memberCap)), more)
                    }
                }
            } while cursor != nil
        }
        guard let span = lineage.rule.span else { return (rows, false) }
        var window: [LibraryRow] = []
        var cursor: String?
        var more = false
        repeat {
            let page = try await MediaLibraryStore.page(
                handle.client, filter: .all, order: .newestFirst, tag: nil, cursor: cursor,
                limit: pageSize, baseURL: baseURL)
            guard stillCurrent(lineage, handle), owns(id, token), isLive(id, lineage) else {
                return nil
            }
            // Newest first: everything from the first row taken before the start on is older still.
            let before = page.items.firstIndex { $0.takenAt.map { $0 < span.start } ?? false }
            let read = page.items[..<(before ?? page.items.endIndex)]
            let inside = read.filter { $0.takenAt.map(span.contains) ?? false }
            window = MediaLibraryStore.merged(window, with: Array(inside), filter: .all)
            cursor = page.nextCursor
            more = before == nil && cursor != nil
        } while more && Set(rows.map(\.id)).union(window.map(\.id)).count < memberCap
        let union = Self.oldestFirst(MediaLibraryStore.merged(rows, with: window, filter: .all))
        let truncated = union.count > memberCap || (more && union.count >= memberCap)
        return (Array(union.prefix(memberCap)), truncated)
    }

    /// Oldest taken first; a row without a taken date last; rows taken at the same instant in the
    /// order they were gathered.
    private static func oldestFirst(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.enumerated().sorted { lhs, rhs in
            let left = lhs.element.takenAt ?? .distantFuture
            let right = rhs.element.takenAt ?? .distantFuture
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Only for a trip the collection store still holds, under the rule it was read for: a
    /// snapshot of a deleted one, which its screen keeps drawing on the way out, reads nothing, and
    /// a trip whose span or tag changed reads nothing until it is drained again.
    private func drained(_ record: CollectionRecord) -> Drained? {
        guard let drained = drained[record.id], drained.rule == Rule(record),
            collections.records.contains(where: { $0.id == record.id })
        else { return nil }
        return drained
    }

    /// Whether the trip a drain is reading is still there, under the rule the drain reads.
    private func isLive(_ id: UUID, _ lineage: Lineage) -> Bool {
        collections.records.first { $0.id == id }.flatMap(Rule.init) == lineage.rule
    }

    /// Drops what this store holds for a trip that was deleted, and lets go of its drain: what that
    /// drain still brings back is refused at its arrival (`run`), and nothing it read is kept.
    public func forget(_ id: UUID) {
        drained[id] = nil
        inFlight.removeValue(forKey: id)?.task.cancel()
        journals[id] = nil
        journalErrors[id] = nil
        journalFlights.removeValue(forKey: id)?.task.cancel()
    }

    /// Whether the record's slot still holds the drain that was given `token`.
    private func owns(_ id: UUID, _ token: Int) -> Bool {
        inFlight[id]?.token == token
    }

    // MARK: - Select mode's Delete (MEMNG-721)

    /// A delete run is out: the Trip screen's toolbar takes no second tap meanwhile.
    public private(set) var isDeleting = false

    /// Deletes the chosen pictures — the member's own only, as the Library's select mode chooses
    /// them (`LibrarySelection.deletable`) — through the Library's own run
    /// (`MediaLibraryStore.deleteRun`): one `DELETE /api/attachments/{uid}` at a time, in the
    /// order chosen, stopping at the first failure.
    ///
    /// * Serialised by REFUSAL, as the Library's is: a second call while a run is out sends
    ///   nothing and returns nil.
    /// * Fenced by the session that issued it AND this store's identity generation: once either
    ///   moved, nothing further is sent and nothing the run learned is applied.
    /// * A failure goes through this store's funnel and writes no sentence over the photos: the
    ///   screen's toast says what the run did.
    /// * What went leaves every trip at once (`removed`, read by `members(for:)`), so a drain that
    ///   read its page before the delete cannot bring it back, and each trip whose members it
    ///   changed has its summary written again.
    ///
    /// - Returns: what the run did, or nil when it was refused.
    public func delete(
        _ uids: [String],
        using handle: SessionHandle
    ) async -> LibraryDeleteOutcome? {
        guard !isDeleting else {
            MemosLog.api.info("a trip delete asked for while another is running is refused")
            return nil
        }
        isDeleting = true
        defer { isDeleting = false }
        let issued = generation
        let outcome = await MediaLibraryStore.deleteRun(
            uids,
            using: handle,
            stillCurrent: { issued == generation && sessionStillCurrent(handle) },
            succeeded: { session?.noteTransportSuccess(issuedUnder: handle.generation) },
            failed: { await report($0, issuedUnder: handle, while: { false }) }
        )
        guard !outcome.stoppedForSessionChange else { return outcome }
        forget(pictures: outcome.deleted)
        return outcome
    }

    /// The deleted pictures leave every trip, and stay gone; each live trip they left has its
    /// summary written again.
    private func forget(pictures uids: [String]) {
        guard !uids.isEmpty else { return }
        let gone = Set(uids)
        removed.formUnion(gone)
        for record in collections.records {
            guard let held = drained(record), held.rows.contains(where: { gone.contains($0.id) }),
                let summary = summary(for: record), summary != record.lastSummary
            else { continue }
            collections.setSummary(id: record.id, summary)
        }
    }

    // MARK: - Select mode's Remove from trip (MEMNG-722)

    /// Removes the chosen pictures from trip `id` ON THIS DEVICE: each one that is still a member
    /// joins the record's exclusions, and the record's summary is computed over what is left and
    /// written in the SAME write (`CollectionStore.setExclusions`), so the root's card counts what
    /// the trip screen shows without waiting for another drain, and a write that fails leaves both
    /// as they were. Nothing is sent: the memo keeps its text and its tag, and the picture stays in
    /// the Library and in every other trip of that tag.
    ///
    /// Synchronous on the main actor, with no suspension anywhere, so two removals in one turn
    /// run one after the other, the second finding the first's pictures no longer members. A
    /// picture that is not a member — already removed, deleted, or never drained — is skipped,
    /// so a removal of nothing writes nothing. The chosen cover is left as it is: while it is
    /// removed the summary falls back to the first member, and Add Back makes it the cover again.
    public func remove(_ uids: [String], from id: UUID) {
        guard let record = collections.records.first(where: { $0.id == id }) else { return }
        let held = Set(members(for: record).map(\.id))
        var next = record.excludedUids
        for uid in uids where held.contains(uid) && !next.contains(uid) { next.append(uid) }
        exclude(next, from: record)
    }

    /// Gives a removed picture back to trip `id`, its summary in the same write.
    public func addBack(_ uid: String, to id: UUID) {
        guard let record = collections.records.first(where: { $0.id == id }) else { return }
        exclude(record.excludedUids.filter { $0 != uid }, from: record)
    }

    /// The record's removed pictures that its drained list still holds, oldest first as the drain
    /// read them — what Show Removed lists. Empty before a drain has applied. An exclusion the
    /// drain holds no row for (the picture deleted, or its memo no longer carrying the tag) is not
    /// listed and stays in the record, so a picture tagged again stays out of this trip.
    public func removedMembers(for record: CollectionRecord) -> [LibraryRow] {
        guard let drained = drained(record) else { return [] }
        let excluded = Set(record.excludedUids)
        return drained.rows.filter { excluded.contains($0.id) && !removed.contains($0.id) }
    }

    /// One write: the record's exclusions become `next`, beside the summary they leave when the
    /// trip has been drained. Nothing is written when the exclusions do not move.
    private func exclude(_ next: [String], from record: CollectionRecord) {
        guard next != record.excludedUids else { return }
        var changed = record
        changed.excludedUids = next
        collections.setExclusions(id: record.id, next, summary: summary(for: changed))
    }

    // MARK: - The journal

    /// What the record's last journal load could not do — said the way `lastError` is, for this
    /// trip alone.
    public func journalError(for record: CollectionRecord) -> String? {
        journalErrors[record.id]
    }

    /// Where the record's journal stands, in the membership's terms.
    public func journalState(for record: CollectionRecord) -> TripMembershipState {
        if journalFlights[record.id] != nil { return .draining }
        guard let journal = journal(record) else { return .notLoaded }
        return journal.truncated ? .truncated : .complete
    }

    /// The memos of the record's tag and of its span, oldest first by their journal instant
    /// (`journalInstant(of:)`), less a span memo whose every file the record excludes. Empty
    /// until a journal load under the record's rule has applied, and for a trip the store no
    /// longer holds.
    public func journal(for record: CollectionRecord) -> [Memo] {
        guard let journal = journal(record) else { return [] }
        guard let span = journal.rule.span else { return journal.memos }
        let excluded = Set(record.excludedUids)
        // A span memo stays while one of its files is a member now: taken in the window (its memo's
        // date standing in for an undated one), not removed from the trip and not deleted.
        return journal.memos.filter { memo in
            journal.tagged.contains(memo.uid) || memo.attachments.isEmpty
                || memo.attachments.contains { file in
                    !excluded.contains(file.uid) && !removed.contains(file.uid)
                        && span.contains(file.captureInstant ?? memo.createdAt)
                }
        }
    }

    /// The instant a memo stands at in a trip's journal: the earliest taken instant among its
    /// files, or its own date when none of them is dated — so a memo posted after the trip stands
    /// in the day its pictures were taken.
    public static func journalInstant(of memo: Memo) -> Date {
        memo.attachments.compactMap(\.captureInstant).min() ?? memo.createdAt
    }

    /// Reads the record's whole journal. Joins a load of the same record already in flight under
    /// the same session and rule (see the type's doc); a record with neither tag nor span sends
    /// nothing.
    public func loadJournal(
        _ record: CollectionRecord, using handle: SessionHandle, baseURL: URL
    ) async {
        guard let rule = Rule(record) else { return }
        let lineage = Lineage(generation: generation, session: handle.generation, rule: rule)
        if let running = journalFlights[record.id], running.lineage == lineage {
            onJournalJoin?()
            await running.task.value
            return
        }
        let id = record.id
        nextToken += 1
        let token = nextToken
        let task = Task {
            await self.runJournal(
                id, lineage: lineage, token: token, handle: handle, baseURL: baseURL)
        }
        journalFlights[id] = (lineage, token, task)
        await task.value
    }

    private func runJournal(
        _ id: UUID, lineage: Lineage, token: Int, handle: SessionHandle, baseURL: URL
    ) async {
        defer {
            if ownsJournal(id, token) { journalFlights[id] = nil }
        }
        var memos: [Memo] = []
        var tagged: Set<String> = []
        var truncated = false
        do {
            // The tag's memos, then the span's: `.newer` is the query read oldest first,
            // `sort=created_at` (`MemoQuery.parameters(in:direction:after:)`) — with no bound for
            // the tag, and from just before the span's start for the span (`created_after` is
            // strict). A memo the tag lane read is not added twice.
            var lanes: [(query: MemoQuery, span: TripSpan?)] = []
            if let tag = lineage.rule.tag { lanes.append((MemoQuery(tags: [tag]), nil)) }
            if let span = lineage.rule.span { lanes.append((MemoQuery(), span)) }
            var known: Set<String> = []
            lanes: for (query, span) in lanes {
                let after = span.map { $0.start.addingTimeInterval(-1) }
                var cursor: String?
                repeat {
                    let page = try await TimelineStore.page(
                        handle.client, query: query, calendar: .current, direction: .newer,
                        after: after, cursor: cursor, limit: pageSize, baseURL: baseURL)
                    guard stillCurrent(lineage, handle), ownsJournal(id, token),
                        isLive(id, lineage)
                    else {
                        MemosLog.api.info(
                            "a trip's journal page answered for a list that has moved on")
                        return
                    }
                    for memo in page.memos where !known.contains(memo.uid) {
                        if let span, !span.contains(Self.journalInstant(of: memo)) { continue }
                        known.insert(memo.uid)
                        memos.append(memo)
                        if span == nil { tagged.insert(memo.uid) }
                    }
                    cursor = page.nextCursor
                    if memos.count >= memberCap {
                        truncated = memos.count > memberCap || cursor != nil
                        memos = Array(memos.prefix(memberCap))
                        // Exactly the cap, read through: the next lane may still add a memo.
                        if truncated { break lanes }
                    }
                } while cursor != nil
            }
        } catch {
            guard lineage.generation == generation, ownsJournal(id, token) else {
                MemosLog.api.info("a trip's journal page failed for a list that has moved on")
                return
            }
            await report(error, issuedUnder: handle, lane: .journal(id)) {
                lineage.generation == self.generation && self.ownsJournal(id, token)
                    && self.isLive(id, lineage)
            }
            return
        }
        guard ownsJournal(id, token), isLive(id, lineage) else {
            MemosLog.api.info("a trip's journal answered for a trip that is gone")
            return
        }
        journals[id] = Journal(
            rule: lineage.rule, memos: Self.byJournalInstant(memos), tagged: tagged,
            truncated: truncated)
        journalErrors[id] = nil
        session?.noteTransportSuccess(issuedUnder: handle.generation)
    }

    /// The memos ordered by their journal instant; those at the same instant as they were read.
    private static func byJournalInstant(_ memos: [Memo]) -> [Memo] {
        memos.enumerated().sorted { lhs, rhs in
            let left = journalInstant(of: lhs.element)
            let right = journalInstant(of: rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Only for a trip the collection store still holds, under the rule it was read for.
    private func journal(_ record: CollectionRecord) -> Journal? {
        guard let journal = journals[record.id], journal.rule == Rule(record),
            collections.records.contains(where: { $0.id == record.id })
        else { return nil }
        return journal
    }

    /// Whether the record's journal slot still holds the load that was given `token`.
    private func ownsJournal(_ id: UUID, _ token: Int) -> Bool {
        journalFlights[id]?.token == token
    }

    // MARK: - The New trip sheet

    /// Reads every tag's count, videos included. Refused, not sent, while the same read is in
    /// flight.
    public func loadTagCounts(using handle: SessionHandle) async {
        guard !countsInFlight else { return }
        countsInFlight = true
        let issued = generation
        defer { if issued == generation { countsInFlight = false } }
        do {
            let rows = try await LibraryTagStore.tags(handle.client, filter: .all)
            guard issued == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a trip sheet's tag counts answered for a session that moved on")
                return
            }
            tagCounts = rows
            tagCountsLoaded = true
            lastError = nil
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            await report(error, issuedUnder: handle)
        }
    }

    /// Reads one tag's first and last taken date among its files. A second read of the same tag,
    /// under the same store generation and the same credential, while one is in flight joins it:
    /// nothing is sent, and it returns when that read ends, so a caller that waits on its return
    /// waits on the read itself. A read issued under another credential or generation is never
    /// joined — its answer is dropped — so the caller sends its own and takes the slot; the old
    /// read's end then lets its own joiners go and leaves the new slot alone. A caller whose
    /// credential is no longer the session's sends nothing: its answer would be dropped too.
    public func loadSpan(ofTag tag: String, using handle: SessionHandle, baseURL: URL) async {
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a trip sheet's span was asked for under a session that moved on")
            return
        }
        if let flight = spansInFlight[tag], flight.generation == generation,
            flight.credential == handle.generation
        {
            onSpanJoin?()
            await withCheckedContinuation { spanJoiners[flight.token, default: []].append($0) }
            return
        }
        nextToken += 1
        let token = nextToken
        spansInFlight[tag] = (generation, handle.generation, token)
        let issued = generation
        defer {
            if spansInFlight[tag]?.token == token { spansInFlight[tag] = nil }
            for joiner in spanJoiners.removeValue(forKey: token) ?? [] { joiner.resume() }
        }
        do {
            let first = try await extremum(.oldestFirst, tag: tag, handle, baseURL)
            guard issued == generation, sessionStillCurrent(handle) else { return }
            let last = try await extremum(.newestFirst, tag: tag, handle, baseURL)
            guard issued == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a trip sheet's span answered for a session that moved on")
                return
            }
            spans[tag] = TripTagSpan(firstTaken: first, lastTaken: last)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            await report(error, issuedUnder: handle)
        }
    }

    private func extremum(
        _ order: MediaLibraryOrder,
        tag: String,
        _ handle: SessionHandle,
        _ baseURL: URL
    ) async throws -> Date? {
        let page = try await MediaLibraryStore.page(
            handle.client,
            filter: .all,
            order: order,
            tag: tag,
            cursor: nil,
            limit: 1,
            baseURL: baseURL
        )
        return page.items.first?.takenAt
    }

    // MARK: - Session

    /// Forgets every membership, count and span because this device is signed in as somebody
    /// else; whatever is in flight was asked for by them, and drops on arrival.
    public func sessionIdentityChanged() {
        drained = [:]
        inFlight = [:]
        tagCounts = []
        tagCountsLoaded = false
        spans = [:]
        countsInFlight = false
        spansInFlight = [:]
        let joiners = spanJoiners.values.joined()
        spanJoiners = [:]
        for joiner in joiners { joiner.resume() }
        lastError = nil
        journals = [:]
        journalFlights = [:]
        journalErrors = [:]
        removed = []
        generation += 1
    }

    private func stillCurrent(_ lineage: Lineage, _ handle: SessionHandle) -> Bool {
        lineage.generation == generation && sessionStillCurrent(handle)
    }

    /// The same funnel, in the same order, as `MediaLibraryStore.report`.
    /// `lane` says which sentence the failure writes: the membership's or a trip's journal's.
    /// `owned` is asked synchronously immediately before each write — after the session's decision
    /// on a refusal, with nothing awaited in between — so a read forgotten while it waited says
    /// nothing.
    private func report(
        _ error: any Error, issuedUnder handle: SessionHandle, lane: Lane = .membership,
        while owned: () -> Bool = { true }
    ) async {
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        if let failure = StoreFailure.transportFailure(error) {
            if owned() { say(nil, on: lane) }
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle),
                owned()
            {
                say(refusal.errorDescription, on: lane)
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        if owned() { say(apiError.errorDescription, on: lane) }
    }

    private func say(_ sentence: String?, on lane: Lane) {
        switch lane {
        case .membership: lastError = sentence
        case .journal(let id): journalErrors[id] = sentence
        }
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
}
