import Foundation
import MemosAPI

/// The cover of each tag card on the Collections root (MEMNG-783): the tag's newest picture, read
/// from `GET /api/attachments?type=image&limit=1&tag=<name>` in the Library's own newest-first
/// order, once per tag, when its card first appears.
///
/// Its fences are the Library's, for the Library's reasons:
///
/// * one lookup per tag at a time — the slot is taken synchronously, before anything is awaited,
///   and a second `load` of a tag already on the wire for the same session JOINS that lookup and
///   returns when it ends, so two appearances of one card are one request;
/// * a tag answered — a picture, no picture, or a failure — is not asked again for the life of
///   the store: a failed lookup is the plain tile, never an error, until the account changes or
///   the root reads its tags again (`forgetMissing`);
/// * an answer is judged against the lineage that ISSUED it — the store's generation, moved by
///   `sessionIdentityChanged`, and the session generation of the handle — so a lookup that
///   outlived its account lands nowhere, success or failure;
/// * a slot is cleared only by the lookup that owns it;
/// * a refused credential goes to `onUnauthorized` as the one typed `CredentialRefusal`, through
///   the shared `StoreFailure` funnel, and is not remembered as an answer.
@MainActor
@Observable
public final class TagCoverStore {
    /// What a tag's lookup answered.
    public enum Cover: Equatable, Sendable {
        case picture(MemoAttachment)
        /// The lookup failed, or the tag has no picture.
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

    private struct Lineage: Equatable {
        var generation: Int
        /// The session generation of the handle that issued the lookup.
        var session: Int
    }

    private struct Slot {
        let token: Int
        let lineage: Lineage
        let task: Task<Void, Never>
    }

    /// The picture a tag's card draws, or nil for the plain tile.
    public func cover(for tag: String) -> MemoAttachment? {
        if case .picture(let attachment) = covers[tag] { return attachment }
        return nil
    }

    /// Whether a lookup of `tag` is on the wire.
    public func isLoading(_ tag: String) -> Bool { slots[tag] != nil }

    /// Looks up the cover of `tag`, unless it has been answered; a lookup of it already on the
    /// wire for the same session is joined. A caller whose session has been replaced sends nothing.
    public func load(tag: String, using handle: SessionHandle, baseURL: URL) async {
        guard covers[tag] == nil else { return }
        let lineage = Lineage(generation: generation, session: handle.generation)
        if let running = slots[tag], running.lineage == lineage {
            await running.task.value
            return
        }
        guard sessionStillCurrent(handle) else { return }
        nextToken += 1
        let token = nextToken
        let task = Task { await self.run(tag, lineage: lineage, token: token, handle, baseURL) }
        slots[tag] = Slot(token: token, lineage: lineage, task: task)
        await task.value
    }

    private func run(
        _ tag: String, lineage: Lineage, token: Int, _ handle: SessionHandle, _ baseURL: URL
    ) async {
        defer { if slots[tag]?.token == token { slots[tag] = nil } }
        do {
            let page = try await MediaLibraryStore.page(
                handle.client, filter: .images, order: .newestFirst, tag: tag, cursor: nil,
                limit: 1, baseURL: baseURL)
            guard lineage.generation == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a tag cover answered for an account that has gone; dropped")
                return
            }
            covers[tag] = page.items.first.map { .picture($0.attachment) } ?? Cover.none
            session?.noteTransportSuccess(issuedUnder: handle.generation)
        } catch {
            guard lineage.generation == generation, sessionStillCurrent(handle) else {
                MemosLog.api.info("a tag cover failed for an account that has gone; dropped")
                return
            }
            await report(error, tag: tag, lineage: lineage, issuedUnder: handle)
        }
    }

    /// Forgets every cover and drops every lookup in flight: another account's pictures are not
    /// this one's, and a lookup it asked for answers nobody.
    public func sessionIdentityChanged() {
        covers = [:]
        slots = [:]
        generation += 1
    }

    /// Forgets every tag answered with no cover, so its card asks again: the root has read its
    /// tags again.
    public func forgetMissing() {
        covers = covers.filter { $0.value != Cover.none }
    }

    /// The Library's funnel, in its order. Whatever is not a refusal or a cancellation is
    /// remembered as no cover — the plain tile, never a sentence.
    private func report(
        _ error: any Error, tag: String, lineage: Lineage, issuedUnder handle: SessionHandle
    ) async {
        if let failure = StoreFailure.transportFailure(error) {
            session?.noteTransportFailure(failure, issuedUnder: handle.generation)
            covers[tag] = Cover.none
            return
        }
        if let refusal = StoreFailure.refusal(error) {
            _ = await onUnauthorized(refusal)
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
