import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

private func row(_ uid: String, mine: Bool = true) -> LibraryRow {
    LibraryRow(
        attachment: MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready),
        takenAt: nil,
        mine: mine,
        filename: "\(uid).jpg"
    )
}

/// What select mode draws (MEMNG-588, the mockup's section 7), held as values.
@MainActor
@Suite("Library select mode, as drawn")
struct LibrarySelectionPresentationTests {
    @Test("the toolbar counts what is chosen, in the singular for one")
    func countText() {
        #expect(LibrarySelectionPresentation.countText(0) == "0 Items Selected")
        #expect(LibrarySelectionPresentation.countText(1) == "1 Item Selected")
        #expect(LibrarySelectionPresentation.countText(2) == "2 Items Selected")
        #expect(LibrarySelectionPresentation.countText(120) == "120 Items Selected")
    }

    @Test("outside select mode every tile opens, mine or not")
    func browsingTiles() {
        let selection = LibrarySelection()
        #expect(LibrarySelectionPresentation.tile(for: row("a"), in: selection) == .browsing)
        #expect(
            LibrarySelectionPresentation.tile(for: row("x", mine: false), in: selection)
                == .browsing)
    }

    @Test("in select mode an own tile is selectable, checked once chosen; another's is inert")
    func selectModeTiles() {
        var selection = LibrarySelection()
        selection.begin()
        selection.toggle(row("a"))

        #expect(
            LibrarySelectionPresentation.tile(for: row("a"), in: selection)
                == .selectable(selected: true))
        #expect(
            LibrarySelectionPresentation.tile(for: row("b"), in: selection)
                == .selectable(selected: false))
        #expect(
            LibrarySelectionPresentation.tile(for: row("x", mine: false), in: selection) == .inert)
        #expect(LibrarySelectionPresentation.tile(for: nil, in: selection) == .inert)
    }

    @Test("a placed picture finds its row only while the list still holds it at that index")
    func rowAtIndex() {
        let items = [row("a"), row("b")]

        #expect(LibrarySelectionPresentation.row(at: 1, uid: "b", in: items)?.id == "b")
        #expect(LibrarySelectionPresentation.row(at: 1, uid: "a", in: items) == nil)
        #expect(LibrarySelectionPresentation.row(at: 2, uid: "b", in: items) == nil)
        #expect(LibrarySelectionPresentation.row(at: -1, uid: "a", in: items) == nil)
        #expect(LibrarySelectionPresentation.row(at: 0, uid: "a", in: []) == nil)
    }
}
