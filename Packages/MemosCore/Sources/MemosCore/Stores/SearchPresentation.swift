import Foundation

/// One search, being presented.
///
/// It is `Identifiable` because the sheet is raised FROM it rather than beside it, and that is the
/// whole point of the type. A sheet raised by a boolean draws whatever its content closure can see
/// at the moment the presentation begins; a content closure gated on a SEPARATE optional therefore
/// draws nothing at all when that optional has not landed yet — and a sheet whose root is nothing
/// has no `.task` on it either, so it does not even start loading. It sits blank until it is closed
/// and opened again over the state the first attempt left behind, which is exactly what MEMNG-175
/// reported: blank the first time, right the second.
///
/// Carried by the presentation, the store cannot be late: there is no state in which the sheet is
/// up and the thing it draws is not there.
public struct SearchSession: Identifiable {
    public let id: UUID
    public let search: MemoSearch

    public init(id: UUID = UUID(), search: MemoSearch) {
        self.id = id
        self.search = search
    }
}

/// The screen's search and whether its sheet is up — one object, because they are two facts that
/// have to move together and, as two pieces of view state, did not.
///
/// They are not the same lifetime, which is why they were two in the first place: the results
/// screen is a push over a timeline that never moved, and it goes on reading and paging that
/// search's store long after the sheet which started it has gone. So closing drops the SESSION and
/// keeps the STORE. Opening sets both, in one change, and the sheet reads its store from the
/// session rather than from anything alongside it.
@MainActor
@Observable
public final class SearchPresentation {
    /// The store the results screen reads. Outlives the sheet deliberately.
    public private(set) var search: MemoSearch?
    /// The sheet's item: non-nil exactly while the sheet is up.
    public var session: SearchSession?

    public init() {}

    /// Raises the sheet on a new search.
    ///
    /// Nothing is remembered between openings — a term left over from yesterday is a filter
    /// silently hiding memos (design note §5, Q4) — so this is handed a fresh search each time and
    /// the session's new id makes it a new presentation.
    public func open(_ search: MemoSearch) {
        self.search = search
        session = SearchSession(search: search)
    }

    /// Puts the sheet away. The store stays: every close is either a hand-off to the results
    /// screen, which has just adopted it, or an abandonment that `MemoSearch.stop` handles on its
    /// own terms. Dropping it here would empty the list the reader is walking into and cost it the
    /// cursor its next page needs.
    public func close() {
        session = nil
    }
}

extension SearchPresentation {
    /// What a closing sheet does with the search it presented.
    public enum CloseAction: Equatable {
        /// The results screen has adopted the store — rows, cursor, and any answer still on its
        /// way. Nothing may be cancelled: the reader is walking into exactly that answer.
        case adopt
        /// Nobody is left reading. Cancel and reset.
        case abandon
    }

    /// The one decision every sheet close funnels through.
    ///
    /// The hand-off case exists because cancelling "stray" work on close cancelled the search
    /// itself whenever the network was slower than the dismissal animation: the chip tap's own
    /// request was still the store's in-flight task, so the results screen opened over a spinner
    /// that could never resolve (MEMNG-177, review round). A hand-off therefore touches nothing;
    /// the sheet's own section loads end with their `.task`s on teardown.
    public static func closeAction(handingOff: Bool) -> CloseAction {
        handingOff ? .adopt : .abandon
    }
}
