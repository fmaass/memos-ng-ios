import Foundation
import MemosAPI

/// What a trip's journal is read by: its tag, and its span beside it. A trip without a tag has no
/// journal (decision 9 of the server-trips plan): its chip says so and nothing is sent.
struct TripJournalRule: Equatable {
    var tag: String
    var span: TripSpan?

    init?(_ trip: Trip) {
        guard let tag = trip.tag else { return nil }
        self.tag = tag
        span = trip.tripSpan
    }
}

/// What a collection's journal is read by (MEMNG-817, decision 3): a trip's tag and span; a tag
/// collection's tag lane alone; a month's or a year's creation interval in its bucket's zone,
/// with no picture date consulted — a memo posted in March about February is March's.
enum CollectionJournalRule: Equatable {
    case trip(TripJournalRule)
    case tag(String)
    case period(CollectionPeriod)

    /// Nil for a trip without a tag, and for a month or year key naming no period.
    init?(_ scope: CollectionScope) {
        switch scope {
        case .trip(let trip):
            guard let rule = TripJournalRule(trip) else { return nil }
            self = .trip(rule)
        case .automatic(let collection):
            if case .tag(let name) = collection.kind {
                self = .tag(name)
                return
            }
            guard let period = collection.period else { return nil }
            self = .period(period)
        }
    }
}

/// What a journal load in flight was issued under — what a second caller has to match to join it.
///
/// A load is fenced by this store's identity generation, the credential and the trip's rule (its
/// tag and span), not by the trip store's revision. The rule is asked again of the trip the trip
/// store holds when the answer lands (`isLive`) and whenever the journal is read (`journal(of:)`),
/// so a changed tag or span, or a deleted trip, hides it. A picture the app removed from the trip
/// (`ownExclusions`) or deleted is taken out when the journal is read (`journal(for:)`), never
/// when it lands, so neither a load that was out meanwhile nor a list or pin that dropped the
/// member drain brings it back.
struct TripJournalLineage: Equatable {
    var generation: Int
    var session: Int
    var rule: CollectionJournalRule
}

struct TripJournal {
    var rule: CollectionJournalRule
    var memos: [Memo]
    /// The memos the tag lane read, which keep their place whatever left the trip.
    var tagged: Set<String>
    var truncated: Bool
}

typealias TripJournalFlight = (lineage: TripJournalLineage, token: Int, task: Task<Void, Never>)

extension TripMemberStore {
    /// What the journal chip says for a trip without a tag; no journal is read for it.
    public static let noTagJournal = "This trip has no tag"

    /// Which of the reads a failure belongs to, and so which sentence it writes.
    enum Lane {
        case members
        case journal(String)
        /// Select's Delete: the toast says what the run did, so no sentence is written.
        case silent
    }

    // MARK: - The journal

    /// What the trip's last journal load could not do — said the way `lastError` is, for this
    /// trip alone.
    public func journalError(for trip: Trip) -> String? {
        journalErrors[trip.uid]
    }

    /// Where the trip's journal stands, in the members' terms.
    public func journalState(for trip: Trip) -> TripMemberState {
        if journalFlights[trip.uid] != nil { return .draining }
        guard let journal = journal(of: trip) else { return .notLoaded }
        return journal.truncated ? .truncated : .complete
    }

    /// The memos of the trip's tag and of its span, oldest first by their journal instant
    /// (`journalInstant(of:)`), less a span memo none of whose files is a member now, and every
    /// memo less the files Delete took. Empty until a journal load under the trip's rule has
    /// applied, for a trip the trip store no longer holds, and for a trip without a tag.
    public func journal(for trip: Trip) -> [Memo] {
        guard let journal = journal(of: trip) else { return [] }
        return withoutDeleted(kept(journal, of: trip))
    }

    /// A deleted file leaves every memo the journal hands out, whatever kept the memo — its tag,
    /// another file, no file at all — and whenever its page was read (MEMNG-794). Asked of the
    /// memos `kept(_:of:)` chose by their files as read, so a span memo of nothing but deleted
    /// pictures has already gone rather than staying as a memo without one.
    private func withoutDeleted(_ memos: [Memo]) -> [Memo] {
        guard !deleted.isEmpty else { return memos }
        return memos.map { memo in
            var memo = memo
            memo.attachments.removeAll { deleted.contains($0.uid) }
            return memo
        }
    }

    /// The journal's memos that are in the trip now, their files as read.
    private func kept(_ journal: TripJournal, of trip: Trip) -> [Memo] {
        guard case .trip(let rule) = journal.rule, let span = rule.span else {
            return journal.memos
        }
        // The server's members say which files are in the trip once a drain has read them all;
        // before that the window is the only rule this device knows.
        let members: Set<String>? =
            state(for: trip) == .complete ? Set(members(for: trip).map(\.id)) : nil
        // What this app removed from the trip stays out whether or not a drain is held
        // (`noteAcknowledged` says when the server's word overrides it).
        let removed = ownExclusions[trip.uid] ?? [:]
        // A span memo stays while one of its files is a member now: taken in the window (its memo's
        // date standing in for an undated one), not deleted, not removed by this app, and listed by
        // the server when the members are known.
        return journal.memos.filter { memo in
            journal.tagged.contains(memo.uid) || memo.attachments.isEmpty
                || memo.attachments.contains { file in
                    !deleted.contains(file.uid) && removed[file.uid] == nil
                        && span.contains(file.captureInstant ?? memo.createdAt)
                        && (members?.contains(file.uid) ?? true)
                }
        }
    }

    /// The instant a memo stands at in a trip's journal: the earliest taken instant among its
    /// files, or its own date when none of them is dated — so a memo posted after the trip stands
    /// in the day its pictures were taken.
    public static func journalInstant(of memo: Memo) -> Date {
        memo.attachments.compactMap(\.captureInstant).min() ?? memo.createdAt
    }

    // MARK: - The journal by scope (MEMNG-817)

    /// A scope's journal: a trip's as `journal(for:)` reads it; an automatic collection's every
    /// memo its rule read, oldest first by journal instant, less the files Delete took. Empty until
    /// a load under the scope's own rule — its zone and bounds included — has applied.
    ///
    /// A month's and a year's are my own memos while `mine` holds (MEMNG-919: another member's
    /// are there only to fill out a trip); `mine` is the screen's "Captured by me", nil for the
    /// scope's own start (`drainQuery`). The read itself is everyone's, so unchecking widens it
    /// with no second read. A trip's and a tag's journal take no such choice.
    public func journal(for scope: CollectionScope, mine: Bool? = nil) -> [Memo] {
        if case .trip(let trip) = scope { return journal(for: trip) }
        guard let journal = automaticJournal(scope) else { return [] }
        let memos = withoutDeleted(journal.memos)
        guard case .automatic(let collection) = scope, collection.bucket != nil,
            mine ?? Self.drainQuery(for: scope).mine
        else { return memos }
        return memos.filter(\.mine)
    }

    public func journalState(for scope: CollectionScope) -> TripMemberState {
        if case .trip(let trip) = scope { return journalState(for: trip) }
        if journalFlights[scope.id] != nil { return .draining }
        guard let journal = automaticJournal(scope) else { return .notLoaded }
        return journal.truncated ? .truncated : .complete
    }

    public func journalError(for scope: CollectionScope) -> String? {
        journalErrors[scope.id]
    }

    /// Reads a scope's whole journal; joins a load of the same key, session and rule in flight.
    public func loadJournal(_ scope: CollectionScope, using handle: SessionHandle, baseURL: URL)
        async
    {
        if case .trip(let trip) = scope {
            await loadJournal(trip, using: handle, baseURL: baseURL)
            return
        }
        guard let rule = CollectionJournalRule(scope) else { return }
        await loadJournal(scope.id, rule: rule, using: handle, baseURL: baseURL)
    }

    /// What applied for an automatic scope under the rule it has now.
    private func automaticJournal(_ scope: CollectionScope) -> TripJournal? {
        guard let rule = CollectionJournalRule(scope), let journal = journals[scope.id],
            journal.rule == rule
        else { return nil }
        return journal
    }

    /// Reads the trip's whole journal. Joins a load of the same trip already in flight under the
    /// same session and rule; a trip without a tag sends nothing.
    public func loadJournal(_ trip: Trip, using handle: SessionHandle, baseURL: URL) async {
        guard let rule = TripJournalRule(trip) else { return }
        await loadJournal(trip.uid, rule: .trip(rule), using: handle, baseURL: baseURL)
    }

    /// The load under `uid`, the key a scope's journal is held by.
    private func loadJournal(
        _ uid: String, rule: CollectionJournalRule, using handle: SessionHandle, baseURL: URL
    ) async {
        let lineage = TripJournalLineage(
            generation: generation, session: handle.generation, rule: rule)
        if let running = journalFlights[uid], running.lineage == lineage {
            onJournalJoin?()
            await running.task.value
            return
        }
        journalToken += 1
        let token = journalToken
        let task = Task {
            await self.runJournal(
                uid, lineage: lineage, token: token, handle: handle, baseURL: baseURL)
        }
        journalFlights[uid] = (lineage, token, task)
        await task.value
    }

    private func runJournal(
        _ uid: String, lineage: TripJournalLineage, token: Int, handle: SessionHandle,
        baseURL: URL
    ) async {
        defer {
            if ownsJournal(uid, token) { journalFlights[uid] = nil }
        }
        let issued = favoriteStamp
        var memos: [Memo] = []
        var tagged: Set<String> = []
        var truncated = false
        do {
            // The tag's memos, then the span's: `.newer` is the query read oldest first,
            // `sort=created_at` (`MemoQuery.parameters(in:direction:after:)`) — with no bound for
            // the tag, and from just before the span's start for the span (`created_after` is
            // strict). A memo the tag lane read is not added twice.
            // A period's lane asks from a second before its start up to its exclusive end on
            // every page, and cuts both again by `createdAt` as it reads.
            var lanes: [(query: MemoQuery, span: TripSpan?, period: CollectionPeriod?)]
            switch lineage.rule {
            case .trip(let rule):
                lanes = [(MemoQuery(tags: [rule.tag]), nil, nil)]
                if let span = rule.span { lanes.append((MemoQuery(), span, nil)) }
            case .tag(let name): lanes = [(MemoQuery(tags: [name]), nil, nil)]
            case .period(let period): lanes = [(MemoQuery(), nil, period)]
            }
            var known: Set<String> = []
            lanes: for (query, span, period) in lanes {
                let after =
                    span.map { $0.start.addingTimeInterval(-1) }
                    ?? period.map { $0.start.addingTimeInterval(-1) }
                // A period's query carries no day, so no calendar is consulted for it; the
                // period's own keeps the device's zone out of the request all the same.
                var calendar = Calendar.current
                if let period {
                    calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = period.zone
                }
                var cursor: String?
                repeat {
                    let page = try await TimelineStore.page(
                        handle.client, query: query, calendar: calendar, direction: .newer,
                        after: after, before: period?.nextStart, cursor: cursor, limit: pageSize,
                        baseURL: baseURL)
                    guard journalStillCurrent(lineage, handle), ownsJournal(uid, token),
                        isLive(uid, lineage)
                    else {
                        MemosLog.api.info(
                            "a trip's journal page answered for a list that has moved on")
                        return
                    }
                    var pastPeriod = false
                    for memo in page.memos where !known.contains(memo.uid) {
                        if let span, !span.contains(Self.journalInstant(of: memo)) { continue }
                        if let period {
                            // Oldest first: the first memo at or past the end ends the lane.
                            if memo.createdAt >= period.nextStart {
                                pastPeriod = true
                                break
                            }
                            if memo.createdAt < period.start { continue }
                        }
                        known.insert(memo.uid)
                        memos.append(memo)
                        if span == nil, period == nil { tagged.insert(memo.uid) }
                    }
                    cursor = pastPeriod ? nil : page.nextCursor
                    if memos.count >= memberCap {
                        truncated = memos.count > memberCap || cursor != nil
                        memos = Array(memos.prefix(memberCap))
                        // Exactly the cap, read through: the next lane may still add a memo.
                        if truncated { break lanes }
                    }
                } while cursor != nil
            }
        } catch {
            guard lineage.generation == generation, ownsJournal(uid, token) else {
                MemosLog.api.info("a trip's journal page failed for a list that has moved on")
                return
            }
            await say(error, issuedUnder: handle, lane: .journal(uid)) {
                lineage.generation == self.generation && self.ownsJournal(uid, token)
                    && self.isLive(uid, lineage)
            }
            return
        }
        guard ownsJournal(uid, token), isLive(uid, lineage) else {
            MemosLog.api.info("a trip's journal answered for a trip that is gone")
            return
        }
        journals[uid] = TripJournal(
            rule: lineage.rule, memos: Self.byJournalInstant(fenced(memos, issued)), tagged: tagged,
            truncated: truncated)
        journalErrors[uid] = nil
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

    /// Only for a trip the trip store still holds, under the rule that trip has now — never the
    /// rule of the record the caller passed, which can be older.
    private func journal(of trip: Trip) -> TripJournal? {
        guard let journal = journals[trip.uid],
            let held = trips.trips.first(where: { $0.uid == trip.uid }),
            journal.rule == TripJournalRule(held).map(CollectionJournalRule.trip)
        else { return nil }
        return journal
    }

    private func ownsJournal(_ uid: String, _ token: Int) -> Bool {
        journalFlights[uid]?.token == token
    }

    /// Whether the trip store still holds trip `uid` under the rule the load was issued for, in
    /// the generation it was issued in.
    /// An automatic collection has no record to outlive: its load stands on its own lineage — the
    /// generation here, the credential and the rule in `journalStillCurrent` and the token.
    private func isLive(_ uid: String, _ lineage: TripJournalLineage) -> Bool {
        guard case .trip = lineage.rule else { return lineage.generation == generation }
        guard lineage.generation == generation,
            let trip = trips.trips.first(where: { $0.uid == uid })
        else { return false }
        return TripJournalRule(trip).map(CollectionJournalRule.trip) == lineage.rule
    }

    private func journalStillCurrent(_ lineage: TripJournalLineage, _ handle: SessionHandle)
        -> Bool
    {
        lineage.generation == generation && credentialCurrent(handle)
    }

    // MARK: - The New trip sheet

    // These reads name tags, not trips: `deletionRevision` fences the deletes that move no trip
    // revision. Counts carry no picture ids and extrema name no successor, so stale answers are
    // dropped whole rather than reconciled (MEMNG-795).

    /// Reads every tag's count, videos included. Refused, not sent, while a read issued under the
    /// same deletion revision is in flight. A read issued after a delete takes a slot of its own,
    /// as a span read does: the older read's answer is dropped, and its end leaves the new slot
    /// alone (MEMNG-809).
    public func loadTagCounts(using handle: SessionHandle) async {
        if let flight = countsInFlight, flight.deletionRevision == deletionRevision { return }
        journalToken += 1
        let token = journalToken
        countsInFlight = (deletionRevision, token)
        let issued = generation
        let issuedDeletion = deletionRevision
        defer { if countsInFlight?.token == token { countsInFlight = nil } }
        do {
            let rows = try await LibraryTagStore.tags(handle.client, filter: .all)
            guard issued == generation, issuedDeletion == deletionRevision,
                credentialCurrent(handle)
            else {
                MemosLog.api.info("a trip sheet's tag counts answered for a scope that moved on")
                return
            }
            tagCounts = rows
            tagCountsLoaded = true
            lastError = nil
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            await say(error, issuedUnder: handle, lane: .members) {
                issued == self.generation && issuedDeletion == self.deletionRevision
            }
        }
    }

    /// Reads one tag's first and last taken date among its files. A second read of the same tag,
    /// under the same generation, credential and deletion revision, while one is in flight joins
    /// it: nothing is sent, and it returns when that read ends. A read issued under another
    /// credential, generation or deletion revision is never joined — its answer is dropped — so
    /// the caller sends its own and takes the slot; the old read's end then lets its own joiners
    /// go and leaves the new slot alone. A caller whose credential is no longer the session's
    /// sends nothing. A delete retires cached spans too, so a joiner cannot read an older answer.
    public func loadSpan(ofTag tag: String, using handle: SessionHandle, baseURL: URL) async {
        guard credentialCurrent(handle) else {
            MemosLog.api.info("a trip sheet's span was asked for under a session that moved on")
            return
        }
        if let flight = spansInFlight[tag], flight.generation == generation,
            flight.credential == handle.generation, flight.deletionRevision == deletionRevision
        {
            onSpanJoin?()
            await withCheckedContinuation { spanJoiners[flight.token, default: []].append($0) }
            return
        }
        journalToken += 1
        let token = journalToken
        spansInFlight[tag] = (generation, handle.generation, deletionRevision, token)
        let issued = generation
        let issuedDeletion = deletionRevision
        defer {
            if spansInFlight[tag]?.token == token { spansInFlight[tag] = nil }
            for joiner in spanJoiners.removeValue(forKey: token) ?? [] { joiner.resume() }
        }
        do {
            let first = try await extremum(.oldestFirst, tag: tag, handle, baseURL)
            guard issued == generation, issuedDeletion == deletionRevision,
                credentialCurrent(handle)
            else { return }
            let last = try await extremum(.newestFirst, tag: tag, handle, baseURL)
            guard issued == generation, issuedDeletion == deletionRevision,
                credentialCurrent(handle)
            else {
                MemosLog.api.info("a trip sheet's span answered for a scope that moved on")
                return
            }
            spans[tag] = TripTagSpan(firstTaken: first, lastTaken: last)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            await say(error, issuedUnder: handle, lane: .members) {
                issued == self.generation && issuedDeletion == self.deletionRevision
            }
        }
    }

    private func extremum(
        _ order: MediaLibraryOrder, tag: String, _ handle: SessionHandle, _ baseURL: URL
    ) async throws -> Date? {
        let page = try await MediaLibraryStore.page(
            handle.client, filter: .all, order: order, tag: tag, cursor: nil, limit: 1,
            baseURL: baseURL)
        return page.items.first?.takenAt
    }

    // MARK: - Select mode's Delete (MEMNG-721)

    /// Deletes the chosen pictures — the member's own only, as the Library's select mode chooses
    /// them (`LibrarySelection.deletable`) — through the Library's own run
    /// (`MediaLibraryStore.deleteRun`): one `DELETE /api/attachments/{uid}` at a time, in the
    /// order chosen, stopping at the first failure.
    ///
    /// * Serialised by REFUSAL, as the Library's is: a second call while a run is out sends
    ///   nothing and returns nil.
    /// * Fenced by the session that issued it AND this store's identity generation: once either
    ///   moved, nothing further is sent and nothing the run learned is applied.
    /// * A failure goes through the session's funnel and writes no sentence over the photos: the
    ///   screen's toast says what the run did.
    /// * What went leaves every trip's members and journal at once, so a drain that read its page
    ///   before the delete cannot bring it back, and each trip it was a member of has its record
    ///   read again — its count and cover are the server's (decision 8).
    ///
    /// - Returns: what the run did, or nil when it was refused.
    public func delete(
        _ uids: [String], using handle: SessionHandle, baseURL: URL
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
            stillCurrent: { issued == generation && credentialCurrent(handle) },
            succeeded: { session?.noteTransportSuccess(issuedUnder: handle.generation) },
            failed: { await say($0, issuedUnder: handle, lane: .silent) }
        )
        if outcome.stoppedForSessionChange {
            // What landed is gone from the server, but nothing the run learned is applied: no
            // tombstone, no reload. The sheet's counts and spans counted it, so they still retire
            // — while the identity that issued the run is still this store's (MEMNG-809).
            if !outcome.deleted.isEmpty, issued == generation { retireSheet() }
            return outcome
        }
        await forget(pictures: outcome.deleted, issued: issued, handle, baseURL)
        return outcome
    }

    /// What the Library's and the Timeline's deletes report to (MEMNG-809). Asked when a delete
    /// is ISSUED, it takes this store's identity generation then; what it returns runs
    /// `picturesDeleted` for the uids that landed only while that generation is still this
    /// store's, so a delete answered after the session became somebody else's changes nothing
    /// here. A credential renewal moves no generation: what landed before it is still forgotten.
    /// `baseURL` is read when the pictures land, for the trips read again.
    public func picturesDeletedHook(baseURL: @escaping @MainActor () -> URL?)
        -> PicturesDeletedHook
    {
        { [weak self] in
            let issued = self?.generation
            return { [weak self] uids, handle in
                guard let self, let issued, let baseURL = baseURL() else { return }
                await self.picturesDeleted(uids, issued: issued, handle, baseURL)
            }
        }
    }

    /// The deleted pictures leave every trip, and stay gone; each trip they were drained as
    /// members of has its record read again.
    private func forget(
        pictures uids: [String], issued: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        guard !uids.isEmpty else { return }
        await picturesDeleted(Set(uids), issued: issued, handle, baseURL)
    }

    /// A delete from anywhere, in three steps. Nothing is applied once the identity generation the
    /// delete was issued under has moved: `sessionIdentityChanged()` already forgot everything
    /// that identity held, and the store is the next one's.
    ///
    /// (a) The trips the pictures were drained as members of, read BEFORE the tombstone, since
    /// `members(for:)` hides every uid in `deleted`. (b) The tombstone, the deletion fence, and
    /// every cached count and span — a count read already in flight keeps its slot only for its
    /// own deletion revision (`loadTagCounts`). (c) Each touched trip's record read again, while
    /// the identity and the credential still hold. An empty `gone` — a memo whose pictures were
    /// not known — still retires every count and span; it reads no trip.
    func picturesDeleted(
        _ gone: Set<String>, issued: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        guard issued == generation else {
            MemosLog.api.info("a delete landed for an identity that has moved on; nothing applied")
            return
        }
        let touched = trips.trips.filter { trip in
            members(for: trip).contains { gone.contains($0.id) }
        }
        deleted.formUnion(gone)
        retireSheet()
        for trip in touched {
            guard issued == generation, credentialCurrent(handle) else { return }
            _ = try? await trips.reload(uid: trip.uid, using: handle, baseURL: baseURL)
        }
    }

    /// Moves the deletion fence and drops every cached count and span. Neither aggregate
    /// identifies every contributing picture, so no cached answer can be repaired; a later read
    /// must establish the new count or extrema, and an answer issued before is dropped.
    private func retireSheet() {
        deletionRevision += 1
        tagCounts = []
        tagCountsLoaded = false
        spans = [:]
    }

    // MARK: - Session

    /// Forgets every count, span, journal, deleted picture and recorded exclusion because this
    /// device is signed in as
    /// somebody else; whatever is in flight was asked for by them, and drops on arrival. The
    /// members go with the trip store's own identity change (`invalidate(uid: nil)`).
    public func sessionIdentityChanged() {
        tagCounts = []
        tagCountsLoaded = false
        spans = [:]
        countsInFlight = nil
        spansInFlight = [:]
        let joiners = spanJoiners.values.joined()
        spanJoiners = [:]
        for joiner in joiners { joiner.resume() }
        journals = [:]
        journalFlights = [:]
        journalErrors = [:]
        deleted = []
        ownExclusions = [:]
        excludedRows = [:]
        ownInclusions = [:]
        renewedCovers = [:]
        coverFlights = [:]
        coverLeases = [:]
        generation += 1
    }

    // MARK: - The funnel

    /// The Library's funnel, in its order. `lane` says which sentence the failure writes; `owned`
    /// is asked synchronously immediately before each write — after the session's decision on a
    /// refusal, with nothing awaited in between — so a read forgotten while it waited says nothing.
    func say(
        _ error: any Error, issuedUnder handle: SessionHandle, lane: Lane,
        while owned: () -> Bool = { true }
    ) async {
        guard credentialCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        if let failure = StoreFailure.transportFailure(error) {
            if owned() { write(nil, on: lane) }
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            if await onUnauthorized(refusal) == .endedSession, establishedNothingSince(handle),
                owned()
            {
                write(refusal.errorDescription, on: lane)
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        if owned() { write(apiError.errorDescription, on: lane) }
    }

    private func write(_ sentence: String?, on lane: Lane) {
        switch lane {
        case .members: lastError = sentence
        case .journal(let uid): journalErrors[uid] = sentence
        case .silent: break
        }
    }

    /// Whether the session still runs the credential `handle` carries; with no session told,
    /// always.
    func credentialCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    private func establishedNothingSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
    }
}
