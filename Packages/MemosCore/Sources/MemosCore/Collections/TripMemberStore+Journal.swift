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

/// What a journal load in flight was issued under — what a second caller has to match to join it.
///
/// A load is fenced by this store's identity generation, the credential and the trip's rule (its
/// tag and span), not by the trip store's revision. The rule is asked again of the trip the trip
/// store holds when the answer lands (`isLive`) and whenever the journal is read (`journal(of:)`),
/// so a changed tag or span, or a deleted trip, hides it. Open gaps: an exclusion keeps a span memo
/// out only while a complete drain is held, and a list or pin drops the drain, so the memo shows
/// again (MEMNG-793); a picture deleted while a load is out, or after it landed, stays among a
/// tagged memo's files as `journal(for:)` returns them (MEMNG-794).
struct TripJournalLineage: Equatable {
    var generation: Int
    var session: Int
    var rule: TripJournalRule
}

struct TripJournal {
    var rule: TripJournalRule
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
    /// (`journalInstant(of:)`), less a span memo none of whose files is a member now. Empty until a
    /// journal load under the trip's rule has applied, for a trip the trip store no longer holds,
    /// and for a trip without a tag.
    public func journal(for trip: Trip) -> [Memo] {
        guard let journal = journal(of: trip) else { return [] }
        guard let span = journal.rule.span else { return journal.memos }
        // The server's members say which files are in the trip once a drain has read them all;
        // before that the window is the only rule this device knows.
        let members: Set<String>? =
            state(for: trip) == .complete ? Set(members(for: trip).map(\.id)) : nil
        // A span memo stays while one of its files is a member now: taken in the window (its memo's
        // date standing in for an undated one), not deleted, and listed by the server when the
        // members are known.
        return journal.memos.filter { memo in
            journal.tagged.contains(memo.uid) || memo.attachments.isEmpty
                || memo.attachments.contains { file in
                    !deleted.contains(file.uid)
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

    /// Reads the trip's whole journal. Joins a load of the same trip already in flight under the
    /// same session and rule; a trip without a tag sends nothing.
    public func loadJournal(_ trip: Trip, using handle: SessionHandle, baseURL: URL) async {
        guard let rule = TripJournalRule(trip) else { return }
        let lineage = TripJournalLineage(
            generation: generation, session: handle.generation, rule: rule)
        if let running = journalFlights[trip.uid], running.lineage == lineage {
            onJournalJoin?()
            await running.task.value
            return
        }
        let uid = trip.uid
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
        var memos: [Memo] = []
        var tagged: Set<String> = []
        var truncated = false
        do {
            // The tag's memos, then the span's: `.newer` is the query read oldest first,
            // `sort=created_at` (`MemoQuery.parameters(in:direction:after:)`) — with no bound for
            // the tag, and from just before the span's start for the span (`created_after` is
            // strict). A memo the tag lane read is not added twice.
            var lanes: [(query: MemoQuery, span: TripSpan?)] = [
                (MemoQuery(tags: [lineage.rule.tag]), nil)
            ]
            if let span = lineage.rule.span { lanes.append((MemoQuery(), span)) }
            var known: Set<String> = []
            lanes: for (query, span) in lanes {
                let after = span.map { $0.start.addingTimeInterval(-1) }
                var cursor: String?
                repeat {
                    let page = try await TimelineStore.page(
                        handle.client, query: query, calendar: .current, direction: .newer,
                        after: after, cursor: cursor, limit: pageSize, baseURL: baseURL)
                    guard journalStillCurrent(lineage, handle), ownsJournal(uid, token),
                        isLive(uid, lineage)
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
            rule: lineage.rule, memos: Self.byJournalInstant(memos), tagged: tagged,
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
            journal.rule == TripJournalRule(held)
        else { return nil }
        return journal
    }

    private func ownsJournal(_ uid: String, _ token: Int) -> Bool {
        journalFlights[uid]?.token == token
    }

    /// Whether the trip store still holds trip `uid` under the rule the load was issued for, in
    /// the generation it was issued in.
    private func isLive(_ uid: String, _ lineage: TripJournalLineage) -> Bool {
        guard lineage.generation == generation,
            let trip = trips.trips.first(where: { $0.uid == uid })
        else { return false }
        return TripJournalRule(trip) == lineage.rule
    }

    private func journalStillCurrent(_ lineage: TripJournalLineage, _ handle: SessionHandle)
        -> Bool
    {
        lineage.generation == generation && credentialCurrent(handle)
    }

    // MARK: - The New trip sheet

    // These reads name tags, not trips, and are fenced by the identity generation and the
    // credential alone. Open gap: an answer issued before a picture delete lands unchanged after
    // it, so a count or a span can still include the deleted picture (MEMNG-795).

    /// Reads every tag's count, videos included. Refused, not sent, while the same read is in
    /// flight.
    public func loadTagCounts(using handle: SessionHandle) async {
        guard !countsInFlight else { return }
        countsInFlight = true
        let issued = generation
        defer { if issued == generation { countsInFlight = false } }
        do {
            let rows = try await LibraryTagStore.tags(handle.client, filter: .all)
            guard issued == generation, credentialCurrent(handle) else {
                MemosLog.api.info("a trip sheet's tag counts answered for a session that moved on")
                return
            }
            tagCounts = rows
            tagCountsLoaded = true
            lastError = nil
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            await say(error, issuedUnder: handle, lane: .members)
        }
    }

    /// Reads one tag's first and last taken date among its files. A second read of the same tag,
    /// under the same generation and the same credential, while one is in flight joins it:
    /// nothing is sent, and it returns when that read ends. A read issued under another credential
    /// or generation is never joined — its answer is dropped — so the caller sends its own and
    /// takes the slot; the old read's end then lets its own joiners go and leaves the new slot
    /// alone. A caller whose credential is no longer the session's sends nothing.
    public func loadSpan(ofTag tag: String, using handle: SessionHandle, baseURL: URL) async {
        guard credentialCurrent(handle) else {
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
        journalToken += 1
        let token = journalToken
        spansInFlight[tag] = (generation, handle.generation, token)
        let issued = generation
        defer {
            if spansInFlight[tag]?.token == token { spansInFlight[tag] = nil }
            for joiner in spanJoiners.removeValue(forKey: token) ?? [] { joiner.resume() }
        }
        do {
            let first = try await extremum(.oldestFirst, tag: tag, handle, baseURL)
            guard issued == generation, credentialCurrent(handle) else { return }
            let last = try await extremum(.newestFirst, tag: tag, handle, baseURL)
            guard issued == generation, credentialCurrent(handle) else {
                MemosLog.api.info("a trip sheet's span answered for a session that moved on")
                return
            }
            spans[tag] = TripTagSpan(firstTaken: first, lastTaken: last)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else { return }
            await say(error, issuedUnder: handle, lane: .members)
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
        guard !outcome.stoppedForSessionChange else { return outcome }
        await forget(pictures: outcome.deleted, issued: issued, handle, baseURL)
        return outcome
    }

    /// The deleted pictures leave every trip, and stay gone; each trip they were drained as
    /// members of has its record read again.
    private func forget(
        pictures uids: [String], issued: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        guard !uids.isEmpty else { return }
        let gone = Set(uids)
        let touched = trips.trips.filter { trip in
            members(for: trip).contains { gone.contains($0.id) }
        }
        deleted.formUnion(gone)
        for trip in touched {
            guard issued == generation, credentialCurrent(handle) else { return }
            _ = try? await trips.reload(uid: trip.uid, using: handle, baseURL: baseURL)
        }
    }

    // MARK: - Session

    /// Forgets every count, span, journal and deleted picture because this device is signed in as
    /// somebody else; whatever is in flight was asked for by them, and drops on arrival. The
    /// members go with the trip store's own identity change (`invalidate(uid: nil)`).
    public func sessionIdentityChanged() {
        tagCounts = []
        tagCountsLoaded = false
        spans = [:]
        countsInFlight = false
        spansInFlight = [:]
        let joiners = spanJoiners.values.joined()
        spanJoiners = [:]
        for joiner in joiners { joiner.resume() }
        journals = [:]
        journalFlights = [:]
        journalErrors = [:]
        deleted = []
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
