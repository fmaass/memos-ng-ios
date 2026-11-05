import Foundation
import MemosCore
import MemosOutbox

/// The Info sheet's Visibility chip (MEMNG-970): what it draws, and where a change from it goes.
extension MediaInfoRows {
    /// The memo's audience as the Memo section draws it (MEMNG-970).
    enum VisibilityChip: Equatable {
        /// A menu of the audiences: the memo is the person's and a change can be sent.
        case menu(MemoVisibility)
        /// The audience, and nothing to tap: the server refuses a change from anyone else.
        case inert(MemoVisibility)
    }

    /// What the viewer's store holds for the page's memo: the looked-up memo, or for a carried
    /// one the answer a change from this sheet left. Nil for an orphan.
    static func held(_ link: MediaViewerContext.MemoLink, in store: MediaContextStore) -> Memo? {
        switch link {
        case .orphan: return nil
        case .carried(let memo): return store.memo(memo.uid)
        case .lookup(let uid): return store.memo(uid)
        }
    }

    /// A menu only for the person's own memo and only where a change can be sent; inert for
    /// everyone else, whose change the server would refuse.
    static func chip(_ card: MemoCard, canChange: Bool) -> VisibilityChip {
        card.mine && canChange ? .menu(card.visibility) : .inert(card.visibility)
    }
}

extension MediaInfoSheet {
    /// Sends a change of the memo's audience through the timeline's line for that memo, and puts
    /// the memo the server answered with where this sheet reads its memo, so the chip shows the
    /// server's answer rather than the pick — for a memo the timeline does not hold as much as for
    /// one it does. The store judges the answer against the session that issued it.
    static func sendVisibility(
        _ change: VisibilityChange,
        uid: String,
        through timeline: TimelineStore,
        owing queue: (any MemoEditQueue)? = nil,
        holding store: MediaContextStore,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        let answer = await timeline.setVisibilityAnswering(
            change, uid: uid, through: queue, using: handle, baseURL: baseURL)
        if let memo = answer.memo { store.adoptAnswer(memo, issuedUnder: handle) }
        return answer.outcome
    }
}

extension MediaInfoSheet {
    /// What the sheet says under the chip after a change from it (MEMNG-1034): the failure's own
    /// sentence, the one the compose and edit sheets say, or nil when there is nothing to tell —
    /// a change that went, and a question, which the widening ask puts up instead.
    static func failureLine(for outcome: ComposeOutcome) -> String? {
        outcome.failure.map(ComposeFailurePresentation.sentence(for:))
    }

    /// The line under the chip, about the LATEST change sent from this sheet and no other: a
    /// change clears it as it goes, and an answer to a change that a later one overtook lands
    /// nowhere, so an outlived failure cannot put its sentence over a later change's answer.
    struct ChipLine: Equatable {
        private(set) var sentence: String?
        private var latest = 0

        /// A change is going: the line clears, and the ticket returned is the one its answer
        /// must carry.
        mutating func sending() -> Int {
            latest += 1
            sentence = nil
            return latest
        }

        /// The answer to the change that was handed `ticket`.
        mutating func heard(_ outcome: ComposeOutcome, for ticket: Int) {
            guard ticket == latest else { return }
            sentence = MediaInfoSheet.failureLine(for: outcome)
        }
    }
}
