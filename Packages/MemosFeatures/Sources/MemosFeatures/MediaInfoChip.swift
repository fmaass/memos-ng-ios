import Foundation
import MemosCore

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
        holding store: MediaContextStore,
        using handle: SessionHandle,
        baseURL: URL
    ) async -> ComposeOutcome {
        let answer = await timeline.setVisibilityAnswering(
            change, uid: uid, using: handle, baseURL: baseURL)
        if let memo = answer.memo { store.adoptAnswer(memo, issuedUnder: handle) }
        return answer.outcome
    }
}
