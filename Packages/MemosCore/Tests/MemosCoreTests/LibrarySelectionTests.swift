import Foundation
import MemosCore
import Testing

private func row(_ uid: String, mine: Bool = true) -> LibraryRow {
    LibraryRow(
        attachment: MemoAttachment(uid: uid, mime: "image/jpeg", status: .ready),
        takenAt: nil,
        mine: mine,
        filename: "\(uid).jpg"
    )
}

/// A selection already in select mode, the state every tap below is made in.
private func selecting() -> LibrarySelection {
    var selection = LibrarySelection()
    selection.begin()
    return selection
}

/// Select mode in the All grid (MEMNG-588, the mockup's section 7): what a tap, the header's
/// select-all toggle, the close button and a list that changed underneath do to the selection.
@Suite("Library select mode")
struct LibrarySelectionTests {
    @Test("a tap selects an own picture and a second tap deselects it")
    func toggleOnAndOff() {
        var selection = selecting()

        selection.toggle(row("a"))
        #expect(selection.uids == ["a"])
        #expect(selection.contains("a"))

        selection.toggle(row("a"))
        #expect(selection.uids.isEmpty)
        #expect(!selection.contains("a"))
    }

    @Test("another member's picture never enters the selection by a tap")
    func othersPictureRefusedByToggle() {
        var selection = selecting()

        selection.toggle(row("theirs", mine: false))

        #expect(selection.uids.isEmpty)
        #expect(!selection.contains("theirs"))
    }

    @Test("select all takes only the own pictures in view, in the order the grid shows them")
    func selectAllTakesOnlyMine() {
        var selection = selecting()
        let rows = [row("a"), row("theirs", mine: false), row("b"), row("c")]

        selection.toggleAllMine(in: rows)

        #expect(selection.uids == ["a", "b", "c"])
        #expect(!selection.contains("theirs"))
        #expect(selection.coversAllMine(in: rows))
    }

    @Test("select all keeps what was chosen first at the front")
    func selectAllKeepsEarlierOrder() {
        var selection = selecting()
        let rows = [row("a"), row("b"), row("c")]

        selection.toggle(row("c"))
        selection.toggleAllMine(in: rows)

        #expect(selection.uids == ["c", "a", "b"])
    }

    @Test("select all tapped again clears the selection")
    func selectAllTappedAgainClears() {
        var selection = selecting()
        let rows = [row("a"), row("b"), row("theirs", mine: false)]

        selection.toggleAllMine(in: rows)
        selection.toggleAllMine(in: rows)

        #expect(selection.uids.isEmpty)
        #expect(selection.isActive, "clearing is not leaving select mode")
    }

    @Test("select all over a view with none of mine selects nothing and covers nothing")
    func selectAllWithNothingOfMine() {
        var selection = selecting()
        let rows = [row("x", mine: false), row("y", mine: false)]

        selection.toggleAllMine(in: rows)

        #expect(selection.uids.isEmpty)
        #expect(!selection.coversAllMine(in: rows))
        #expect(!selection.coversAllMine(in: []))
    }

    @Test("close empties the selection and leaves select mode")
    func closeEmpties() {
        var selection = selecting()
        selection.toggle(row("a"))
        selection.toggle(row("b"))

        selection.close()

        #expect(selection.uids.isEmpty)
        #expect(!selection.isActive)
        #expect(selection.count == 0)
    }

    @Test("outside select mode a tap and select all change nothing")
    func nothingOutsideSelectMode() {
        var selection = LibrarySelection()

        selection.toggle(row("a"))
        selection.toggleAllMine(in: [row("b")])

        #expect(selection.uids.isEmpty)
        #expect(!selection.isActive)
    }

    @Test("a picture that left the grid leaves the selection, and the rest keep their order")
    func pruneDropsRowsNoLongerInTheGrid() {
        var selection = selecting()
        selection.toggle(row("c"))
        selection.toggle(row("a"))
        selection.toggle(row("b"))

        selection.prune(keeping: [row("a"), row("b"), row("d")])

        #expect(selection.uids == ["a", "b"])
        #expect(!selection.contains("c"))
    }

    @Test("pruning against an empty grid empties the selection")
    func pruneAgainstNothing() {
        var selection = selecting()
        selection.toggle(row("a"))

        selection.prune(keeping: [])

        #expect(selection.uids.isEmpty)
        #expect(!selection.contains("a"))
    }

    @Test("the selection is kept in the order the pictures were tapped")
    func orderIsSelectionOrder() {
        var selection = selecting()

        selection.toggle(row("b"))
        selection.toggle(row("c"))
        selection.toggle(row("a"))
        selection.toggle(row("c"))
        selection.toggle(row("c"))

        #expect(selection.uids == ["b", "a", "c"])
    }

    @Test("the rows handed on are the selected ones, in selection order")
    func rowsInSelectionOrder() {
        var selection = selecting()
        let rows = [row("a"), row("b"), row("c")]
        selection.toggle(rows[2])
        selection.toggle(rows[0])

        let chosen = selection.rows(in: rows)

        #expect(chosen.map(\.id) == ["c", "a"])
        // A uid whose row is no longer loaded is simply not handed on.
        #expect(selection.rows(in: [rows[0]]).map(\.id) == ["a"])
    }
}
