import MemosCore
import SwiftUI

/// Select mode's Delete (MEMNG-589; the mockup's section 7): the question, which pictures it was
/// asked about, and what is allowed to reach the server.
///
/// `AttachmentDeleteFlow` for a list of pictures instead of one, and it keeps that machine's one
/// load-bearing property: there is NO path from `idle` to `deleting`. The Delete button opens a
/// question and nothing else; only the alert's yes starts a run, and the server hard-deletes, so a
/// stray event, a repeat tap or a re-render must not be able to remove anything nobody agreed to.
///
/// The uids travel INSIDE the stage, in the order they were chosen, for the reason the single
/// flow carries its one: a question asked about one set of pictures and a run sent about another
/// is the defect this type exists to make impossible. They are only ever the member's OWN chosen
/// pictures (`tap(_:in:)`); the question carries how many chosen pictures were left out because
/// they are another member's (MEMNG-684), so it can say so.
@MainActor
@Observable
public final class LibraryDeleteFlow {
    public enum Stage: Equatable, Sendable {
        case idle
        case asking([String], skipped: Int = 0)
        case deleting([String])
    }

    public enum Event: Equatable, Sendable {
        /// The toolbar's Delete, with the own pictures of the selection at that moment and how
        /// many others it skips (`tap(_:in:)`). Deliberately harmless.
        case tapped([String], skipped: Int = 0)
        /// The question was answered yes, in the alert.
        case confirmed
        /// The question was dismissed, by Cancel or by the alert going away.
        case cancelled
        /// The run ended, however it ended.
        case returned
    }

    public private(set) var stage = Stage.idle
    /// What the last run has to say — "N deleted, M failed" — or nil. The toast.
    public private(set) var message: String?

    /// Which run is the live one. Moved by `abandon`: a run that set out under another number has
    /// no screen left to answer to, so it changes neither the stage nor the message when it ends.
    private var run = 0

    public init() {}

    /// The pictures a question is open about, or nil while none is. What the alert binds to.
    public var asking: [String]? {
        guard case .asking(let uids, _) = stage else { return nil }
        return uids
    }

    /// How many chosen pictures the open question leaves out as another member's; 0 while none
    /// is open.
    public var skipping: Int {
        guard case .asking(_, let skipped) = stage else { return 0 }
        return skipped
    }

    /// The toolbar's Delete as an event: the selection's own pictures, in selection order, and the
    /// count of the others (`LibrarySelection.deletable`). The ONE place a delete's uids are taken
    /// from a selection, so another member's picture can reach neither the question nor the run.
    public static func tap(_ selection: LibrarySelection, in rows: [LibraryRow]) -> Event {
        let set = selection.deletable(in: rows)
        return .tapped(set.own, skipped: set.othersCount)
    }

    /// Whether a run this flow started is out. The spinner on the Delete button.
    public var isDeleting: Bool { Self.deletes(stage) != nil }

    /// The pictures being deleted right now, or nil. The ONE stage that may reach the network, and
    /// the uids it is allowed to name.
    public static func deletes(_ stage: Stage) -> [String]? {
        guard case .deleting(let uids) = stage else { return nil }
        return uids
    }

    public static func next(_ stage: Stage, on event: Event) -> Stage {
        switch event {
        case .tapped(let uids, let skipped):
            // Nothing of mine chosen is nothing to ask about — the disabled button says so, and
            // this says it again. And a repeat tap is one question, about the pictures it was
            // first asked about: it cannot restart a run or aim it elsewhere.
            guard stage == .idle, !uids.isEmpty else { return stage }
            return .asking(uids, skipped: skipped)
        case .confirmed:
            guard case .asking(let uids, _) = stage else { return stage }
            return .deleting(uids)
        case .cancelled:
            // A dismissal cannot recall a run that has already gone.
            if case .deleting = stage { return stage }
            return .idle
        case .returned:
            if case .deleting = stage { return .idle }
            return stage
        }
    }

    /// Moves the machine NOW, on the caller's own turn, and answers whether THIS event is the one
    /// that starts a run — synchronous for the reason `AttachmentDeleteFlow.claim` is: the alert's
    /// yes and its binding's dismissal land in the same turn, and wrapped in tasks they have no
    /// order between them.
    @discardableResult
    public func claim(_ event: Event) -> Bool {
        let previous = stage
        stage = Self.next(stage, on: event)
        // A new question is not the last run's report.
        if case .tapped = event, stage != previous { message = nil }
        return Self.deletes(stage) != nil && Self.deletes(previous) == nil
    }

    /// Runs the deletion a claim started, and applies what it says.
    ///
    /// The run is passed IN, as `AttachmentDeleteFlow.perform` takes its request: this layer has no
    /// store and no session, and it is what lets a test hold "the pictures asked about are the ones
    /// deleted" rather than trust it. It sends only from `deleting`, which only a claim can reach.
    /// - Returns: what the run did, or nil when nothing was run — no claim, or a run the store
    ///   refused because another one is out.
    @discardableResult
    public func perform(
        delete: @MainActor ([String]) async -> LibraryDeleteOutcome?
    ) async -> LibraryDeleteOutcome? {
        guard let uids = Self.deletes(stage) else { return nil }
        let mine = run
        let outcome = await delete(uids)
        // Select mode ended while the run was out. The server did what it did, and the store has
        // dropped those rows already; what this flow would SAY about it belongs to a screen that
        // is gone, and must not surface over whatever select mode is opened next.
        guard run == mine else { return outcome }
        stage = Self.next(stage, on: .returned)
        message = outcome.flatMap(Self.resultText)
        return outcome
    }

    /// Select mode ended — closed, left for Years or Months, the account changed, the Library went
    /// away. An open question closes; a run still out is left to finish, because a DELETE already
    /// sent cannot be taken back and one cut off halfway leaves nobody knowing whether the file
    /// went. It simply stops being this screen's: its answer changes nothing here (`perform`).
    public func abandon() {
        run += 1
        stage = .idle
        message = nil
    }

    /// The toast has been read, or has timed out.
    public func dismissMessage() {
        message = nil
    }

    /// What the alert asks. It names the count, so the yes is an answer about THIS many pictures,
    /// and, when the selection holds other members' pictures, how many of them stay (MEMNG-684).
    /// A selection with none of mine is never asked about (`next`); its sentence says why.
    public static func question(count: Int, skipped: Int = 0) -> String {
        let ask = count == 1 ? "Delete 1 Item?" : "Delete \(count) Items?"
        guard skipped > 0 else { return ask }
        if count == 0 {
            if skipped == 1 { return "Nothing to delete: 1 item belongs to another member." }
            return "Nothing to delete: \(skipped) items belong to another member."
        }
        if skipped == 1 { return "\(ask) 1 other belongs to another member and stays." }
        return "\(ask) \(skipped) others belong to another member and stay."
    }

    /// The alert's destructive button.
    public static let confirmTitle = "Delete"

    /// What the alert says underneath. Every picture asked about is the member's own, and the
    /// server hard-deletes: the file goes for good, and from any memo it was attached to.
    public static let explanation =
        "They are deleted from the server and from any memo they belong to. This can't be undone."

    /// The toast after a run, or nil when there is nothing to report: every picture went, or the
    /// run stopped because somebody else signed in, which is nothing to tell the new account.
    ///
    /// "Failed" counts every picture the run did not delete — the one the server refused and the
    /// ones after it that were never sent — because all of them are still there, still chosen.
    public static func resultText(_ outcome: LibraryDeleteOutcome) -> String? {
        guard !outcome.stoppedForSessionChange else { return nil }
        let failed = outcome.failedCount + outcome.notAttemptedCount
        guard failed > 0 else { return nil }
        return "\(outcome.deletedCount) deleted, \(failed) failed"
    }
}
