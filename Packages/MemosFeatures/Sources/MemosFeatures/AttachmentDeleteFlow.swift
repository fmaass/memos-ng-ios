import MemosCore
import SwiftUI

/// Removing ONE picture from a memo that is already posted: what a long press opens, what the
/// question asks, and what is allowed to reach the server.
///
/// The same discipline the whole-memo delete is built on (`MemoEditFlow.nextDelete`), for the same
/// reason: the tap that opens the conversation and the tap that destroys something are different
/// events, and only one of them reaches the network. There is NO path from `idle` to `deleting`, so
/// a stray event, a repeat tap or a re-render cannot remove a picture nobody agreed to remove — and
/// the server hard-deletes, so there is nothing to undo afterwards.
///
/// A model rather than three modifiers in a view body because TWO surfaces share it — the detail
/// gallery's context menu and the full-screen viewer's overlay — and "exactly one delete, of the
/// picture that was asked about, and only after a question was answered" is a rule about orders,
/// which is what a view body cannot be asked about.
@MainActor
@Observable
public final class AttachmentDeleteFlow {
    /// How far the conversation has got, and about WHICH picture. The uid is part of the stage
    /// rather than kept beside it: a question open about one picture and a request sent about
    /// another is the bug this type exists to make impossible.
    public enum Stage: Equatable, Sendable {
        case idle
        case asking(String)
        case deleting(String)
    }

    public enum Event: Equatable, Sendable {
        /// The destructive row was chosen, on this attachment. Deliberately harmless.
        case tapped(String)
        /// The question was answered yes, in the alert.
        case confirmed
        /// The question was dismissed, by Cancel or by the alert going away.
        case cancelled
        /// The server answered.
        case returned(Bool)
    }

    public private(set) var stage = Stage.idle
    /// Why the last delete did not work, or nil. A haptic is not a message.
    public private(set) var lastError: String?

    public init() {}

    /// The picture a question is open about, or nil while none is. What the alert binds to.
    public var asking: String? {
        guard case .asking(let uid) = stage else { return nil }
        return uid
    }

    /// The picture being deleted right now, or nil. The ONE stage that may reach the network, and
    /// the uid it is allowed to name.
    public static func deletes(_ stage: Stage) -> String? {
        guard case .deleting(let uid) = stage else { return nil }
        return uid
    }

    public static func next(_ stage: Stage, on event: Event) -> Stage {
        switch event {
        case .tapped(let uid):
            // Idempotent: a double tap is one question, asked once about one picture, and it
            // cannot restart a request already in flight or move it to a different file.
            return stage == .idle ? .asking(uid) : stage
        case .confirmed:
            guard case .asking(let uid) = stage else { return stage }
            return .deleting(uid)
        case .cancelled:
            // A dismissal cannot recall a request that has already gone.
            if case .deleting = stage { return stage }
            return .idle
        case .returned:
            if case .deleting = stage { return .idle }
            return stage
        }
    }

    /// Feeds one event to the machine, RUNS the request when that event is the one that starts it,
    /// and applies the answer.
    ///
    /// The request is passed IN, exactly as `MemoEditFlow.advanceDelete` takes it, because the flow
    /// has no store and no client — and because that is what makes "exactly one delete, of the
    /// picture that was asked about" a thing a test can hold rather than a sequence it has to
    /// trust. It fires on the TRANSITION into `deleting` and nowhere else: `previous` is read
    /// before the machine moves, so a second confirmation arriving while the request is out sends
    /// nothing.
    @discardableResult
    public func advance(
        _ event: Event,
        delete: @MainActor (String) async -> Bool
    ) async -> Bool {
        let previous = stage
        stage = Self.next(stage, on: event)
        settle(event)
        guard let uid = Self.deletes(stage), Self.deletes(previous) == nil else { return false }
        let succeeded = await delete(uid)
        let answer = Event.returned(succeeded)
        stage = Self.next(stage, on: answer)
        settle(answer)
        return succeeded
    }

    /// What an event means for what the screen SAYS. Separate from the machine because the stage
    /// and the message are two different questions.
    private func settle(_ event: Event) {
        switch event {
        case .tapped:
            // A new question is not the last one's failure.
            lastError = nil
        case .returned(let succeeded):
            lastError = succeeded ? nil : Self.failureMessage
        case .confirmed, .cancelled:
            break
        }
    }

    /// What the destructive row and the alert's yes are CALLED. A photo and a clip are different
    /// words to somebody about to remove one, and the file itself is what decides which.
    public static func title(for attachment: MemoAttachment) -> String {
        attachment.isVideo ? "Delete Video" : "Delete Photo"
    }

    /// What the alert asks.
    public static func question(for attachment: MemoAttachment) -> String {
        attachment.isVideo ? "Delete this video?" : "Delete this photo?"
    }

    /// What the alert says underneath. It states both halves — the memo and the server — because
    /// the memo keeps its words and only the file goes, and because the file goes for good.
    public static let explanation =
        "It is removed from the memo and from the server. This can't be undone."

    static let failureMessage = "This picture could not be deleted. It is still on the server."
}
