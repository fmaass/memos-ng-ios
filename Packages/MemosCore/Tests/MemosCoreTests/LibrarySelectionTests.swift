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

    /// MEMNG-684: in a household most of the grid is the other member's, and a tap on one of
    /// those pictures chooses it like any other. Before, the selection refused it.
    @Test("a tap selects another member's picture too, and a second tap deselects it")
    func othersPictureTakenByToggle() {
        var selection = selecting()

        selection.toggle(row("theirs", mine: false))

        #expect(selection.uids == ["theirs"])
        #expect(selection.contains("theirs"))

        selection.toggle(row("theirs", mine: false))
        #expect(selection.uids.isEmpty)
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

    @Test("outside select mode a tap changes nothing")
    func nothingOutsideSelectMode() {
        var selection = LibrarySelection()

        selection.toggle(row("a"))

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

    /// A page arriving changes the grid's list, and every change prunes: another member's chosen
    /// picture still on the grid must survive it, or the next page would silently unchoose it.
    @Test("another member's chosen picture stays chosen while the grid still shows it")
    func pruneKeepsOthersPicturesInTheGrid() {
        var selection = selecting()
        selection.toggle(row("theirs", mine: false))
        selection.toggle(row("a"))
        selection.toggle(row("gone", mine: false))

        selection.prune(keeping: [row("a"), row("theirs", mine: false), row("b")])

        #expect(selection.uids == ["theirs", "a"])
        #expect(!selection.contains("gone"))
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

    // MARK: - what a delete may take (MEMNG-684)

    @Test("a delete of a selection of only my pictures takes all of them, in selection order")
    func deletableAllOwn() {
        var selection = selecting()
        let rows = [row("a"), row("b"), row("c")]
        selection.toggle(rows[2])
        selection.toggle(rows[0])
        selection.toggle(rows[1])

        let set = selection.deletable(in: rows)

        #expect(set.own == ["c", "a", "b"])
        #expect(set.othersCount == 0)
    }

    @Test("a delete of a mixed selection takes only my pictures and counts the others it skips")
    func deletableMixed() {
        var selection = selecting()
        let rows = [row("a"), row("x", mine: false), row("b"), row("y", mine: false), row("c")]
        selection.toggle(rows[1])
        selection.toggle(rows[4])
        selection.toggle(rows[3])
        selection.toggle(rows[0])

        let set = selection.deletable(in: rows)

        #expect(set.own == ["c", "a"], "another member's picture reached the delete set")
        #expect(set.othersCount == 2)
    }

    @Test("a delete of a selection of only another member's pictures takes nothing")
    func deletableNoneOwn() {
        var selection = selecting()
        let rows = [row("x", mine: false), row("y", mine: false)]
        selection.toggle(rows[0])
        selection.toggle(rows[1])

        let set = selection.deletable(in: rows)

        #expect(set.own.isEmpty)
        #expect(set.othersCount == 2)
    }

    @Test("a delete of an empty selection takes nothing and skips nothing")
    func deletableEmpty() {
        let selection = selecting()

        let set = selection.deletable(in: [row("a"), row("x", mine: false)])

        #expect(set == LibrarySelection.DeleteSet(own: [], othersCount: 0))
        // A chosen uid whose row is not loaded is in neither part.
        var unloaded = selecting()
        unloaded.toggle(row("a"))
        #expect(unloaded.deletable(in: []) == LibrarySelection.DeleteSet(own: [], othersCount: 0))
    }

    // MARK: - Show Selected (MEMNG-779)

    @Test("Show Selected narrows the grid to the chosen pictures in the grid's order, then widens")
    func showSelectedNarrowsInGridOrder() {
        var selection = selecting()
        let grid = ["a", "b", "c", "d", "e"].map { row($0) }
        // Chosen out of the grid's order: the narrowed grid keeps the grid's.
        selection.toggle(row("d"))
        selection.toggle(row("b"))

        selection.toggleNarrowed()
        #expect(selection.narrowed)
        #expect(selection.visible(in: grid).map(\.id) == ["b", "d"])

        selection.toggleNarrowed()
        #expect(!selection.narrowed)
        #expect(selection.visible(in: grid).map(\.id) == ["a", "b", "c", "d", "e"])
    }

    @Test("with nothing chosen, or outside select mode, Show Selected narrows nothing")
    func showSelectedNeedsAChoice() {
        var selection = selecting()
        selection.toggleNarrowed()
        #expect(!selection.narrowed, "an empty selection narrowed the grid to nothing")

        var idle = LibrarySelection()
        idle.toggleNarrowed()
        #expect(!idle.narrowed, "a grid outside select mode was narrowed")
    }

    @Test("letting go of the last chosen picture while narrowed widens the grid")
    func lastDeselectWidens() {
        var selection = selecting()
        selection.toggle(row("a"))
        selection.toggleNarrowed()
        selection.toggle(row("a"))
        #expect(!selection.narrowed, "an emptied selection kept the grid narrowed to nothing")
        #expect(selection.visible(in: [row("a"), row("b")]).map(\.id) == ["a", "b"])
    }

    @Test("close ends the narrowing, so select mode opens again on the whole grid")
    func closeWidens() {
        var selection = selecting()
        selection.toggle(row("a"))
        selection.toggleNarrowed()
        #expect(selection.narrowed)

        selection.close()
        #expect(!selection.narrowed)
        selection.begin()
        #expect(selection.visible(in: [row("a"), row("b")]).map(\.id) == ["a", "b"])
    }

    @Test("a list that drops every chosen picture while narrowed widens the grid")
    func pruneToNothingWidens() {
        var selection = selecting()
        selection.toggle(row("a"))
        selection.toggleNarrowed()

        selection.prune(keeping: [row("b")])
        #expect(selection.count == 0)
        #expect(!selection.narrowed, "a page that took the chosen pictures left an empty grid")
    }
}
