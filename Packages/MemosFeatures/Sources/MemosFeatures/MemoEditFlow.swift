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
    /// Set once the server has confirmed the memo is gone. The screen it was open on has to go
    /// with it — a detail view of a memo that no longer exists is a screen showing a lie.
    public private(set) var memoDeleted = false

    public init() {}

    /// The memo the sheet is open on. The delete acts on THIS uid rather than on one the caller
    /// carries separately, so the sheet and the request cannot come to be about different memos.
    public var editingUID: String? {
        guard case .edit(let uid, _, _) = editing else { return nil }
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
        lastError = nil
        deleteStage = .idle
        memoDeleted = false
        editing = mode
    }

    public func dismiss() {
        editing = nil
        // A dismissal cannot abort a request already sent — see `nextDelete(_:on:)`.
        if deleteStage != .deleting { deleteStage = .idle }
    }

    // MARK: - deleting

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
        let previous = deleteStage
        deleteStage = Self.nextDelete(deleteStage, on: event)
        settle(event)
        guard Self.deletes(deleteStage), !Self.deletes(previous), let uid = editingUID else {
            return false
        }
        let succeeded = await delete(uid)
        let answer = DeleteEvent.returned(succeeded)
        deleteStage = Self.nextDelete(deleteStage, on: answer)
        settle(answer)
        return succeeded
    }

    /// What an answer from the server means for the sheet. Separate from the machine because the
    /// stage and the screen are two different questions.
    private func settle(_ event: DeleteEvent) {
        guard case .returned(let succeeded) = event else { return }
        if succeeded {
            lastError = nil
            memoDeleted = true
            editing = nil
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
        save: (ComposeView.Mode, ComposeSubmission) async -> Bool
    ) async -> Bool {
        guard let mode = editing else { return false }
        let saved = await save(mode, submission)
        lastError = saved ? nil : Self.failureMessage
        if saved { editing = nil }
        return saved
    }

    static let failureMessage = "This memo could not be saved. Nothing was changed on the server."
    static let deleteFailureMessage =
        "This memo could not be deleted. It is still on the server."
}
