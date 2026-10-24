import Foundation
import MemosAPI

/// The one picture tag this app writes (MEMNG-867). One constant, so no second spelling of it can
/// reach the wire.
public enum FavoriteTag {
    public static let name = "favorites"

    /// `tags` with the favorite set to `on`, in the server's order (sorted by name).
    static func applying(_ on: Bool, to tags: [String]) -> [String] {
        var set = Set(tags)
        if on { set.insert(name) } else { set.remove(name) }
        return set.sorted()
    }
}

/// A favorite the server confirmed: the picture's own tags as they now stand, and the revision of
/// the ledger that recorded them.
public struct FavoriteCommit: Sendable, Equatable {
    public let uid: String
    public let tags: [String]
    public let revision: Int
}

/// The revision of the favorites ledger a read was ISSUED under. A row read under an older stamp
/// than a commit for its uid takes the ledger's tags instead of its own: the read left before the
/// change and cannot be the newer word on it, however current its answer looks.
public struct FavoriteStamp: Sendable, Equatable {
    public let revision: Int
}

/// Marks and unmarks any picture the reader can see as a favorite (MEMNG-867, plan decision 6):
/// memos-ng is a family app, so the heart is nobody's in particular and works across all users.
///
/// The write is a SET — `PUT`/`DELETE /api/attachments/{uid}/tags/favorites`, both answering 204
/// with no body — so a call names the state it wants and nothing is parsed from the answer.
///
/// * Serialised per picture by JOINING: at most one request per uid is on the wire. A second call
///   for the same state joins it; a call for the opposite state while it is out records the new
///   wish, and exactly one follow-up request carries the final one after the answer. A call for
///   the state already committed, with nothing out, sends nothing.
/// * Fenced by the session that issued it, before the request and after the answer: an answer for
///   a session that has moved on neither commits nor reverts.
/// * Three failure classes, said differently because they mean different things. A CONFIRMED
///   rejection (not found, invalid) reverts and says nothing changed — which is
///   then literally true. A refused credential goes to the session as one typed refusal and says
///   nothing here. Anything else is an UNKNOWN outcome — the server may have committed — so the
///   picture is held pending and ONE reconciling read of its own record decides; only when that
///   read fails too does the heart go back, with a sentence that does not claim to know.
/// * Every commit bumps a monotonic `revision`, is written to a per-picture ledger and is handed
///   to whatever follows this store, so every copy of the picture is told; a read issued before
///   the commit is overlaid from the ledger when it lands (`overlay(_:issuedAt:)`).
@MainActor
@Observable
public final class FavoriteStore {
    public static let nothingChangedNotice =
        "Could not mark as favorite. Nothing changed."
    public static let unconfirmedNotice = "Could not confirm the favorite."

    /// Bumped by every commit, never reset — a stamp taken under one account must still compare
    /// as older than every commit made after it.
    public private(set) var revision = 0
    /// The sentence to show, or nil. Set only by a rejection or an unconfirmed outcome.
    public private(set) var notice: String?
    /// The pictures whose outcome is unknown and whose reconciling read is out.
    public private(set) var pending: Set<String> = []
    /// A picture's own record as last read, its URLs signed then (`loadDetail`). Invalidated while
    /// a write to it has an unknown outcome.
    public private(set) var details: [String: MemoAttachment] = [:]

    private var committed: [String: FavoriteCommit] = [:]
    /// A picture whose server state this device does not know: a tap for the state it shows is
    /// sent anyway rather than taken for a no-op.
    private var unconfirmed: Set<String> = []
    private struct Flight {
        var token: Int
        var desired: Bool
        var task: Task<Void, Never>
    }
    private var flights: [String: Flight] = [:]
    private var nextToken = 0
    private var detailGeneration = 0
    private var observers: [@MainActor (FavoriteCommit) async -> Void] = []
    private var invalidations: [@MainActor (String) -> Void] = []
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    public init(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's requests belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    /// Hands every commit, in order, to `observer`. A store that holds copies of pictures follows
    /// this one through it (`follow(_:)`).
    public func observe(_ observer: @escaping @MainActor (FavoriteCommit) async -> Void) {
        observers.append(observer)
    }

    /// Tells `observer`, synchronously, every time a picture's own record may no longer say what
    /// it said: on a commit, and the moment a write's outcome turns out unknown — whether or not
    /// the reconciling read that follows lands (MEMNG-869). A store that keeps a picture's record
    /// forgets it here, so its next read asks the server again.
    public func observeInvalidations(_ observer: @escaping @MainActor (String) -> Void) {
        invalidations.append(observer)
    }

    // MARK: - Reading

    /// The stamp a read takes at the instant it is issued.
    public var stamp: FavoriteStamp { FavoriteStamp(revision: revision) }

    /// What the heart shows for `uid`: the state a write in flight is asking for, else the ledger,
    /// else the tags the caller's copy carries.
    public func tags(for uid: String, shown: [String]) -> [String] {
        let base = committed[uid]?.tags ?? shown
        guard let flight = flights[uid], !pending.contains(uid) else { return base }
        return FavoriteTag.applying(flight.desired, to: base)
    }

    public func isPending(_ uid: String) -> Bool { pending.contains(uid) }

    public func dismissNotice() { notice = nil }

    /// `tags` replaced from the ledger when a commit for `uid` is newer than `stamp`.
    public func overlay(_ uid: String, tags: [String], issuedAt stamp: FavoriteStamp) -> [String] {
        guard let entry = committed[uid], entry.revision > stamp.revision else { return tags }
        return entry.tags
    }

    public func overlay(_ attachment: MemoAttachment, issuedAt stamp: FavoriteStamp)
        -> MemoAttachment
    {
        var fenced = attachment
        fenced.tags = overlay(attachment.uid, tags: attachment.tags, issuedAt: stamp)
        return fenced
    }

    public func overlay(_ rows: [LibraryRow], issuedAt stamp: FavoriteStamp) -> [LibraryRow] {
        guard committed.values.contains(where: { $0.revision > stamp.revision }) else {
            return rows
        }
        return rows.map { row in
            var fenced = row
            fenced.attachment = overlay(row.attachment, issuedAt: stamp)
            return fenced
        }
    }

    public func overlay(_ memos: [Memo], issuedAt stamp: FavoriteStamp) -> [Memo] {
        guard committed.values.contains(where: { $0.revision > stamp.revision }) else {
            return memos
        }
        return memos.map { overlay($0, issuedAt: stamp) }
    }

    public func overlay(_ memo: Memo, issuedAt stamp: FavoriteStamp) -> Memo {
        var fenced = memo
        fenced.attachments = memo.attachments.map { overlay($0, issuedAt: stamp) }
        return fenced
    }

    // MARK: - Writing

    /// Asks for `uid` to be a favorite (`true`) or not. `shownTags` is the picture's own tags as
    /// the caller's copy carries them; the ledger outranks it once this session has committed.
    ///
    /// - Returns: the task carrying the request, joined by every overlapping call for `uid`.
    @discardableResult
    public func setFavorite(
        uid: String, to target: Bool, shownTags: [String], using handle: SessionHandle,
        baseURL: URL
    ) -> Task<Void, Never> {
        if var flight = flights[uid] {
            flight.desired = target
            flights[uid] = flight
            return flight.task
        }
        let base = committed[uid]?.tags ?? shownTags
        guard unconfirmed.contains(uid) || base.contains(FavoriteTag.name) != target else {
            return Task {}
        }
        nextToken += 1
        let token = nextToken
        notice = nil
        let task = Task { [self] in
            await fly(uid, token: token, from: base, handle, baseURL)
            if flights[uid]?.token == token { flights[uid] = nil }
        }
        flights[uid] = Flight(token: token, desired: target, task: task)
        return task
    }

    private enum Outcome {
        case committed
        case rejected
        case refused(CredentialRefusal)
        case unknown(any Error)
    }

    private func fly(
        _ uid: String, token: Int, from pre: [String], _ handle: SessionHandle, _ baseURL: URL
    ) async {
        var current = pre
        while let flight = flights[uid], flight.token == token {
            let target = flight.desired
            guard unconfirmed.contains(uid) || current.contains(FavoriteTag.name) != target else {
                return
            }
            guard sessionStillCurrent(handle) else { return }
            let outcome: Outcome
            do {
                outcome =
                    try await Self.write(handle.client, uid: uid, favorite: target)
                    ? .committed : .rejected
            } catch {
                if let refusal = StoreFailure.refusal(error) {
                    outcome = .refused(refusal)
                } else {
                    outcome = .unknown(error)
                }
            }
            // An answer for a session that has moved on is not this session's word: the ledger,
            // the notice and the heart stay as they are.
            guard owns(uid, token), sessionStillCurrent(handle) else {
                MemosLog.api.info("a favorite answered for a session that has ended is dropped")
                return
            }
            switch outcome {
            case .committed:
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                current = FavoriteTag.applying(target, to: current)
                unconfirmed.remove(uid)
                await commit(uid, tags: current)
            case .rejected:
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                notice = Self.nothingChangedNotice
                return
            case .refused(let refusal):
                _ = await onUnauthorized(refusal)
                return
            case .unknown(let error):
                invalidate(uid)
                if let failure = StoreFailure.transportFailure(error) {
                    session?.noteTransportFailure(failure, issuedUnder: handle.generation)
                }
                guard let read = await reconcile(uid, token: token, handle, baseURL) else {
                    return
                }
                current = read
                // The one read IS the outcome, landed or not. Only a wish made while the write
                // was out is followed up; resending the same one would loop for as long as answers
                // are lost.
                guard flights[uid]?.desired != target else { return }
            }
        }
    }

    /// The one read that decides an unknown outcome: the picture's own record, whose tags become
    /// the committed truth. Nil when the flight is over — refused, failed or overtaken.
    private func reconcile(
        _ uid: String, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async -> [String]? {
        pending.insert(uid)
        unconfirmed.insert(uid)
        details[uid] = nil
        detailGeneration += 1
        defer { pending.remove(uid) }
        do {
            let read = try await TripMemberStore.attachment(
                handle.client, uid: uid, baseURL: baseURL)
            guard owns(uid, token), sessionStillCurrent(handle) else { return nil }
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            unconfirmed.remove(uid)
            details[uid] = read
            await commit(uid, tags: read.tags)
            return read.tags
        } catch {
            guard owns(uid, token), sessionStillCurrent(handle) else { return nil }
            if let refusal = StoreFailure.refusal(error) {
                _ = await onUnauthorized(refusal)
                return nil
            }
            if let failure = StoreFailure.transportFailure(error) {
                session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            }
            notice = Self.unconfirmedNotice
            return nil
        }
    }

    private func commit(_ uid: String, tags: [String]) async {
        revision += 1
        let entry = FavoriteCommit(uid: uid, tags: tags, revision: revision)
        committed[uid] = entry
        details[uid]?.tags = tags
        invalidate(uid)
        for observer in observers { await observer(entry) }
    }

    private func invalidate(_ uid: String) {
        for observer in invalidations { observer(uid) }
    }

    private func owns(_ uid: String, _ token: Int) -> Bool { flights[uid]?.token == token }

    // MARK: - The picture's own record

    /// Reads `uid`'s own record (`GET /api/attachments/{uid}`) into `details`, fenced by the
    /// session that issued it and by the favorites ledger.
    public func loadDetail(uid: String, using handle: SessionHandle, baseURL: URL) async {
        let issued = stamp
        let generation = detailGeneration
        do {
            let read = try await TripMemberStore.attachment(
                handle.client, uid: uid, baseURL: baseURL)
            guard generation == detailGeneration, sessionStillCurrent(handle) else { return }
            session?.noteTransportSuccess(issuedUnder: handle.generation)
            details[uid] = overlay(read, issuedAt: issued)
        } catch {
            guard generation == detailGeneration, sessionStillCurrent(handle) else { return }
            if let refusal = StoreFailure.refusal(error) {
                _ = await onUnauthorized(refusal)
            } else if let failure = StoreFailure.transportFailure(error) {
                session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            }
        }
    }

    /// Forgets everything this account committed, because this device is signed in as somebody
    /// else. A write in flight is let go: its answer finds no flight and changes nothing.
    public func sessionIdentityChanged() {
        committed = [:]
        unconfirmed = []
        pending = []
        flights = [:]
        details = [:]
        notice = nil
        detailGeneration += 1
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }

    /// One write. True for a commit, false for a confirmed rejection; anything else throws.
    static func write(_ client: any APIProtocol, uid: String, favorite: Bool) async throws -> Bool {
        if favorite {
            let input = Operations.AddPictureTagApiAttachmentsUidTagsNamePut.Input(
                path: .init(uid: uid, name: FavoriteTag.name))
            switch try await client.addPictureTagApiAttachmentsUidTagsNamePut(input) {
            case .noContent: return true
            case .notFound, .unprocessableContent: return false
            case .serviceUnavailable: throw APIError.fromStatus(503)
            case .undocumented(let status, _): throw APIError.fromStatus(status)
            }
        }
        let input = Operations.RemovePictureTagApiAttachmentsUidTagsNameDelete.Input(
            path: .init(uid: uid, name: FavoriteTag.name))
        switch try await client.removePictureTagApiAttachmentsUidTagsNameDelete(input) {
        case .noContent: return true
        case .notFound, .unprocessableContent: return false
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        }
    }
}
