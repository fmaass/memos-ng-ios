import Foundation
import MemosAPI

/// The cover of each tag card on the Collections root (MEMNG-783): the tag's newest picture, read
/// from `GET /api/attachments?type=image&limit=1&tag=<name>` in the Library's own newest-first
/// order, once per tag, when its card first appears. The Favorites card's is the same read under
/// `pictureTag=<name>` (MEMNG-868), held apart from a memo tag of the same name: a `#favorites`
/// memo tag's cover is never the favorites collection's, nor the other way round.
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

    /// What a lookup is of: a memo tag (`tag=`) or a picture's own tag (`pictureTag=`).
    public enum Subject: Hashable, Sendable {
        case tag(String)
        case pictureTag(String)
    }

    /// Every answered subject.
    private var answers: [Subject: Cover] = [:]

    /// The answered memo tags.
    public var covers: [String: Cover] {
        var tags: [String: Cover] = [:]
        for (subject, cover) in answers {
            if case .tag(let name) = subject { tags[name] = cover }
        }
        return tags
    }

    private var generation = 0
    /// Moved for one subject by `forget`: a lookup of it issued before lands nowhere.
    private var subjectEpochs: [Subject: Int] = [:]
    private var nextToken = 0
    private var slots: [Subject: Slot] = [:]
    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    /// Whose memos' pictures may be a cover, fixed for the store's life (MEMNG-933): the Collections
    /// root's Tags row reads Public, so a Just us picture never covers a tag's card.
    public let visibility: MediaVisibilityFilter

    public init(
        visibility: MediaVisibilityFilter = .any,
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.visibility = visibility
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
    public func cover(for tag: String) -> MemoAttachment? { cover(of: .tag(tag)) }

    /// The picture the card of `subject` draws, or nil for the plain tile.
    public func cover(of subject: Subject) -> MemoAttachment? {
        if case .picture(let attachment) = answers[subject] { return attachment }
        return nil
    }

    /// What the lookup of `subject` answered, or nil while it has not.
    public func answer(for subject: Subject) -> Cover? { answers[subject] }

    /// Whether a lookup of `tag` is on the wire.
    public func isLoading(_ tag: String) -> Bool { slots[.tag(tag)] != nil }

    /// How many loads are waiting on the lookup of `tag` on the wire, besides its own.
    func joiners(of tag: String) -> Int { slots[.tag(tag)]?.joiners ?? 0 }

    /// Looks up the cover of `tag`, unless it has been answered. A lookup of it already on the
    /// wire is joined, whatever credential this caller holds; otherwise a caller whose session
    /// has been replaced sends nothing.
    public func load(tag: String, using handle: SessionHandle, baseURL: URL) async {
        await load(.tag(tag), using: handle, baseURL: baseURL)
    }

    /// `load(tag:using:baseURL:)` for any subject, under the same fences.
    public func load(_ subject: Subject, using handle: SessionHandle, baseURL: URL) async {
        guard !isSettled(subject, at: Date()) else { return }
        if var running = slots[subject], running.generation == generation {
            running.joiners += 1
            slots[subject] = running
            await running.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let issued = generation
        let epoch = subjectEpochs[subject, default: 0]
        let task = Task {
            await self.run(
                subject, generation: issued, epoch: epoch, token: token, handle, baseURL)
        }
        slots[subject] = Slot(token: token, generation: issued, task: task)
        await task.value
    }

    private func run(
        _ subject: Subject, generation issued: Int, epoch: Int, token: Int,
        _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if slots[subject]?.token == token { slots[subject] = nil } }
        var tag: String?
        var pictureTag: String?
        switch subject {
        case .tag(let name): tag = name
        case .pictureTag(let name): pictureTag = name
        }
        do {
            let page = try await MediaLibraryStore.page(
                handle.client, filter: .images, order: .newestFirst, tag: tag,
                visibility: visibility, pictureTag: pictureTag, cursor: nil, limit: 1,
                baseURL: baseURL)
            guard issued == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a tag cover answered for a credential that has gone; dropped")
                return
            }
            guard epoch == subjectEpochs[subject, default: 0] else {
                MemosLog.api.info("a tag cover answered before its subject changed; dropped")
                return
            }
            answers[subject] = Self.cover(of: page.items.first?.attachment)
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard issued == generation else {
                MemosLog.api.info("a tag cover failed for an account that has gone; dropped")
                return
            }
            // A refusal still goes to the session's rule; any other failure of a forgotten
            // lookup is not its subject's answer.
            guard epoch == subjectEpochs[subject, default: 0] || StoreFailure.refusal(error) != nil
            else {
                MemosLog.api.info("a tag cover failed before its subject changed; dropped")
                return
            }
            await report(error, subject: subject, issuedUnder: handle)
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
    private func isSettled(_ subject: Subject, at now: Date) -> Bool {
        switch answers[subject] {
        case nil: false
        case .some(.none): true
        case .some(.picture(let attachment)): !attachment.isPastURLHorizon(at: now)
        }
    }

    /// Forgets every cover and drops every lookup in flight: another account's pictures are not
    /// this one's, and a lookup it asked for answers nobody.
    public func sessionIdentityChanged() {
        answers = [:]
        slots = [:]
        generation += 1
    }

    /// Forgets the answer of `subject`, whose pictures have changed, and any lookup of it on the
    /// wire: that lookup was asked before the change, so it lands nowhere, and the next `load`
    /// asks afresh rather than joining it.
    public func forget(_ subject: Subject) {
        answers[subject] = nil
        slots[subject] = nil
        subjectEpochs[subject, default: 0] += 1
    }

    /// Forgets every tag answered with no cover — no picture, a failure, or a picture not yet
    /// finished — so its card asks again: the root has read its tags again.
    public func forgetMissing() {
        answers = answers.filter { $0.value != Cover.none }
    }

    /// The Library's funnel, in its order. A refusal goes to the session's rule even when the
    /// session has renewed since, the rule judging it by the credential it names; anything else
    /// is said only for the credential still current. Whatever is not a refusal or a
    /// cancellation is remembered as no cover — the plain tile, never a sentence.
    private func report(_ error: any Error, subject: Subject, issuedUnder handle: SessionHandle)
        async
    {
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
            answers[subject] = Cover.none
            return
        }
        guard StoreFailure.reportable(error) != nil else {
            MemosLog.api.info("a cancelled tag cover lookup is not an answer")
            return
        }
        answers[subject] = Cover.none
    }

    private func sessionStillCurrent(_ handle: SessionHandle) -> Bool {
        guard let session else { return true }
        guard let current = session.activeHandle?.generation else { return false }
        return current == handle.generation
    }
}
