import MemosCore

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
    struct Pending: Equatable {
        let uid: String
        let question: VisibilityChange.Question
    }

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

    /// The alert's title for the question on screen.
    var title: String { pending.map { "Make this memo \($0.question.to.label)?" } ?? "" }

    /// A person picked `to` on memo `uid`, which is `from` as the screen knows it.
    mutating func pick(_ to: MemoVisibility, from: MemoVisibility?, on uid: String) -> Next {
        switch VisibilityChange.propose(to, from: from) {
        case .unchanged: return .send(nil)
        case .ready(let change): return .send(change)
        case .ask(let question):
            pending = Pending(uid: uid, question: question)
            return .asking
        }
    }

    /// What the store answered a change on memo `uid`. A question there is asked exactly like
    /// one asked at the pick; anything else leaves this as it was.
    mutating func heard(_ outcome: ComposeOutcome, on uid: String) {
        guard case .ask(let question) = outcome else { return }
        pending = Pending(uid: uid, question: question)
    }

    /// The answer to the question `shown`: what to send, or nil when nothing goes.
    ///
    /// The question is taken down HERE, synchronously, before anything is sent — so a second tap
    /// on the yes, or a yes to a question that is no longer the one up, finds nothing to answer
    /// and sends nothing. A dismissal takes it down and sends nothing.
    mutating func answer(_ shown: Pending?, confirmed: Bool) -> Send? {
        guard let shown, shown == pending else { return nil }
        pending = nil
        guard confirmed else { return nil }
        return Send(uid: shown.uid, change: shown.question.confirmed())
    }
}
