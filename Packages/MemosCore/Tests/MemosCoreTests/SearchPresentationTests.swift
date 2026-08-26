import Foundation
import MemosAPI
import MemosCore
import Testing

/// Raising the search sheet, as one change rather than two.
///
/// The defect this pins is not in the sheet at all, it is in what the sheet is raised FROM. A sheet
/// presented on a boolean draws whatever its content closure can see at the moment the presentation
/// begins, and a content closure gated on a SEPARATE optional draws nothing at all when that
/// optional has not landed — a sheet whose root is nothing, with no `.task` on it to load anything
/// either. It stays blank until it is closed and opened again over the state the first attempt left
/// behind, which is exactly what the owner saw (MEMNG-175).
@MainActor
@Suite("Search presentation")
struct SearchPresentationTests {
    private static func search() -> MemoSearch {
        MemoSearch(
            client: Stub.client { _, _, _ in Stub.json(Stub.memoList(["a"], nextCursor: nil)) },
            baseURL: Stub.baseURL
        )
    }

    @Test("nothing is presented until a search is opened")
    func nothingIsPresentedUntilOpened() {
        let presentation = SearchPresentation()

        #expect(presentation.session == nil)
        #expect(presentation.search == nil)
    }

    /// The invariant the whole type exists for: a presented sheet always has its store, because
    /// the store is IN the thing being presented rather than beside it.
    @Test("opening presents the very search it retained, in one change")
    func openingPresentsTheSearchItRetained() {
        let presentation = SearchPresentation()
        let search = Self.search()

        presentation.open(search)

        #expect(presentation.session?.search === search, "the sheet was raised over another store")
        #expect(presentation.search === search, "the results screen would read a different store")
        // A second opening is a second presentation, not the first one re-shown: the sheet
        // remembers nothing between openings, so SwiftUI must be told it is a new sheet.
        let first = presentation.session?.id
        presentation.open(Self.search())
        #expect(presentation.session?.id != first, "reopening reused the closed sheet's identity")
        #expect(presentation.session?.search !== search, "reopening kept the old search")
    }

    /// Closing is where the two lifetimes part. The results screen is a push over a timeline that
    /// never moved and it goes on paging this store; dropping it here would empty the list the
    /// reader is walking into and cost it the cursor its next page needs.
    @Test("closing puts the sheet away and leaves the store the results screen reads")
    func closingKeepsTheStore() {
        let presentation = SearchPresentation()
        let search = Self.search()
        presentation.open(search)

        presentation.close()

        #expect(presentation.session == nil, "the sheet stayed up")
        #expect(presentation.search === search, "closing the sheet took the results' list with it")
    }
}

extension SearchPresentationTests {
    @Test("a hand-off adopts the search; every other close abandons it")
    func closeActionPerCause() {
        #expect(SearchPresentation.closeAction(handingOff: true) == .adopt)
        #expect(SearchPresentation.closeAction(handingOff: false) == .abandon)
    }

    /// The review blocker's exact sequence: the chip starts the search, the sheet closes on the
    /// hand-off, and the answer arrives only after the dismissal. Adoption means nobody touched
    /// the store, so the late answer still fills the results the reader walked into.
    @Test("an answer that lands after a hand-off still fills the results")
    func aHandedOffSearchSurvivesItsSheet() async {
        let entered = Latch()
        let release = Latch()
        let search = MemoSearch(
            client: Stub.client { _, _, _ in
                entered.signal()
                await release.wait()
                if Task.isCancelled { throw URLError(.cancelled) }
                return Stub.json(Stub.memoList(["late"], nextCursor: nil))
            },
            baseURL: Stub.baseURL
        )

        search.run(MemoQuery(tags: ["curated"]), showing: "#curated")
        await entered.wait()
        // The sheet closes on a hand-off. `closeAction(.adopt)` is "touch nothing", so the test,
        // like the view, calls nothing on the store.
        release.signal()
        await search.settled()

        guard case .matched = search.outcome else {
            Issue.record("the handed-off search ended in \(search.outcome), not matched")
            return
        }
        #expect(
            search.results.memos.map(\.uid) == ["late"],
            "the late answer never reached the reader"
        )
    }

    /// The contrast that keeps `.abandon` honest: the same late answer after `stop()` lands
    /// nowhere — and silently, which is StoreCancellationTests' half of the contract.
    @Test("an abandoned search does not keep its late answer")
    func anAbandonedSearchIsReset() async {
        let entered = Latch()
        let release = Latch()
        let search = MemoSearch(
            client: Stub.client { _, _, _ in
                entered.signal()
                await release.wait()
                if Task.isCancelled { throw URLError(.cancelled) }
                return Stub.json(Stub.memoList(["late"], nextCursor: nil))
            },
            baseURL: Stub.baseURL
        )

        search.run(MemoQuery(tags: ["curated"]), showing: "#curated")
        await entered.wait()
        search.stop()
        release.signal()
        await search.settled()

        #expect(search.results.memos.isEmpty, "an abandoned search kept rows nobody is reading")
        #expect(search.results.lastError == nil)
    }
}
