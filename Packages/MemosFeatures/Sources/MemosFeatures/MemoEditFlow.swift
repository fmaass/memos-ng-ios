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

    public init() {}

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
        editing = mode
    }

    public func dismiss() {
        editing = nil
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
}
