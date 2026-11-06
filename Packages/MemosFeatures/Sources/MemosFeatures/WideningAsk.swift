import MemosCore
import SwiftUI

/// The one conversation a widening has, for every screen that moves a memo's audience: the edit
/// sheet's Save and the timeline's long press (MEMNG-969, MEMNG-981).
///
/// The RULE is `VisibilityChange`'s; this is what a screen does with its answer. A pick either
/// goes or puts a question up; a store answer that is a question (`ComposeOutcome.ask`, a
/// narrowing that became a widening while its memo's line ran) puts up the same question; and the
/// answer is decided here, once: a dismissal sends nothing, and a yes sends that question's
/// `confirmed()` change exactly once. The screens hold this as state and call it; neither carries
/// a copy of the decision to drift.
struct WideningAsk: Equatable {
    /// A question waiting for its answer, and the memo it is about.
    ///
    /// `id` is the presentation: the same question put up again — a dismissal, then the store
    /// answering that memo with the identical question — is a new one, so a yes still on its way
    /// from the alert that was dismissed matches nothing (MEMNG-1033).
    struct Pending: Equatable {
        let id: Int
        let uid: String
        let question: VisibilityChange.Question
    }

    /// The last presentation's id; never reset, so no two presentations share one.
    private var presented = 0

    /// What a pick asks the screen to do next.
    enum Next: Equatable {
        /// Send this. Nil is the memo's own audience: an edit's Save still goes, saying nothing
        /// about who may see it, and a long press has nothing to send.
        case send(VisibilityChange?)
        /// The question is up, and nothing goes until it is answered.
        case asking
    }

    /// The yes to a question: the change to send, and the memo to send it to.
    struct Send: Equatable {
        let uid: String
        let change: VisibilityChange
    }

    /// The question on screen, or nil.
    private(set) var pending: Pending?

    /// The questions put up while another was on screen, oldest first; each is asked once the one
    /// before it is answered (MEMNG-1193). Replacing the one on screen instead would lose it
    /// without an answer: nothing sent, which is safe, but a change somebody asked for gone.
    private var queued: [Pending] = []

    /// The alert's title for the question on screen.
    var title: String { pending.map { "Make this memo \($0.question.to.label)?" } ?? "" }

    /// A person picked `to` on memo `uid`, which is `from` as the screen knows it.
    mutating func pick(_ to: MemoVisibility, from: MemoVisibility?, on uid: String) -> Next {
        switch VisibilityChange.propose(to, from: from) {
        case .unchanged: return .send(nil)
        case .ready(let change): return .send(change)
        case .ask(let question):
            present(question, on: uid)
            return .asking
        }
    }

    /// What the store answered a change on memo `uid`. A question there is asked exactly like
    /// one asked at the pick; anything else leaves this as it was.
    mutating func heard(_ outcome: ComposeOutcome, on uid: String) {
        guard case .ask(let question) = outcome else { return }
        present(question, on: uid)
    }

    /// One question per memo in line: the question already on screen for that memo is not
    /// asked twice, and a newer one for a memo whose question is still waiting takes its place
    /// there — the later pick is what the person wants now, and two yeses would be two changes.
    private mutating func present(_ question: VisibilityChange.Question, on uid: String) {
        if let pending, pending.uid == uid, pending.question == question { return }
        presented += 1
        let asked = Pending(id: presented, uid: uid, question: question)
        if pending == nil {
            pending = asked
        } else if let waiting = queued.firstIndex(where: { $0.uid == uid }) {
            queued[waiting] = asked
        } else {
            queued.append(asked)
        }
    }

    /// The answer to the question `shown`: what to send, or nil when nothing goes.
    ///
    /// The question is taken down HERE, synchronously, before anything is sent — so a second tap
    /// on the yes, or a yes to a question that is no longer the one up, finds nothing to answer
    /// and sends nothing. A dismissal takes it down and sends nothing. Either way the next queued
    /// question goes up in its place.
    mutating func answer(_ shown: Pending?, confirmed: Bool) -> Send? {
        guard let shown, shown == pending else { return nil }
        pending = queued.isEmpty ? nil : queued.removeFirst()
        guard confirmed else { return nil }
        return Send(uid: shown.uid, change: shown.question.confirmed())
    }

    /// The `isPresented` an alert over `ask` is rendered with: up while a question is, and its
    /// dismissal answers the presentation THIS render showed (MEMNG-1193). The alert writes that
    /// dismissal after its button's action has run, and an answer promotes the next queued
    /// question — so a dismissal reading `pending` when it arrives would take down a question
    /// nobody has seen yet.
    static func presented(_ ask: Binding<WideningAsk>) -> Binding<Bool> {
        let shown = ask.wrappedValue.pending
        return Binding(
            get: { ask.wrappedValue.pending != nil },
            set: { if !$0 { _ = ask.wrappedValue.answer(shown, confirmed: false) } }
        )
    }
}
