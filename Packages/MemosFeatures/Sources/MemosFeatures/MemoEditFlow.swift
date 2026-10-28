import MemosCore
import SwiftUI

/// Editing a memo from its own screen: what the pencil opens, what Save does, and what is said
/// when it does not work.
///
/// It is a model rather than three modifiers inside `MemoDetailView` because a toolbar item, a
/// sheet binding and a submit closure are three links that can each be removed one at a time
/// without any other test noticing — and this affordance did not exist at all until now, so "it
/// is actually wired up" is the part worth holding.
///
/// The save itself is passed IN rather than owned, because the view is the only thing that has a
/// client and a store, and a model that reached for them would be untestable for exactly that
/// reason.
@MainActor
@Observable
public final class MemoEditFlow {
    /// The memo the sheet is open on, or nil while it is closed.
    public private(set) var editing: ComposeView.Mode?
    /// Why the last save did not work, or nil. A haptic is not a message: before this, a failed
    /// save left the sheet open and said nothing at all.
    public private(set) var lastError: String?
    /// How far the delete conversation has got. See `nextDelete`.
    public private(set) var deleteStage = DeleteStage.idle
    /// Set once the server has confirmed the memo is gone, and never before the sheet has closed
    /// (see `settle`). The screen it was open on has to go with it — a detail view of a memo that
    /// no longer exists is a screen showing a lie.
    public private(set) var memoDeleted = false
    /// Which opening of the sheet is on screen. Every answer is judged against the one that issued
    /// its request, never against this one directly — see `PresentationGeneration`.
    private var presentation = PresentationGeneration.first

    public init() {}

    /// The memo the sheet is open on. The delete acts on THIS uid rather than on one the caller
    /// carries separately, so the sheet and the request cannot come to be about different memos.
    public var editingUID: String? {
        guard case .edit(let uid, _, _, _, _) = editing else { return nil }
        return uid
    }

    /// What `.sheet(item:)` binds to. Only dismissal comes back through it — the sheet is opened
    /// by `begin`, never by an assignment from the outside.
    public var sheet: Binding<ComposeView.Mode?> {
        Binding(get: { self.editing }, set: { if $0 == nil { self.dismiss() } })
    }

    /// Opens the sheet on this memo. A nil mode — the projection for a memo that is not mine —
    /// opens nothing, so the gate cannot be got round by calling this directly.
    public func begin(_ mode: ComposeView.Mode?) {
        guard let mode else { return }
        presentation = presentation.next()
        lastError = nil
        deleteStage = .idle
        // The memo this sheet is about is not the one the last sheet deleted. A screen consumes
        // this by leaving; a timeline has no screen to leave, so the reset has to happen here or
        // the next sheet opens onto an answer about a memo nobody is looking at.
        memoDeleted = false
        editing = mode
    }

    public func dismiss() {
        editing = nil
        // A dismissal cannot abort a request already sent — see `nextDelete(_:on:)`.
        if deleteStage != .deleting { deleteStage = .idle }
    }

    // MARK: - deleting

    /// Which opening of the sheet something belongs to.
    ///
    /// An answer can arrive after the sheet that asked for it has gone and another has opened in
    /// its place, and what it must not do then is write over the newer one — close it, discard the
    /// words in it, or put its own failure in its message. Minted by `begin` and by nothing else: a
    /// DISMISSAL does not end the presentation that sent a request already out, so the answer to a
    /// delete confirmed before a swipe still lands, as `nextDelete(_:on:)` says it must.
    public struct PresentationGeneration: Hashable, Sendable {
        private let value: Int

        static let first = PresentationGeneration(value: 0)

        func next() -> PresentationGeneration { PresentationGeneration(value: value + 1) }
    }

    /// One confirmed delete: which memo, and which opening of the sheet confirmed it.
    ///
    /// Immutable, and HANDED to the request rather than read back off the flow when the request
    /// starts. Between the claim and the task's first line the sheet can be dismissed — leaving
    /// nothing to read — or replaced, leaving the wrong thing to read, and a yes about one memo
    /// must not become a delete of another or a delete of nothing at all.
    public struct MemoDeleteWork: Sendable, Equatable {
        public let uid: String
        public let presentation: PresentationGeneration
    }

    /// How far the delete conversation has got. `deleting` is the ONLY stage in which the app is
    /// allowed to tell the server to remove anything.
    public enum DeleteStage: Equatable, Sendable {
        case idle
        case asking
        case deleting
    }

    public enum DeleteEvent: Equatable, Sendable {
        /// The destructive row in the edit sheet was tapped. Deliberately harmless.
        case tapped
        /// The question was answered yes, in the alert.
        case confirmed
        /// The question was dismissed, by Cancel or by the alert going away.
        case cancelled
        /// The server answered.
        case returned(Bool)
    }

    /// The same discipline the sign-out flow is built on, for the same reason: the tap that opens
    /// the conversation and the tap that destroys something are different events, and only one of
    /// them reaches the server. There is NO path from `idle` to `deleting` — a `confirmed` that
    /// arrives without a question having been asked is ignored rather than obeyed, so no stray
    /// event, repeat tap or re-render can delete a memo nobody agreed to delete.
    public static func nextDelete(_ stage: DeleteStage, on event: DeleteEvent) -> DeleteStage {
        switch event {
        case .tapped:
            // Idempotent: a double tap is one question, asked once, and it cannot restart a
            // delete already in flight.
            return stage == .idle ? .asking : stage
        case .confirmed:
            return stage == .asking ? .deleting : stage
        case .cancelled:
            // Dismissal cannot abort a request that has already been sent: it is gone, and
            // pretending otherwise would leave the screen disagreeing with the server.
            return stage == .deleting ? .deleting : .idle
        case .returned:
            return stage == .deleting ? .idle : stage
        }
    }

    /// The one stage that is allowed to reach the network. The view starts the request when the
    /// machine ENTERS it, so there is exactly one place a delete can begin.
    public static func deletes(_ stage: DeleteStage) -> Bool { stage == .deleting }

    /// Feeds one event to the delete machine, RUNS the request when that event is the one that
    /// starts it, and applies the answer to the sheet.
    ///
    /// Both halves in one turn, for a caller that has nothing to do between them — which is every
    /// test and no view: a view claims first, so the claim cannot be reordered against the alert's
    /// own dismissal (`sendDelete`).
    ///
    /// The request is passed IN, exactly as the save is, because the flow has no store and no
    /// client — and because that is what makes "exactly one delete, of the memo the sheet is open
    /// on, and only after a question was answered" a thing a test can hold rather than a sequence
    /// of events a test has to trust.
    ///
    /// It fires on the TRANSITION into `deleting` and nowhere else: `previous` is read before the
    /// machine moves, so no repeat of any tap, no re-render and no stray event can send a second
    /// request. The uid comes from `editing`, so a delete cannot be aimed at a memo other than the
    /// one on screen.
    ///
    /// A delete that WORKED closes the sheet and marks the memo gone. One that failed keeps the
    /// sheet open and says why through the same `lastError` a failed save uses — the memo is still
    /// there, and so is the screen it was being edited on.
    @discardableResult
    public func advanceDelete(
        _ event: DeleteEvent,
        delete: @MainActor (String) async -> Bool
    ) async -> Bool {
        guard let work = claimDelete(event) else { return false }
        return await performDelete(work, delete: delete)
    }

    /// Moves the delete machine NOW, on the caller's own turn, and hands back the work this event
    /// started — or nil when it started none.
    ///
    /// The synchronous half, and it has to be synchronous. The alert answers through a button AND
    /// through its binding's dismissal, in the same turn: wrapped in tasks those are two pieces of
    /// work with no order between them, and the cancellation running first puts the machine back to
    /// `idle`, so the Delete somebody actually pressed finds nothing to confirm and silently does
    /// nothing. Claimed here, before any hop, the confirmation has already reached `deleting` when
    /// the dismissal lands, where a `cancelled` is the no-op it is supposed to be. Same rule as
    /// `AttachmentDeleteFlow.claim(_:)`, for the reason written there.
    public func claimDelete(_ event: DeleteEvent) -> MemoDeleteWork? {
        let previous = deleteStage
        deleteStage = Self.nextDelete(deleteStage, on: event)
        settle(event)
        guard Self.deletes(deleteStage), !Self.deletes(previous), let uid = editingUID else {
            return nil
        }
        return MemoDeleteWork(uid: uid, presentation: presentation)
    }

    /// Runs the request a claim started, and applies the answer to the sheet that asked for it.
    ///
    /// The uid is the WORK's, never `editingUID`: by the time this runs the sheet may be gone or
    /// showing another memo, and neither of those changes which memo was agreed to. The answer,
    /// on the other hand, belongs to the presentation that confirmed — so it is applied only while
    /// that one is still current, and otherwise dropped. A confirmed delete goes out whatever
    /// happened to the sheet meanwhile; what must not happen is its answer landing on a newer one.
    @discardableResult
    public func performDelete(
        _ work: MemoDeleteWork,
        delete: @MainActor (String) async -> Bool
    ) async -> Bool {
        let succeeded = await delete(work.uid)
        guard work.presentation == presentation else { return succeeded }
        let answer = DeleteEvent.returned(succeeded)
        deleteStage = Self.nextDelete(deleteStage, on: answer)
        settle(answer)
        return succeeded
    }

    /// The one way a view sends a delete event: the transition is claimed HERE, synchronously, and
    /// only the REQUEST is a task — which is what makes the claim unorderable against the alert's
    /// dismissal. A view that wrapped this in a task would have the bug back.
    public func sendDelete(
        _ event: DeleteEvent,
        delete: @escaping @MainActor (String) async -> Bool
    ) {
        guard let work = claimDelete(event) else { return }
        Task { await performDelete(work, delete: delete) }
    }

    /// What an answer from the server means for the sheet. Separate from the machine because the
    /// stage and the screen are two different questions.
    private func settle(_ event: DeleteEvent) {
        guard case .returned(let succeeded) = event else { return }
        if succeeded {
            lastError = nil
            // The sheet closes FIRST, and only then is the memo reported gone. Observation
            // notifies its observers synchronously, so the screen watching `memoDeleted` is woken
            // in whatever state this method has reached by then — and a screen woken while its own
            // sheet is still open cannot leave: the dismissal it asks for is spent on the sheet.
            editing = nil
            memoDeleted = true
        } else {
            lastError = Self.deleteFailureMessage
        }
    }

    /// Runs the save and answers what `ComposeView` asks: may the sheet close?
    ///
    /// A failure keeps the sheet open WITH the words still in it — the one thing that must not
    /// happen to a memo somebody has just rewritten is that it closes and loses them.
    @discardableResult
    public func submit(
        _ submission: ComposeSubmission,
        save: (ComposeView.Mode, ComposeSubmission) async -> ComposeOutcome
    ) async -> ComposeOutcome {
        guard let mode = editing else { return .failed(.authorization) }
        let presented = presentation
        let outcome = await save(mode, submission)
        // The same fence the delete's answer carries: a save that answers after its sheet has been
        // replaced must not close the sheet that replaced it, nor write its failure into it.
        guard presented == presentation else { return outcome }
        // The sentence is the failure's own, because they are not interchangeable: a request that
        // never left the device DID change nothing, and one whose answer was lost may well have
        // changed everything. The old single message claimed the first about both.
        lastError = outcome.failure.map(ComposeFailurePresentation.sentence(for:))
        if outcome.isSaved { editing = nil }
        return outcome
    }

    static let deleteFailureMessage =
        "This memo could not be deleted. It is still on the server."
}
