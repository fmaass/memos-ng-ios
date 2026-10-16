import Foundation
import MemosAPI
import MemosOutbox

/// One chosen picture as select mode's actions see it (MEMNG-788): its uid, the memo it hangs on
/// (nil for an orphan) and whether that memo is the caller's.
public struct MemoActionPicture: Hashable, Sendable {
    public let uid: String
    public let memoUID: String?
    public let mine: Bool

    public init(uid: String, memoUID: String?, mine: Bool) {
        self.uid = uid
        self.memoUID = memoUID
        self.mine = mine
    }

    public init(_ row: LibraryRow) {
        self.init(uid: row.attachment.uid, memoUID: row.attachment.memoUID, mine: row.mine)
    }

    /// Whether an action may act on this picture's memo: the caller's, and a memo there is.
    public var actsOnMemo: Bool { mine && memoUID != nil }

    /// The DISTINCT memos of the caller's chosen pictures, in the order first chosen (plan
    /// decision 5): an orphan and another member's memo are not among them. The N of "Set
    /// visibility for N memos" and the memos its Change sends.
    public static func memos(of pictures: [MemoActionPicture]) -> [String] {
        var seen: Set<String> = []
        return pictures.compactMap { picture in
            guard picture.actsOnMemo, let memo = picture.memoUID, seen.insert(memo).inserted
            else { return nil }
            return memo
        }
    }
}

/// What one of select mode's memo actions asked for.
public enum MemoAction: Hashable, Sendable {
    /// Every chosen memo to this visibility, one PATCH per memo.
    case visibility(MemoVisibility)
    /// The chosen pictures into the trip of this uid, by ONE inclusion request.
    case addToTrip(String)
}

/// What a run of a memo action did: of the `asked` items (memos for visibility, pictures for Add
/// to trip), how many the server `changed` — set, or `added` — how many were held back because an
/// edit of their memo is still owed from this phone's outbox, and the sentence of what stopped
/// or refused the rest, if anything did.
public struct MemoActionOutcome: Equatable, Sendable {
    public let action: MemoAction
    public let asked: Int
    public let changed: Int
    public let heldByOutbox: Int
    public let failure: String?

    public init(
        action: MemoAction, asked: Int, changed: Int, heldByOutbox: Int = 0,
        failure: String? = nil
    ) {
        self.action = action
        self.asked = asked
        self.changed = changed
        self.heldByOutbox = heldByOutbox
        self.failure = failure
    }
}

/// How a call to `MemoActionStore` ended.
public enum MemoActionResult: Equatable, Sendable {
    /// The run ended under the session that issued it; the outcome is what it did.
    case finished(MemoActionOutcome)
    /// Another call of the same kind with different work is running; nothing was sent.
    case refused
    /// The session that issued it ended while it was out: nothing to say, nothing re-read.
    case superseded
}

/// Select mode's memo actions (MEMNG-788): Set visibility — memo-scoped, one
/// `PATCH /api/memos/{uid}` per distinct memo of the caller's, `visibility` alone in the body —
/// and Add to trip — ONE `POST /api/collections/{uid}/attachments`, the server tagging each
/// picture's memo under its edit lock (plan decision 4).
///
/// **The store serialises its own work.** One slot per kind of action. A second call identical
/// in kind, target set, payload and session generation JOINS the running one and shares its
/// whole outcome; any other call of that kind while one runs is REFUSED (`.refused`) and sends
/// nothing — it never receives the running call's result for different work.
///
/// **Fenced by the session generation that issued it.** Asked before every send and once after
/// the last answer: a run whose session ended is `.superseded` — no outcome, no re-read under the
/// session that replaced it. A rejected credential goes through the session's funnel
/// (`onUnauthorized`, the typed `CredentialRefusal`) and stops the run.
///
/// **The trips are re-read inside the slot.** Add to trip moves the trip's revision, reads its
/// record and drains its members again (`TripStore.membersChanged`); Set visibility drops every
/// trip's members and filtered reads, which the screens then read again.
@MainActor
@Observable
public final class MemoActionStore {
    /// The banner of a refused call.
    public static let busySentence = "Another change is still running"
    /// The contract's ceiling on one inclusion request (`CollectionInclusion.attachmentUids`).
    public static let inclusionCap = 500

    enum Kind: Hashable { case visibility, addToTrip }

    private struct Key: Hashable {
        var kind: Kind
        var targets: Set<String>
        var payload: String
        var generation: Int
    }

    private typealias Slot = (key: Key, token: Int, task: Task<MemoActionResult, Never>)

    private let trips: TripStore?
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    /// Whether this phone's outbox still owes an edit to the memo of a picture (memo uid, picture
    /// uid): such a picture is not added, because that edit carries text read before the tag.
    private let owesEdit: @MainActor (String?, String) -> Bool
    private var session: (any SessionReporting)?
    private var slots: [Kind: Slot] = [:]
    private var nextToken = 0

    /// A seam for tests: called when a call joins the one running.
    @ObservationIgnored var onJoin: (@MainActor () -> Void)?

    public init(
        trips: TripStore?,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded },
        owesEdit: @escaping @MainActor (String?, String) -> Bool = { _, _ in false }
    ) {
        self.trips = trips
        self.onUnauthorized = onUnauthorized
        self.owesEdit = owesEdit
    }

    /// Names the session this store's transport outcomes belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    /// Whether a run of either kind is out.
    public var isRunning: Bool { !slots.isEmpty }

    /// Whether an outbox job still owes an edit to the memo `memoUID`, or to the memo that holds
    /// `attachmentUID`: a capture whose create resolved and whose editor's later changes are
    /// still to be sent (`UploadJob.pendingEdit`).
    public nonisolated static func owesEdit(
        in jobs: [UploadJob], memoUID: String?, attachmentUID: String
    ) -> Bool {
        jobs.contains { job in
            guard job.pendingEdit != nil else { return false }
            if let memoUID, job.resolvedMemoUID == memoUID { return true }
            return job.files.contains { $0.attachmentUID == attachmentUID }
        }
    }

    // MARK: - Set visibility

    /// Sets every memo of `memos` (duplicates once) to `visibility`: one PATCH per memo, in order,
    /// with `visibility` alone in its body — never `attachment_uids`, whose empty list would remove
    /// the memo's pictures. A memo the server refuses is counted out and the run goes on; a
    /// rejected credential or an unreachable server stops it.
    public func setVisibility(
        _ visibility: MemoVisibility, forMemos memos: [String], using handle: SessionHandle,
        baseURL: URL
    ) async -> MemoActionResult {
        var seen: Set<String> = []
        let targets = memos.filter { seen.insert($0).inserted }
        let key = Key(
            kind: .visibility, targets: Set(targets), payload: visibility.rawValue,
            generation: handle.generation)
        return await run(key, handle) {
            await self.runVisibility(visibility, targets, handle, baseURL)
        }
    }

    private func runVisibility(
        _ visibility: MemoVisibility, _ targets: [String], _ handle: SessionHandle, _ baseURL: URL
    ) async -> MemoActionResult {
        let action = MemoAction.visibility(visibility)
        var changed = 0
        var failure: String?
        memos: for memo in targets {
            guard sessionStillCurrent(handle.generation) else { return .superseded }
            do {
                try await Self.patchVisibility(handle.client, memo: memo, to: visibility)
                session?.noteTransportSuccess(issuedUnder: handle.generation)
                changed += 1
            } catch {
                switch await classify(error, handle) {
                case .superseded: return .superseded
                case .stop(let sentence):
                    failure = sentence
                    break memos
                case .skip(let sentence):
                    failure = failure ?? sentence
                }
            }
        }
        guard sessionStillCurrent(handle.generation) else { return .superseded }
        if changed > 0 { await trips?.membersChanged(uid: nil, using: handle, baseURL: baseURL) }
        guard sessionStillCurrent(handle.generation) else { return .superseded }
        return .finished(
            MemoActionOutcome(
                action: action, asked: targets.count, changed: changed, failure: failure))
    }

    // MARK: - Add to trip

    /// Adds the chosen pictures to `trip` with ONE inclusion request naming the caller's pictures
    /// that hang on a memo (duplicates once). A picture whose memo this phone's outbox still owes
    /// an edit is held back and counted (`heldByOutbox`); others' pictures and orphans are never
    /// sent. "N of M added": N the server's `added` answers, M the distinct pictures chosen.
    public func add(
        attachments pictures: [MemoActionPicture], toTrip trip: Trip, using handle: SessionHandle,
        baseURL: URL
    ) async -> MemoActionResult {
        var seen: Set<String> = []
        let chosen = pictures.filter { seen.insert($0.uid).inserted }
        let key = Key(
            kind: .addToTrip, targets: Set(chosen.map(\.uid)), payload: trip.uid,
            generation: handle.generation)
        return await run(key, handle) {
            await self.runAdd(chosen, trip, handle, baseURL)
        }
    }

    private func runAdd(
        _ chosen: [MemoActionPicture], _ trip: Trip, _ handle: SessionHandle, _ baseURL: URL
    ) async -> MemoActionResult {
        let action = MemoAction.addToTrip(trip.uid)
        let eligible = chosen.filter(\.actsOnMemo)
        let held = eligible.filter { owesEdit($0.memoUID, $0.uid) }
        let sent = eligible.filter { picture in !held.contains(picture) }.map(\.uid)
        func outcome(_ changed: Int, _ failure: String? = nil) -> MemoActionResult {
            .finished(
                MemoActionOutcome(
                    action: action, asked: chosen.count, changed: changed,
                    heldByOutbox: held.count, failure: failure))
        }
        guard !sent.isEmpty else { return outcome(0) }
        guard sent.count <= Self.inclusionCap else {
            return outcome(0, "Choose at most \(Self.inclusionCap) pictures to add at a time.")
        }
        guard sessionStillCurrent(handle.generation) else { return .superseded }
        let added: Int
        do {
            added = try await Self.include(handle.client, trip: trip.uid, attachments: sent)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            switch await classify(error, handle) {
            case .superseded: return .superseded
            case .stop(let sentence), .skip(let sentence):
                return outcome(0, Self.inclusionSentence(error) ?? sentence)
            }
        }
        guard sessionStillCurrent(handle.generation) else { return .superseded }
        await trips?.membersChanged(uid: trip.uid, using: handle, baseURL: baseURL)
        guard sessionStillCurrent(handle.generation) else { return .superseded }
        return outcome(added)
    }

    // MARK: - The slot

    /// Runs `perform` in the kind's slot, joins the identical call already in it, or refuses.
    private func run(
        _ key: Key, _ handle: SessionHandle,
        perform: @escaping @MainActor () async -> MemoActionResult
    ) async -> MemoActionResult {
        if let running = slots[key.kind] {
            guard running.key == key else {
                MemosLog.api.info("a memo action asked for while another is running is refused")
                return .refused
            }
            onJoin?()
            let joined = await running.task.value
            return sessionStillCurrent(handle.generation) ? joined : .superseded
        }
        nextToken += 1
        let token = nextToken
        let task = Task {
            let result = await perform()
            if self.slots[key.kind]?.token == token { self.slots[key.kind] = nil }
            return result
        }
        slots[key.kind] = (key, token, task)
        let result = await task.value
        return sessionStillCurrent(handle.generation) ? result : .superseded
    }

    private func sessionStillCurrent(_ generation: Int) -> Bool {
        guard let session else { return true }
        return session.activeHandle?.generation == generation
    }

    // MARK: - Failures

    private enum Classified {
        /// The session moved: nothing is said.
        case superseded
        /// The run cannot go on: the server is unreachable or the credential was refused.
        case stop(String?)
        /// This item failed; the others may still go.
        case skip(String?)
    }

    /// A failure, typed: an answered one is reported as answered, an unreachable server to the
    /// session's banner, a refused credential through the session's funnel and the generation
    /// asked again after that wait.
    private func classify(_ error: any Error, _ handle: SessionHandle) async -> Classified {
        if StoreFailure.reachedServer(error) {
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        }
        guard sessionStillCurrent(handle.generation), !StoreFailure.isCancellation(error) else {
            return .superseded
        }
        if let reason = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(reason, issuedUnder: handle.generation)
            return .stop(nil)
        }
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
            guard sessionStillCurrent(handle.generation), nothingEstablishedSince(handle) else {
                return .superseded
            }
            return .stop(refusal.errorDescription)
        }
        return .skip(StoreFailure.reportable(error)?.errorDescription)
    }

    private func nothingEstablishedSince(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        return session.nothingEstablishedSince(handle)
    }

    /// The inclusion's own refusals, in words: a trip without a tag (membership by span only)
    /// and a trip that is gone.
    private static func inclusionSentence(_ error: any Error) -> String? {
        switch error as? APIError {
        case .server(status: 409)?: "This trip has no tag, so pictures can't be added to it."
        case .notFound?: "This trip is no longer there."
        default: nil
        }
    }

    // MARK: - Requests

    /// One memo's visibility, and nothing else of it.
    static func patchVisibility(
        _ client: any APIProtocol, memo: String, to visibility: MemoVisibility
    ) async throws {
        let response = try await client.patchMemoApiMemosUidPatch(
            .init(path: .init(uid: memo), body: .json(.init(visibility: visibility.generated))))
        switch response {
        case .ok: return
        case .notFound: throw APIError.notFound
        case .conflict: throw APIError.server(status: 409)
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        }
    }

    /// The ONE inclusion request; answers how many pictures the server says it `added`.
    static func include(
        _ client: any APIProtocol, trip: String, attachments: [String]
    ) async throws -> Int {
        let response = try await client.includeAttachmentsApiCollectionsUidAttachmentsPost(
            .init(path: .init(uid: trip), body: .json(.init(attachmentUids: attachments))))
        switch response {
        case .ok(let ok):
            return try ok.body.json.results.filter { $0.outcome.rawValue == "added" }.count
        case .notFound: throw APIError.notFound
        case .conflict: throw APIError.server(status: 409)
        case .unprocessableContent: throw APIError.server(status: 422)
        case .serviceUnavailable: throw APIError.fromStatus(503)
        case .undocumented(let status, _): throw APIError.fromStatus(status)
        default: throw StoreFailure.documentedRefusal
        }
    }
}
