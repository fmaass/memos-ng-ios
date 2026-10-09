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

/// The members of a trip: every picture of every memo carrying the record's tag, oldest first,
/// minus the record's exclusions — and what they add up to.
///
/// **Membership is DRAINED, never derived.** `GET /api/attachments?tag=<t>&type=image&order=
/// taken_asc&limit=60` is read page after page, following `X-Next-Cursor` until the server stops
/// sending one, up to `memberCap` pictures (beyond which the state is `truncated`). A count or an
/// extremum cannot stand in for it: exclusions are device-local, so only the list itself says
/// which pictures are left and which of them is first. The grid, the viewer, the map and the
/// summary all read the SAME drained list, so an excluded picture is absent from every one.
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
/// **The New trip sheet reads less.** For one tag without exclusions a count and two extrema are
/// enough, so the sheet never drains: `loadTagCounts` reads `GET /api/attachments/tags?type=image`
/// (the length of the image list under each tag, so a tagged video is not counted) and
/// `loadSpan(ofTag:)` reads the first picture of `taken_asc` and of `taken_desc`, `limit=1`, both
/// `type=image`. Each is refused while the same read is already in flight, and fenced the same way.
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
    /// The image count of every tag, in the server's order, for the New trip sheet.
    public private(set) var tagCounts: [LibraryTag] = []
    /// Whether `tagCounts` is an answer, so the sheet can tell "no tag has a picture" from "not
    /// read yet".
    public private(set) var tagCountsLoaded = false
    /// The span of every tag the sheet has asked about, by tag.
    public private(set) var spans: [String: TripTagSpan] = [:]

    private struct Drained {
        var tag: String
        var rows: [LibraryRow]
        var truncated: Bool
    }

    /// What a drain in flight was issued under — what a second caller has to match to join it.
    private struct Lineage: Equatable {
        var generation: Int
        var session: Int
        var tag: String
    }

    private var drained: [UUID: Drained] = [:]
    private var inFlight: [UUID: (lineage: Lineage, token: Int, task: Task<Void, Never>)] = [:]
    /// The token the next drain's slot is given; never reused.
    private var nextToken = 0
    private var countsInFlight = false
    private var spansInFlight: Set<String> = []
    /// Bumped by `sessionIdentityChanged`: everything read before it belongs to somebody else.
    private var generation = 0

    /// Called when a caller joins a drain already in flight, before it waits for it. A seam for
    /// tests only: it is how a test knows the second caller has reached the join.
    @ObservationIgnored var onJoin: (@MainActor () -> Void)?

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
        return drained.rows.filter { !excluded.contains($0.id) }
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
    /// the same record already in flight under the same session and tag (see the type's doc).
    public func drain(_ record: CollectionRecord, using handle: SessionHandle, baseURL: URL) async {
        guard let tag = record.tags.first else { return }
        let lineage = Lineage(generation: generation, session: handle.generation, tag: tag)
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
        let client = handle.client
        var rows: [LibraryRow] = []
        var cursor: String?
        var truncated = false
        do {
            repeat {
                let page = try await MediaLibraryStore.page(
                    client,
                    filter: .images,
                    order: .oldestFirst,
                    tag: lineage.tag,
                    cursor: cursor,
                    limit: pageSize,
                    baseURL: baseURL
                )
                guard stillCurrent(lineage, handle), owns(id, token), isLive(id, lineage) else {
                    MemosLog.api.info("a trip's page answered for a list that has moved on")
                    return
                }
                rows = MediaLibraryStore.merged(rows, with: page.items, filter: .images)
                cursor = page.nextCursor
                if rows.count >= memberCap {
                    truncated = rows.count > memberCap || cursor != nil
                    rows = Array(rows.prefix(memberCap))
                    break
                }
            } while cursor != nil
        } catch {
            guard lineage.generation == generation, owns(id, token) else {
                MemosLog.api.info("a trip's page failed for a list that has moved on")
                return
            }
            await report(error, issuedUnder: handle)
            return
        }
        // The record as it is NOW, asked before anything is written: a trip deleted while its pages
        // were out publishes nothing, and an exclusion or a cover chosen meanwhile counts.
        guard owns(id, token), let record = collections.records.first(where: { $0.id == id }),
            record.tags.first == lineage.tag
        else {
            MemosLog.api.info("a trip's drain answered for a trip that is gone")
            return
        }
        drained[id] = Drained(tag: lineage.tag, rows: rows, truncated: truncated)
        lastError = nil
        session?.noteTransportSuccess(issuedUnder: handle.generation)
        guard let summary = summary(for: record), summary != record.lastSummary else { return }
        collections.setSummary(id: id, summary)
    }

    /// Only for a trip the collection store still holds: a snapshot of a deleted one, which its
    /// screen keeps drawing on the way out, reads nothing.
    private func drained(_ record: CollectionRecord) -> Drained? {
        guard let drained = drained[record.id], drained.tag == record.tags.first,
            collections.records.contains(where: { $0.id == record.id })
        else { return nil }
        return drained
    }

    /// Whether the trip a drain is reading is still there, under the tag the drain reads.
    private func isLive(_ id: UUID, _ lineage: Lineage) -> Bool {
        collections.records.first { $0.id == id }?.tags.first == lineage.tag
    }

    /// Drops what this store holds for a trip that was deleted, and lets go of its drain: what that
    /// drain still brings back is refused at its arrival (`run`), and nothing it read is kept.
    public func forget(_ id: UUID) {
        drained[id] = nil
        inFlight.removeValue(forKey: id)?.task.cancel()
    }

    /// Whether the record's slot still holds the drain that was given `token`.
    private func owns(_ id: UUID, _ token: Int) -> Bool {
        inFlight[id]?.token == token
    }

    // MARK: - The New trip sheet

    /// Reads every tag's IMAGE count. Refused, not sent, while the same read is in flight.
    public func loadTagCounts(using handle: SessionHandle) async {
        guard !countsInFlight else { return }
        countsInFlight = true
        let issued = generation
        defer { if issued == generation { countsInFlight = false } }
        do {
            let rows = try await LibraryTagStore.tags(handle.client, filter: .images)
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

    /// Reads one tag's first and last taken date among its images. Refused, not sent, while a
    /// read of the same tag is in flight.
    public func loadSpan(ofTag tag: String, using handle: SessionHandle, baseURL: URL) async {
        guard spansInFlight.insert(tag).inserted else { return }
        let issued = generation
        defer { if issued == generation { spansInFlight.remove(tag) } }
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
            filter: .images,
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
        spansInFlight = []
        lastError = nil
        generation += 1
    }

    private func stillCurrent(_ lineage: Lineage, _ handle: SessionHandle) -> Bool {
        lineage.generation == generation && sessionStillCurrent(handle)
    }

    /// The same funnel, in the same order, as `MediaLibraryStore.report`.
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
}
