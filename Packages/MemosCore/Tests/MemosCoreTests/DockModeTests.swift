import MemosCore
import Testing

/// The Library's two bottom bars, every event from both states (MEMNG-604, MEMNG-679). Each row
/// is written out rather than derived, so the table is the rule as the owner gave it, not the code
/// read back: 3 x 3 presses, the icon, 3 selections and 4 scroll offsets on each of 3 tabs are 25
/// events, and 18 + 2 + 6 + 24 rows cover each from both states.
@Suite("DockMode")
struct DockModeTests {
    private struct Row: CustomStringConvertible {
        let from: DockMode
        let event: DockEvent
        let to: DockMode
        var description: String { "\(from) + \(event) -> \(to)" }
    }

    private func check(_ rows: [Row]) {
        for row in rows {
            #expect(row.from.after(row.event) == row.to, "\(row)")
        }
    }

    @Test("the app opens on the tabs")
    func opensOnTheTabs() {
        #expect(DockMode.initial == .tabs)
    }

    /// Replaces MEMNG-604's `libraryPressGivesTheScope`, under which a press from another tab gave
    /// the scope too: from another tab the press is the way back to the Library, on the tabs.
    @Test("the Library pressed where it shows gives the scope; pressed from elsewhere, the tabs")
    func libraryPressWhereItShows() {
        check([
            Row(from: .tabs, event: .pressedTab(.library, showing: .library), to: .scope),
            Row(from: .scope, event: .pressedTab(.library, showing: .library), to: .scope),
            Row(from: .tabs, event: .pressedTab(.library, showing: .timeline), to: .tabs),
            Row(from: .scope, event: .pressedTab(.library, showing: .timeline), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.library, showing: .places), to: .tabs),
            Row(from: .scope, event: .pressedTab(.library, showing: .places), to: .tabs),
        ])
    }

    @Test("a press on Timeline or Places gives the tabs, whatever was showing")
    func otherPressGivesTheTabs() {
        check([
            Row(from: .tabs, event: .pressedTab(.timeline, showing: .library), to: .tabs),
            Row(from: .scope, event: .pressedTab(.timeline, showing: .library), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.timeline, showing: .timeline), to: .tabs),
            Row(from: .scope, event: .pressedTab(.timeline, showing: .timeline), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.timeline, showing: .places), to: .tabs),
            Row(from: .scope, event: .pressedTab(.timeline, showing: .places), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.places, showing: .library), to: .tabs),
            Row(from: .scope, event: .pressedTab(.places, showing: .library), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.places, showing: .timeline), to: .tabs),
            Row(from: .scope, event: .pressedTab(.places, showing: .timeline), to: .tabs),
            Row(from: .tabs, event: .pressedTab(.places, showing: .places), to: .tabs),
            Row(from: .scope, event: .pressedTab(.places, showing: .places), to: .tabs),
        ])
    }

    @Test("the Library icon in the scope toolbar gives the tabs back")
    func iconGivesTheTabs() {
        check([
            Row(from: .scope, event: .pressedLibraryIcon, to: .tabs),
            Row(from: .tabs, event: .pressedLibraryIcon, to: .tabs),
        ])
    }

    @Test("arriving on the Library keeps the state; arriving anywhere else is the tabs")
    func selectionLeavesTheLibrary() {
        check([
            Row(from: .tabs, event: .selected(.library), to: .tabs),
            Row(from: .scope, event: .selected(.library), to: .scope),
            Row(from: .tabs, event: .selected(.timeline), to: .tabs),
            Row(from: .scope, event: .selected(.timeline), to: .tabs),
            Row(from: .tabs, event: .selected(.places), to: .tabs),
            Row(from: .scope, event: .selected(.places), to: .tabs),
        ])
    }

    /// Past 24 points the scope; at 24 or less nothing changes, and no scroll — the top of the
    /// page and a pull past it included — gives the tabs back. Only on the Library.
    @Test("a Library scroll past 24 points gives the scope, and no scroll gives the tabs back")
    func scrollPastTheThreshold() {
        check([
            Row(from: .tabs, event: .scrolled(y: 25, showing: .library), to: .scope),
            Row(from: .scope, event: .scrolled(y: 25, showing: .library), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 24, showing: .library), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 24, showing: .library), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 0, showing: .library), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 0, showing: .library), to: .scope),
            Row(from: .tabs, event: .scrolled(y: -10, showing: .library), to: .tabs),
            Row(from: .scope, event: .scrolled(y: -10, showing: .library), to: .scope),
        ])
        #expect(DockMode.scopeThreshold == 24)
    }

    /// A Library scroll view that reports while another tab shows changes nothing, in either state.
    @Test("a scroll while Timeline or Places shows changes nothing")
    func scrollOffTheLibrary() {
        var rows: [Row] = []
        for showing in [MainTab.timeline, .places] {
            for y in [25.0, 24, 0, -10] {
                rows.append(Row(from: .tabs, event: .scrolled(y: y, showing: showing), to: .tabs))
                rows.append(
                    Row(from: .scope, event: .scrolled(y: y, showing: showing), to: .scope))
            }
        }
        #expect(rows.count == 16)
        check(rows)
    }

    private func reading(
        y: Double = 300, height: Double = 652, insetTop: Double = 139, insetBottom: Double = 83
    ) -> DockScrollReading {
        DockScrollReading(
            y: y, width: 402, height: height,
            insetTop: insetTop, insetLeading: 0, insetBottom: insetBottom, insetTrailing: 0
        )
    }

    @Test("a frame or an inset that differs is a reframe; the offset alone is not")
    func reframes() {
        let before = reading()
        #expect(!reading(y: 900).reframed(from: before))
        #expect(reading(insetBottom: 34).reframed(from: before), "a bar went")
        #expect(reading(insetTop: 160).reframed(from: before), "the header grew")
        #expect(reading(height: 701).reframed(from: before), "the frame grew")
        let sideways = DockScrollReading(
            y: 300, width: 874, height: 652,
            insetTop: 139, insetLeading: 0, insetBottom: 83, insetTrailing: 0)
        #expect(sideways.reframed(from: before), "the screen turned")
        let edged = DockScrollReading(
            y: 300, width: 402, height: 652,
            insetTop: 139, insetLeading: 20, insetBottom: 83, insetTrailing: 20)
        #expect(edged.reframed(from: before), "the side insets changed")
    }

    /// With nothing reframed, every move of the offset is a scroll and a kept offset is none.
    @Test("with the frame steady every move of the offset is a scroll, and a kept offset is none")
    func steadyMovesAreScrolls() {
        var fence = DockScrollFence()
        let start = ContinuousClock.now
        #expect(fence.scrolled(from: reading(y: 0), to: reading(y: 25), at: start) == 25)
        #expect(fence.scrolled(from: reading(y: 25), to: reading(y: -10), at: start) == -10)
        #expect(fence.scrolled(from: reading(), to: reading(), at: start) == nil, "nothing moved")
    }

    /// The echo the render test caught: the dock swaps the bars, the frame and an inset change in
    /// one reading, and the offset jumps several hundred points in the next with nothing else
    /// changed, the scroll view idle. Rewritten in round 2: the window opens at the swap, and a
    /// reframe extends it.
    @Test("an idle offset moved within the settling after a swap, or a reframe in it, is none")
    func swapSettles() {
        var fence = DockScrollFence()
        let swap = ContinuousClock.now
        let start = swap.advanced(by: .milliseconds(100))
        let before = reading(y: 4657, height: 701, insetBottom: 34)
        let reframed = reading(y: 4657, height: 652, insetBottom: 83)
        #expect(fence.scrolled(from: before, to: reframed, at: start, swappedAt: swap) == nil)
        let settled = start.advanced(by: DockScrollFence.settling)
        let moved = reading(y: 5295)
        let early = settled.advanced(by: .milliseconds(-1))
        #expect(
            fence.scrolled(from: reframed, to: moved, at: early, swappedAt: swap) == nil,
            "the system's move, 499 ms after the reframe that extended the swap's window")
        let next = reading(y: 5335)
        #expect(fence.scrolled(from: moved, to: next, at: settled, swappedAt: swap) == 5335)

        // A reframe that moves the offset in the same reading, the swap just made, is none either.
        var again = DockScrollFence()
        let both = reading(y: 900, insetBottom: 34)
        #expect(again.scrolled(from: reading(), to: both, at: swap, swappedAt: swap) == nil)
        #expect(DockScrollFence.settling == .milliseconds(500))
    }

    /// A drag, its deceleration or an animated scroll right after the icon's swap is the reader's
    /// or the app's: it counts inside the window, where the same move made idle does not.
    @Test("a move while the scroll view moves counts inside the settling; the same move idle not")
    func movingCountsInTheSettling() {
        let swap = ContinuousClock.now
        let soon = swap.advanced(by: .milliseconds(200))
        var idle = DockScrollFence()
        let still = idle.scrolled(from: reading(), to: reading(y: 500), at: soon, swappedAt: swap)
        #expect(still == nil)
        var dragged = DockScrollFence()
        let moved = dragged.scrolled(
            from: reading(), to: reading(y: 500), at: soon, swappedAt: swap, moving: true)
        #expect(moved == 500)
    }

    /// A programmatic jump the dock did not set off — Months opening at a month, a new scroll
    /// view's first landing, a day jump — counts though the frame changes with it or just before.
    @Test("a jump past the threshold with no bar swap counts, with a reframe or just after one")
    func jumpWithoutASwapCounts() {
        var fence = DockScrollFence()
        let start = ContinuousClock.now
        let landed = reading(y: 900, insetBottom: 34)
        #expect(fence.scrolled(from: reading(y: 0), to: landed, at: start) == 900, "with a reframe")
        let soon = start.advanced(by: .milliseconds(100))
        let further = reading(y: 1400, insetBottom: 34)
        #expect(fence.scrolled(from: landed, to: further, at: soon) == 1400, "just after one")
    }
}
