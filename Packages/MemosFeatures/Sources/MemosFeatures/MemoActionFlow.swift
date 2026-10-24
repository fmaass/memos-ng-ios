import MemosCore
import SwiftUI

/// Select mode's memo actions on a screen (MEMNG-788): the banner of the last run — "N of M
/// added", or "Another change is still running" when the store refused. Set visibility left select
/// mode on 2026-10-18 (visibility belongs to a memo, not to a picture), and its question with it;
/// `MemoActionStore` keeps the action.
///
/// **What a run does after it returns is fenced by the session that issued it** (`perform`): the
/// banner and every re-read are asked for only while that session's generation is still the
/// screen's, checked synchronously before each one. The banner belongs to select mode — a run
/// that select mode closed under says nothing — but the re-read belongs to the data: a batch that
/// changed memos still has the screen read them again under its own session after select mode
/// closed.
@MainActor
@Observable
final class MemoActionFlow {
    /// What the last run has to say, or nil. Also published into `banner`, which the screen shows.
    private(set) var message: String?
    /// Which run is the live one: moved by `abandon`, so a run that set out before has no select
    /// mode left to speak to.
    private var run = 0
    /// The screen's one result banner (`SelectBanner`).
    let banner: SelectBanner

    init(banner: SelectBanner = SelectBanner()) {
        self.banner = banner
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
        if outcome.heldUnchecked > 0 {
            text += " — \(outcome.heldUnchecked) not added, this phone's outbox can't be read"
        }
        if let failure = outcome.failure { text += ". \(failure)" }
        return text
    }

    /// Runs an action issued under the session of `generation` and applies what it says: a
    /// finished run's banner, then each of the screen's re-reads (`rereads`, in order); a refusal's
    /// banner and no re-read; nothing for a run whose session ended.
    ///
    /// `current` is the screen's session generation now. It is asked synchronously after the run
    /// returns and again before every re-read, so neither the banner nor a read is asked for under
    /// a session that did not issue the run — however the run itself ended. Select mode closing
    /// while the run was out silences only the banner: the re-reads still go, under the issuing
    /// session, because the memos changed whether or not anybody is still selecting.
    func perform(
        issuedUnder generation: Int,
        current: @MainActor () -> Int?,
        rereads: [@MainActor () async -> Void],
        _ action: @MainActor () async -> MemoActionResult
    ) async {
        let mine = run
        let result = await action()
        guard current() == generation else { return }
        switch result {
        case .finished(let outcome):
            if run == mine { say(Self.resultText(outcome)) }
            for reread in rereads {
                guard current() == generation else { return }
                await reread()
            }
        case .refused:
            if run == mine { say(MemoActionStore.busySentence) }
        case .superseded:
            break
        }
    }

    /// The flow's sentence, and the banner's: published when there is one, retired — if it is
    /// still the one shown — when there is none.
    private func say(_ text: String?) {
        message = text
        if let text {
            banner.publish(text, from: .action)
        } else {
            banner.retire(.action)
        }
    }

    /// Select mode ended: a run still out stops being this screen's.
    func abandon() {
        run += 1
        say(nil)
    }

    func dismissMessage() { say(nil) }
}
