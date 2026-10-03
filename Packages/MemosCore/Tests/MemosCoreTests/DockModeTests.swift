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

    /// MEMNG-684: a claim or a release the scroll view lived through holds its idle moves past the
    /// settling — the swing a lazy stack makes at the foot a second later is no scroll — until it
    /// next moves; a moving reading counts at once and ends the hold. Lived through: the fence
    /// took a reading before the hold was made (review round 2), and heard it within the settling.
    @Test("a claim or release holds idle moves until the scroll view moves; a moving one counts")
    func holdLastsUntilAMove() {
        let held = ContinuousClock.now
        var fence = DockScrollFence()
        let before = fence.scrolled(
            from: reading(y: 4000), to: reading(y: 5027), at: held.advanced(by: .seconds(-1)),
            moving: true)
        #expect(before == 5027, "the drag that brought the scroll view to the foot")
        func idle(_ from: Double, _ to: Double, after: Duration) -> Double? {
            fence.scrolled(
                from: reading(y: from), to: reading(y: to), at: held.advanced(by: after),
                heldAt: held)
        }
        #expect(idle(5027, 4967, after: .milliseconds(50)) == nil, "the release's own move")
        #expect(idle(4967, 5379, after: .milliseconds(800)) == nil, "a swing past the settling")
        #expect(idle(5379, 4954, after: .seconds(3)) == nil, "a swing seconds later")
        let dragged = fence.scrolled(
            from: reading(y: 4954), to: reading(y: 4000), at: held.advanced(by: .seconds(3)),
            heldAt: held, moving: true)
        #expect(dragged == 4000, "a moving reading under the hold was dropped")
        #expect(idle(4000, 4100, after: .seconds(4)) == 4100, "the hold outlived the move")

        var stranger = DockScrollFence()
        let warm = stranger.scrolled(
            from: reading(y: 0), to: reading(y: 10), at: held.advanced(by: .seconds(-1)),
            moving: true)
        #expect(warm == 10)
        let stale = stranger.scrolled(
            from: reading(y: 10), to: reading(y: 300), at: held.advanced(by: .milliseconds(800)),
            heldAt: held)
        #expect(stale == 300, "a hold first heard after the settling held this scroll view")
    }

    /// Review round 2: a scroll view that came after the claim or release — the one a scope pick
    /// puts on screen as Close is pressed — did not live through it. Its fence, first called
    /// 100 ms after the release, holds nothing: its idle first landing, once the settling of the
    /// release has passed, counts, as a new scroll view's first landing always has.
    @Test("a fence whose first reading comes after the claim or release holds nothing")
    func freshFenceHoldsNothing() {
        let held = ContinuousClock.now
        var fresh = DockScrollFence()
        let framed = fresh.scrolled(
            from: reading(y: 0, insetBottom: 83), to: reading(y: 0, insetBottom: 34),
            at: held.advanced(by: .milliseconds(100)), swappedAt: held, heldAt: held)
        #expect(framed == nil, "a reframe that keeps the offset")
        let landed = fresh.scrolled(
            from: reading(y: 0, insetBottom: 34), to: reading(y: 300, insetBottom: 34),
            at: held.advanced(by: .milliseconds(800)), swappedAt: held, heldAt: held)
        #expect(landed == 300, "a new scroll view's idle first landing was held")

        // The boundary: a first reading taken at the very instant of the release did not precede
        // it, and holds nothing either.
        var same = DockScrollFence()
        let shown = reading(y: 0, insetBottom: 34)
        _ = same.scrolled(from: reading(y: 0), to: shown, at: held, heldAt: held)
        let later = same.scrolled(
            from: shown, to: reading(y: 300, insetBottom: 34),
            at: held.advanced(by: .milliseconds(800)), heldAt: held)
        #expect(later == 300, "a fence first read at the release's own instant held")
    }

    /// A second claim or release re-arms the hold of a fence whose first hold a move ended, and a
    /// hold the fence has already heard is not taken again by a later reading.
    @Test("a later claim or release holds again once a move ended the first hold")
    func secondReleaseHoldsAgain() {
        let first = ContinuousClock.now
        var fence = DockScrollFence()
        _ = fence.scrolled(
            from: reading(y: 0), to: reading(y: 10), at: first.advanced(by: .seconds(-1)),
            moving: true)
        func idle(_ to: Double, _ held: ContinuousClock.Instant, after: Duration) -> Double? {
            fence.scrolled(
                from: reading(y: to - 50), to: reading(y: to), at: held.advanced(by: after),
                heldAt: held)
        }
        #expect(idle(550, first, after: .milliseconds(50)) == nil, "the first release's move")
        #expect(idle(600, first, after: .milliseconds(800)) == nil, "the first release's swing")
        let moved = fence.scrolled(
            from: reading(y: 600), to: reading(y: 700), at: first.advanced(by: .seconds(1)),
            heldAt: first, moving: true)
        #expect(moved == 700, "the move that ends the first hold")
        #expect(idle(900, first, after: .seconds(2)) == 900, "the first hold, heard again, held")
        let second = first.advanced(by: .seconds(3))
        #expect(idle(1200, second, after: .milliseconds(50)) == nil, "the second release's move")
        #expect(
            idle(1500, second, after: .milliseconds(800)) == nil,
            "a swing past the second release's settling counted")
    }

    /// The one bottom bar (MEMNG-684), for every mode x tab x claim: 2 x 3 x 3 rows, written out.
    /// A takeover leaves nothing anywhere; select mode its toolbar on the Library and nothing
    /// elsewhere; with no claim the scope stands on the Library in `scope`, the tabs otherwise.
    @Test("one bottom bar for every mode, tab and claim")
    func oneBarStands() {
        let table: [(DockMode, MainTab, DockClaim?, DockBar)] = [
            (.tabs, .timeline, nil, .tabs),
            (.tabs, .timeline, .select, .none),
            (.tabs, .timeline, .takeover, .none),
            (.tabs, .places, nil, .tabs),
            (.tabs, .places, .select, .none),
            (.tabs, .places, .takeover, .none),
            (.tabs, .library, nil, .tabs),
            (.tabs, .library, .select, .select),
            (.tabs, .library, .takeover, .none),
            (.scope, .timeline, nil, .tabs),
            (.scope, .timeline, .select, .none),
            (.scope, .timeline, .takeover, .none),
            (.scope, .places, nil, .tabs),
            (.scope, .places, .select, .none),
            (.scope, .places, .takeover, .none),
            (.scope, .library, nil, .scope),
            (.scope, .library, .select, .select),
            (.scope, .library, .takeover, .none),
        ]
        #expect(table.count == DockMode.allCases.count * MainTab.allCases.count * 3)
        for (mode, tab, claim, bar) in table {
            let standing = DockBar.standing(mode: mode, on: tab, claim: claim)
            let held = claim.map(\.rawValue) ?? "no claim"
            #expect(standing == bar, "\(mode) on \(tab) under \(held)")
        }
        // Every combination is a row: none is left to a default.
        let rows = Set(table.map { "\($0.0)-\($0.1)-\($0.2.map(\.rawValue) ?? "-")" })
        #expect(rows.count == table.count, "a combination written twice")
    }
}
