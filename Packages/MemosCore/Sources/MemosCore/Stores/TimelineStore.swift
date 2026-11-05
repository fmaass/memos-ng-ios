import Foundation
import MemosAPI
// For `StagedSource`: the four things an upload needs to know about a picked file. It is the
// outbox's type because the outbox was the first lane to need it, and a second identical struct
// here would be a second answer to "what is a file about to be uploaded".
import MemosOutbox

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

/// One picture in the list a save states, in the order the sheet showed it.
///
/// Two cases because the two kinds of picture are named differently on the wire and only one of
/// them has a name the client already knows: `attachment_uids` accepts an attachment uid the memo
/// already holds, or an upload uid named in the SAME request's `upload_uids` — and a picture just
/// picked from the library has no attachment uid until the server answers. So a picked one travels
/// as its PLACE in the files handed to `attaching:`, and is resolved to the uid the upload
/// returned at the moment that answer is in hand.
public enum MemoPictureEntry: Equatable, Sendable {
    /// A picture the memo already holds, by its attachment uid.
    case kept(String)
    /// A picture going up in this same save, by its place in `attaching:`.
    case uploading(Int)
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
    /// The captures still in the queue, drawn as cards above the memos (MEMNG-951).
    public private(set) var pending = PendingMemoBoard()
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    /// A page towards now is in flight.
    public private(set) var isLoadingNewer = false
    public private(set) var lastError: String?
    /// Whether the last read of this list never reached the server.
    ///
    /// It is not an error message and it is deliberately not one: the sentence about an
    /// unreachable server belongs to the session, once, on its banner. What this carries is the
    /// FACT, for a reader that has to tell "the server said nothing matched" from "nobody asked
    /// the server" — an empty list that would otherwise read as an answer.
    public private(set) var serverUnreachable = false
    public private(set) var hasMore = true
    /// Whether anything is believed to sit ABOVE the loaded rows.
    ///
    /// False for a plain timeline, always: its first page starts at the newest memo there is, so
    /// there is nothing above it and an upward read would be a request whose answer is known to be
    /// empty. True the moment a list is anchored — an anchor is a ceiling, and everything written
    /// since is above it — and false again as soon as the server says an upward page was the last
    /// one (MEMNG-179).
    public private(set) var hasNewer = false
    /// The server's own ascending continuation for the CURRENT upward run, or nil when the next
    /// upward page starts a new run from the newest loaded row. The cursor carries the full
    /// (created_at, id) keyset tuple, which a timestamp alone cannot: a page boundary inside a
    /// group of equal timestamps would strand the group's unseen half for ever (review round).
    private var newerCursor: String?

    private var nextCursor: String?
    /// Which loaded list this is. Bumped at the two moments the list stops being the one an
    /// unanswered page was a continuation of: a refresh replacing it, and a delete taking a row
    /// out of it.
    ///
    /// It exists because a page can outlive the list it was asked for. `refresh` and `loadMore`
    /// genuinely overlap — a pull, or the reload a sign-in does, does not wait for a scroll that
    /// is already fetching — and a page that started against the old list carries the old list's
    /// rows AND the old list's cursor. Merged on arrival it shows a memo twice, puts back one the
    /// delete has just taken away, and — the damage that outlives the merge — leaves `nextCursor`
    /// pointing into a lineage nobody is reading any more, so every page after it is fetched from
    /// the wrong place. So the generation is taken before the request and checked before the merge.
    ///
    /// The live media path deliberately does NOT bump it: `apply` and `refreshMemo` change what a
    /// memo says, never which memos there are, so a page in flight is still a continuation of the
    /// list they touched and must still land.
    private var timelineGeneration = 0
    private let pageSize: Int
    /// The calendar an anchored query's day is read in — injected rather than reached for, so what
    /// a chosen day becomes on the wire is decided by a time zone a test can name.
    private let calendar: Calendar
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    /// Where a failure that never reached the server goes instead of `lastError`, and the seam
    /// this store reads the session's incarnation from (`SessionReporting`).
    ///
    /// Named by the owner rather than taken at construction, because the timeline builds its own
    /// from a `.task` and names the session to it there.
    private var session: (any SessionReporting)?
    /// Told of the pictures a delete took — a memo's attachments, or one attachment — for the New
    /// trip sheet's counts and spans (MEMNG-809). Asked when the delete is issued; what it returns
    /// is called once the server has confirmed the pictures gone.
    @ObservationIgnored public var onPicturesDeleted: PicturesDeletedHook?
    /// Where the last-seen list is kept between launches, or nil for a store that keeps none —
    /// which is every list that is not THE timeline: any other list is an answer to a question
    /// nobody asked again on the next launch.
    private let snapshots: TimelineSnapshotWriter?
    /// Whose timeline this is. Nil is the same "keep none" as above, and it is what a store built
    /// before anybody is signed in has.
    private let snapshotIdentity: TimelineSnapshotIdentity?
    /// Whether this store's list is one a next launch should open on.
    ///
    /// False for every list that is not THE timeline: any other `TimelineStore` holds an answer to
    /// a question nobody will ask again tomorrow.
    private let persists: Bool
    /// How many times the published list has changed in this run.
    ///
    /// It is what the writer compares two pictures by, because the order two writes reach it in is
    /// not something Swift promises. Moved at the ONE place the list changes, synchronously, before
    /// anything is awaited.
    private var listRevision = 0
    /// The query the rows on screen were ADMITTED under — not the one that has since been asked
    /// for.
    ///
    /// The two come apart on purpose: `setQuery` leaves the loaded rows where they are until a
    /// refresh replaces them, so between a filter change and its answer the list is still the old
    /// query's. Writing it down under the new query's name is how an anchored day would end up
    /// being opened as "the timeline" on the next launch. Nil until a first page has replaced the
    /// list at all.
    private var admittedQuery: MemoQuery?
    /// The memos carrying a change this app has made on screen and the server has not confirmed,
    /// each under the CLAIM that made it.
    ///
    /// Nothing is written down while one of these is outstanding: a tick that is about to be put
    /// back is not a state a next launch should open on. The settle — the server's answer, or the
    /// rollback — is itself a change to the list, so the write follows it.
    ///
    /// A claim rather than a bare uid because a release happens after awaits, and by then the
    /// entry under that uid may belong to somebody else: an identity change empties this map, and
    /// the next tap on the same memo makes a NEW claim. A release that removed whatever it found
    /// would retire that one and let a third request overlap it, which is the very thing the map
    /// exists to prevent. So a release names the claim it owns and a stale one does nothing.
    private var optimistic: [String: Int] = [:]
    /// The last claim handed out. Never reset — a number that comes round again is a claim that
    /// can be released by the wrong owner.
    private var optimisticClaim = 0
    /// A change that was not written because something optimistic was outstanding at the time.
    private var snapshotDirty = false
    /// This store's claim on its identity, once the writer has issued one. Nil until it has: a
    /// store that has not claimed the identity does not write for it.
    private var producerToken: Int?
    /// The claim being made, so two changes arriving together make ONE of them rather than a second
    /// that retires the first.
    private var producerBinding: Task<Int, Never>?
    /// Whether the rows on screen came off the disk and no server has spoken yet.
    private var showingSnapshot = false
    /// Set when the signed-in identity stops being the one this store was built for. Everything
    /// this store does with the disk ends there: what it restored is dropped, and nothing more is
    /// written under an identity that has been left behind.
    private var identityWithdrawn = false

    /// What this list is asking the server for. `.empty` is the plain timeline, and it is the
    /// default: a store nobody has filtered sends exactly what it always sent.
    public private(set) var query: MemoQuery

    public init(
        pageSize: Int = 20,
        query: MemoQuery = .empty,
        calendar: Calendar = .current,
        snapshots: TimelineSnapshotWriter? = nil,
        snapshotIdentity: TimelineSnapshotIdentity? = nil,
        persists: Bool = false,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.pageSize = pageSize
        self.query = query
        self.calendar = calendar
        self.snapshots = snapshots
        self.snapshotIdentity = snapshotIdentity
        self.persists = persists
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    /// Follows the favorites ledger (MEMNG-867): a commit reaches every attachment of that picture
    /// on the loaded list — and the snapshot with it — and every read is stamped with the ledger's
    /// revision when it is ISSUED, so one that left before a commit lands with the ledger's tags
    /// for that picture rather than its own.
    public func follow(_ favorites: FavoriteStore) {
        self.favorites = favorites
        favorites.observe { [weak self] favorite in await self?.applyFavorite(favorite) }
    }

    @ObservationIgnored private weak var favorites: FavoriteStore?

    private var favoriteStamp: FavoriteStamp { favorites?.stamp ?? FavoriteStamp(revision: 0) }

    private func fencedFavorites(_ memos: [Memo], _ issued: FavoriteStamp) -> [Memo] {
        favorites?.overlay(memos, issuedAt: issued) ?? memos
    }

    private func fencedFavorites(_ memo: Memo, _ issued: FavoriteStamp) -> Memo {
        favorites?.overlay(memo, issuedAt: issued) ?? memo
    }

    private func applyFavorite(_ favorite: FavoriteCommit) async {
        let next = memos.map { memo in
            guard memo.attachments.contains(where: { $0.uid == favorite.uid }) else { return memo }
            var memo = memo
            for position in memo.attachments.indices
            where memo.attachments[position].uid == favorite.uid {
                memo.attachments[position].tags = favorite.tags
            }
            return memo
        }
        guard next != memos else { return }
        // Entry is the issue point, as for a live media event: nothing was asked of the server
        // here, the ledger said something and this is the moment it is acted on.
        await commit(next, under: issuedAuthority())
    }

    /// Puts the memos this identity last saw on screen, before anything has been asked of the
    /// server. Called once, where the store is made.
    ///
    /// It renders and nothing more. No cursor comes back with it — a cursor is a position inside a
    /// list the server sent THIS run, and one read off a file would page into somebody else's idea
    /// of the list — so `hasMore` keeps its optimistic default and the first `refresh` replaces the
    /// rows whole. A list that is not empty is left alone: the network has already answered, and
    /// the snapshot is the older word by definition.
    ///
    /// The identity is checked on both sides of the read. A file is only ever asked for under the
    /// identity the session held when the read was ISSUED, and it is only ever rendered if that is
    /// still the identity when the bytes come back.
    public func restoreSnapshot() async {
        guard memos.isEmpty, query.isEmpty, !identityWithdrawn else { return }
        guard let snapshots, let snapshotIdentity else { return }
        // Taken BEFORE the first suspension, and compared after the last one. The claim and the
        // read are both awaits, and a session can end inside either: rendering afterwards would
        // put one account's memos on a device that has become somebody else's — and the store's
        // own `identityWithdrawn` cannot answer it, because that only moves if somebody tells
        // this store, and the incarnation moves whether anybody does or not.
        let issued = lineage
        await claimProducer()
        guard let snapshot = await snapshots.read(identity: snapshotIdentity) else { return }
        guard memos.isEmpty, !identityWithdrawn, issued == lineage else {
            MemosLog.api.info("a snapshot read under a session that has moved on was not rendered")
            return
        }
        memos = snapshot.memos
        showingSnapshot = true
    }

    /// Who the device is signed in as has changed. Everything this store holds belonged to the
    /// identity it was built for, and that is no longer who is looking.
    ///
    /// Unconditional, and that is the point: rows the SERVER sent are one account's memos exactly
    /// as much as rows read off the disk are. A store is not torn down by a switch between two
    /// signed-in identities on the same server — the screen holding it stays in the same branch of
    /// the root view and keeps its state — so a store that emptied only what it had restored would
    /// leave the outgoing account's timeline on screen for the incoming one.
    ///
    /// The cursors go with the rows: a cursor is a position inside a list this store is no longer
    /// showing, and a page in flight was asked for by somebody else, so the lineage moves and those
    /// answers drop on arrival. Nothing more is written either — this store's identity has gone.
    public func sessionIdentityChanged(to identity: TimelineSnapshotIdentity?) {
        guard identity != snapshotIdentity else { return }
        identityWithdrawn = true
        memos = []
        showingSnapshot = false
        admittedQuery = nil
        optimistic.removeAll()
        // The line goes with the claims for the same reason: it orders one account's changes to one
        // account's rows, and what is still in it was asked for by somebody who is no longer here.
        // The tasks standing in it keep running under the handles they captured and refuse
        // themselves on arrival; their places are not the incoming identity's to wait behind.
        mutations.removeAll()
        sentVisibility.removeAll()
        unsettledVisibility.removeAll()
        // And so do the fences and the debts they left: they hold one account's rows against one
        // account's reads, and there are no rows left here to hold. The sequence itself is a
        // counter like `mutationClaim` and is never reset — a stamp from the line that has gone
        // matches nothing, which is what keeps a task that outlived the change from holding the
        // incoming identity's first read off.
        fences.removeAll()
        owedReads.removeAll()
        // Which memos the server has confirmed gone is a fact about one account's memos, said by a
        // server this device is no longer asking as that account.
        confirmedDeletions.removeAll()
        // The reads already out to pay a debt are forgotten rather than cancelled, like every other
        // task that outlives the identity that started it: each carries the handle its debt was
        // recorded under, so it is refused where it lands and nothing it brings back reaches a list
        // that belongs to somebody else. What is dropped here is only this store's wait on them.
        owedPayments.removeAll()
        snapshotDirty = false
        nextCursor = nil
        newerCursor = nil
        hasMore = true
        hasNewer = false
        lastError = nil
        timelineGeneration += 1
        // Events kept for a read in flight are this identity's news as much as the rows are. The
        // read itself will be refused on arrival; what it was holding goes now.
        reconcileReads.removeAll()
    }

    /// The one place the published list changes — and, with it, the picture of it on the disk.
    ///
    /// Every caller sits AFTER the fence that decides whether the change happens at all, so a page
    /// from a lineage nobody is reading, or from a session that has ended, updates neither. The
    /// write is AWAITED rather than launched: it takes its place in the writer's queue in the order
    /// the changes were applied, and the session it was issued under travels with it so the writer
    /// can refuse it at the moment of writing if that session has since gone.
    ///
    /// Only the plain timeline is kept. An anchored day, a tag filter or a search result is an
    /// answer to a question nobody will ask again on the next launch, and opening the app on one
    /// would be opening it on a list the reader never chose.
    private func commit(_ next: [Memo], under authority: Int) async {
        memos = next
        // Whatever is on screen now came from the server, not from the disk.
        showingSnapshot = false
        // This number is how the writer tells which of two pictures THIS store took is the newer.
        listRevision += 1
        await persist(under: authority)
    }

    /// Claims this identity for this store, once, retiring whoever held it before.
    ///
    /// Joined rather than repeated: two changes arriving together would otherwise make two claims,
    /// the second retiring the first, and the first store's write would be refused as a stranger's.
    @discardableResult
    private func claimProducer() async -> Int? {
        guard persists, let snapshots, let snapshotIdentity else { return nil }
        if let producerToken { return producerToken }
        if let producerBinding { return await producerBinding.value }
        let binding = Task { await snapshots.bind(to: snapshotIdentity) }
        producerBinding = binding
        let token = await binding.value
        producerToken = token
        return token
    }

    /// Writes the picture, when there is one worth writing.
    private func persist(under authority: Int) async {
        guard persists, !identityWithdrawn else { return }
        // BOTH queries: the one the rows were admitted under, and the one being asked for now. A
        // list of default rows with an anchor already requested is a list about to be replaced —
        // writing it down would put a picture of the old list under the new list's name.
        guard admittedQuery?.isEmpty == true, query.isEmpty else { return }
        guard let snapshots, let snapshotIdentity else { return }
        guard optimistic.isEmpty else {
            snapshotDirty = true
            return
        }
        // CAPTURED, before the claim below suspends. The eligibility checked above is about the
        // list as it stands NOW — plain rows, admitted under the plain query — and the claim is
        // long enough for an anchored refresh to replace both. Writing `memos` on the way out
        // would then file that day's rows under the plain timeline's name, and the next launch
        // would open on a window the reader never chose. What is written is the picture the
        // change that called this made, and the revision that picture had.
        let picture = memos
        let revision = listRevision
        guard let producer = await claimProducer() else { return }
        // Taken AGAIN, because the claim above suspends: a tick begun while it was out would
        // otherwise have its unconfirmed content written by this call, which is the one thing the
        // check before the await exists to prevent. The withdrawal is re-asked for the same
        // reason — an identity that has been left behind writes nothing more.
        guard optimistic.isEmpty, !identityWithdrawn else {
            snapshotDirty = true
            return
        }
        snapshotDirty = false
        await snapshots.write(
            picture,
            for: snapshotIdentity,
            producer: producer,
            revision: revision,
            query: .empty,
            // The AUTHORITY the operation was ISSUED under, not the one now: the writer's refusal
            // is about the credential this device was holding when the change was asked for, and
            // it is read again — synchronously, on the writer — at the moment the bytes land.
            session: authority
        )
    }

    /// An optimistic change has been answered — confirmed, or put back — so the list is once again
    /// something a next launch may open on. Anything held back while it was outstanding goes now.
    ///
    /// LAST, after the apply or the rollback it belongs to has been awaited to the end: a claim
    /// released before that is a claim a second tap can take while the first one is still landing,
    /// and the first one's settle would then retire the second's.
    ///
    /// A lane whose place in line is worth no more than its optimistic claim hands that place in
    /// too, and the two go together with nothing awaited between them: the write below may be held
    /// for as long as the disk pleases, and a tap that is allowed to change the row again must not
    /// be made to wait behind somebody else's picture of it.
    private func settle(_ uid: String, claim: Int, gate: Int? = nil, under authority: Int) async {
        release(uid, claim: claim)
        if let gate { finishMutation(gate, on: uid) }
        guard optimistic.isEmpty, snapshotDirty else { return }
        await persist(under: authority)
    }

    /// Gives up ONE claim on a memo — the caller's own, or nothing.
    ///
    /// A release that ran after an identity change would otherwise take the incoming identity's
    /// claim with it (`sessionIdentityChanged` empties the map, and the next tap makes a new one).
    private func release(_ uid: String, claim: Int) {
        guard optimistic[uid] == claim else { return }
        optimistic.removeValue(forKey: uid)
    }

    /// Asks for a different list.
    ///
    /// The loaded rows are left on screen until a refresh replaces them — the same choice the
    /// refresh path already makes, and for the same reason: a list that blanks the moment a filter
    /// changes is a worse lie than one that is a moment out of date.
    public func setQuery(_ query: MemoQuery) {
        guard query != self.query else { return }
        self.query = query
        // Back to the state a store starts in: nothing read yet, and no reason to believe there is
        // no more. The old cursor is a position inside the old list's rows and means nothing under
        // a filter that removes some of them; `loadMore` reads nothing until a refresh hands it a
        // cursor of this query's own.
        nextCursor = nil
        hasMore = true
        // Nothing is known to be above a list that has not been read yet. `refresh` decides this
        // from the query it actually read, so a query set and never refreshed cannot leave a
        // stale upward promise behind.
        hasNewer = false
        newerCursor = nil
        // A page already in flight was a continuation of the query it set out under, not of this
        // one, so it is superseded exactly as a page from a replaced list is.
        timelineGeneration += 1
    }

    /// Which list a page in flight was asked for — the generation AND the query, because either
    /// one moving makes the answer a continuation of something nobody is reading any more.
    private struct Lineage: Equatable {
        var generation: Int
        var query: MemoQuery
        /// Which INCARNATION asked — who the device was signed in as. A page issued as one person
        /// and answered after the device became somebody else's — or nobody's — continues nothing:
        /// it must not reach the list, and therefore it cannot reach the disk either.
        var session: Int
    }

    private var lineage: Lineage {
        Lineage(
            generation: timelineGeneration,
            query: query,
            // The incarnation, from the session itself. A store with no session named to it has
            // nothing to be wrong about and reads zero — the same answer `sessionStillCurrent`
            // gives one.
            session: session?.sessionIncarnation.current ?? 0
        )
    }

    /// The authority epoch to stamp a picture of this list with, read at the moment an operation
    /// is ISSUED and carried through it.
    ///
    /// It is NOT part of the lineage, and the difference is the point. The authority epoch also
    /// moves on a token renewal, which replaces the credential without ending the session: judging
    /// the LIST by it would drop every page in flight whenever a renewal landed, and nothing
    /// retries a dropped page. The list is judged by the incarnation; only the WRITE is judged by
    /// this, and only to be refused (`TimelineSnapshotWriter.write`).
    ///
    /// Read from the very box the writer refuses on, so a store cannot stamp its pictures with a
    /// counter that is not the one judging them. Every operation takes it ONCE, before its
    /// request goes out, and hands it to every apply point it reaches — re-reading it when the
    /// answer comes back would stamp the picture with an authority the request never had.
    private func issuedAuthority() -> Int { snapshots?.epoch.current ?? 0 }

    /// Which lineage the first page in flight belongs to, or nil when none is.
    ///
    /// `isLoading` alone cannot decide whether a refresh is redundant. The request a superseded
    /// query left in flight is exactly what a person changing a filter is waiting for the end of,
    /// so counting it turns the change into nothing at all: the old page is fenced out on arrival,
    /// the new query was never read, and no trigger is left to try again. What is redundant is a
    /// refresh of the lineage ALREADY being read; a refresh of a different one is the whole point.
    private var loadingLineage: Lineage?
    /// The one read a refusal above leaves owed, with the handle and the address it arrived with.
    ///
    /// A refresh of the lineage already being read is refused. For a second pull of a list that
    /// is coming anyway the refusal is the whole answer; for a trigger meaning the list may have
    /// MOVED it is not, because the read in flight left BEFORE that trigger and cannot carry it —
    /// a route regain delivered mid-read is exactly that, and nothing else asks again. So the
    /// refusal is remembered and spent once, from the tail of the read it was refused for. At most
    /// one, whatever number
    /// were refused — they all ask the same question — and a refusal recorded for a DIFFERENT
    /// lineage is left where it is, because the read that is finishing is not the one it was owed.
    private var refreshAgain: (lineage: Lineage, handle: SessionHandle, baseURL: URL)?

    public func refresh(using handle: SessionHandle, baseURL: URL) async {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        let lineage = self.lineage
        guard loadingLineage != lineage else {
            // Refused, and REMEMBERED: the read in flight left before this was asked for, so its
            // answer cannot carry whatever made somebody ask (`refreshAgain`).
            refreshAgain = (lineage, handle, baseURL)
            return
        }
        loadingLineage = lineage
        isLoading = true
        // Only the newest reader clears the flag. A superseded request finishing while the current
        // one is still out would otherwise take the spinner down over a list still being read.
        defer {
            if loadingLineage == lineage {
                loadingLineage = nil
                isLoading = false
                // Whatever was refused while this read was out is owed one read, taken from here
                // — the earliest instant at which it would not simply be refused again.
                if refreshAgain?.lineage == lineage { Task { await self.refreshOnceMore() } }
            }
        }
        do {
            // The instant this read leaves, taken immediately before it does. Every row it comes
            // back with is judged against it, so a change made while it was in the air outranks it.
            let issued = mutationSequence
            let favoritesIssued = favoriteStamp
            // The pending cards whose memo this read can answer for (MEMNG-951): it leaves after
            // they resolved, so once it has landed they have said their piece.
            let settleable = pending.resolvedJobIDs
            let page = try await Self.page(
                client,
                query: lineage.query,
                calendar: calendar,
                cursor: nil,
                limit: pageSize,
                baseURL: baseURL
            )
            // A first page read before a delete still has the deleted memo on it, so publishing it
            // now would undo the delete on screen. It is dropped whole rather than filtered: the
            // list stays as it is, which is the truth minus one row, and the next pull re-reads it.
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/memos answered for a list that has moved on")
                return
            }
            guard sessionStillCurrent(handle) else {
                MemosLog.api.info("a page answered for a session that has ended is not applied")
                return
            }
            serverUnreachable = false
            // The other half of the sentence this store reports to the session. A page that
            // arrived is evidence the server is reachable for the credential that asked — and it
            // is handed over as a QUESTION, never as an answer: only a whoami confirms a session
            // (`noteTransportSuccess`).
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            // An anchored first page starts BELOW a ceiling, so everything written after that day
            // is above it. An unanchored one starts at the newest memo there is, so nothing is.
            hasNewer = lineage.query.anchor != nil
            newerCursor = nil
            lastError = nil
            // This IS a different list — a new lineage, whose cursor no page in flight shares.
            timelineGeneration += 1
            // The one place rows are REPLACED, and so the one place the query they were admitted
            // under is settled.
            admittedQuery = lineage.query
            // Last, and awaited: everything this list says about itself is already true when the
            // picture of it is taken.
            await commit(
                effective(
                    admitted(fencedFavorites(page.memos, favoritesIssued)), issuedAt: issued,
                    using: handle, baseURL: baseURL
                ),
                under: authority
            )
            // Only here, after the page landed: a read that failed or was dropped leaves each card
            // standing until a list that can hold its memo has been read.
            pending.settle(settleable)
        } catch {
            // A failure belongs to the request that suffered it. One from a list nobody is reading
            // any more would put an error over a list that loaded perfectly well — and, for a
            // refusal,
            // end the session on the word of a request that has been superseded. The current
            // lineage asks the server the same question and is the one entitled to answer it.
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/memos failed for a list that has moved on")
                return
            }
            await report(error, issuedUnder: handle)
        }
    }

    /// The single read every refresh refused while the last one was in flight is owed.
    ///
    /// Read out of the box rather than handed in, so that however many were refused, this asks
    /// once. It is taken with the handle the refusal arrived with, and a session that has ended in
    /// between stops it where every other read of a dead session stops
    /// (`sessionStillCurrent`).
    private func refreshOnceMore() async {
        guard let owed = refreshAgain else { return }
        refreshAgain = nil
        await refresh(using: owed.handle, baseURL: owed.baseURL)
    }

    /// Reads the page that follows the loaded ones — and reads it AGAIN, itself, when the list it
    /// was a continuation of is gone by the time it lands.
    ///
    /// The second read has to happen here, because nothing else would make it happen. The next
    /// page is asked for when the last row appears, and a row already on screen does not appear a
    /// second time: a reader sitting at the end of the list would be waiting for a page this
    /// store had decided to throw away, and would go on waiting until they pulled or scrolled
    /// about. So the drop and the read that replaces it are ONE operation, not two that something
    /// above has to sequence.
    ///
    /// It is bounded by the thing that causes it. A drop asks again once, for the page that
    /// follows the list as it stands NOW — so a list changing under a reader costs one extra read
    /// per change, with never more than one in flight. A refresh already running is left to
    /// finish instead: it is about to replace the list, cursor and all.
    public func loadMore(using handle: SessionHandle, baseURL: URL) async {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        guard !isLoadingMore, !isLoading, hasMore, nextCursor != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // Read ONCE, for the whole operation. The cursor and the list lineage are re-read on every
        // pass — after a drop, the page that comes next is the CURRENT list's next page, not the
        // one this call set out to fetch — but the SESSION is not: an operation that started as one
        // person must not continue as another, and re-reading here is exactly how it would.
        let issued = self.lineage
        while !isLoading, hasMore, let cursor = nextCursor {
            guard sessionStillCurrent(handle) else { return }
            let lineage = Lineage(
                generation: timelineGeneration,
                query: query,
                session: issued.session
            )
            do {
                // Inside the loop, because a pass that asks again is a NEW read: it left later, and
                // a mutation the dropped pass was held off by may be finished by the time it does.
                // Named apart from the lineage this operation set out with, which is also `issued`.
                let issuedAt = mutationSequence
                let favoritesIssued = favoriteStamp
                let page = try await Self.page(
                    client,
                    query: lineage.query,
                    calendar: calendar,
                    cursor: cursor,
                    limit: pageSize,
                    baseURL: baseURL
                )
                // The continuation of a list that is gone continues nothing: its rows can include
                // a memo the delete removed, and its cursor walks a lineage nobody is reading.
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/memos answered for a list that has moved on")
                    // The loop asks again — with the client this call was handed, which belongs to
                    // the session that started it. If that session is over, asking again would
                    // reissue a superseded credential's request under the new one's number, and
                    // its rows would merge into a list belonging to somebody else.
                    guard sessionStillCurrent(handle) else { return }
                    continue
                }
                guard sessionStillCurrent(handle) else {
                    MemosLog.api.info("a page answered for a session that has ended is not merged")
                    return
                }
                serverUnreachable = false
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                // A cursor page can overlap the one before it when a memo moved; appending blindly
                // would show the same memo twice and break SwiftUI's identity.
                let known = Set(memos.map(\.uid))
                // Everything reaching the fence here is a uid the list does NOT hold, so a held one
                // has no row to keep and is dropped: a memo changed while this page was in the air
                // is not appended at the version the page describes. The next read brings it.
                let fresh = fencedFavorites(page.memos, favoritesIssued).filter {
                    !known.contains($0.uid)
                }
                let merged =
                    memos
                    + effective(
                        admitted(fresh), issuedAt: issuedAt, using: handle, baseURL: baseURL
                    )
                nextCursor = page.nextCursor
                hasMore = page.nextCursor != nil
                lastError = nil
                await commit(merged, under: authority)
                return
            } catch {
                // Fenced exactly as the page above it is: a failure that answers a superseded
                // request says nothing about the list being read now, and the loop asks again for
                // the page that follows the list as it stands.
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/memos failed for a list that has moved on")
                    guard sessionStillCurrent(handle) else { return }
                    continue
                }
                await report(error, issuedUnder: handle)
                return
            }
        }
    }

    /// True once the reader is close enough to the end that the next page should already be on its
    /// way. Pure, so the trigger is unit-tested rather than inferred from a scroll position.
    public func shouldLoadMore(after index: Int, lookahead: Int = 3) -> Bool {
        guard hasMore, !isLoadingMore, !isLoading, nextCursor != nil else { return false }
        return index >= memos.count - lookahead
    }

    /// Reads the page directly ABOVE the loaded rows and puts it on top of them.
    ///
    /// This is what makes an anchored list two-way. Until MEMNG-179 a jump was a trapdoor: the
    /// list came back with a ceiling on it, `loadMore` walked down from that ceiling, and nothing
    /// anywhere could walk back up — so a reader taken to a day in June could scroll to the
    /// beginning of the account and never reach yesterday again except through "Today", which
    /// throws the anchor away entirely.
    ///
    /// The bound is the newest `createdAt` already loaded, not the anchor's own ceiling. Two
    /// reasons, and both of them are correctness rather than taste. The ceiling is an instant
    /// nothing is guaranteed to sit exactly on, but a memo written on it precisely would fall in
    /// NEITHER direction — `created_at < ceiling` excludes it and `created_at > ceiling` excludes
    /// it too, both being strict. And the bound has to MOVE, or the second upward page would be
    /// the first one again: reading from the newest loaded row makes each page start where the
    /// last one stopped, which is the same thing the downward cursor does at the other end.
    ///
    /// The page comes back ascending — the memos directly above the list, oldest first — so it is
    /// reversed before it goes on top. Asking for it descending would answer with the newest
    /// memos in the account and leave a hole between them and the list.
    ///
    /// - Returns: the uid the reader was standing on before the block went above it, or nil when
    ///   nothing was prepended. The caller scrolls back to it: a list that grows upwards under a
    ///   still finger throws the reader down the page by exactly as much as it grew, which is the
    ///   hazard every prepend has (`TimelineView`).
    @discardableResult
    public func loadNewer(using handle: SessionHandle, baseURL: URL) async -> String? {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        guard !isLoadingNewer, !isLoading, hasNewer else { return nil }
        isLoadingNewer = true
        defer { isLoadingNewer = false }
        let lineage = self.lineage
        let previousTop = memos.first?.uid
        // Mid-run, the server's own cursor is the position — it carries the (created_at, id)
        // tuple the keyset really orders by. A run START has no cursor, so it asks from ONE
        // SECOND below the newest loaded row and lets uid-dedup drop the overlap: a bound taken
        // at the row's exact timestamp would strictly exclude an unseen sibling written in the
        // same second, on either side of a page boundary (review round).
        var continuation = newerCursor
        let bound = memos.map(\.createdAt).max()
        do {
            // Followed in a loop, not handed back: the eased start can answer with nothing but
            // rows the list already has while the cursor says more remain, and returning nil
            // there would consume the reader's top-arrival with nothing to show — the page
            // above would sit stranded until they scrolled away and back (review round). Each
            // pass advances the server's own cursor; eight known-only pages in a row is a
            // server that is not converging, not a household timeline.
            for _ in 0..<8 {
                // Inside the loop, for the reason the downward one takes it there: each pass is a
                // read of its own and is judged against the instant that read left.
                let issued = mutationSequence
                let favoritesIssued = favoriteStamp
                let page = try await Self.page(
                    client,
                    query: lineage.query,
                    calendar: calendar,
                    direction: .newer,
                    after: continuation == nil ? bound?.addingTimeInterval(-1) : nil,
                    cursor: continuation,
                    limit: pageSize,
                    baseURL: baseURL
                )
                // Fenced exactly as every other page is: a refresh or a delete has replaced the
                // list this block was measured against, and a block measured against a list that
                // is gone can put back a deleted memo and sit above rows it is older than.
                guard lineage == self.lineage else {
                    MemosLog.api.info("GET /api/memos answered for a list that has moved on")
                    return nil
                }
                guard sessionStillCurrent(handle) else {
                    MemosLog.api.info("a page answered for a session that has ended is not merged")
                    return nil
                }
                serverUnreachable = false
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                // The server says whether it was the last page, exactly as it does downwards.
                // Read BEFORE the emptiness check, because an upward page that adds nothing new
                // is still the server saying there is nothing above.
                hasNewer = page.nextCursor != nil
                newerCursor = page.nextCursor
                let known = Set(memos.map(\.uid))
                // As downwards: only uids the list does not hold reach the fence, so a held one has
                // no row to keep and is left off the block rather than prepended at a stale state.
                let fresh = effective(
                    admitted(
                        fencedFavorites(page.memos, favoritesIssued).filter {
                            !known.contains($0.uid)
                        }),
                    issuedAt: issued,
                    using: handle,
                    baseURL: baseURL
                )
                lastError = nil
                if !fresh.isEmpty {
                    await commit(Array(fresh.reversed()) + memos, under: authority)
                    // The uid handed back is a row of THIS account's list, and the caller scrolls
                    // to it. After the commit's own await, ask once more whose list it is.
                    guard sessionStillCurrent(handle) else { return nil }
                    return previousTop
                }
                guard let next = page.nextCursor else { return nil }
                continuation = next
            }
            return nil
        } catch {
            guard lineage == self.lineage else {
                MemosLog.api.info("GET /api/memos failed for a list that has moved on")
                return nil
            }
            await report(error, issuedUnder: handle)
            return nil
        }
    }

    /// True once the reader is close enough to the TOP that the page above should already be on
    /// its way — the mirror of `shouldLoadMore`, and pure for the same reason.
    public func shouldLoadNewer(before index: Int, lookahead: Int = 3) -> Bool {
        guard hasNewer, !isLoadingNewer, !isLoading else { return false }
        return index < lookahead
    }

    /// Says what went wrong — unless what went wrong was this app cancelling its own request.
    ///
    /// The lineage fence above cannot decide that one: a supersede cancels the transport BEFORE it
    /// moves the lineage, so the cancelled request is still the current one when its `-999` lands
    /// (MEMNG-180). `StoreFailure` recognises the cancellation itself, and it is the same
    /// recognition in every store rather than five that drift apart.
    private func report(_ error: any Error, issuedUnder handle: SessionHandle) async {
        // A FAILURE is as much this session's as a success is, and the fence is the same one. A
        // stale refusal reaching `onUnauthorized` below wipes the session running NOW — the single
        // worst thing a missing fence can do here — and a stale sentence lands on a screen that
        // never asked for it. Neither is a list-lineage question, so the lineage guards at the
        // call sites cannot answer it.
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a failure for a session that has ended is not reported")
            return
        }
        // A server that never answered is the SESSION's to say, once, in a banner — never this
        // store's. Saying it here as well is what painted an error card under that banner on every
        // load, refresh and tag fetch of an offline launch, and no ordering fixes it from in here:
        // a list's request can fail BEFORE the launch check does, so the later transition to
        // `.unverified` has nothing to clear the card it wrote.
        if let failure = StoreFailure.transportFailure(error) {
            serverUnreachable = true
            // The sentence a PREVIOUS answer left behind is not about this attempt, and a reader
            // that sees both reads the older one.
            lastError = nil
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            return
        }
        // The server ANSWERED, so whatever this list last said about being unable to reach it is
        // out of date — true of a refusal as much as of anything else it said.
        if let refusal = StoreFailure.refusal(error) {
            serverUnreachable = false
            // The SESSION owns the verdict; this store owns only what it says about it. A refusal
            // of a credential the device has already replaced is not this list's news, and "sign
            // in again" over a session that renewed a second ago is a false instruction.
            //
            // The second question is asked HERE, after that await and with nothing awaited before
            // the write: the rule's own fences are taken before its awaits, and a sign-in can
            // complete inside them. The verdict is about the session that issued this request,
            // and so is the sentence — neither is the incoming identity's to carry.
            if await onUnauthorized(refusal) == .endedSession, nothingEstablishedSince(handle) {
                lastError = refusal.errorDescription
            }
            return
        }
        guard let apiError = StoreFailure.reportable(error) else {
            MemosLog.api.info("a cancelled request is not a failure and is not reported")
            return
        }
        serverUnreachable = false
        lastError = apiError.errorDescription
    }

    // MARK: - pending memos (MEMNG-951)

    /// The queue as last read, and the memos its finished captures became. Only captures bound
    /// to `identity` are this timeline's: a capture made under another account is that
    /// account's, and nil — nobody signed in — shows none.
    public func showPending(
        _ jobs: [UploadJob], resolved: [UUID: String], for identity: TimelineSnapshotIdentity?
    ) {
        let mine = jobs.filter { job in
            guard let identity else { return false }
            return job.binding.serverBaseURL == identity.server
                && job.binding.ownerSubject == identity.subject
        }
        pending.show(mine, resolved: resolved)
    }

    /// A person removed this capture; nothing that arrives later puts its card back.
    public func withdrawPending(_ jobID: UUID) { pending.withdraw(jobID) }

    /// The cards to draw, newest first: a card whose memo the list already holds is that memo.
    public var pendingCards: [PendingMemo] { pending.visible(present: Set(memos.map(\.uid))) }

    /// The key a memo's row is drawn under — its card's, when it was one, so the swap is one row.
    public func identityKey(for memo: Memo) -> String { identityKey(forUID: memo.uid) }
    public func identityKey(forUID uid: String) -> String { pending.key(for: uid) }

    /// The picked items a memo went without, carried over from the card it replaced so the line
    /// that says so outlives the swap (MEMNG-1049).
    public func missingItems(forUID uid: String) -> Int { pending.missingItems(for: uid) }

    /// Empties the loaded list.
    ///
    /// The timeline never does this — a list that blanks because one refresh failed is a worse lie
    /// than a stale one — but a SEARCH is a different case: its rows are the answer to a question,
    /// and rows from the previous question left under "can't search right now" read as this
    /// question's answer. The lineage moves with them, so a page still in the air cannot put them
    /// back.
    public func clearRows() {
        memos = []
        pending.reset()
        nextCursor = nil
        hasMore = true
        hasNewer = false
        newerCursor = nil
        timelineGeneration += 1
    }

    /// Whether the session that ISSUED an operation is still the one this device is running.
    ///
    /// A store with no session named to it answers yes: a preview and a suite that is about paging
    /// have no incarnation to be wrong about.
    /// The same question, asked by an owner that holds this store's handle across its own awaits,
    /// long enough for a session to end inside them.
    public func sessionIsCurrent(_ handle: SessionHandle) -> Bool { sessionStillCurrent(handle) }

    /// The same fence, as a value the SENDING executor can ask.
    ///
    /// `sessionStillCurrent` is main-actor isolated, which is right for everything this store
    /// applies and wrong for a lane that sends from somewhere else. A chunked upload runs for
    /// minutes off this actor, so it carries this instead: the incarnation it was granted under,
    /// and a nonisolated box to compare it with (`SessionReporting.sessionIncarnation`).
    private func sendAuthority() -> SendAuthority {
        guard let session else { return .unfenced }
        let incarnation = session.sessionIncarnation
        let granted = incarnation.current
        return SendAuthority { incarnation.isCurrent(granted) }
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        // A store with no session named to it has nothing to be wrong about — a preview, and the
        // suites that are about paging. A store that HAS one and finds it holding no client is
        // looking at a session that has been WITHDRAWN, and that answers no: the whole point of
        // the withdrawal is that nothing issued under it may land. Answering "still current"
        // there is the bug, not the safe default.
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    /// The question asked AFTER the session has answered a refusal, with nothing awaited between
    /// it and the sentence it guards (`SessionReporting.nothingEstablishedSince`). The fence
    /// above cannot cover it: it is taken before the await, and the switch happens inside it.
    ///
    /// A store with no session named to it writes, for the reason it is current above.
    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
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
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        do {
            let response = try await client.createMemoApiMemosPost(
                .init(body: .json(.init(content: content, visibility: visibility?.generated)))
            )
            switch response {
            case .created(let created):
                guard sessionStillCurrent(handle) else { return false }
                let memo = admitted(Memo(try created.body.json, baseURL: baseURL))
                lastError = nil
                await commit(
                    Self.placed(memo, in: memos, tie: .justCreated), under: authority
                )
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
            await report(error, issuedUnder: handle)
            return false
        }
    }

    /// Replaces a memo's content with what the editor produced, and — when the editor was given a
    /// date — the display date it carries, and — when the editor picked files — the media that
    /// goes on it.
    ///
    /// `createdAt` is left OUT of the request when it is nil rather than sent as the memo's
    /// current value: a PATCH is a partial update, and an edit that did not touch the date has no
    /// business rewriting it. The web app sends the date on every edit because its editor always
    /// holds one; here the absence is what says "unchanged". `attaching` is absent in exactly the
    /// same way, and it matters more: `upload_uids` on a patch ADDS attachments
    /// (`app/routers/memos.py` links the finalized uploads onto the memo), so an empty array sent
    /// on every edit would be a field the server has to ignore rather than a statement about this
    /// one.
    ///
    /// An edit that attaches files is not sent from here at all (MEMNG-954): it is written to
    /// `queue` as an edit job and answered `.saved` once it is persisted, so the sheet closes at
    /// once. The outbox mints the job's edit key, uploads the files on the lane new captures use
    /// and patches the memo with them as the job's terminal action — a retry presents the same key,
    /// so the server applies it once. No queue, or a write the device refused, is `.storage`, with
    /// nothing sent. An edit without files is the direct PATCH.
    ///
    /// `listing` is the third of these absences and the sharpest one. `attachment_uids` REPLACES a
    /// memo's picture list with what it names, so the key is left out entirely when the caller has
    /// nothing to say about pictures — nil means untouched, and every caller that never opened the
    /// compose sheet sends exactly that. A caller that does pass a list is stating the memo's WHOLE
    /// list in its order, which is why an empty one is honoured as deliberate clearing rather than
    /// read as "nothing to say".
    @discardableResult
    public func edit(
        uid: String,
        content: String,
        createdAt: Date? = nil,
        attaching files: [StagedSource] = [],
        listing pictures: [MemoPictureEntry]? = nil,
        visibility change: VisibilityChange? = nil,
        through queue: (any MemoEditQueue)? = nil,
        composedUnder account: AccountBinding? = nil,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        let attempt = MemoEditAttempt(
            uid: uid, content: content, createdAt: createdAt,
            files: files.map(\.editIdentity), pictures: pictures, visibility: change
        )
        // The place in line is taken here, before the key is minted and before a single byte goes
        // up: a save that joins the one ahead of it must present neither a second key nor a second
        // copy of the same photograph.
        return await claimMutation(.edit(attempt), on: uid) { [self] claim in
            MemoMutationAnswer(
                await performEdit(
                    attempt, attaching: files, through: queue, composedUnder: account,
                    claim: claim, using: handle, baseURL: baseURL
                ))
        }.value.outcome
    }

    /// The save itself, once every earlier mutation of this memo has finished.
    private func performEdit(
        _ attempt: MemoEditAttempt,
        attaching files: [StagedSource],
        through queue: (any MemoEditQueue)?,
        composedUnder account: AccountBinding?,
        claim: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        // Before the first request and AFTER whatever this memo's line made it wait for: a place
        // in line is an unbounded wait, and the session that ISSUED a mutation is the one it is
        // judged against. A save queued under an account that has gone since must put nothing on
        // the wire under the next one's name — the uploads below are a send like any other.
        guard sessionStillCurrent(handle) else {
            mutationChangedNothing(claim, on: attempt.uid)
            return .failed(.authorization)
        }
        // Beside that question and asked at the same instant: the memo these words belong to may
        // have been taken away while they queued. The answer stands in for the 404 the server
        // would give them, and it is reported rather than swallowed — a save nobody can keep is
        // not a save that went through.
        guard !serverConfirmedDeletion(of: attempt.uid) else {
            mutationChangedNothing(claim, on: attempt.uid)
            return .failed(.rejection)
        }
        // And the audience this save carries, judged where the memo now stands: a narrowing that
        // has become a widening while it queued goes back to the sheet as its question, with
        // nothing sent and no key minted.
        if let question = visibilityReask(attempt.visibility, on: attempt.uid) {
            mutationChangedNothing(claim, on: attempt.uid)
            return .ask(question)
        }

        // One change owed to a memo at a time (MEMNG-954). An edit job freezes the memo's words and
        // its whole picture list when it is written and patches them later, so an edit saved
        // beside it — words only, or more files — would be undone by its PATCH or undo it. Asked
        // here, inside this memo's line: the next edit of it waits for this one's enqueue to land
        // before it asks, and the outbox refuses a second job in the same call that would write it.
        if let queue, await queue.hasUnfinishedEdit(memoUID: attempt.uid) {
            mutationChangedNothing(claim, on: attempt.uid)
            return .failed(.editPending)
        }

        // Files make the edit a JOB (MEMNG-954): it is written to the outbox, which mints its edit
        // key, uploads the files on the lane new captures use and sends the PATCH that names them
        // as its terminal action — after this sheet has closed, and after a relaunch. Nothing is
        // sent from here, so nothing on the server changed: the reads this claim held off know the
        // row as well as it does.
        if !files.isEmpty {
            defer { mutationChangedNothing(claim, on: attempt.uid) }
            guard let queue else { return .failed(.storage) }
            // The audience goes LATER (MEMNG-1187): the job's PATCH is sent after this sheet has
            // closed, when the memo may have been narrowed elsewhere, and nothing asks then. So the
            // job carries only an audience no later state can make a widening — Private, or one the
            // person confirmed — and any other is asked here, before anything is written.
            if let question = attempt.visibility?.askedBeforeDeferral { return .ask(question) }
            let order = MemoEditOrder(
                memoUID: attempt.uid,
                content: attempt.content,
                visibility: attempt.visibility?.to.rawValue,
                createdAt: attempt.createdAt,
                pictures: attempt.pictures?.map { entry in
                    switch entry {
                    case .kept(let uid): .kept(uid)
                    case .uploading(let index): .adding(index)
                    }
                }
            )
            // Bound to the account the sheet was saved under: a job written after a switch would
            // send these words into the next account's memo (`Outbox.enqueueEdit` refuses it).
            switch await queue.enqueueEdit(order, sources: files, composedUnder: account) {
            case .queued: return .saved
            case .editPending: return .failed(.editPending)
            case .notWritten: return .failed(.storage)
            }
        }

        // No authority is taken here: the patch below is issued inside `patch`, which takes its
        // own at the moment it sends.
        let key = editKey(for: attempt)
        // The sheet's list. `attachment_uids` is the COMPLETE list and the server unlinks what it
        // omits, so an entry that cannot be resolved takes the whole key out of the request: a
        // partial list would delete a picture nobody removed. A direct edit carries no files, so
        // an entry naming one has nothing to resolve to.
        let listed: [String]? = attempt.pictures.flatMap { entries in
            var resolved: [String] = []
            for entry in entries {
                switch entry {
                case .kept(let uid): resolved.append(uid)
                case .uploading: return nil
                }
            }
            return resolved
        }
        let outcome = await patchAnswer(
            uid: attempt.uid,
            .init(
                attachmentUids: listed, content: attempt.content, createdAt: attempt.createdAt,
                editKey: key, uploadUids: nil, visibility: attempt.visibility?.generated
            ),
            claim: claim,
            using: handle,
            baseURL: baseURL
        ).outcome
        finishEdit(key: key, saved: outcome.isSaved)
        return outcome
    }

    /// What identifies ONE Save, so that a retry of it can be told apart from a new one.
    ///
    /// Everything the request would carry, because that is exactly the question the edit key
    /// answers. Two attempts with the same fields are the same logical edit — a lost response, a
    /// refused upload, a tap on Save after either — and they must share a key, or the second one
    /// applies the first one's edit a second time. Two attempts that differ in ANY field are
    /// different edits and must not: a shared key would have the server replay the first and answer
    /// 200 while the new words went nowhere, which looks exactly like a save that worked.
    private struct MemoEditAttempt: Equatable, Sendable {
        var uid: String
        var content: String
        var createdAt: Date?
        /// The files as their IDENTITIES rather than as their bytes on disk.
        ///
        /// A retry after a failed upload re-imports the picker's export, which lands under a new
        /// temporary name with a new modification date. Keyed on those, the same photograph
        /// attached to the same memo would mint a NEW key, and the server would apply a retry of a
        /// lost save a second time instead of replaying it — which is the one thing the key exists
        /// to prevent (`StagedSource.editIdentity`).
        var files: [String]
        /// The picture list this save states, or nil when it states none.
        ///
        /// Part of the attempt, and so part of the key, because two saves that differ ONLY in which
        /// pictures the memo keeps are two different edits: sharing a key would have the server
        /// replay the first and answer 200 while the removal went nowhere.
        var pictures: [MemoPictureEntry]?
        /// The audience this save moves the memo to, or nil when it leaves the audience alone —
        /// in which case the key is left out of the PATCH entirely rather than restating the
        /// visibility the sheet happened to open on, which a change made since would then undo.
        /// Part of the key for the reason `pictures` is.
        var visibility: VisibilityChange?
    }

    /// The edit a key was minted for, that key, and how many invocations are USING it right now.
    ///
    /// One slot, because a person is editing one memo in one sheet: the moment a different edit is
    /// submitted, the previous key is of no further use — the edit it named either landed or was
    /// abandoned. The count is the part that cannot be inferred from the slot alone, and it is what
    /// stops one invocation tidying up while an identical one is still on the wire.
    private struct EditKeySlot {
        var attempt: MemoEditAttempt
        var key: String
        var inFlight: Int
    }

    private var lastEdit: EditKeySlot?

    /// The retry token this attempt sends, and a note that one more invocation is using it.
    ///
    /// It is what makes a media edit repeatable at all. Without a key the server refuses a retried
    /// media edit outright (409 `uploads_unlinkable`, because the first attempt consumed the
    /// uploads); with one, the replay is answered BEFORE the uploads are looked at, so a retry
    /// whose predecessor actually landed gets the memo back rather than a conflict — and cannot
    /// apply the edit twice.
    ///
    /// A UUID satisfies the contract's `^[A-Za-z0-9_-]{8,64}$` as it stands, hyphens included.
    private func editKey(for attempt: MemoEditAttempt) -> String {
        if var slot = lastEdit, slot.attempt == attempt {
            slot.inFlight += 1
            lastEdit = slot
            return slot.key
        }
        // A different edit. Whatever is still running under the old key keeps it — it is holding
        // it in a local — and `finishEdit` will find the slot renamed and leave it alone.
        let slot = EditKeySlot(attempt: attempt, key: UUID().uuidString, inFlight: 1)
        lastEdit = slot
        return slot.key
    }

    /// One invocation has finished with its key.
    ///
    /// The key is released when it has done its work, because keeping it would make the very same
    /// edit submitted again later — the same words typed back into a memo somebody has since
    /// changed — answerable as a REPLAY: 200, and nothing applied.
    ///
    /// Two conditions, and each closes a way of losing an edit somebody made.
    ///
    /// The slot must still be THIS edit's. The slot is one for the whole store while the line each
    /// memo's mutations stand in is per memo, so a save of a DIFFERENT memo can be submitted while
    /// this one is in flight and mint its own key into the slot first. Clearing then throws away
    /// the key of the edit still running, and if that one's response is lost its retry mints a
    /// fresh key and applies the same edit twice.
    ///
    /// And this must be the LAST invocation using the key: releasing one another invocation is
    /// still presenting leaves that one's lost response to mint a fresh key on retry and attach the
    /// same files a second time — the same harm as above, reached by the other door. Two saves of
    /// identical fields cannot reach that today, because the line joins them into ONE task
    /// (`claimMutation`) and the key is taken once inside it, and no other pair of one memo's
    /// mutations overlaps at all. The count is kept because it guards the slot itself rather than
    /// depending on the line above staying the shape it is.
    ///
    /// A failure never releases: the retry is the whole point of the key. And once nothing is in
    /// flight and one of them landed, the key IS spent — a later tap on Save is a new edit by
    /// design, which is what `aSuccessfulSaveEndsItsKey` holds.
    private func finishEdit(key: String, saved: Bool) {
        guard var slot = lastEdit, slot.key == key else { return }
        slot.inFlight = max(0, slot.inFlight - 1)
        lastEdit = saved && slot.inFlight == 0 ? nil : slot
    }

    /// What tells one unfinished mutation of a memo from another.
    ///
    /// Equal identities are the same mutation submitted twice — a double tap on Save, a retried
    /// save, two sheets open on one memo. An edit is identified by everything its request would
    /// carry, exactly as `editKey(for:)` identifies it; every other mutation by the operation and
    /// the state it asks for, which is all there is to tell two of them apart.
    private enum MemoMutationIdentity: Equatable {
        case edit(MemoEditAttempt)
        case delete
        /// The yes is part of it: a confirmed change queued behind an identical unconfirmed one is
        /// the answer to that one's question, and joining it would hand the question back.
        case visibility(MemoVisibility, confirmed: Bool)
        case archived(Bool)
        case pinned(Bool)
        case task(index: Int)
    }

    /// One unfinished mutation: what it is, and the work everything behind it waits for.
    private struct MemoMutation {
        var claim: Int
        var identity: MemoMutationIdentity
        var task: Task<MemoMutationAnswer, Never>
    }

    /// The unfinished mutations of each memo, in arrival order: the one on the wire first, then
    /// everything queued behind it.
    ///
    /// A screen is never the guard. The compose sheet and the detail view both reach the same memo
    /// through this store, and a request already on the wire cannot be recalled by a view that has
    /// closed — so the order two saves of one memo reach the server is this store's to decide, and
    /// nobody else's.
    private var mutations: [String: [MemoMutation]] = [:]

    private var mutationClaim = 0

    /// How far a memo's row has been carried by mutations this store performed.
    ///
    /// `applied` is the stamp of the last mutation the server confirmed for it; `claims` holds the
    /// stamp each unfinished mutation took when it entered the line. The higher of the two is what a
    /// read is judged against, so a row is held from the moment somebody changes it until the answer
    /// that confirmed the change has landed.
    private struct MemoFence {
        var applied = 0
        var claims: [Int: Int] = [:]

        var value: Int { max(applied, claims.values.max() ?? 0) }
    }

    /// One order over the mutations of every memo.
    ///
    /// Store-wide rather than per memo because a read is issued once and comes back carrying a whole
    /// page: the instant it left is a single instant, and every row it carries is judged against it.
    private var mutationSequence = 0

    private var fences: [String: MemoFence] = [:]

    /// What a fenced read left behind, which is everything the read that pays for it needs.
    ///
    /// The handle and the base URL are the FENCED read's own, captured where the refusal happened
    /// and never re-sampled from the session: the payment stands in for that read, so it belongs to
    /// the same incarnation and is refused wherever that read would have been refused.
    private struct OwedRead {
        let handle: SessionHandle
        let baseURL: URL
    }

    /// The memos whose loaded row was kept against a read that had been issued before it.
    ///
    /// That read was the one thing on its way to bring the server's own version of the row, and it
    /// was refused; the debt is recorded where the refusal happens, and only where a row actually
    /// stands — a memo with no row cannot be repaired by a read that may not insert one. A second
    /// fenced read of the same memo overwrites the entry, and writes the same incarnation it found
    /// there: an identity change empties the table.
    private var owedReads: [String: OwedRead] = [:]

    /// The memos this store watched the server confirm the deletion of.
    ///
    /// Written where the 204 is read and asked wherever a queued lane resumes, because a place in
    /// line is an unbounded wait and a delete can finish inside it. Row presence cannot answer the
    /// question: a memo also leaves the loaded list when its archive state or the query it is
    /// filtered by moves, and neither of those means the server stopped holding it. Only a delete
    /// this store saw confirmed does.
    ///
    /// The record ends where a read that LEFT after that confirmation comes back still carrying
    /// the memo: the server's importer is rerunnable and recreates an absent memo under its old
    /// uid, so a uid that is gone is not gone forever, and a note that never ends would refuse
    /// every later change to it until the person signs out. A read issued EARLIER ends nothing —
    /// it was asked about a memo that still existed and is not a statement about now.
    private var confirmedDeletions: Set<String> = []

    /// Whether a mutation about to send has been overtaken by a delete of the same memo that the
    /// server already confirmed.
    ///
    /// The uploads are the reason it is asked before the first request rather than around it: files
    /// posted for a memo that no longer exists are bytes nothing will ever attach, and the patch
    /// behind them would be a change to a memo this app itself asked to have removed.
    private func serverConfirmedDeletion(of uid: String) -> Bool {
        confirmedDeletions.contains(uid)
    }

    /// The server is still holding this memo, so the note of its deletion is over.
    ///
    /// Called only where a read was NOT fenced — that read left after the last change this store
    /// confirmed for the memo, so it is the newest word there is, and it carries the memo. A
    /// fenced read is the opposite case and retires nothing: it was asked before the delete
    /// landed, and a state the delete left must not be resurrectable by an answer that outlived
    /// it. `fenced` stays a pure question; this is the one place the answer is acted on.
    private func serverStillHolds(_ memo: Memo, issuedAt issued: Int) {
        confirmedDeletions.remove(memo.uid)
        // Its audience as well — but not past a mutation still in line for the memo, which may yet
        // move it: that one's own answer is the word that settles the record (`patchAnswer`). Nor
        // from a read that left before a lost answer was recorded: unfenced as it is, it may have
        // been answered before the server applied the change whose answer was lost.
        guard fences[memo.uid]?.claims.isEmpty ?? true,
            issued >= unsettledVisibility[memo.uid] ?? 0
        else { return }
        recordServerAudience(memo)
    }

    /// The reads in flight to pay a debt, each one clearing its own entry, in the idiom
    /// `refreshMemo` uses for its join slot and for the same reason.
    private var owedPayments: [Int: Task<Void, Never>] = [:]

    private var owedPaymentTicket = 0

    /// Waits for every read this store issued to pay a debt.
    ///
    /// Two samples of a request count cannot show that no further payment is still to come, so the
    /// store offers the instant at which there is none. A
    /// payment that leaves a debt of its own is waited for too. No mutation awaits this: a save is
    /// finished when the save is finished, and must not wait on a read it did not need.
    ///
    /// It waits for the payments outstanding AT THE CALL, identity change or not. A change of
    /// identity forgets the table without cancelling anything, so each of those reads still lands
    /// — refused, under the handle its debt was recorded with — and a test that changed the
    /// identity mid-payment can only assert what that answer did not do once it has arrived. So
    /// the waits are taken from the table when called and kept here, where the change cannot drop
    /// them. After those, it waits for whatever the table then holds — a debt one of them left,
    /// or a payment started since — whoever's it is. A call made AFTER a change finds the table it
    /// emptied and waits for nothing the outgoing identity started.
    func owedReadsSettled() async {
        for payment in Array(owedPayments.values) {
            await payment.value
        }
        while let payment = owedPayments.values.first {
            await payment.value
        }
    }

    /// Pays this memo's owed read, once per debt, as soon as no mutation owns the row.
    ///
    /// The debt leaves the table BEFORE the paying task exists, so a second arrival in the same
    /// stretch finds nothing to pay: the claim is taken synchronously, ahead of every hop. A paying
    /// read that is itself fenced records a fresh debt through the ordinary path and is paid when
    /// THAT claim leaves.
    private func payOwedRead(for uid: String) {
        guard fences[uid]?.claims.isEmpty ?? true, let owed = owedReads.removeValue(forKey: uid)
        else { return }
        owedPaymentTicket += 1
        let ticket = owedPaymentTicket
        owedPayments[ticket] = Task { [self] in
            // A read already running for this memo left before the debt fell due and would be
            // fenced all over again, so it is waited out rather than joined — and waiting it out is
            // what leaves the join slot to the paying read. Two reads of one memo overlapping undo
            // each other's replay (see `refreshMemo`); paying a debt must not be what does that.
            let slot = ReconcileSlot(uid: uid, generation: owed.handle.generation)
            if let running = reconcileJoins[slot] { _ = await running.value }
            await refreshMemo(uid: uid, using: owed.handle, baseURL: owed.baseURL)
            owedPayments[ticket] = nil
        }
    }

    private func nextMutationSequence() -> Int {
        mutationSequence += 1
        return mutationSequence
    }

    /// Whether this memo's row has moved since the instant a read left.
    ///
    /// Strictly greater, so a read issued while a mutation stands in line is held off only once that
    /// mutation has actually moved the row — the fresh stamp its confirmation takes. A mutation that
    /// ends up changing nothing must not cost a reader the answer it went to fetch.
    private func fenced(_ uid: String, issuedAt issued: Int) -> Bool {
        (fences[uid]?.value ?? 0) > issued
    }

    /// The server confirmed this mutation under a session that is still current: the row this store
    /// holds is the newer statement about that memo, whatever the confirmation then did to the list.
    private func mutationApplied(_ claim: Int, on uid: String) {
        retireClaim(claim, on: uid) { $0.applied = nextMutationSequence() }
    }

    /// Nothing vouches for what the server did with this mutation, so the row stays held against
    /// every read that was already on its way when the mutation took its place in line: the claim
    /// keeps the stamp it entered with, and only a read issued after THAT moment can settle it.
    /// The failure is where the answer runs out, not where the boundary is.
    private func mutationOutcomeUnknown(_ claim: Int, on uid: String) {
        retireClaim(claim, on: uid) { $0.applied = max($0.applied, $0.claims[claim] ?? 0) }
    }

    /// The mutation left nothing behind — it never went out, or the server refused it in a way that
    /// cannot have changed the memo — so the reads it was holding off know this row as well as it
    /// does.
    private func mutationChangedNothing(_ claim: Int, on uid: String) {
        retireClaim(claim, on: uid) { _ in }
    }

    /// What a thrown failure says about the row.
    ///
    /// A refusal the server issued about the request itself leaves the memo as it was. Anything else
    /// — the request left and no answer vouches for what became of it — leaves the row unknown, and
    /// a read issued before it cannot be the thing that decides.
    private func mutationFailed(_ claim: Int, on uid: String, with error: any Error) {
        mutationEnded(claim, on: uid, MemoMutationEffect.of(error))
    }

    /// `mutationFailed` for a caller that has already read the error once and acts on it twice.
    private func mutationEnded(_ claim: Int, on uid: String, _ effect: MemoMutationEffect) {
        switch effect {
        case .changedNothing: mutationChangedNothing(claim, on: uid)
        case .outcomeUnknown: mutationOutcomeUnknown(claim, on: uid)
        }
    }

    /// MEMBERSHIP first, like `finishMutation` and for the same reason: an identity change empties
    /// the fences under every task still running, and a task that outlived it may neither stamp the
    /// identity that came after nor hold its first read off.
    private func retireClaim(_ claim: Int, on uid: String, _ stamp: (inout MemoFence) -> Void) {
        guard var fence = fences[uid], fence.claims[claim] != nil else { return }
        stamp(&fence)
        fence.claims[claim] = nil
        fences[uid] = fence.claims.isEmpty && fence.applied == 0 ? nil : fence
        // The one door every exit leaves through, so this is the one place that sees the moment a
        // memo may have no mutation on it any more — which is the moment a read owed on it is due.
        payOwedRead(for: uid)
    }

    /// Takes this memo's place in line and hands back the work to await.
    ///
    /// Synchronous to its last line, so two taps arriving in one turn of the main actor cannot both
    /// find the queue as it was.
    ///
    /// The arrival is compared with the LAST unfinished mutation rather than with the one on the
    /// wire: two identical saves submitted while a DIFFERENT one is held are still one save, and
    /// must reach the server once. The tail and not "any unfinished one", because the same words
    /// saved again after something else is no repeat — it is the person putting them back, and
    /// joining it to the earlier one would leave what came between standing.
    ///
    /// Everything the gated work needs is read INSIDE it rather than here: a picture of the list
    /// taken at the moment of the tap would be a generation out of date by the time its turn came,
    /// and the mutation's own write would be dropped as stale (`issuedAuthority`).
    ///
    /// The work is handed its own claim so that a lane which knows its place in line is over before
    /// its task is can say so itself — the task-end release below stays for every lane, and is a
    /// no-op for a claim already gone.
    private func claimMutation(
        _ identity: MemoMutationIdentity,
        on uid: String,
        perform work: @escaping @MainActor @Sendable (Int) async -> MemoMutationAnswer
    ) -> Task<MemoMutationAnswer, Never> {
        var queue = mutations[uid] ?? []
        if let tail = queue.last, tail.identity == identity { return tail.task }
        mutationClaim += 1
        let claim = mutationClaim
        // The row is held from HERE, in the same synchronous breath as the place in line: a read
        // issued while these words are on their way carries a memo the person has already moved
        // past, and it arrives with nothing to say about that. A joined arrival takes no stamp of
        // its own — it is the same mutation, and it is already holding the row.
        fences[uid, default: .init()].claims[claim] = nextMutationSequence()
        let predecessor = queue.last?.task
        let task = Task { [self] in
            // Whatever stands ahead of it goes first; that one's answer is its own caller's.
            _ = await predecessor?.value
            let outcome = await work(claim)
            finishMutation(claim, on: uid)
            return outcome
        }
        queue.append(MemoMutation(claim: claim, identity: identity, task: task))
        mutations[uid] = queue
        return task
    }

    /// This mutation is over, and the next one may go.
    ///
    /// Inside the task that owns it rather than in the caller that started it, for the reason
    /// `deleteAttachment` clears its own slot there — and by claim rather than by position, so an
    /// invocation can only ever take its own place out of the line.
    ///
    /// MEMBERSHIP first: a lane may give its place up before its task ends, and an identity change
    /// empties the line under every task still running. The claim counter is never reset, so a
    /// number from a line that has gone matches nothing here — asking whether this claim is still
    /// in the line is what keeps a departed mutation from retiring a living one's place.
    private func finishMutation(_ claim: Int, on uid: String) {
        guard var queue = mutations[uid], queue.contains(where: { $0.claim == claim }) else {
            return
        }
        queue.removeAll { $0.claim == claim }
        mutations[uid] = queue.isEmpty ? nil : queue
    }

    /// Changes who can see a memo.
    ///
    /// It takes a `VisibilityChange` rather than a bare visibility so that a widening reaches the
    /// wire only as the yes to its question: the rule lives in that type, not in the screens that
    /// call this. Two identical changes overlapping are JOINED into one request (`claimMutation`).
    ///
    /// A change that has become a widening while it waited answers `.ask` with its question and
    /// sends nothing (MEMNG-981); the caller asks it like any widening and sends only the yes.
    @discardableResult
    public func setVisibility(
        _ change: VisibilityChange,
        uid: String,
        through queue: (any MemoEditQueue)? = nil,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        await setVisibilityAnswering(
            change, uid: uid, through: queue, using: handle, baseURL: baseURL
        ).outcome
    }

    /// `setVisibility`, handing back the memo the server answered with as well (MEMNG-970): the
    /// viewer's Info sheet shows a memo this list may not hold, and the chip there reflects the
    /// server's answer rather than the pick. The SAME line as the long press and the edit sheet,
    /// so a chip, a long press and a Save on one memo are one queue, and a caller that joins an
    /// identical change in line is handed the same memo.
    public func setVisibilityAnswering(
        _ change: VisibilityChange,
        uid: String,
        through queue: (any MemoEditQueue)? = nil,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> MemoMutationAnswer {
        let identity = MemoMutationIdentity.visibility(change.to, confirmed: change.confirmed)
        return await claimMutation(identity, on: uid) { [self] claim in
            // The edit job's PATCH carries the audience its sheet stated (MEMNG-954), so a change
            // sent beside it would be put back by it: refused inside this memo's line, as
            // `performEdit` refuses an edit, and asked before the request's own session check.
            if let queue, await queue.hasUnfinishedEdit(memoUID: uid) {
                mutationChangedNothing(claim, on: uid)
                return MemoMutationAnswer(.failed(.editPending))
            }
            if let question = visibilityReask(change, on: uid) {
                mutationChangedNothing(claim, on: uid)
                return MemoMutationAnswer(.ask(question))
            }
            return await patchAnswer(
                uid: uid, .init(visibility: change.generated), claim: claim, using: handle,
                baseURL: baseURL)
        }.value
    }

    /// The widening rule asked again once the line reached the change, against where the memo now
    /// stands: the loaded row, else the audience this store last put on the wire for it, else the
    /// change's own `from`. The middle term is the memo that LEFT the list while its line ran — an
    /// archive between two changes takes the row away, and the change behind it must not then be
    /// judged against the audience it was proposed over (MEMNG-981). An absent row with nothing
    /// sent is not "unknown": a narrowing from a memo outside the loaded list goes as it is.
    ///
    /// While the memo's last visibility PATCH is unanswered (`unsettledVisibility`) the row is what
    /// the memo was before it and the record what it asked for, and the server may hold either: the
    /// change is judged over the narrower of the two, so it is asked whenever it widens from either
    /// (MEMNG-1033).
    private func visibilityReask(_ change: VisibilityChange?, on uid: String)
        -> VisibilityChange.Question?
    {
        guard let change else { return nil }
        let row = memos.first { $0.uid == uid }?.visibility
        let sent = sentVisibility[uid]
        if unsettledVisibility[uid] != nil, let row, let sent {
            return change.reask(over: VisibilityChange.narrower(row, sent))
        }
        return change.reask(over: row ?? sent)
    }

    /// The audience each memo was last asked to have by a request this store SENT, written the
    /// moment the PATCH goes (`patchAnswer`): a request that went may have been applied, so it is
    /// the memo's last known audience until the server says otherwise. It says so three ways
    /// (MEMNG-1033): a refusal of that request puts back what was recorded before it, and its
    /// confirmation, or a read no mutation of the memo was in line for, replaces the entry with the
    /// server's own word — a change made on the web or by another store included. One account's
    /// memos, so it goes with the identity (`sessionIdentityChanged`).
    private var sentVisibility: [String: MemoVisibility] = [:]

    /// The memos whose last PATCH naming an audience went and was never answered, so the server
    /// may hold either the row's audience or the one sent (`visibilityReask`). Cleared by the next
    /// statement of the server's about the memo (`recordServerAudience`); a refusal of a LATER
    /// request says nothing about what became of this one, so it clears nothing.
    ///
    /// Each holds the sequence stamp taken the moment the loss was recorded. The fence alone cannot
    /// tell a read issued after the loss from one issued while the request was in line — both are
    /// unfenced once its claim is gone — and only the first can say what became of it.
    private var unsettledVisibility: [String: Int] = [:]

    /// What `sentVisibility` held for a memo before a PATCH naming its audience overwrote it.
    private struct PriorRecord {
        let visibility: MemoVisibility?
    }

    /// What one PATCH's end says about the record it wrote. Only while its claim is still in line:
    /// an identity change empties both the claims and the record, and putting the outgoing
    /// identity's entry back would resurrect it under the incoming one.
    private func settleRecord(
        _ prior: PriorRecord?, of claim: Int, on uid: String, _ effect: MemoMutationEffect
    ) {
        guard let prior, fences[uid]?.claims[claim] != nil else { return }
        switch effect {
        case .changedNothing: sentVisibility[uid] = prior.visibility
        case .outcomeUnknown: unsettledVisibility[uid] = nextMutationSequence()
        }
    }

    /// The server's own word about a memo's audience. An entry only where one exists: an absent
    /// entry already lets the asking screen's `from` stand, and a read of every page would
    /// otherwise copy the whole list in here.
    private func recordServerAudience(_ memo: Memo) {
        if sentVisibility[memo.uid] != nil { sentVisibility[memo.uid] = memo.visibility }
        unsettledVisibility[memo.uid] = nil
    }

    /// Archives a memo, or takes it back out of the archive.
    ///
    /// One call for both directions, because on the wire it IS one call: `archived` is a Boolean on
    /// `MemoPatch`, and the server turns it into a timestamp or a null (`app/services/memos.py`).
    /// A pair of methods would be two spellings of one request that could drift apart.
    ///
    /// Nothing moves before the server answers. Archiving is reversible, so an optimistic version
    /// would not be the disaster an optimistic delete is — but it would still show a memo leaving a
    /// list it is in fact still in whenever the write fails, and this store already has exactly one
    /// optimistic write (`toggleTask`) for a reason that does not apply here. What DOES happen when
    /// the answer arrives is that the memo leaves the loaded list if this list is no longer asking
    /// for it: see `apply`.
    @discardableResult
    public func setArchived(
        _ archived: Bool,
        uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        await patch(
            uid: uid, .init(archived: archived), as: .archived(archived),
            using: handle, baseURL: baseURL
        )
    }

    /// Pins or unpins through the server's own routes rather than by patching the flag: pinning
    /// is the server's decision to make (it also reorders), and a PATCH would only describe it.
    @discardableResult
    public func setPinned(
        _ pinned: Bool,
        uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        await claimMutation(.pinned(pinned), on: uid) { [self] claim in
            MemoMutationAnswer(
                await performPin(pinned, uid: uid, claim: claim, using: handle, baseURL: baseURL))
        }.value.isSaved
    }

    /// The pin itself, once every earlier mutation of this memo has finished.
    private func performPin(
        _ pinned: Bool,
        uid: String,
        claim: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        // Before the first request and AFTER whatever this memo's line made it wait for, for the
        // reason `performEdit` asks before its uploads.
        guard sessionStillCurrent(handle) else {
            mutationChangedNothing(claim, on: uid)
            return .failed(.authorization)
        }
        guard !serverConfirmedDeletion(of: uid) else {
            mutationChangedNothing(claim, on: uid)
            return .failed(.rejection)
        }

        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        do {
            // Each response is switched on rather than reached through the generated throwing
            // accessors: those throw an untyped "unexpected status" error, and a refusal that does
            // not arrive as the API's own refusal case never reaches the rule that ends the session.
            let json: Components.Schemas.MemoOut
            if pinned {
                switch try await client.pinMemoApiMemosUidPinPost(.init(path: .init(uid: uid))) {
                case .ok(let ok): json = try ok.body.json
                case .unprocessableContent: throw APIError.server(status: 422)
                // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
                case .serviceUnavailable: throw APIError.fromStatus(503)
                case .undocumented(let statusCode, _): throw APIError.fromStatus(statusCode)
                }
            } else {
                switch try await client.unpinMemoApiMemosUidUnpinPost(
                    .init(path: .init(uid: uid))
                ) {
                case .ok(let ok): json = try ok.body.json
                case .unprocessableContent: throw APIError.server(status: 422)
                // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
                case .serviceUnavailable: throw APIError.fromStatus(503)
                case .undocumented(let statusCode, _): throw APIError.fromStatus(statusCode)
                }
            }
            // Pinning is also a MOVE, and a move is a new lineage: it goes through `apply`,
            // whose re-place branch bumps the generation, so a page in flight measured against
            // the old order drops on arrival instead of merging around the moved memo (review
            // round: `placed` called here directly bypassed exactly that fence).
            guard sessionStillCurrent(handle) else {
                mutationOutcomeUnknown(claim, on: uid)
                return .failed(.authorization)
            }
            let updated = Memo(json, baseURL: baseURL)
            // Before the apply, which awaits: a line cleared afterwards would be cleared for
            // whatever session the answer came back into.
            lastError = nil
            await apply(updated, under: authority, confirming: claim)
            return .saved
        } catch {
            mutationFailed(claim, on: uid, with: error)
            await report(error, issuedUnder: handle)
            return .failed(ComposeFailure.classify(error, sent: true))
        }
    }

    /// Deletes a memo. The row goes when the server says it is gone, not before: a delete that
    /// failed and left the row on screen is recoverable, one that vanished optimistically is not.
    @discardableResult
    public func delete(uid: String, using handle: SessionHandle) async -> Bool {
        // Two calls for one memo JOIN, exactly as two calls for one attachment do: the caller's
        // question — "is it gone?" — has one true answer, and a second DELETE for a memo the first
        // has already removed comes back 404 and reads as a fact about a memo this app deleted
        // itself.
        await claimMutation(.delete, on: uid) { [self] claim in
            MemoMutationAnswer(await performDelete(uid: uid, claim: claim, using: handle))
        }.value.isSaved
    }

    /// The delete itself, once every earlier mutation of this memo has finished.
    private func performDelete(
        uid: String, claim: Int, using handle: SessionHandle
    ) async -> ComposeOutcome {
        // Before the first request and AFTER whatever this memo's line made it wait for, for the
        // reason `performEdit` asks before its uploads.
        guard sessionStillCurrent(handle) else {
            mutationChangedNothing(claim, on: uid)
            return .failed(.authorization)
        }
        // Beside that question, for the reason `performEdit` asks it: a delete that queued behind
        // another delete of the same memo cannot join it when a save stands between them, and its
        // DELETE would be the 404 this store reads as a fact about a memo it removed itself. The
        // ANSWER differs from every other lane because the question does: `delete` asks "is it
        // gone?", and for a memo the server has confirmed gone the true answer is yes.
        guard !serverConfirmedDeletion(of: uid) else {
            mutationChangedNothing(claim, on: uid)
            return .saved
        }

        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        // Before the send, while the row may still be held: the pictures the listener is told
        // went with the memo. A memo this list does not hold — a detail opened from elsewhere —
        // reports none, which still retires every count and span (MEMNG-809).
        let pictures = memos.first(where: { $0.uid == uid }).map { Set($0.attachments.map(\.uid)) }
        let landed = pictures == [] ? nil : onPicturesDeleted?()
        do {
            let response = try await client.deleteMemoApiMemosUidDelete(
                .init(path: .init(uid: uid))
            )
            switch response {
            case .noContent:
                guard sessionStillCurrent(handle) else {
                    mutationOutcomeUnknown(claim, on: uid)
                    // Gone from the server all the same: the listener judges it by the identity
                    // the delete was issued under, as it does a Library run a renewal stopped.
                    if let landed { await landed(pictures ?? [], handle) }
                    return .failed(.authorization)
                }
                // A memo that is gone owes nothing: there is no row for a read to repair, and a
                // payment made against it would be a GET the server answers 404. Dropped BEFORE
                // the stamp below, which is what would otherwise find the debt due and pay it.
                owedReads[uid] = nil
                // Written in the same breath as the stamp below, with nothing awaited between, so
                // that the next lane to resume for this memo cannot ask before the answer that
                // settled it has been written down.
                confirmedDeletions.insert(uid)
                // Stamped before the commit below and before anything suspends, for the reason
                // `apply` stamps at its top: the memo is gone whether or not a row stood for it.
                mutationApplied(claim, on: uid)
                // The memo is gone from the server as well, so any page still in flight — read
                // while the memo was still there, and cursor pages overlap — would put it back on
                // screen. It belongs to the list that still had this row; this one does not.
                timelineGeneration += 1
                lastError = nil
                await commit(memos.filter { $0.uid != uid }, under: authority)
                if let landed { await landed(pictures ?? [], handle) }
                return .saved
            // The contract documents this one now. It arrived as `.undocumented(404)` before and
            // is thrown exactly as it was: a memo that is already gone is a fact about the server,
            // not a licence to take the row off screen without one.
            case .notFound:
                throw APIError.fromStatus(404)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
            case .serviceUnavailable:
                throw APIError.fromStatus(503)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            mutationFailed(claim, on: uid, with: error)
            await report(error, issuedUnder: handle)
            return .failed(ComposeFailure.classify(error, sent: true))
        }
    }

    /// Removes ONE picture or clip from a memo it is already posted on.
    ///
    /// The server hard-deletes: the row, the original and every derived tier go, and there is no
    /// trash to take them back out of. So nothing moves here before the 204 arrives, exactly as the
    /// whole-memo delete waits for its own — and, unlike that one, nothing about the LIST changes,
    /// so `timelineGeneration` is deliberately left alone. That counter is the list's lineage
    /// (`refresh` bumps it, so does a memo leaving or moving in `apply`); fencing this call on it
    /// would throw away a real 204 whenever somebody pulled to refresh while the request was out.
    /// What this delete needs instead is a memory of what it removed: `removedAttachments`.
    ///
    /// Two calls for one attachment JOIN: the second awaits the first's answer and sends nothing.
    /// The caller's question — "is it gone?" — has one true answer, and a second DELETE for a uid
    /// the first one has already removed would come back 404 and be read as a fact about a file
    /// this app deleted itself. The slot is claimed BEFORE the first suspension point, so two taps
    /// arriving in one turn of the main actor cannot both find it empty.
    @discardableResult
    public func deleteAttachment(
        uid: String,
        from memoUID: String,
        using handle: SessionHandle
    ) async -> Bool {
        if let running = attachmentDeletions[uid] { return await running.value }
        let deletion = Task { [self] in
            let outcome = await performAttachmentDelete(
                uid: uid, from: memoUID, using: handle
            )
            // Cleared HERE rather than by the caller that started it, for the reason
            // `SessionStore.renewDeviceToken` clears its own slot inside the task: that caller can
            // be resumed long after a later one has legitimately begun the next delete of this
            // uid, and clearing it then would drop the later one's handle.
            self.attachmentDeletions[uid] = nil
            return outcome
        }
        attachmentDeletions[uid] = deletion
        return await deletion.value
    }

    private func performAttachmentDelete(
        uid: String,
        from memoUID: String,
        using handle: SessionHandle
    ) async -> Bool {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        // Asked HERE, before the send, and not only of the answer below. This runs in a Task of
        // its own (`deleteAttachment` claims the slot and spawns), so the session can be withdrawn
        // between the handle being captured and this body starting — and a DELETE is not a read:
        // an answer discarded afterwards does not put the file back.
        guard sessionStillCurrent(handle) else { return false }
        // Asked before the send, for the reason the memo delete asks it (MEMNG-809).
        let landed = onPicturesDeleted?()
        do {
            let response = try await client.deleteAttachmentApiAttachmentsUidDelete(
                .init(path: .init(uid: uid))
            )
            switch response {
            case .noContent:
                break
            case .unprocessableContent:
                throw APIError.server(status: 422)
            // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
            case .serviceUnavailable:
                throw APIError.fromStatus(503)
            case .undocumented(let statusCode, _):
                // A 404 says the same thing a 204 does: the file is not on the server. It is what
                // the web app deleting it first looks like, and what a retry of a request whose
                // answer was lost looks like. Reporting it would put "That item no longer exists"
                // over a picture that has indeed stopped existing, which is what was asked for.
                guard statusCode == 404 else { throw APIError.fromStatus(statusCode) }
            }
            guard sessionStillCurrent(handle) else {
                // Gone from the server all the same: see the memo delete's twin of this branch.
                await landed?([uid], handle)
                return false
            }
            // Before the forget, which awaits its way to the disk: see `setPinned`.
            lastError = nil
            await forget(uid, from: memoUID, under: authority)
            await landed?([uid], handle)
            return true
        } catch {
            await report(error, issuedUnder: handle)
            return false
        }
    }

    /// The attachment is gone from the server; make it gone from this list, and stay gone.
    ///
    /// In place, by uid: the memo's own ordering keys did not move, so it keeps its position and
    /// nothing is re-placed. The tombstone is what the rest of the store reads — see `admitted`.
    private func forget(_ attachment: String, from memoUID: String, under authority: Int) async {
        removedAttachments.insert(attachment)
        guard let position = memos.firstIndex(where: { $0.uid == memoUID }) else { return }
        var next = memos
        next[position].attachments.removeAll { $0.uid == attachment }
        await commit(next, under: authority)
    }

    /// The delete in flight for each attachment uid, so a second call for one of them joins it
    /// rather than sending a sibling request.
    private var attachmentDeletions: [String: Task<Bool, Never>] = [:]

    /// The attachments this session has watched the server confirm gone.
    ///
    /// It exists because a response can outlive the delete that made it wrong. Every read this
    /// store has out at that moment — a page, a reconciling read, an edit's own answer — describes
    /// the memo as it was BEFORE the file was removed, and each of them carries the attachment
    /// back in on arrival. Nothing else can tell those answers apart from the truth: they are
    /// well-formed, current-looking and simply older than one fact.
    ///
    /// Never cleared. A uid the server hard-deleted cannot legitimately come back — the row and
    /// the files are gone and a new upload gets a new uid — so there is nothing for an expiry to
    /// protect against, and the set is bounded by the deletes one session makes.
    private var removedAttachments: Set<String> = []

    /// The one door a server memo comes through, with everything this list knows to be gone
    /// stripped off it.
    ///
    /// Every site that takes a `Memo` from the server calls this: the first page (`refresh`), the
    /// next one (`loadMore`), the block above (`loadNewer`), a created memo (`create`), the copy
    /// `fetchMemo` hands its caller, and `apply` — which is where the reconciling read, an edit's
    /// answer, a pin, an archive and a ticked checkbox all land. A funnel rather than a check in
    /// each of them because the failure mode is a lane somebody forgets, and one that has to be
    /// remembered six times is one that will be.
    private func admitted(_ memo: Memo) -> Memo {
        guard !removedAttachments.isEmpty else { return memo }
        var admitted = memo
        admitted.attachments.removeAll { removedAttachments.contains($0.uid) }
        return admitted
    }

    private func admitted(_ memos: [Memo]) -> [Memo] {
        guard !removedAttachments.isEmpty else { return memos }
        return memos.map { admitted($0) }
    }

    /// The rows of a read that may still be published, judged against the instant the read LEFT.
    ///
    /// A memo whose row has moved since then keeps the row this store holds: the read was asked
    /// before the change and cannot be the newer word about it, however current its answer looks.
    /// With no row loaded there is nothing to keep — and nothing this store is entitled to put on
    /// the list at a version it already knows to be behind — so the memo is dropped instead.
    ///
    /// Records the owed read wherever a loaded row is kept: the one read on its way to bring the
    /// server's own version of that row was refused here, and the debt is what remembers it.
    private func effective(
        _ page: [Memo],
        issuedAt issued: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) -> [Memo] {
        page.compactMap { memo in
            guard fenced(memo.uid, issuedAt: issued) else {
                serverStillHolds(memo, issuedAt: issued)
                return memo
            }
            guard let loaded = memos.first(where: { $0.uid == memo.uid }) else { return nil }
            owedReads[memo.uid] = OwedRead(handle: handle, baseURL: baseURL)
            // A row held by a mutation that has already applied has nothing left to wait for.
            payOwedRead(for: memo.uid)
            return loaded
        }
    }

    /// The one row a reconciling read may apply, judged against the instant the read LEFT.
    ///
    /// Held rows keep what the loaded row says about the MEMO — its content, its visibility, which
    /// attachments it has — because a read older than the change speaks about none of it. What the
    /// read is still the only word on is how far each of those attachments has got: a transcode is
    /// the server's business alone and no mutation of the memo makes a statement about it. So the
    /// membership is the row's and each member is taken from the read's copy of that same uid.
    ///
    /// Nil when no row is loaded: there is nothing to carry the read's word into, and `apply`
    /// discards a memo the list does not hold anyway.
    ///
    /// Records the owed read for the same reason the page overload does.
    private func effective(
        _ merged: Memo,
        reconciledAt issued: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) -> Memo? {
        guard fenced(merged.uid, issuedAt: issued) else {
            serverStillHolds(merged, issuedAt: issued)
            return merged
        }
        guard let loaded = memos.first(where: { $0.uid == merged.uid }) else { return nil }
        owedReads[merged.uid] = OwedRead(handle: handle, baseURL: baseURL)
        payOwedRead(for: merged.uid)
        var held = loaded
        held.attachments = loaded.attachments.map { attachment in
            merged.attachments.first { $0.uid == attachment.uid } ?? attachment
        }
        return held
    }

    /// Re-reads ONE memo from the server and applies it to the loaded list.
    ///
    /// The live media channel is what ends the waiting now, so this is no longer a poll. It is the
    /// single reconciling read `MediaChannel.reconcile` makes when the channel starts, for the one
    /// case the stream cannot report: an attachment that finished while no connection was open is
    /// in no snapshot the server compares against, so nothing on the stream will ever mention it.
    /// It goes through the same `apply` an edit does, so the answer lands in the card that is
    /// already on screen instead of appearing as a new row.
    ///
    /// A failure is deliberately NOT reported into `lastError`: this runs in the background,
    /// behind a screen nobody asked to refresh, and a blip on it must not paint an error banner
    /// over a timeline that is working. A refusal is different — it ends the session wherever it
    /// happens — so that one is still handed on.
    ///
    /// It is also MERGED around whatever the stream said while it was in the air. The answer
    /// describes the memo as it was when the request went out, so an attachment an event moved in
    /// the meantime is kept as the stream left it while the rest of the answer — including the
    /// attachments no event will ever mention, which are the reason this pass exists — still
    /// lands. `reconciled(_:issuedWith:replaying:)` is that rule; `true` therefore still means what
    /// it always did, that the read reached the list.
    ///
    /// Only this lane is merged: `fetchMemo` answers a caller that needs the memo it asked for,
    /// and an ordinary edit or refresh is a reader's own action rather than a background snapshot,
    /// so a re-transcode that honestly returns an attachment to waiting still reaches the list
    /// through those.
    ///
    /// Two reads of the SAME memo under the same session JOIN: the second sends nothing and awaits
    /// the first's outcome. Left overlapping they undo each other — both are handed whatever the
    /// stream says while they are out, the first replays it onto the attachment its answer
    /// introduces, and the second, whose answer describes that attachment as it was before, now
    /// finds it HELD, skips its own replay and writes the older snapshot over it. Joining rather
    /// than refusing, because the caller's question is "is this card up to date now", which a
    /// refusal does not answer. The slot is claimed BEFORE the first suspension point, so two
    /// passes arriving in one turn of the main actor cannot both find it empty; it is keyed by the
    /// session incarnation as well as the memo, because a read issued by a session that has since
    /// been replaced is not the read a later caller is asking for.
    @discardableResult
    public func refreshMemo(
        uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        let slot = ReconcileSlot(uid: uid, generation: handle.generation)
        if let running = reconcileJoins[slot] { return await running.value }
        let read = Task { [self] in
            let outcome = await performReconcilingRead(uid: uid, using: handle, baseURL: baseURL)
            // Cleared HERE rather than by the caller that started it, for the reason
            // `deleteAttachment` clears its own slot inside the task: that caller can be resumed
            // long after a later one has legitimately begun the next read of this memo.
            self.reconcileJoins[slot] = nil
            return outcome
        }
        reconcileJoins[slot] = read
        return await read.value
    }

    /// One memo, read from the server once and merged into the list. `refreshMemo`'s body, behind
    /// the slot that makes two overlapping calls for one memo a single request.
    private func performReconcilingRead(
        uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        // Read BEFORE the request goes out. What it is compared against on the way back is which
        // attachments the stream spoke about while the answer was in the air.
        let appliedWhenIssued = liveApplications
        // The same instant, on the other side of the same problem. An event about an attachment no
        // loaded row holds yet moves nothing, so it is never counted above and nothing else
        // remembers it — and THIS read may be the one that introduces that attachment. So the read
        // declares itself in flight and every such event is kept against ITS number, to be spent on
        // its own answer: the fence is the generation that issued the request, never the list as it
        // stands when the answer lands. The close is unconditional, so a read that fails, is
        // refused or is superseded takes what it kept with it (MEMNG-197).
        let readID = openReconcileRead()
        defer { closeReconcileRead(readID) }
        // The mutation instant, alongside the two above it and read the same way: before the
        // request, so what comes back is judged against when it was asked rather than when it
        // landed.
        let issued = mutationSequence
        let favoritesIssued = favoriteStamp
        do {
            let response = try await client.getMemoApiMemosUidGet(.init(path: .init(uid: uid)))
            switch response {
            case .ok(let ok):
                guard sessionStillCurrent(handle) else { return false }
                let read = fencedFavorites(
                    Memo(try ok.body.json, baseURL: baseURL), favoritesIssued)
                // A memo changed since this read was asked keeps the row this store holds, with
                // only the attachment states the read carries — that part of the answer is about
                // nothing a mutation of the memo touched. The read HAPPENED either way, so the
                // caller is told so and does not ask again on the strength of a refusal it caused.
                guard
                    let row = effective(
                        reconciled(
                            read,
                            issuedWith: appliedWhenIssued,
                            replaying: reconcileReads[readID] ?? [:]
                        ),
                        reconciledAt: issued,
                        using: handle,
                        baseURL: baseURL
                    )
                else { return true }
                await apply(row, under: authority)
                return true
            case .unprocessableContent:
                throw APIError.server(status: 422)
            // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
            case .serviceUnavailable:
                throw APIError.fromStatus(503)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            // Same rule as `report`: a refusal about a session that has ended must not end this one.
            guard sessionStillCurrent(handle) else { return false }
            if let refusal = StoreFailure.refusal(error) { _ = await onUnauthorized(refusal) }
            return false
        }
    }

    /// One reconciling read, merged around whatever the stream said while it was in the air.
    ///
    /// Attachment by attachment, because neither wholesale answer is right. Taking the read whole
    /// talks an attachment the stream has already finished back out of that state, and nothing
    /// says it again. Dropping the read whole strands the attachments the stream CANNOT speak
    /// about — the ones that finished before the connection took its snapshot, which is the entire
    /// reason this pass exists — and dropping is not a delay but a loss: while a sibling is
    /// mid-transcode its events keep arriving, so every retry lands in the same window.
    ///
    /// So each attachment comes from whichever source spoke about it LAST: the loaded list, for
    /// the ones an event moved since this read went out, and the read for all the rest. Everything
    /// no event can carry — the content, the visibility, the dates, an attachment added or removed
    /// since — is the read's, because on those the read is the only word there is.
    ///
    /// An attachment this read INTRODUCES has no history to be judged against: the loaded row does
    /// not hold it, so an event about it moved nothing and was counted nowhere. Those are the ones
    /// the read kept while it was in the air, and they are replayed here IN ORDER, on top of the
    /// read, through the same pure transform the live channel uses — so the terminal-versus-
    /// in-flight rule is the one rule it has always been, rather than a second copy of it written
    /// for this lane, and a sequence of them lands exactly as it would have landed live.
    private func reconciled(
        _ read: Memo,
        issuedWith applications: [String: Int],
        replaying retained: [String: [MediaEvent]]
    ) -> Memo {
        guard let loaded = memos.first(where: { $0.uid == read.uid }) else { return read }
        var merged = read
        merged.attachments = read.attachments.map { attachment in
            guard liveApplications[attachment.uid] != applications[attachment.uid],
                let moved = loaded.attachments.first(where: { $0.uid == attachment.uid })
            else { return attachment }
            return moved
        }
        guard !retained.isEmpty else { return merged }
        let alreadyHeld = Set(loaded.attachments.map(\.uid))
        for uid in merged.attachments.map(\.uid) where !alreadyHeld.contains(uid) {
            for event in retained[uid] ?? [] {
                let before = merged.attachments.first { $0.uid == uid }
                merged = applyMediaEvent(event, to: [merged]).first ?? merged
                guard merged.attachments.first(where: { $0.uid == uid }) != before else { continue }
                // Counted exactly as the live path counts it. This IS a live application, taken
                // late: without the count, the next answer to land would find no change against
                // its own snapshot, decide the read is the newer word on this attachment, and put
                // the state the event replaced straight back.
                liveApplications[uid, default: 0] += 1
            }
        }
        return merged
    }

    /// Reads ONE memo from the server and hands it back, whether or not this list holds it.
    ///
    /// It is the companion `refreshMemo` cannot be. That one exists to update a card already on
    /// screen and goes through `apply`, which DISCARDS a memo the list does not contain — correct
    /// for a reconciling read, and exactly wrong for the case this answers: a memo reached from the
    /// media library is very often a hundred cursor pages down a list that has never loaded it, and
    /// the detail screen needs a `Memo` value to open with. So the server's answer is returned
    /// rather than swallowed, and the loaded list is left as it is (MEMNG-191).
    ///
    /// Applied on the way past when the list DOES hold it, because a screen about to show this memo
    /// should show the same copy the card behind it does.
    public func fetchMemo(
        uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Memo? {
        guard case .memo(let memo) = await readMemo(uid: uid, using: handle, baseURL: baseURL)
        else { return nil }
        return memo
    }

    /// How one read of a single memo ended.
    ///
    /// The distinction a `Memo?` cannot carry: a request the server never ANSWERED is not the
    /// server saying the memo is gone, and a caller that cannot tell them apart tells the reader
    /// a memo that exists is no longer here.
    private enum SingleMemoRead {
        case memo(Memo)
        /// The server said there is no such memo — or the session this was read for is over,
        /// which is the same nothing as far as the caller is concerned.
        case absent
        /// The read failed and nothing in it says the memo is gone: the server never answered,
        /// or it answered with something that is not an answer about this memo. A transport
        /// failure has already been reported to the session by the incarnation that asked,
        /// exactly as a page read reports it; anything the server did answer stays here.
        case unreadable
    }

    /// `fetchMemo`'s body, keeping what the caller needs to say the right sentence.
    private func readMemo(
        uid: String,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> SingleMemoRead {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        // Read before the request, as every other read of this store reads it.
        let issued = mutationSequence
        let favoritesIssued = favoriteStamp
        do {
            let response = try await client.getMemoApiMemosUidGet(.init(path: .init(uid: uid)))
            switch response {
            case .ok(let ok):
                guard sessionStillCurrent(handle) else { return .absent }
                let memo = admitted(
                    fencedFavorites(Memo(try ok.body.json, baseURL: baseURL), favoritesIssued))
                // Changed since this read was asked: the loaded row is the newer word, so it is
                // what the caller opens the memo with, and nothing is applied over it. No
                // per-attachment rule here — this lane merges nothing, it hands a memo over.
                let loaded = memos.first { $0.uid == memo.uid }
                let heldBack = fenced(memo.uid, issuedAt: issued)
                if heldBack, let loaded {
                    owedReads[memo.uid] = OwedRead(handle: handle, baseURL: baseURL)
                    payOwedRead(for: memo.uid)
                    return .memo(loaded)
                }
                // Asked separately from the branch above, because the fall-through is also where
                // a FENCED read with no loaded row lands, and that read is too old to say the
                // memo exists.
                if !heldBack {
                    serverStillHolds(memo, issuedAt: issued)
                }
                await apply(memo, under: authority)
                // AGAIN, after the apply: it awaits its way to the disk, and the memo below is
                // one account's own — handing it to a caller that has become somebody else is an
                // effect exactly as much as writing it would be.
                guard sessionStillCurrent(handle) else { return .absent }
                return .memo(memo)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
            case .serviceUnavailable:
                throw APIError.fromStatus(503)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            // A memo that cannot be read is a navigation that does not happen, which the caller can
            // see from the answer. A refusal still ends the session wherever it happens — as long
            // as it is THIS session the refusal was about.
            guard sessionStillCurrent(handle) else { return .absent }
            if let refusal = StoreFailure.refusal(error) {
                _ = await onUnauthorized(refusal)
                return .absent
            }
            // Gone is something only the server can say, and it says it with a 404. A 500, a 422,
            // a body that would not decode are all failures of the READ: answering `absent` to
            // any of them tells the reader a memo that exists is no longer there, which is the
            // same false sentence a dropped request used to produce.
            if let api = error as? APIError, api == .notFound { return .absent }
            // A server that never answered is the SESSION's to say, once, in its banner — the same
            // sentence every page read reports (`report`), under the generation that ISSUED this
            // request rather than whichever one is current when the failure lands. Swallowing it
            // here is what told a reader that a memo which exists is no longer there, while the
            // one notice that could have explained it never heard of the outage. An error the
            // server DID answer with is not that notice's business and is not reported to it.
            if let failure = StoreFailure.transportFailure(error) {
                session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            }
            return .unreadable
        }
    }

    /// What a jump to a memo ended as.
    public enum MemoJumpOutcome: Equatable, Sendable {
        /// The loaded window now HOLDS it, so this store owns it and an edit made on it lands here.
        case ready(Memo)
        /// It could not be read, or it is not in the window even after anchoring — deleted while
        /// the jump was in flight, or filtered out of the list this screen is showing.
        case unavailable
        /// The read failed, and nothing in that failure says the memo is gone — the server never
        /// answered, or what it answered was an error of its own. When it was the server that
        /// could not be reached the session has been told; either way the caller owes the reader
        /// a sentence that does not claim the memo is no longer there.
        case unreadable
    }

    /// Takes this timeline to a memo, and does not come back until the LOADED WINDOW contains it.
    ///
    /// Fetching the memo is not enough and that is the whole point of this function. A value handed
    /// to the detail screen with no copy in `memos` is a read-only memo: `apply` drops any memo the
    /// list does not hold (see `apply` above), so an edit, a pin, or a checklist tap made on it is
    /// discarded on the way back and the screen silently reverts. So the list is ANCHORED at the
    /// memo's own day — the same landing a day chosen on the heatmap gets — and the window that
    /// comes back is what owns it from then on (MEMNG-191).
    public func jump(
        to uid: String,
        calendar: Calendar,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> MemoJumpOutcome {
        let memo: Memo
        switch await readMemo(uid: uid, using: handle, baseURL: baseURL) {
        case .memo(let read): memo = read
        case .absent: return .unavailable
        case .unreadable: return .unreadable
        }
        // Already on screen: the read applied the server's copy into it, and nothing needs
        // moving.
        if memos.contains(where: { $0.uid == uid }) { return .ready(memo) }
        guard let anchor = MemoQueryAnchor.day(of: memo.createdAt, in: calendar) else {
            return .unavailable
        }
        setQuery(MemoQuery(anchor: anchor))
        await refresh(using: handle, baseURL: baseURL)
        // The refresh awaits its way to the disk as well as to the server, and what comes back
        // from here is a MEMO — the screen it opens belongs to whoever owns the session now.
        guard sessionStillCurrent(handle) else { return .unavailable }
        // Anchored and still absent. Pushing now would open a screen whose edits go nowhere, so
        // the caller is told instead.
        guard memos.contains(where: { $0.uid == uid }) else { return .unavailable }
        return .ready(memo)
    }

    /// Applies one live media event to the loaded timeline.
    ///
    /// The transform itself is `applyMediaEvent`, which is pure and shared in spirit with the SPA's
    /// version of the same name; this is only where it meets the observable list.
    ///
    /// It writes back ONLY when something actually moved. A transcode emits an event roughly every
    /// one and a half seconds as its percentage climbs (memos-ng `app/routers/assets.py:766`), and
    /// this app shows no percentage — so most of those events change nothing a reader can see.
    /// Assigning the array anyway would re-render the whole timeline once per event for a value
    /// nothing on screen reads, which is the shape of the reconnect churn this channel is supposed
    /// not to have.
    public func apply(_ event: MediaEvent) async {
        // Entry IS the issue point for an event: nothing was asked of the server, the stream said
        // something and this is the moment it is acted on.
        await apply(event, under: issuedAuthority())
    }

    private func apply(_ event: MediaEvent, under authority: Int) async {
        let next = applyMediaEvent(event, to: memos)
        guard next != memos else {
            // Nothing moved, so nothing counted it — and an event nothing counted is an event
            // nothing repeats. If a reconciling read is in the air it may be the read that
            // introduces this attachment, and this is the only word about it there will ever be.
            keepForReadsInFlight(event)
            return
        }
        // This event is the newer word on this attachment, and it has just been applied where
        // everything can see it. Anything a read is still holding about the same file is older
        // than it and must never be replayed over it — a duplicate `failed` kept a moment before
        // the retry's `ready` would otherwise come back as the failure, on any landing that finds
        // the attachment gone from the loaded row.
        retireKept(event.uid)
        // The one attachment this event named, and only because it really moved: a read already
        // in the air is now the older word on THIS file and still the newer word on every other
        // one — see `reconciled(_:issuedWith:replaying:)`.
        liveApplications[event.uid, default: 0] += 1
        await commit(next, under: authority)
    }

    /// Takes one live event this list cannot apply, only so a read in the air can have it.
    ///
    /// The channel decides what an event MEANS before any store is touched, and an event about an
    /// attachment no loaded row holds means `.unchanged`: nothing a reader can see moves. That is
    /// right about the LIST and silent about the READ — an attachment absent from every row is
    /// exactly what a reconciling read is about to introduce, and this store cannot keep what it is
    /// never told (MEMNG-197).
    ///
    /// Deliberately NOT `apply`: that one commits, and committing awaits the picture of this list
    /// reaching the disk. Skipping that await is the whole purpose of the `.unchanged` branch — a
    /// transcode emits an event every second and a half, most of them about attachments this list
    /// never holds — so this is synchronous, writes nothing, and does nothing at all when no
    /// reconciling read is open.
    public func keep(_ event: MediaEvent) {
        keepForReadsInFlight(event)
    }

    /// How many live media events this list has APPLIED to each ATTACHMENT.
    ///
    /// A read is a snapshot of the moment it was ISSUED, and the stream is faster than a round
    /// trip. A reconciling pass asks for a memo whose attachment is still pending; the terminal
    /// event for that attachment lands while the answer is in the air; the answer then arrives
    /// still saying `pending`. Applied, it puts a finished tile back under the waiting treatment —
    /// and nothing takes it out again, because the stream synthesises `ready` once, from a uid
    /// dropping out of the connection's snapshot (memos-ng `app/routers/assets.py:757-761`), and
    /// that has already happened.
    ///
    /// Keyed per ATTACHMENT and not per memo, because a memo's files are in different situations
    /// at the same moment: one finished before the connection took its snapshot — no event will
    /// ever mention it, and the read is the only thing that can bring it in — while another is
    /// mid-transcode, emitting an event every second and a half. A per-memo key would let the
    /// second one's chatter throw away the first one's news, and every retry would land in the
    /// same window, so the finished file would never arrive at all.
    ///
    /// It grows by one entry per attachment the stream has ever moved, which is bounded by the
    /// uploads a session sees.
    ///
    /// A replay out of `reconcileReads` turns it too, and must: an event kept while a read was in
    /// the air and applied to the attachment that read introduced is a live application that
    /// happened late, and anything landing after it has to see that it happened.
    private var liveApplications: [String: Int] = [:]

    /// What each reconciling read now in flight has been handed while it waits.
    ///
    /// Keyed by the read, and inside that by attachment, holding the events IN THE ORDER THEY
    /// ARRIVED. A sequence rather than a last-word slot, because the stream is a poll: `ready`
    /// followed by a late `processing` is an ordinary pair, and applied one after the other the
    /// late one does nothing — a finished tile is never talked back into waiting. Kept by
    /// replacement it would be the only thing left, and the finish, with the layout the worker
    /// wrote, would be gone. Replaying the sequence in order through the same transform the live
    /// channel uses is what makes keeping equivalent to having been there.
    ///
    /// What bounds it: an entry exists only between `openReconcileRead` and the `defer` that
    /// closes it — one round trip — a live application retires everything kept about its own
    /// attachment (`retireKept`), and only events that moved NOTHING are kept at all. With no read
    /// in the air this dictionary is empty and keeping is a no-op.
    private var reconcileReads: [Int: [String: [MediaEvent]]] = [:]

    /// The number the next reconciling read is known by. Monotonic, so a read that has closed can
    /// never be confused with the one that took its place.
    private var reconcileReadsIssued = 0

    private func openReconcileRead() -> Int {
        reconcileReadsIssued += 1
        reconcileReads[reconcileReadsIssued] = [:]
        return reconcileReadsIssued
    }

    private func closeReconcileRead(_ read: Int) {
        reconcileReads[read] = nil
    }

    /// Hands one event to every reconciling read that is still waiting for its answer.
    ///
    /// Every one of them, because which memo an attachment belongs to is exactly what this list
    /// does not know yet — that is what the answer is going to say. A read whose answer does not
    /// introduce the attachment ignores what it was given; see `reconciled`.
    private func keepForReadsInFlight(_ event: MediaEvent) {
        guard !reconcileReads.isEmpty else { return }
        for read in reconcileReads.keys {
            reconcileReads[read]?[event.uid, default: []].append(event)
        }
    }

    /// Drops everything kept about one attachment, everywhere it is kept.
    ///
    /// Called when an event for that attachment MOVED the list: what is kept is by definition
    /// older than that, and older is exactly what must not be replayed later.
    private func retireKept(_ uid: String) {
        guard !reconcileReads.isEmpty else { return }
        for read in reconcileReads.keys {
            reconcileReads[read]?[uid] = nil
        }
    }

    /// The memo a reconciling read is for, and which session incarnation asked.
    private struct ReconcileSlot: Hashable {
        let uid: String
        let generation: Int
    }

    /// The reconciling read in flight for each memo, so a second call for the same one joins it
    /// instead of racing it. See `refreshMemo`.
    private var reconcileJoins: [ReconcileSlot: Task<Bool, Never>] = [:]

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
        through queue: (any MemoEditQueue)? = nil,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        // Refused, not joined, and the difference is the point: the second tap's INTENT depends on
        // what the first one turns out to have done. A join would send one request and report its
        // answer to both, which is a lie to whichever tap wanted the other state; a queue would send
        // the second tick derived from a content the server may be about to reject. One outstanding
        // toggle per memo, and the second tap is simply not taken (a store serializes its own
        // mutations).
        //
        // The claim is held until this invocation's change has LANDED on the row — the apply is an
        // await, and a tap taken inside it would be a second request on a memo whose first answer
        // is still being written down. It ends there and not later: a place in line orders the
        // requests that go out and the row each answer is applied to, and both are over once the
        // apply has returned. The picture of the list written afterwards is nobody's turn to wait
        // for — it is this store catching up with a row the person can already see and tick again.
        //
        // The refusal reaches every OTHER unfinished mutation of this memo for the same reason it
        // has always reached another tap: the tick is a whole content patch derived from the row as
        // it stands, and a save queued ahead of it is about to rewrite exactly that. Waiting its
        // turn would send words the person never typed; so the tap is not taken, and the box goes
        // back where it was.
        guard optimistic[uid] == nil, mutations[uid] == nil else { return false }
        guard let position = memos.firstIndex(where: { $0.uid == uid }) else { return false }
        let original = memos[position]
        let toggled = MemosCore.toggleTask(original.content, at: index)
        guard toggled != original.content else { return false }

        // NOT through `commit`, and that is the point: a tick nobody has confirmed is not a state
        // the next launch should open on. The memo is marked instead, which holds every OTHER
        // change out of the file until this one is answered — see `persist` and `settle`.
        optimisticClaim += 1
        let claim = optimisticClaim
        optimistic[uid] = claim
        memos[position].content = toggled
        // Its place in line is taken all the same: the tick that went out first is the one a save
        // submitted after it must be sent after.
        return await claimMutation(.task(index: index), on: uid) { [self] gate in
            MemoMutationAnswer(
                await performToggle(
                    toggled, restoring: original, in: uid, through: queue, claim: claim,
                    gate: gate, using: handle, baseURL: baseURL
                ))
        }.value.isSaved
    }

    /// The patch a tick asks for, and the rollback when the server refuses it.
    private func performToggle(
        _ toggled: String,
        restoring original: Memo,
        in uid: String,
        through queue: (any MemoEditQueue)?,
        claim: Int,
        gate: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        // A tick is a whole content PATCH, and an edit job owed to this memo froze its words
        // (MEMNG-954): its later PATCH would undo the tick. Refused inside this memo's line, as
        // `performEdit` refuses an edit, before the session question below so nothing is awaited
        // between that question and the request. Nothing was sent; the tick goes back.
        if let queue, await queue.hasUnfinishedEdit(memoUID: uid) {
            mutationChangedNothing(gate, on: uid)
            guard sessionStillCurrent(handle) else {
                release(uid, claim: claim)
                finishMutation(gate, on: uid)
                return .failed(.authorization)
            }
            let authority = issuedAuthority()
            if let current = memos.firstIndex(where: { $0.uid == uid }) {
                var restored = memos
                restored[current] = admitted(original)
                await commit(restored, under: authority)
            }
            await settle(uid, claim: claim, gate: gate, under: authority)
            return .failed(.editPending)
        }
        // Before the first request and AFTER whatever this memo's line made it wait for, for the
        // reason `performEdit` asks before its uploads. Nothing has been sent, so nothing is
        // written to the row either: a write for a session that has ended belongs to nobody, and
        // both claims go back the way the session-ended branches below give them back.
        guard sessionStillCurrent(handle) else {
            mutationChangedNothing(gate, on: uid)
            release(uid, claim: claim)
            finishMutation(gate, on: uid)
            return .failed(.authorization)
        }
        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        do {
            let response = try await client.patchMemoApiMemosUidPatch(
                .init(path: .init(uid: uid), body: .json(.init(content: toggled)))
            )
            switch response {
            case .ok(let ok):
                // The session may have ended while the patch was out. Both claims go either way —
                // the request they were held for is over — but they go AFTER the work they guard,
                // together, and never over another owner's (`release`, `finishMutation`).
                guard sessionStillCurrent(handle) else {
                    mutationOutcomeUnknown(gate, on: uid)
                    release(uid, claim: claim)
                    finishMutation(gate, on: uid)
                    return .failed(.authorization)
                }
                // Before the apply, which awaits: see `setPinned`.
                lastError = nil
                await apply(
                    Memo(try ok.body.json, baseURL: baseURL), under: authority, confirming: gate
                )
                // LAST: the apply above is awaited, and a tap taken inside it would overlap this
                // one. The settle gives up both claims and then writes whatever they were holding
                // back.
                await settle(uid, claim: claim, gate: gate, under: authority)
                return .saved
            // The contract documents this one now. It arrived as `.undocumented(404)` before and
            // is thrown exactly as it was, so the tick is rolled back and the claim released by
            // the catch below rather than left standing on a memo the server no longer has.
            case .notFound:
                throw APIError.fromStatus(404)
            // The strict linking refusal is declared on the patch too. A ticked checkbox names no
            // upload, so this is reported rather than recovered from — recovering would mean
            // re-uploading files this call never sent.
            case .conflict:
                throw APIError.server(status: 409)
            // A keyed edit that lost a race and left nothing behind. THIS path sends no key (a
            // checkbox is a whole content patch of its own), so it cannot safely repeat itself:
            // the memo is put back and the person is told, rather than the app guessing at what
            // the winner wrote.
            case .serviceUnavailable:
                // The one 503 the contract says left nothing behind, read here rather than from
                // the thrown value for the reason `patchAnswer` reads it here.
                mutationChangedNothing(gate, on: uid)
                throw APIError.server(status: 503)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            // What the failure says about the row is read where the answer arrives, before the
            // rollback below awaits anything: after the await it would be a statement about an
            // instant that has passed. Both returns in here are covered by this one reading.
            mutationFailed(gate, on: uid, with: error)
            // Put the memo back as it was. It is found by uid rather than by the index captured
            // above, because a refresh may have moved it while the request was in flight.
            //
            // Through `admitted` like every other memo this store takes in, because `original` is
            // a snapshot from BEFORE the request and the request is exactly long enough for an
            // attachment to be deleted underneath it: tick a box, delete a picture, the patch
            // fails, and a raw restore would put the picture back on a memo the server has no
            // copy of it for. The tick still rolls back — that is what the snapshot is for — and
            // only what the server has confirmed gone is left out of it.
            // The rollback is a WRITE, and a write for a session that has ended belongs to
            // nobody: the row it would put back is the previous account's, and the list it would
            // put it into is the next one's. Both claims are given up either way, and only ever
            // the ones this invocation made.
            guard sessionStillCurrent(handle) else {
                release(uid, claim: claim)
                finishMutation(gate, on: uid)
                return .failed(.authorization)
            }
            if let current = memos.firstIndex(where: { $0.uid == uid }) {
                var restored = memos
                restored[current] = admitted(original)
                await commit(restored, under: authority)
            }
            // After the rollback has landed, for the reason the success path settles last.
            await settle(uid, claim: claim, gate: gate, under: authority)
            await report(error, issuedUnder: handle)
            return .failed(ComposeFailure.classify(error, sent: true))
        }
    }

    private func patch(
        uid: String,
        _ body: Components.Schemas.MemoPatch,
        as identity: MemoMutationIdentity,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> Bool {
        await claimMutation(identity, on: uid) { [self] claim in
            await patchAnswer(uid: uid, body, claim: claim, using: handle, baseURL: baseURL)
        }.value.isSaved
    }

    /// The same request, with the reason it failed kept rather than flattened to false.
    ///
    /// Only the compose sheet needs the reason — the other callers of `patch` act on a memo that is
    /// already on screen and have the store's own error line for it — but the request may exist
    /// only once, or the two would drift apart in exactly the way a lost answer is easiest to get
    /// wrong.
    ///
    /// The patch is a SEND: by the time anything can be caught below, the request has gone out.
    /// That is what `sent: true` records, and it is the difference between "nothing changed" and
    /// "this could not be confirmed".
    ///
    /// A request the server answered hands back the memo it answered with, the memo this store
    /// applies, so a caller showing a memo this list does not hold can show the answer (MEMNG-970).
    private func patchAnswer(
        uid: String,
        _ body: Components.Schemas.MemoPatch,
        claim: Int,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> MemoMutationAnswer {
        // Before the first request and AFTER whatever this memo's line made it wait for, for the
        // reason `performEdit` asks before its uploads.
        guard sessionStillCurrent(handle) else {
            mutationChangedNothing(claim, on: uid)
            return MemoMutationAnswer(.failed(.authorization))
        }
        guard !serverConfirmedDeletion(of: uid) else {
            mutationChangedNothing(claim, on: uid)
            return MemoMutationAnswer(.failed(.rejection))
        }

        // The client and the incarnation it belongs to arrive as ONE value and are carried
        // through every request and every apply point below. Nothing here re-samples the session:
        // re-sampling is what let a request rejected as one session's reissue itself under the
        // next one's number, with the first one's client still in hand.
        let client = handle.client
        // The authority any picture this operation takes is stamped with, read ONCE here —
        // see `issuedAuthority()`.
        let authority = issuedAuthority()
        let prior = body.visibility.map { _ in PriorRecord(visibility: sentVisibility[uid]) }
        if let visibility = body.visibility { sentVisibility[uid] = MemoVisibility(visibility) }
        do {
            let response = try await client.patchMemoApiMemosUidPatch(
                .init(path: .init(uid: uid), body: .json(body))
            )
            switch response {
            case .ok(let ok):
                // The one apply point in this store that had no fence, and the one behind the
                // most entry points: `save`, `setVisibility` and `setArchived` are all this
                // method. An edit issued under one session and answered after a switch would
                // otherwise land in the next one — clearing ITS error line and telling the sheet
                // the save went through, for a session that no longer exists.
                guard sessionStillCurrent(handle) else {
                    // The server did something and no one is left to be told what: the row stays
                    // held against every read that was already on its way.
                    mutationOutcomeUnknown(claim, on: uid)
                    return MemoMutationAnswer(.failed(.authorization))
                }
                // Before the apply, which awaits: see `setPinned`.
                lastError = nil
                let answered = Memo(try ok.body.json, baseURL: baseURL)
                recordServerAudience(answered)
                await apply(answered, under: authority, confirming: claim)
                return MemoMutationAnswer(.saved, memo: answered)
            // The contract documents this one now. It arrived as `.undocumented(404)` before and
            // is thrown exactly as it was, so the sheet stays open with the reason in it rather
            // than reporting a save for a memo that is no longer there.
            case .notFound:
                throw APIError.fromStatus(404)
            // Either a named upload the server cannot link, or an edit key already bound to a
            // DIFFERENT memo. Neither is recoverable here: the uploads this call named are spent,
            // and a key is minted per (memo, edit) so a key on another memo is not a state this
            // client produces. Reported, and the sheet stays open with the words in it.
            case .conflict:
                throw APIError.server(status: 409)
            // A keyed edit that lost a race and left nothing behind — the one refusal the contract
            // says to repeat verbatim. It is repeated by the PERSON rather than by the app: the
            // save failed, the sheet is still open, and tapping Save again re-sends the identical
            // request with the identical key (`editKey(for:)`), which is exactly what the server
            // asked for. Retrying in here would also have to decide what to do about the uploads,
            // which are spent, and that decision belongs to the attempt rather than to this switch.
            case .serviceUnavailable:
                // Read here rather than from the thrown value: this is the ONE 503 the contract
                // says left nothing behind, and a 503 arriving any other way says no such thing.
                // The claim goes now, which makes the classifier below a no-op for it.
                settleRecord(prior, of: claim, on: uid, .changedNothing)
                mutationChangedNothing(claim, on: uid)
                throw APIError.server(status: 503)
            case .unprocessableContent:
                throw APIError.server(status: 422)
            case .undocumented(let statusCode, _):
                throw APIError.fromStatus(statusCode)
            }
        } catch {
            let effect = MemoMutationEffect.of(error)
            // Before the claim goes, which is what tells this request's record from one an identity
            // change has already taken — and a no-op after the 503 above, which settled its own.
            settleRecord(prior, of: claim, on: uid, effect)
            mutationEnded(claim, on: uid, effect)
            await report(error, issuedUnder: handle)
            return MemoMutationAnswer(.failed(ComposeFailure.classify(error, sent: true)))
        }
    }

    /// Replaces the loaded copy of a memo with the server's, if it is on screen at all — and
    /// MOVES it when the server's copy no longer belongs where the old one sat, or DROPS it when
    /// this list is not asking for memos in the state the server says it is now in.
    ///
    /// A memo whose display date changed has left the day it was filed under, and the timeline is
    /// cut into days: replacing it in place would leave it printed under the old date, above
    /// memos newer than it, until something else forced a refresh. So it is re-placed — and only
    /// when an ordering key actually moved, because an ordinary content edit must not reshuffle
    /// a list whose exact order came from the server.
    ///
    /// The drop is the archive: a memo archived out of a plain timeline, or restored out of the
    /// archived-only list, is a memo the request behind this list would not have returned. Keeping
    /// it would leave a row that the next refresh removes without explanation. It happens HERE, in
    /// the one place every server answer lands, so an archive made from a card, from the memo's own
    /// screen, or noticed by the reconciling read all reach the same conclusion.
    public func apply(_ memo: Memo) async {
        await apply(memo, under: issuedAuthority())
    }

    /// - Parameter claim: the mutation this memo is the server's confirmation of, if it is one.
    ///   The row is stamped HERE, before the early return below and before anything suspends: the
    ///   memo in hand is what the server says, whether or not this list has a row to put it in, and
    ///   a stamp taken after an await would be a statement about an instant that has passed.
    private func apply(_ memo: Memo, under authority: Int, confirming claim: Int? = nil) async {
        if let claim { mutationApplied(claim, on: memo.uid) }
        let memo = admitted(memo)
        guard let position = memos.firstIndex(where: { $0.uid == memo.uid }) else { return }
        // The server stamps `updated_at` on every write, so an answer older than the row already
        // held describes the memo before a change this store has since applied — an earlier edit's
        // answer arriving after a later visibility change. Judged by that stamp rather than by the
        // order the answers came in, which says nothing about the order they were written in.
        // Strictly older only: an equal stamp is the same write, or a write that changed nothing.
        guard memo.updatedAt >= memos[position].updatedAt else { return }
        guard query.admitsArchiveState(of: memo) else {
            // Same fence a delete raises, and for the same reason: a cursor page read while this
            // memo still belonged here overlaps the rows around it and would put it back.
            timelineGeneration += 1
            newerCursor = nil
            var next = memos
            next.remove(at: position)
            await commit(next, under: authority)
            return
        }
        let previous = memos[position]
        guard previous.createdAt != memo.createdAt || previous.pinned != memo.pinned else {
            var next = memos
            next[position] = memo
            await commit(next, under: authority)
            return
        }
        // An ordering key moved, so the order every in-flight page was measured against is gone:
        // an upward block bounded below the memo's OLD place would land above rows it is older
        // than, and the next bound - read from the moved row - would skip the interval it jumped
        // over. Same fence as setQuery: the lineage moves, and stale answers drop on arrival.
        timelineGeneration += 1
        newerCursor = nil
        await commit(Self.placed(memo, in: memos, tie: .alreadyExisted), under: authority)
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

    /// One page of whatever the query asks for.
    ///
    /// Every parameter travels on EVERY page, because the server's cursor carries no filter state
    /// — it is base64 `created_at|id` (`app/services/memos.py:43-49`) — so a filter left off the
    /// second request quietly widens the list halfway down it.
    ///
    /// An empty query contributes nothing but nils, which the generated client omits: the request
    /// is then character for character the `cursor` + `limit` one this store has always sent.
    static func page(
        _ client: any APIProtocol,
        query: MemoQuery,
        calendar: Calendar,
        direction: MemoPageDirection = .older,
        after bound: Date? = nil,
        before ceiling: Date? = nil,
        cursor: String?,
        limit: Int,
        baseURL: URL
    ) async throws -> (memos: [Memo], nextCursor: String?) {
        var parameters = query.parameters(in: calendar, direction: direction, after: bound)
        // A period's journal reads towards now and still needs its exclusive upper bound on every
        // page (MEMNG-817); the direction alone drops it. Nil leaves every other request as it was.
        if let ceiling { parameters.createdBefore = ceiling }
        let response = try await client.listMemosApiMemosGet(
            .init(
                query: .init(
                    createdBefore: parameters.createdBefore,
                    createdAfter: parameters.createdAfter,
                    tag: parameters.tag,
                    visibility: parameters.visibility?.generated,
                    q: parameters.q,
                    includeArchived: parameters.includeArchived,
                    archivedOnly: parameters.archivedOnly,
                    sort: parameters.sort,
                    cursor: cursor,
                    limit: limit
                )
            )
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
        // Documented since v2.1.0; thrown exactly as its `.undocumented(503)` was.
        case .serviceUnavailable:
            throw APIError.fromStatus(503)
        case .undocumented(let statusCode, _):
            throw APIError.fromStatus(statusCode)
        }
    }
}
