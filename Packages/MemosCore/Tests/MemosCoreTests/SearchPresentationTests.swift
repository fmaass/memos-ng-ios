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
