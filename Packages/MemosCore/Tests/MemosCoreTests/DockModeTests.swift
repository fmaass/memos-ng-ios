import MemosCore
import Testing

/// The Library's two bottom bars, every event from both states (MEMNG-604, MEMNG-679, MEMNG-685).
/// Each row is written out rather than derived, so the table is the rule as the owner gave it, not
/// the code read back: 3 x 3 presses, the icon, 3 selections, 5 scroll offsets by each of 3 kinds
/// on the Library and 4 offsets by a scroll on each of the 2 other tabs are 36 events, and
/// 18 + 2 + 6 + 30 + 16 rows cover each from both states.
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

    /// Past 24 points the scope, whatever moved the Library there; from 24 down to 1 nothing
    /// changes, the hysteresis; at the top — 0, and a pull past it — a scroll gives the tabs back
    /// (MEMNG-685, the owner's report of 2026-10-03), while a scope pick's landing and a jump the
    /// app asked for leave the bar as it was. Only on the Library.
    @Test("a Library scroll past 24 points gives the scope, and a scroll back to the top the tabs")
    func scrollPastTheThreshold() {
        check([
            Row(from: .tabs, event: .scrolled(y: 25, showing: .library, by: .scroll), to: .scope),
            Row(from: .scope, event: .scrolled(y: 25, showing: .library, by: .scroll), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 24, showing: .library, by: .scroll), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 24, showing: .library, by: .scroll), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 1, showing: .library, by: .scroll), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 1, showing: .library, by: .scroll), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 0, showing: .library, by: .scroll), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 0, showing: .library, by: .scroll), to: .tabs),
            Row(from: .tabs, event: .scrolled(y: -10, showing: .library, by: .scroll), to: .tabs),
            Row(from: .scope, event: .scrolled(y: -10, showing: .library, by: .scroll), to: .tabs),

            Row(from: .tabs, event: .scrolled(y: 25, showing: .library, by: .landing), to: .scope),
            Row(from: .scope, event: .scrolled(y: 25, showing: .library, by: .landing), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 24, showing: .library, by: .landing), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 24, showing: .library, by: .landing), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 1, showing: .library, by: .landing), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 1, showing: .library, by: .landing), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 0, showing: .library, by: .landing), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 0, showing: .library, by: .landing), to: .scope),
            Row(from: .tabs, event: .scrolled(y: -10, showing: .library, by: .landing), to: .tabs),
            Row(
                from: .scope, event: .scrolled(y: -10, showing: .library, by: .landing), to: .scope
            ),

            Row(from: .tabs, event: .scrolled(y: 25, showing: .library, by: .jump), to: .scope),
            Row(from: .scope, event: .scrolled(y: 25, showing: .library, by: .jump), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 24, showing: .library, by: .jump), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 24, showing: .library, by: .jump), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 1, showing: .library, by: .jump), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 1, showing: .library, by: .jump), to: .scope),
            Row(from: .tabs, event: .scrolled(y: 0, showing: .library, by: .jump), to: .tabs),
            Row(from: .scope, event: .scrolled(y: 0, showing: .library, by: .jump), to: .scope),
            Row(from: .tabs, event: .scrolled(y: -10, showing: .library, by: .jump), to: .tabs),
            Row(from: .scope, event: .scrolled(y: -10, showing: .library, by: .jump), to: .scope),
        ])
        #expect(DockMode.scopeThreshold == 24)
    }

    /// What made a move: the jump asked whatever else holds; a scope pick's landing for an idle
    /// move while it is unsettled; else a scroll — a move made while the scroll view moves
    /// included, so a pick's landing never takes the reader's first scroll (MEMNG-685).
    @Test("an asked move is a jump, an idle one in a pick's landing a landing, any other a scroll")
    func kindOfAMove() {
        let rows: [(asked: Bool, moving: Bool, landing: Bool, kind: DockScrollKind)] = [
            (asked: false, moving: false, landing: false, kind: .scroll),
            (asked: false, moving: true, landing: false, kind: .scroll),
            (asked: false, moving: false, landing: true, kind: .landing),
            (asked: false, moving: true, landing: true, kind: .scroll),
            (asked: true, moving: false, landing: false, kind: .jump),
            (asked: true, moving: true, landing: false, kind: .jump),
            (asked: true, moving: false, landing: true, kind: .jump),
            (asked: true, moving: true, landing: true, kind: .jump),
        ]
        for row in rows {
            let kind = DockScrollKind.of(asked: row.asked, moving: row.moving, landing: row.landing)
            #expect(kind == row.kind, "\(row)")
        }
    }

    /// A Library scroll view that reports while another tab shows changes nothing, in either state.
    @Test("a scroll while Timeline or Places shows changes nothing")
    func scrollOffTheLibrary() {
        var rows: [Row] = []
        for showing in [MainTab.timeline, .places] {
            for y in [25.0, 24, 0, -10] {
                let event = DockEvent.scrolled(y: y, showing: showing, by: .scroll)
                rows.append(Row(from: .tabs, event: event, to: .tabs))
                rows.append(Row(from: .scope, event: event, to: .scope))
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
    /// took a reading before the hold was made (review round 2), however late it heard it.
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

    /// MEMNG-703: the witness rule is the fence's identity, never a delivery deadline. A scroll
    /// view that read before the claim or release — the Library grid at the foot as Close is
    /// pressed — lived through it however late the layout hands it its next reading: an idle
    /// reflow heard 600 ms or 5 s after the release is no scroll, and the hold ends only when the
    /// scroll view next moves.
    @Test("a fence that read before the claim or release holds it however late its next reading")
    func survivingFenceHoldsLateReadings() {
        let held = ContinuousClock.now
        for late in [Duration.milliseconds(600), .seconds(5)] {
            var survivor = DockScrollFence()
            let warm = survivor.scrolled(
                from: reading(y: 0), to: reading(y: 960), at: held.advanced(by: .seconds(-1)),
                moving: true)
            #expect(warm == 960, "the drag that brought the scroll view there")
            let heard = held.advanced(by: late)
            let reflow = survivor.scrolled(
                from: reading(y: 960), to: reading(y: 980), at: heard, heldAt: held)
            #expect(reflow == nil, "an idle reflow first heard \(late) after the release counted")
            let swing = survivor.scrolled(
                from: reading(y: 980), to: reading(y: 535), at: heard.advanced(by: .seconds(1)),
                heldAt: held)
            #expect(swing == nil, "a later idle swing under the hold heard at \(late) counted")
            let dragged = survivor.scrolled(
                from: reading(y: 535), to: reading(y: 200), at: heard.advanced(by: .seconds(2)),
                heldAt: held, moving: true)
            #expect(dragged == 200, "the reader's drag under the hold was dropped")
            let after = survivor.scrolled(
                from: reading(y: 200), to: reading(y: 300), at: heard.advanced(by: .seconds(3)),
                heldAt: held)
            #expect(after == 300, "the hold heard at \(late) outlived the move that ended it")
        }
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

    /// The one bottom bar (MEMNG-684), for every mode x tab x claim: 3 x 3 x 3 rows, written out.
    /// Folded is a shape of the tabs (MEMNG-690): it stands the tabs wherever `tabs` would.
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
            (.folded, .timeline, nil, .tabs),
            (.folded, .timeline, .select, .none),
            (.folded, .timeline, .takeover, .none),
            (.folded, .places, nil, .tabs),
            (.folded, .places, .select, .none),
            (.folded, .places, .takeover, .none),
            (.folded, .library, nil, .tabs),
            (.folded, .library, .select, .select),
            (.folded, .library, .takeover, .none),
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

    /// One reading of a tab's scroll view as the feed hands it to `DockFold`: where it stands,
    /// how far it moved since the last reading (down positive), and whether the reader moved it.
    private struct Move {
        let y: Double
        let step: Double
        var moving = true
    }

    /// The modes a run of readings leaves the dock in, one per reading, from `start`: each
    /// reading committed by one `DockFold` and told to the dock only as the decision it commits.
    private static func drive(
        _ moves: [Move], from start: DockMode = .tabs, tab: MainTab = .timeline,
        showing: MainTab? = nil
    ) -> [DockMode] {
        var fold = DockFold()
        var mode = start
        return moves.map { move in
            if let folds = fold.read(y: move.y, step: move.step, moving: move.moving) {
                mode = mode.after(.scrolledTab(tab, folds: folds, showing: showing ?? tab))
            }
            return mode
        }
    }

    /// The leading bar's committed fold (MEMNG-690): the travel of one run in one direction
    /// decides, 24 points down folding and 24 up unfolding; the top unfolds; a reversal starts a
    /// new run, so a wavering finger flips nothing; a move that is not the reader's counts for
    /// nothing; the Library's scroll and a tab not on screen move nothing.
    @Test("a run of the reader's travel folds and unfolds the bar once per direction")
    func foldIsCommittedPerRun() {
        let table: [(String, DockMode, MainTab, MainTab?, [Move], [DockMode])] = [
            (
                "a waver below the threshold", .tabs, .timeline, nil,
                [
                    Move(y: 230, step: 10), Move(y: 225, step: -5), Move(y: 235, step: 10),
                    Move(y: 228, step: -7), Move(y: 238, step: 10), Move(y: 231, step: -7),
                ],
                [.tabs, .tabs, .tabs, .tabs, .tabs, .tabs]
            ),
            (
                "24 down folds, 23 does not", .tabs, .timeline, nil,
                [Move(y: 23, step: 23), Move(y: 1, step: -22), Move(y: 25, step: 24)],
                [.tabs, .tabs, .folded]
            ),
            (
                "down 30 folds", .tabs, .timeline, nil,
                [Move(y: 215, step: 15), Move(y: 230, step: 15)], [.tabs, .folded]
            ),
            (
                "down 30, then up 10, stays folded", .tabs, .timeline, nil,
                [Move(y: 230, step: 30), Move(y: 220, step: -10)], [.folded, .folded]
            ),
            (
                "further down stays folded", .folded, .timeline, nil,
                [Move(y: 260, step: 30), Move(y: 300, step: 40)], [.folded, .folded]
            ),
            (
                "up 30 unfolds, at the run's 24th point", .folded, .timeline, nil,
                [Move(y: 290, step: -10), Move(y: 280, step: -10), Move(y: 270, step: -10)],
                [.folded, .folded, .tabs]
            ),
            (
                "a reversal starts a new run", .tabs, .timeline, nil,
                [Move(y: 220, step: 20), Move(y: 215, step: -5), Move(y: 235, step: 20)],
                [.tabs, .tabs, .tabs]
            ),
            (
                "at the top unfolds", .folded, .timeline, nil,
                [Move(y: 0, step: -5)], [.tabs]
            ),
            (
                "a pull past the top unfolds", .folded, .timeline, nil,
                [Move(y: -12, step: -4)], [.tabs]
            ),
            (
                "down from a pull past the top, still at the top", .tabs, .timeline, nil,
                [Move(y: -30, step: -30), Move(y: 0, step: 30)], [.tabs, .tabs]
            ),
            (
                "an idle move folds nothing", .tabs, .timeline, nil,
                [Move(y: 400, step: 200, moving: false)], [.tabs]
            ),
            (
                "an idle move to the top unfolds nothing", .folded, .timeline, nil,
                [Move(y: 0, step: -40, moving: false)], [.folded]
            ),
            (
                "an idle move neither counts nor breaks a run", .tabs, .timeline, nil,
                [
                    Move(y: 212, step: 12), Move(y: 100, step: -112, moving: false),
                    Move(y: 112, step: 12),
                ],
                [.tabs, .tabs, .folded]
            ),
            (
                "the Library's own scroll folds nothing", .tabs, .library, nil,
                [Move(y: 230, step: 30), Move(y: 260, step: 30)], [.tabs, .tabs]
            ),
            (
                "the scope is the Library's", .scope, .timeline, nil,
                [Move(y: 230, step: 30), Move(y: 200, step: -30)], [.scope, .scope]
            ),
            (
                "a tab not on screen folds nothing", .tabs, .timeline, .places,
                [Move(y: 230, step: 30)], [.tabs]
            ),
            (
                "Places, if it scrolls, as the Timeline", .tabs, .places, nil,
                [
                    Move(y: 215, step: 15), Move(y: 230, step: 15), Move(y: 220, step: -10),
                    Move(y: 195, step: -25),
                ],
                [.tabs, .folded, .folded, .tabs]
            ),
        ]
        for (name, start, tab, showing, moves, modes) in table {
            #expect(moves.count == modes.count, "\(name): a row without a mode per reading")
            let seen = Self.drive(moves, from: start, tab: tab, showing: showing)
            #expect(seen == modes, "\(name): \(seen)")
        }
    }

    /// A new gesture is a new run: the fold the last one committed is not re-committed by the
    /// first point of the next, so the icon's press between them holds (MEMNG-690).
    @Test("a gesture begins a new run")
    func gestureBeginsANewRun() {
        var fold = DockFold()
        #expect(fold.read(y: 230, step: 30, moving: true) == true, "precondition: folded")
        #expect(fold.run == 30)
        #expect(fold.read(y: 231, step: 1, moving: true) == true, "the same run goes on")
        fold.began()
        #expect(fold.run == 0)
        #expect(fold.read(y: 232, step: 1, moving: true) == nil, "a new gesture's first point")
        #expect(fold.read(y: 256, step: 24, moving: true) == true, "24 down in the new run")
        #expect(fold.read(y: 256, step: 0, moving: true) == nil, "no step, no decision")
        #expect(fold.read(y: 0, step: -256, moving: true) == false)
        #expect(fold.run == 0, "the top ends the run")
    }

    @Test("a fold is the tab's: the icon, another tab and the Library unfold it")
    func foldEndsOffItsTab() {
        #expect(DockMode.folded.after(.pressedTab(.timeline, showing: .timeline)) == .tabs)
        #expect(DockMode.folded.after(.pressedTab(.library, showing: .timeline)) == .tabs)
        #expect(DockMode.folded.after(.selected(.library)) == .tabs)
        #expect(DockMode.folded.after(.selected(.places)) == .tabs)
        #expect(DockMode.scope.after(.selected(.library)) == .scope, "the scope is kept")
        #expect(DockMode.folded.folds(on: .timeline))
        #expect(DockMode.folded.folds(on: .places))
        #expect(!DockMode.folded.folds(on: .library))
        #expect(!DockMode.tabs.folds(on: .timeline))
        #expect(!DockMode.scope.folds(on: .timeline))
    }
}
