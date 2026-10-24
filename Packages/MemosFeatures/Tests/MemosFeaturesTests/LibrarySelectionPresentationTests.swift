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

    /// MEMNG-779: the Library's centre is a button — "Select Items", looking disabled, before
    /// anything is chosen, and "Show Selected (N)" after.
    @Test("the centre button says Select Items with nothing chosen, Show Selected (N) after")
    func showSelectedText() {
        #expect(LibrarySelectionPresentation.showSelectedText(0) == "Select Items")
        #expect(LibrarySelectionPresentation.showSelectedText(1) == "Show Selected (1)")
        #expect(LibrarySelectionPresentation.showSelectedText(3) == "Show Selected (3)")
    }

    @Test("outside select mode every tile opens, mine or not")
    func browsingTiles() {
        let selection = LibrarySelection()
        #expect(LibrarySelectionPresentation.tile(for: row("a"), in: selection) == .browsing)
        #expect(
            LibrarySelectionPresentation.tile(for: row("x", mine: false), in: selection)
                == .browsing)
    }

    /// MEMNG-684: another member's picture is as selectable as mine; only a tile with no row is
    /// not, because there is nothing for its tap to choose.
    @Test("in select mode every loaded tile is selectable, checked once chosen; no row is inert")
    func selectModeTiles() {
        var selection = LibrarySelection()
        selection.begin()
        selection.toggle(row("a"))
        selection.toggle(row("y", mine: false))

        #expect(
            LibrarySelectionPresentation.tile(for: row("a"), in: selection)
                == .selectable(selected: true))
        #expect(
            LibrarySelectionPresentation.tile(for: row("b"), in: selection)
                == .selectable(selected: false))
        #expect(
            LibrarySelectionPresentation.tile(for: row("x", mine: false), in: selection)
                == .selectable(selected: false))
        #expect(
            LibrarySelectionPresentation.tile(for: row("y", mine: false), in: selection)
                == .selectable(selected: true))
        #expect(LibrarySelectionPresentation.tile(for: nil, in: selection) == .unloaded)
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

    /// Select mode's More on the Library: Add alone, which opens the Add to collection sheet
    /// (MEMNG-855). No visibility row, and no Public or Just us anywhere under it — visibility
    /// belongs to a memo, and what select mode chooses is pictures; it went out on the owner's
    /// word (2026-10-18).
    @Test("the Library's select menu is Add alone: no submenu, no visibility row")
    func selectMenuHasNoVisibilityRow() {
        let day = Date(timeIntervalSince1970: 1_773_000_000)
        let trip = Trip(
            uid: "trip-1", title: "Portugal", tag: "portugal", spanStart: nil, spanEnd: nil,
            cover: nil, memberCount: 2, createdAt: day, updatedAt: day)
        var opened = 0
        // Two chosen pictures on ONE memo of mine, the case the visibility row miscounted.
        let rows = MediaLibraryView.selectRows(memos: ["m1"], free: true, tagged: [trip]) {
            opened += 1
        }
        func walk(_ rows: [SelectAction]) -> [SelectAction] {
            rows.flatMap { [$0] + walk($0.children) }
        }
        #expect(rows.map(\.id) == ["add"])
        #expect(rows.first?.disabled == false, "control: Add is live")
        #expect(rows.first?.children.isEmpty == true, "Add is one row, not a submenu")
        let labels = MemoVisibility.allCases.map(\.label)
        let visibility = walk(rows).filter {
            $0.id.hasPrefix("visibility") || $0.title.hasPrefix("Set visibility")
                || labels.contains($0.title)
        }
        #expect(visibility.isEmpty, "a visibility row: \(visibility.map(\.title))")
        rows.first?.action()
        #expect(opened == 1, "control: Add opens the sheet")
        // Nothing of mine chosen: Add stays, drawn disabled.
        let none = MediaLibraryView.selectRows(memos: [], free: true, tagged: [trip]) {}
        #expect(none.map(\.id) == ["add"] && none.first?.disabled == true)
    }
}
