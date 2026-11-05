import Foundation
import MemosAPI

/// Who may see a memo, moved from one audience to another — and the one place that decides
/// whether that move may simply happen or has to be agreed to first (MEMNG-969).
///
/// The rule is the owner's (2026-10-27): NARROWING — Public to Just us to Private — goes as it is,
/// because showing something to fewer people is never the mistake anybody has to be warned about.
/// WIDENING asks once, in one sentence that names what it means, and only a yes sends it; a
/// dismissal sends nothing.
///
/// The rule is a property of the TYPE rather than of the screens that ask it. Every store that
/// changes a memo's visibility takes a `VisibilityChange`, and a widening one can only be made by
/// answering its `Question` — `init` is private to this file. So a screen that forgot to ask has
/// nothing to hand the store: the edit sheet, the timeline's long press and the media Info sheet
/// cannot drift apart, because none of them carries a copy of the rule to drift.
///
/// An unknown starting point (`from == nil`, a batch of memos whose audiences were never read)
/// counts as widening unless the target is Private, which narrows from anything.
public struct VisibilityChange: Hashable, Sendable {
    /// The audience the memo had as the asking screen knew it, or nil when nobody read it.
    public let from: MemoVisibility?
    /// The audience it is to have.
    public let to: MemoVisibility
    /// Whether a person said yes to this change. Only `Question.confirmed()` sets it.
    public let confirmed: Bool

    private init(from: MemoVisibility?, to: MemoVisibility, confirmed: Bool) {
        self.from = from
        self.to = to
        self.confirmed = confirmed
    }

    /// Asked again by the store once the memo's line reaches this change: a narrowing proposed
    /// against a row an earlier change was still moving can have become a widening by the time
    /// it goes (Public→Private in flight, then "Just us"). Unconfirmed, it is then not sent.
    public func maySend(over current: MemoVisibility?) -> Bool {
        confirmed || !Self.widens(from: current ?? from, to: to)
    }

    /// The question this change has to be asked AGAIN with once its memo's line reaches it, or nil
    /// when it may simply go (MEMNG-981). A narrowing that has become a widening is not refused:
    /// it is the same widening any screen asks about, from where the memo now stands, and only
    /// that question's yes sends it.
    public func reask(over current: MemoVisibility?) -> Question? {
        maySend(over: current) ? nil : Question(from: current ?? from, to: to)
    }

    /// What asking for `to` on a memo that is `from` amounts to.
    /// The question this change must be answered before it is sent at a LATER, unknown instant —
    /// an edit job's PATCH (MEMNG-1187) — or nil when no audience the memo can be given meanwhile
    /// makes it a widening: it was confirmed, or it is Private.
    public var askedBeforeDeferral: Question? {
        maySend(over: .private) ? nil : Question(from: from, to: to)
    }

    public enum Proposal: Hashable, Sendable {
        /// The memo is already there: nothing is sent.
        case unchanged
        /// A narrowing: send it.
        case ready(VisibilityChange)
        /// A widening: ask this, and send only its `confirmed()` change.
        case ask(Question)
    }

    /// The one question a widening asks.
    public struct Question: Hashable, Sendable {
        public let from: MemoVisibility?
        public let to: MemoVisibility

        /// What the widening means, in one line.
        public var sentence: String { VisibilityChange.meaning(of: to) }

        /// The yes: the only way a widening change comes into being.
        public func confirmed() -> VisibilityChange {
            VisibilityChange(from: from, to: to, confirmed: true)
        }
    }

    public static func propose(_ to: MemoVisibility, from: MemoVisibility?) -> Proposal {
        if from == to { return .unchanged }
        if widens(from: from, to: to) { return .ask(Question(from: from, to: to)) }
        return .ready(VisibilityChange(from: from, to: to, confirmed: false))
    }

    /// Whether this change shows the memo to more people than before.
    public var widens: Bool { Self.widens(from: from, to: to) }

    static func widens(from: MemoVisibility?, to: MemoVisibility) -> Bool {
        guard let from else { return to != .private }
        return breadth(to) > breadth(from)
    }

    /// The audience of the two that reaches fewer people: where a memo may stand when the store
    /// cannot tell which of two it holds, so that a change widening from either is asked
    /// (MEMNG-1033).
    static func narrower(_ a: MemoVisibility, _ b: MemoVisibility) -> MemoVisibility {
        breadth(b) < breadth(a) ? b : a
    }

    /// How many people an audience reaches, as an order.
    private static func breadth(_ visibility: MemoVisibility) -> Int {
        switch visibility {
        case .private: 0
        case .protected: 1
        case .public: 2
        }
    }

    /// The sentence a widening to `to` is asked with. Private is never widened to.
    static func meaning(of to: MemoVisibility) -> String {
        switch to {
        case .public: "Everyone with the link can see it."
        case .protected: "Everyone with an account on this server can see it."
        case .private: "Only you can see it."
        }
    }

    /// The value the PATCH carries.
    var generated: Components.Schemas.Visibility { to.generated }
}
