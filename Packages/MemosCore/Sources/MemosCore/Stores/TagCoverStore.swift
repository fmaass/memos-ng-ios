import Foundation
import MemosAPI

/// The cover of each tag card on the Collections root (MEMNG-783): the tag's newest picture, read
/// from `GET /api/attachments?type=image&limit=1&tag=<name>` in the Library's own newest-first
/// order, once per tag, when its card first appears.
///
/// Its fences are the Library's, for the Library's reasons:
///
/// * one lookup per tag at a time — the slot is taken synchronously, before anything is awaited,
///   and a second `load` of a tag already on the wire JOINS that lookup and returns when it ends,
///   whatever credential the joiner holds: a renewal while a lookup is out is still one request
///   for the tag, and only a change of account (`sessionIdentityChanged`) abandons a slot;
/// * a tag answered — a picture, no picture, or a failure — is not asked again for the life of
///   the store: a failed lookup is the plain tile, never an error, until the account changes or
///   the root reads its tags again (`forgetMissing`). Two answers are not settled, because the
///   tile could never draw them: a newest picture the server has not finished is no cover and is
///   asked again with the missing ones, and a picture whose signature is spent
///   (`MemoAttachment.isPastURLHorizon`, the Library's own rule) is asked again by the next
///   appearance of its card, whose answer the server signs afresh;
/// * an answer is judged against the lineage that ISSUED it — the store's generation, moved by
///   `sessionIdentityChanged`, and the session generation of the handle that sent it — so a
///   lookup that outlived its account or its credential lands nowhere and leaves the tag to be
///   asked again; a joiner of such a lookup gets no cover;
/// * a slot is cleared only by the lookup that owns it;
/// * a refused credential goes to `onUnauthorized` as the one typed `CredentialRefusal`, through
///   the shared `StoreFailure` funnel, even when the session has renewed since — the refusal
///   carries the credential it was earned with, and the session's rule judges it by that — and
///   is not remembered as an answer.
@MainActor
@Observable
public final class TagCoverStore {
    /// What a tag's lookup answered.
    public enum Cover: Equatable, Sendable {
        case picture(MemoAttachment)
        /// The lookup failed, the tag has no picture, or its newest picture is not finished.
        case none
    }

    /// The answered tags.
    public private(set) var covers: [String: Cover] = [:]

    private var generation = 0
    private var nextToken = 0
    private var slots: [String: Slot] = [:]
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    public init(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    private struct Slot {
        let token: Int
        /// The store generation the lookup was issued under.
        let generation: Int
        let task: Task<Void, Never>
        /// The loads waiting on this lookup besides the one that issued it.
        var joiners = 0
    }

    /// The picture a tag's card draws, or nil for the plain tile.
    public func cover(for tag: String) -> MemoAttachment? {
        if case .picture(let attachment) = covers[tag] { return attachment }
        return nil
    }

    /// Whether a lookup of `tag` is on the wire.
    public func isLoading(_ tag: String) -> Bool { slots[tag] != nil }

    /// How many loads are waiting on the lookup of `tag` on the wire, besides its own.
    func joiners(of tag: String) -> Int { slots[tag]?.joiners ?? 0 }

    /// Looks up the cover of `tag`, unless it has been answered. A lookup of it already on the
    /// wire is joined, whatever credential this caller holds; otherwise a caller whose session
    /// has been replaced sends nothing.
    public func load(tag: String, using handle: SessionHandle, baseURL: URL) async {
        guard !isSettled(tag, at: Date()) else { return }
        if var running = slots[tag], running.generation == generation {
            running.joiners += 1
            slots[tag] = running
            await running.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let task = Task { await self.run(tag, generation: issued, token: token, handle, baseURL) }
        slots[tag] = Slot(token: token, generation: issued, task: task)
        await task.value
    }

    private func run(
        _ tag: String, generation issued: Int, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if slots[tag]?.token == token { slots[tag] = nil } }
        do {
            let page = try await MediaLibraryStore.page(
                handle.client, filter: .images, order: .newestFirst, tag: tag, cursor: nil,
                limit: 1, baseURL: baseURL)
            guard issued == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a tag cover answered for a credential that has gone; dropped")
                return
            }
            covers[tag] = Self.cover(of: page.items.first?.attachment)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else {
                MemosLog.api.info("a tag cover failed for an account that has gone; dropped")
                return
            }
            await report(error, tag: tag, issuedUnder: handle)
        }
    }

    /// What a lookup's row makes of the card. A picture the server is still deriving — or gave up
    /// on — is not one: the tile refuses to fetch it, and cached as the cover it would hold the
    /// plain tile until the account changed. As no cover it is asked again with the missing ones
    /// when the root reads its tags again, and not on every appearance of its card.
    static func cover(of newest: MemoAttachment?) -> Cover {
        guard let newest, newest.readiness == .ready else { return Cover.none }
        return .picture(newest)
    }

    /// Whether `tag`'s answer stands at `now`: answered, and — for a picture — with URLs the tile
    /// can still start a fetch on. A spent signature is not an answer to keep; the lookup is
    /// asked again, and joined like any other while it is on the wire.
    private func isSettled(_ tag: String, at now: Date) -> Bool {
        switch covers[tag] {
        case nil: false
        case .some(.none): true
        case .some(.picture(let attachment)): !attachment.isPastURLHorizon(at: now)
        }
    }

    /// Forgets every cover and drops every lookup in flight: another account's pictures are not
    /// this one's, and a lookup it asked for answers nobody.
    public func sessionIdentityChanged() {
        covers = [:]
        slots = [:]
        generation += 1
    }

    /// Forgets every tag answered with no cover — no picture, a failure, or a picture not yet
    /// finished — so its card asks again: the root has read its tags again.
    public func forgetMissing() {
        covers = covers.filter { $0.value != Cover.none }
    }

    /// The Library's funnel, in its order. A refusal goes to the session's rule even when the
    /// session has renewed since, the rule judging it by the credential it names; anything else
    /// is said only for the credential still current. Whatever is not a refusal or a
    /// cancellation is remembered as no cover — the plain tile, never a sentence.
    private func report(_ error: any Error, tag: String, issuedUnder handle: SessionHandle) async {
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
            return
        }
        guard sessionStillCurrent(handle) else {
            MemosLog.api.info("a tag cover failed for a credential that has gone; dropped")
            return
        }
        if let failure = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            covers[tag] = Cover.none
            return
        }
        guard StoreFailure.reportable(error) != nil else {
            MemosLog.api.info("a cancelled tag cover lookup is not an answer")
            return
        }
        covers[tag] = Cover.none
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }
}
