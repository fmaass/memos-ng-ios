import MemosCore
import SwiftUI

/// Select mode's memo actions on a screen (MEMNG-788): the visibility question and its answer,
/// and the banner of the last run — "N of M changed", "N of M added", or "Another change is still
/// running" when the store refused.
///
/// **The question is about the memos, and says so** (plan decision 5): N counts the DISTINCT memos
/// of the caller's chosen pictures, and the message discloses that a memo changes as a whole —
/// its text and every other picture on it. The memos, the value, the session generation and the
/// screen's filter are captured WHEN IT ASKS; the answer is claimed synchronously (`claim`), so a
/// second answer finds none, and one given under another session or filter sends nothing.
@MainActor
@Observable
final class MemoActionFlow {
    /// What a visibility question asked about.
    struct Question: Equatable {
        let memos: [String]
        let visibility: MemoVisibility
        let generation: Int
        /// The screen's filter when it asked, as the screen spells it.
        let filter: String
    }

    /// The open visibility question, or nil. What the alert binds to.
    private(set) var asking: Question?
    /// What the last run has to say, or nil. The banner.
    private(set) var message: String?
    /// Which run is the live one: moved by `abandon`, so a run that set out before has no screen
    /// left to answer to.
    private var run = 0

    /// The visibility choices a member can give a whole memo from select mode.
    static let choices: [MemoVisibility] = [.public, .protected]
    static let addRowTitle = "Add to trip"
    static let confirmTitle = "Change"
    static let explanation =
        "The memos these pictures belong to change as a whole — "
        + "their text and every other picture on them."

    static func visibilityRowTitle(_ count: Int) -> String {
        "Set visibility for \(memos(count))"
    }

    static func question(_ count: Int, to visibility: MemoVisibility) -> String {
        "Change \(memos(count)) to \(visibility.label)?"
    }

    private static func memos(_ count: Int) -> String {
        count == 1 ? "1 memo" : "\(count) memos"
    }

    /// The banner of a finished run: of M asked, N changed (or added), the pictures the outbox
    /// held back, and what stopped the rest.
    static func resultText(_ outcome: MemoActionOutcome) -> String {
        let verb: String
        switch outcome.action {
        case .visibility: verb = "changed"
        case .addToTrip: verb = "added"
        }
        var text = "\(outcome.changed) of \(outcome.asked) \(verb)"
        if outcome.heldByOutbox == 1 {
            text += " — 1 waits for an edit this phone is still sending"
        } else if outcome.heldByOutbox > 1 {
            text += " — \(outcome.heldByOutbox) wait for edits this phone is still sending"
        }
        if let failure = outcome.failure { text += ". \(failure)" }
        return text
    }

    /// The row's Public or Just us: a question about `memos`, or nothing when there are none.
    func ask(memos: [String], visibility: MemoVisibility, generation: Int, filter: String) {
        guard !memos.isEmpty else { return }
        message = nil
        asking = Question(
            memos: memos, visibility: visibility, generation: generation, filter: filter)
    }

    /// The alert's Change, claimed NOW: the question is taken in this turn, so a second answer
    /// finds none, and it is handed back only while the session and the filter it was asked under
    /// are still the screen's.
    func claim(generation: Int, filter: String) -> Question? {
        guard let asked = asking else { return nil }
        asking = nil
        guard asked.generation == generation, asked.filter == filter else { return nil }
        return asked
    }

    /// Cancel, or the alert going away.
    func cancel() { asking = nil }

    /// The session or the filter changed: the open question is no question any more.
    func void() { asking = nil }

    /// Runs an action and applies what it says: a finished run's banner and then the screen's
    /// re-read (`reread`); a refusal's banner and no re-read; nothing for a run whose session
    /// ended, or one whose select mode ended while it was out.
    func perform(
        reread: @MainActor () async -> Void,
        _ action: @MainActor () async -> MemoActionResult
    ) async {
        let mine = run
        let result = await action()
        guard run == mine else { return }
        switch result {
        case .finished(let outcome):
            message = Self.resultText(outcome)
            await reread()
        case .refused:
            message = MemoActionStore.busySentence
        case .superseded:
            break
        }
    }

    /// Select mode ended: the question closes and a run still out stops being this screen's.
    func abandon() {
        run += 1
        asking = nil
        message = nil
    }

    func dismissMessage() { message = nil }
}
