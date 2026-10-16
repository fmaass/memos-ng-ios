import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The dock's two shared objects, asked directly: what the tab bar, the scope toolbar and the
/// Library all read.
@MainActor
@Suite("The dock's shared state")
struct DockTests {
    private typealias Tabs = MainTabs<EmptyView>

    private final class Held<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Rewritten for MEMNG-684: every bar is read from the one value, `bar(on:)`.
    @Test("the scope toolbar takes the bar's place on the Library alone, and a claim takes both")
    func barsFollowTheMode() {
        let dock = AppDock()
        #expect(dock.mode == .tabs)
        #expect(MainTab.allCases.allSatisfy { dock.bar(on: $0) == .tabs }, "a bar missing")

        dock.send(.pressedTab(.library, showing: .library))
        #expect(dock.bar(on: .library) == .scope, "the scope toolbar did not take the bar's place")
        #expect(dock.bar(on: .timeline) == .tabs, "the scope toolbar off the Library")

        // Select mode's toolbar is then the only bottom chrome, and ending it restores the scope.
        let select = UUID()
        dock.claim(select, for: .select)
        #expect(dock.bar(on: .library) == .select, "select mode's toolbar did not stand")
        #expect(dock.bar(on: .timeline) == .none, "a tab bar on another root under Select")
        dock.release(select)
        #expect(dock.bar(on: .library) == .scope, "Select did not hand the scope toolbar back")

        dock.send(.pressedLibraryIcon)
        #expect(dock.bar(on: .library) == .tabs, "the icon did not give the bar back")
        dock.claim(select, for: .select)
        #expect(dock.bar(on: .library) == .select, "the bar drawn beside Select")
        dock.release(select)
        #expect(dock.bar(on: .library) == .tabs, "Select did not hand the bar back")

        // A takeover leaves no bar at all, and outranks select mode while both hold.
        let settings = UUID()
        dock.claim(select, for: .select)
        dock.claim(settings, for: .takeover)
        #expect(dock.claimant == .takeover)
        #expect(MainTab.allCases.allSatisfy { dock.bar(on: $0) == .none }, "a bar under Settings")
        dock.release(settings)
        #expect(dock.bar(on: .library) == .select, "the takeover's end lost select mode's toolbar")
        dock.release(select)
        #expect(dock.claimant == nil)
    }

    /// Rewritten for MEMNG-679: the Library pressed from the Timeline is selected on the TABS,
    /// where MEMNG-604 gave it the scope toolbar; pressed again where it shows, the scope.
    @Test("the tab view's selection tells the dock of every press before it moves")
    func pressesReachTheDock() {
        let dock = AppDock()
        let held = Held(MainTab.library)
        let selection = Binding(get: { held.value }, set: { held.value = $0 })
        let pressing = Tabs.pressing(selection: selection, dock: dock)

        // The tab already showing, pressed again: the selection holds, the dock hears it.
        pressing.wrappedValue = .library
        #expect(held.value == .library)
        #expect(dock.mode == .scope, "a press on the Library showing left \(dock.mode)")

        pressing.wrappedValue = .timeline
        #expect(held.value == .timeline)
        #expect(dock.mode == .tabs, "a press on the Timeline left \(dock.mode)")
        #expect(dock.showing == .timeline)

        // The Library pressed from another tab: selected, on the tabs.
        pressing.wrappedValue = .library
        #expect(held.value == .library)
        #expect(dock.mode == .tabs, "a press on the Library from the Timeline left \(dock.mode)")
        #expect(dock.bar(on: .library) == .tabs, "the Library from the Timeline: no tab bar")
        #expect(dock.showing == .library)

        pressing.wrappedValue = .library
        #expect(dock.mode == .scope, "the Library pressed again where it shows left \(dock.mode)")
    }

    /// The dock stamps each swap of the bars — a change of mode, another tab on screen — and
    /// only those: what a Library scroll view's settling window opens on (MEMNG-679).
    @Test("a swap of the bars is stamped; a press or scroll that swaps nothing is not")
    func swapsAreStamped() async throws {
        // Two stamps a few milliseconds apart differ on any clock; two taken back to back may not.
        let apart = Duration.milliseconds(5)
        let dock = AppDock()
        #expect(dock.swappedAt == nil)
        dock.send(.selected(.library))
        let shown = try #require(dock.swappedAt, "the first tab on screen was not stamped")
        try await Task.sleep(for: apart)
        dock.scrolled(to: 10, by: .scroll)
        #expect(dock.swappedAt == shown, "a scroll that swapped nothing was stamped")
        dock.scrolled(to: 300, by: .scroll)
        let collapsed = try #require(dock.swappedAt)
        #expect(collapsed > shown, "the swap to the scope was not stamped")
        try await Task.sleep(for: apart)
        dock.scrolled(to: 900, by: .scroll)
        #expect(dock.swappedAt == collapsed, "a scroll under the scope was stamped")
        dock.send(.pressedLibraryIcon)
        let restored = try #require(dock.swappedAt)
        #expect(restored > collapsed, "the icon's swap to the tabs was not stamped")

        // MEMNG-684: a claim takes the bars away and its release gives them back, each a swap.
        let select = UUID()
        try await Task.sleep(for: apart)
        dock.claim(select, for: .select)
        let claimed = try #require(dock.swappedAt)
        #expect(claimed > restored, "select mode's claim was not stamped")
        try await Task.sleep(for: apart)
        dock.claim(select, for: .select)
        #expect(dock.swappedAt == claimed, "a claim delivered twice was stamped twice")
        dock.release(select)
        let released = try #require(dock.swappedAt)
        #expect(released > claimed, "the release was not stamped")
        try await Task.sleep(for: apart)
        dock.release(select)
        #expect(dock.swappedAt == released, "a release with nothing claimed was stamped")
    }

    /// A jump the Library asks for explains the first move after it, once, and only while fresh:
    /// it cannot let a later layout echo through (MEMNG-679).
    @Test("a jump the Library asked for is claimed by the next move, once, and not once lapsed")
    func askedJumpIsClaimedOnce() {
        let dock = AppDock()
        #expect(!dock.claimJump(at: .now), "a claim with nothing asked")
        dock.askedToJump()
        let moved = ContinuousClock.now
        #expect(dock.claimJump(at: moved), "the move right after the ask")
        #expect(!dock.claimJump(at: moved), "the same ask claimed twice")
        dock.askedToJump()
        let late = ContinuousClock.now.advanced(by: DockScrollFence.settling)
        #expect(!dock.claimJump(at: late), "an ask claimed once the settling had passed")
    }

    /// A Library scroll under select mode or Settings is dropped, so ending the claim brings back
    /// the bar it hid — the tab bar, not a scope the hidden scroll would have swapped in.
    /// Extended for MEMNG-684: the offset the layout moves as the release gives the bars back,
    /// idle and inside the window the release opened, is no scroll either. It is fed the way a
    /// Library scroll view feeds the dock (`AppDock.scrolled(from:to:judgedBy:moving:at:)`, the
    /// whole of `DockFeed`), with the dock's last swap long past before Select began, so only the
    /// release's own stamp can hold it — and the swing the lazy stack makes 800 ms later, past
    /// the window, is held too until the scroll view moves (review round 1).
    @Test("a scroll under a claim leaves the mode alone, and ending the claim restores the bar")
    func scrollUnderAClaimIsDropped() async throws {
        let dock = AppDock()
        dock.send(.selected(.library))
        try await Task.sleep(for: DockScrollFence.settling + .milliseconds(100))
        var fence = DockScrollFence()
        let top = Self.reading(y: 0, insetBottom: 83)
        // The scroll view is on screen before Select: a reading of its own, a nudge short of the
        // threshold, so it lives through the claim and the release (review round 2).
        let before = ContinuousClock.now.advanced(by: .milliseconds(-1))
        dock.scrolled(from: top, to: top, judgedBy: &fence, moving: true, at: before)
        let select = UUID()
        dock.claim(select, for: .select)
        dock.scrolled(to: 300, by: .scroll)
        #expect(dock.mode == .tabs, "a scroll under a claim swapped the bars: \(dock.mode)")
        #expect(dock.bar(on: .library) == .select, "the tab bar drawn under a claim")
        dock.release(select)
        #expect(dock.bar(on: .library) == .tabs, "ending the claim did not restore the tab bar")

        // The release's settling: the tab bar back, the frame changes and the offset shifts.
        let reframed = Self.reading(y: 0, insetBottom: 34)
        dock.scrolled(from: top, to: reframed, judgedBy: &fence, moving: false)
        let shifted = Self.reading(y: 300, insetBottom: 34)
        dock.scrolled(from: reframed, to: shifted, judgedBy: &fence, moving: false)
        #expect(dock.mode == .tabs, "the release's own settling swapped the bars: \(dock.mode)")
        #expect(dock.bar(on: .library) == .tabs, "the release's settling drew the scope")
        // The lazy stack's swing at the foot, past the settling: held until the scroll moves.
        let late = ContinuousClock.now.advanced(by: .milliseconds(800))
        let swung = Self.reading(y: 700, insetBottom: 34)
        dock.scrolled(from: shifted, to: swung, judgedBy: &fence, moving: false, at: late)
        #expect(dock.mode == .tabs, "an idle swing 800 ms after the release swapped the bars")

        // The same scroll with no claim, made while the scroll view moves, is a scroll.
        let dragged = Self.reading(y: 320, insetBottom: 34)
        dock.scrolled(from: swung, to: dragged, judgedBy: &fence, moving: true, at: late)
        #expect(dock.mode == .scope, "a scroll with no claim left \(dock.mode)")
        #expect(dock.bar(on: .library) == .scope)
    }

    /// MEMNG-684: the window a claim or a release opens is the one a swap opens. The stamp the
    /// dock wrote is what the fence is handed: an idle move inside 500 ms of it is no scroll, the
    /// same move made while the scroll view moves is one.
    @Test("an idle move within the settling of a claim or a release is none; a moving one counts")
    func claimAndReleaseSettle() throws {
        let dock = AppDock()
        let select = UUID()
        for step in ["claim", "release"] {
            if step == "claim" { dock.claim(select, for: .select) } else { dock.release(select) }
            let stamp = try #require(dock.swappedAt, "the \(step) was not stamped")
            let soon = stamp.advanced(by: .milliseconds(200))
            let late = stamp.advanced(by: DockScrollFence.settling)
            var idle = DockScrollFence()
            let still = idle.scrolled(
                from: Self.reading(y: 0), to: Self.reading(y: 300), at: soon, swappedAt: stamp)
            #expect(still == nil, "an idle move 200 ms after the \(step) counted")
            var moving = DockScrollFence()
            let moved = moving.scrolled(
                from: Self.reading(y: 0), to: Self.reading(y: 300), at: soon, swappedAt: stamp,
                moving: true)
            #expect(moved == 300, "a moving scroll 200 ms after the \(step) was dropped")
            var after = DockScrollFence()
            let past = after.scrolled(
                from: Self.reading(y: 0), to: Self.reading(y: 300), at: late, swappedAt: stamp)
            #expect(past == 300, "an idle move once the \(step)'s settling had passed was dropped")
        }
    }

    /// A jump the Library asked for is a move of its own, under a hold as anywhere: it counts at
    /// once and ends the hold, so the idle move after it counts too (review round 2).
    @Test("an asked jump under a claim's hold counts, and ends the hold")
    func askedJumpEndsTheHold() async throws {
        let dock = AppDock()
        dock.send(.selected(.library))
        var fence = DockScrollFence()
        let before = ContinuousClock.now.advanced(by: .milliseconds(-1))
        let nudged = Self.reading(y: 10, insetBottom: 83)
        dock.scrolled(
            from: Self.reading(y: 0, insetBottom: 83), to: nudged, judgedBy: &fence, moving: true,
            at: before)
        let select = UUID()
        dock.claim(select, for: .select)
        dock.release(select)
        let held = try #require(dock.heldAt, "the release was not stamped")
        let reframed = Self.reading(y: 10)
        dock.scrolled(from: nudged, to: reframed, judgedBy: &fence, moving: false)
        try await Task.sleep(for: DockScrollFence.settling + .milliseconds(100))
        let swung = Self.reading(y: 400)
        dock.scrolled(from: reframed, to: swung, judgedBy: &fence, moving: false)
        #expect(dock.mode == .tabs, "precondition: an idle swing under the hold counted")

        dock.askedToJump()
        let landed = Self.reading(y: 2000)
        dock.scrolled(from: swung, to: landed, judgedBy: &fence, moving: false)
        #expect(dock.mode == .scope, "the asked jump under the hold was dropped: \(dock.mode)")
        let after = ContinuousClock.now.advanced(by: DockScrollFence.settling * 2)
        let next = fence.scrolled(
            from: landed, to: Self.reading(y: 2100), at: after, swappedAt: dock.swappedAt,
            heldAt: held)
        #expect(next == 2100, "the hold outlived the asked jump")
    }

    private static func reading(y: Double, insetBottom: Double = 34) -> DockScrollReading {
        DockScrollReading(
            y: y, width: 402, height: 701, insetTop: 0, insetLeading: 0,
            insetBottom: insetBottom, insetTrailing: 0)
    }

    /// The dock judges a scroll against the tab it was last told is on screen: a Library scroll
    /// view that reports while another tab shows, or before any tab is known, changes nothing.
    /// Flipped for MEMNG-685: on the Library a scroll back to the top gives the tabs back.
    @Test("a scroll counts while the Library is the tab on screen, and only then")
    func scrollCountsOnTheLibraryAlone() {
        let dock = AppDock()
        dock.scrolled(to: 300, by: .scroll)
        #expect(dock.mode == .tabs, "a scroll before any tab was known left \(dock.mode)")

        dock.send(.selected(.timeline))
        dock.scrolled(to: 300, by: .scroll)
        #expect(dock.mode == .tabs, "a scroll while the Timeline shows left \(dock.mode)")

        dock.send(.selected(.library))
        dock.scrolled(to: 24, by: .scroll)
        #expect(dock.mode == .tabs, "a scroll to 24 points left \(dock.mode)")
        dock.scrolled(to: 25, by: .scroll)
        #expect(dock.mode == .scope, "a scroll to 25 points left \(dock.mode)")
        dock.scrolled(to: 0, by: .scroll)
        #expect(dock.mode == .tabs, "a scroll back to the top left \(dock.mode)")
    }

    /// A jump the Library asked for that lands at the top is the app's move, not a scroll: the
    /// scope stays, though the same reading unasked gives the tabs back (MEMNG-685). Fed the way a
    /// Library scroll view feeds the dock, starting in the scope away from the top, the jump's
    /// reading made while the scroll view moves so the fence passes it whatever the window.
    @Test("an asked jump that lands at the top keeps the scope; a scroll there gives the tabs")
    func askedJumpToTheTopKeepsTheScope() {
        let dock = AppDock()
        dock.send(.selected(.library))
        var fence = DockScrollFence()
        let top = Self.reading(y: 0)
        let away = Self.reading(y: 300)
        dock.scrolled(from: top, to: away, judgedBy: &fence, moving: true)
        #expect(dock.mode == .scope, "precondition: a scroll to 300 left \(dock.mode)")

        dock.askedToJump()
        dock.scrolled(from: away, to: top, judgedBy: &fence, moving: true)
        #expect(dock.mode == .scope, "an asked jump to the top gave the tabs back")
        dock.askedToJump()
        let pulled = Self.reading(y: -10)
        dock.scrolled(from: top, to: pulled, judgedBy: &fence, moving: false)
        #expect(dock.mode == .scope, "an idle asked jump past the top gave the tabs back")

        // The same reading with nothing asked is the reader's scroll reaching the top.
        dock.scrolled(from: pulled, to: away, judgedBy: &fence, moving: true)
        dock.scrolled(from: away, to: top, judgedBy: &fence, moving: true)
        #expect(dock.mode == .tabs, "a scroll back to the top left \(dock.mode)")
    }

    /// A scope pick swaps the Library's scroll view: the one it takes away collapses and the one it
    /// puts on screen lands at its top, both idle — the readings the probe of MEMNG-685 saw, fed
    /// the way each scroll view feeds the dock. Neither is a scroll; the reader's first drag on
    /// the new one is, and pulled past the top it gives the tabs back.
    @Test("a scope pick's landing at the top keeps the scope; the next drag there does not")
    func scopePickLandingKeepsTheScope() {
        let dock = AppDock()
        let choice = LibraryScopeChoice()
        choice.whenScopeMoves { dock.pickedScope() }
        dock.send(.selected(.library))
        var leaving = DockScrollFence()
        let scrolled = Self.reading(y: 960)
        dock.scrolled(from: Self.reading(y: 0), to: scrolled, judgedBy: &leaving, moving: true)
        #expect(dock.mode == .scope, "precondition: a scroll to 960 left \(dock.mode)")

        // Past the settling of the swap to the scope, so only the pick can explain what follows.
        let later = ContinuousClock.now.advanced(by: DockScrollFence.settling * 2)
        choice.choose(.months)
        let collapsed = Self.reading(y: -3367)
        dock.scrolled(from: scrolled, to: collapsed, judgedBy: &leaving, moving: false, at: later)
        #expect(dock.mode == .scope, "the scroll view the pick took away gave the tabs back")
        var landed = DockScrollFence()
        let bare = DockScrollReading(
            y: 0, width: 402, height: 649, insetTop: 0, insetLeading: 0, insetBottom: 0,
            insetTrailing: 0)
        let atTop = DockScrollReading(
            y: -0.000_000_000_000_028, width: 402, height: 649, insetTop: 139, insetLeading: 0,
            insetBottom: 86, insetTrailing: 0)
        dock.scrolled(from: bare, to: atTop, judgedBy: &landed, moving: false, at: later)
        #expect(dock.mode == .scope, "the new scroll view's landing gave the tabs back")

        let pulled = DockScrollReading(
            y: -10, width: 402, height: 649, insetTop: 139, insetLeading: 0, insetBottom: 86,
            insetTrailing: 0)
        dock.scrolled(from: atTop, to: pulled, judgedBy: &landed, moving: true, at: later)
        #expect(dock.mode == .tabs, "the reader's first drag past the top left \(dock.mode)")
    }

    /// Every move of the scope is told before it moves, by hand or by the Library; a choice of
    /// the scope already showing moves nothing and is not told (MEMNG-685).
    @Test("each move of the scope is told once; a choice of the scope showing is not")
    func scopeMovesAreTold() {
        let choice = LibraryScopeChoice()
        let told = Held<[LibraryScope]>([])
        choice.whenScopeMoves { told.value.append(choice.scope) }
        choice.choose(.all)
        #expect(told.value.isEmpty, "a choice of the scope showing was told")
        choice.choose(.years)
        choice.showMonths(of: "2026")
        choice.showAll()
        choice.showMonth("2026-09")
        choice.showMonth("2026-08")
        #expect(told.value == [.all, .years, .months, .all], "told: \(told.value)")
    }

    private static func reading(_ y: Double) -> DockScrollReading {
        DockScrollReading(
            y: y, width: 402, height: 700, insetTop: 100, insetLeading: 0, insetBottom: 96,
            insetTrailing: 0)
    }

    /// The Timeline's list fed through the path its feed takes (`AppDock.scrolledTab`): a run of
    /// the reader's travel down folds the leading bar to its icon and one up gives the capsule
    /// back, each told to the dock once; an idle move, a waver and a scroll under a claim change
    /// nothing, and the Library's bar is never folded.
    @Test("the Timeline's scroll folds the leading bar through the dock, once per direction")
    func timelineScrollFoldsThroughTheDock() {
        let dock = AppDock()
        var fold = DockFold()
        dock.send(.selected(.timeline))
        let swapped = dock.swappedAt
        func move(_ from: Double, _ to: Double, moving: Bool = true) {
            dock.scrolledTab(
                .timeline, from: Self.reading(from), to: Self.reading(to), committing: &fold,
                moving: moving)
        }
        #expect(Tabs.leadingShape(dock, on: .timeline) == .tabs)
        move(0, 200, moving: false)
        #expect(dock.mode == .tabs, "an idle move folded the bar")
        move(200, 220)
        move(220, 215)
        move(215, 235)
        #expect(dock.mode == .tabs, "a waver below the threshold folded the bar")
        #expect(dock.swappedAt == swapped, "a reading that decided nothing reached the dock")
        move(235, 260)
        #expect(dock.mode == .folded)
        let folded = dock.swappedAt
        #expect(folded != swapped, "the fold was not told to the dock")
        #expect(Tabs.leadingShape(dock, on: .timeline) == .folded)
        #expect(Tabs.leadingShape(dock, on: .library) == .tabs, "the Library folded")
        #expect(dock.bar(on: .timeline) == .tabs, "a fold is no other bar")
        move(260, 300)
        move(300, 400)
        #expect(dock.swappedAt == folded, "a fold already standing was told again")
        move(400, 390)
        #expect(dock.mode == .folded, "up 10 unfolded")
        move(390, 360)
        #expect(dock.mode == .tabs, "up 40 left it folded")
        move(360, 400)
        #expect(dock.mode == .folded)
        dock.send(.pressedTab(.timeline, showing: .timeline))
        #expect(dock.mode == .tabs, "the icon's press gave the capsule back")
        fold.began()
        move(400, 410)
        #expect(dock.mode == .tabs, "the next gesture's first points undid the press")
        let claim = UUID()
        dock.claim(claim, for: .takeover)
        move(410, 600)
        #expect(dock.mode == .tabs, "a scroll under a claim folded the bar")
        dock.release(claim)
        dock.send(.selected(.places))
        move(600, 800)
        #expect(dock.mode == .tabs, "the Timeline's scroll folded the bar on Places")
    }

    /// The Timeline's large title folding into the inline bar mid-drag takes its height off the top
    /// inset: the reading's `y` (offset + inset) falls while the content goes on moving down. The
    /// travel is the offset's, so the drag stays folded — read as `y`'s, it was a run back up, and
    /// the simulator's recording showed the bar unfold and fold again inside one drag (MEMNG-690).
    @Test("a large title folding mid-drag is not travel back up")
    func largeTitleFoldIsNotTravel() {
        let dock = AppDock()
        var fold = DockFold()
        dock.send(.selected(.timeline))
        func reading(_ y: Double, top: Double) -> DockScrollReading {
            DockScrollReading(
                y: y, width: 402, height: 700, insetTop: top, insetLeading: 0, insetBottom: 96,
                insetTrailing: 0)
        }
        func move(_ from: DockScrollReading, _ to: DockScrollReading) {
            dock.scrolledTab(.timeline, from: from, to: to, committing: &fold, moving: true)
        }
        move(reading(0, top: 148), reading(80, top: 148))
        #expect(dock.mode == .folded, "precondition: 80 down folded")
        // The title goes: the inset loses 52 pt while the offset moves on 12 pt down, so `y`
        // falls by 40.
        move(reading(80, top: 148), reading(40, top: 96))
        #expect(dock.mode == .folded, "the title's fold unfolded the bar")
        move(reading(40, top: 96), reading(60, top: 96))
        #expect(dock.mode == .folded)
        move(reading(60, top: 96), reading(30, top: 96))
        #expect(dock.mode == .tabs, "a run of 30 up no longer unfolds")
    }

    /// Where the selection pill stands under each tab: one tab 86 pt along, the 94 pt pill
    /// reaching 4 pt past its tab on either side (MEMNG-690 phase 3).
    @Test(
        "the pill stands centred under its tab, one tab apart",
        arguments: [
            (MainTab.library, CGFloat(-4)),
            (.collections, 82),
            (.timeline, 168),
            (.places, 254),
        ] as [(MainTab, CGFloat)])
    func pillOffset(tab: MainTab, expected: CGFloat) {
        #expect(LeadingMainBar.pillOffset(for: tab) == expected)
        let middle = LeadingMainBar.pillOffset(for: tab) + LeadingMainBar.pillWidth / 2
        let index = CGFloat(MainTab.allCases.firstIndex(of: tab) ?? -1)
        #expect(middle == (index + 0.5) * LeadingMainBar.itemWidth, "not centred on its tab")
    }

    /// Each root draws the bar inside its own stack (MEMNG-690): its shape there, nothing
    /// without a dock nor under a takeover.
    @Test("a root's foot bar is the bar's shape, nothing without a dock or under a takeover")
    func footBarFollowsTheDock() {
        let dock = AppDock()
        dock.send(.selected(.timeline))
        #expect(LeadingFootBar.shape(dock, on: .timeline) == .tabs)
        #expect(LeadingFootBar.shape(dock, on: .places) == .tabs)
        #expect(LeadingFootBar.shape(nil, on: .timeline) == nil, "no dock")
        var fold = DockFold()
        dock.scrolledTab(
            .timeline, from: Self.reading(200), to: Self.reading(260), committing: &fold,
            moving: true)
        #expect(LeadingFootBar.shape(dock, on: .timeline) == .folded)
        let claim = UUID()
        dock.claim(claim, for: .takeover)
        #expect(LeadingFootBar.shape(dock, on: .timeline) == nil, "a takeover")
    }

    @Test("the leading bar draws the scope row on the Library's scope and nothing under a claim")
    func leadingShapeFollowsTheBar() {
        let dock = AppDock()
        dock.send(.selected(.library))
        dock.send(.pressedTab(.library, showing: .library))
        #expect(Tabs.leadingShape(dock, on: .library) == .scope)
        #expect(Tabs.leadingShape(dock, on: .timeline) == .tabs)
        let claim = UUID()
        dock.claim(claim, for: .select)
        #expect(Tabs.leadingShape(dock, on: .library) == nil)
        dock.release(claim)
        dock.claim(claim, for: .takeover)
        #expect(Tabs.leadingShape(dock, on: .timeline) == nil)
    }

    /// The Library draws its foot's bar inside its stack, and so keeps its height clear at its
    /// foot: the scope row on the scope, the capsule on the tabs, nothing under a claim
    /// (MEMNG-690).
    @Test("the Library draws the scope row on its scope, the capsule on the tabs")
    func libraryDrawsItsFootRow() {
        for bar in DockBar.allCases {
            let wanted: LeadingMainBar.BarShape? =
                switch bar {
                case .scope: .scope
                case .tabs: .tabs
                case .select, .none: nil
                }
            #expect(MediaLibraryView.footRow(bar) == wanted, "\(bar)")
        }
    }

    @Test("a claim delivered twice claims once, and two claims need two releases")
    func takeoverClaims() {
        let dock = AppDock()
        let settings = UUID()
        let another = UUID()
        #expect(!dock.isTakenOver)

        dock.claim(settings, for: .takeover)
        dock.claim(settings, for: .takeover)
        #expect(dock.isTakenOver)
        dock.release(settings)
        #expect(!dock.isTakenOver, "an appearance delivered twice left the dock away")

        dock.claim(settings, for: .takeover)
        dock.claim(another, for: .takeover)
        dock.release(settings)
        #expect(dock.isTakenOver, "one release gave the dock back under another claim")
        dock.release(another)
        #expect(!dock.isTakenOver)
        // A release with nothing claimed is no claim at all, not a debt the next claim pays off.
        dock.release(another)
        dock.claim(settings, for: .takeover)
        #expect(dock.isTakenOver)
    }

    @Test("a hand choice abandons the jump at once, and only when the view changes")
    func handChoiceAbandons() {
        let choice = LibraryScopeChoice()
        var abandoned = 0
        choice.whenChosenByHand { abandoned += 1 }

        choice.choose(.all)
        #expect(abandoned == 0, "choosing the view already on screen abandoned the jump")

        choice.choose(.years)
        // Synchronously: counted before anything could hop.
        #expect(abandoned == 1)
        #expect(choice.scope == .years)
    }

    @Test("a hand choice widens Months back to every year; a Years card narrows it")
    func handChoiceClearsTheYear() {
        let choice = LibraryScopeChoice()
        choice.showMonths(of: "2026")
        #expect(choice.scope == .months)
        #expect(choice.year == "2026")

        choice.choose(.months)
        #expect(choice.scope == .months)
        #expect(choice.year == nil, "a hand choice kept the Years narrowing")

        choice.showMonths(of: "2019")
        choice.showAll()
        #expect(choice.scope == .all)
    }

    @Test("a programmatic move is no hand choice: it abandons nothing")
    func programmaticMovesAbandonNothing() {
        let choice = LibraryScopeChoice()
        var abandoned = 0
        choice.whenChosenByHand { abandoned += 1 }
        choice.showMonths(of: "2026")
        choice.showAll()
        #expect(abandoned == 0)
    }

    // MARK: - The modes row on Collections (MEMNG-822)

    /// The dock with Collections on screen and `routes` as its stack's path, each route's screen
    /// having attached its modes when `attached`.
    private func collectionDock(
        _ routes: [String], attached: Bool = true
    ) -> (dock: AppDock, modes: [String: CollectionModeChoice]) {
        let dock = AppDock()
        dock.send(.selected(.collections))
        dock.collectionTrail(routes)
        var modes: [String: CollectionModeChoice] = [:]
        if attached {
            for route in routes {
                let choice = CollectionModeChoice()
                dock.attachModes(choice, to: route)
                modes[route] = choice
            }
        }
        return (dock, modes)
    }

    private func shape(_ dock: AppDock) -> LeadingMainBar.BarShape? {
        Tabs.leadingShape(dock, on: .collections)
    }

    /// What a collection's scroll past the threshold tells the dock: its modes row (MEMNG-845).
    private func scrolledDown(_ dock: AppDock) {
        dock.send(.scrolledTab(.collections, folds: true, showing: .collections))
    }

    @Test("a collection opens on the tabs; its scroll brings the modes row, as the Library's does")
    func aCollectionOnTopScrollsToTheModesRow() {
        let (dock, modes) = collectionDock(["A"])
        #expect(shape(dock) == .tabs, "the collection opened on its row, not on the tabs")
        #expect(dock.collectionModes === modes["A"], "the row is not the top screen's")
        scrolledDown(dock)
        #expect(shape(dock) == .modes, "the scroll folded the row instead of bringing it")
        #expect(Tabs.leadingShape(dock, on: .library) == .tabs, "the row reached the Library")
        #expect(collectionDock([]).dock.collectionModes == nil)
        #expect(shape(collectionDock([]).dock) == .tabs, "the root drew a modes row")
    }

    @Test("over a collection the row's scroll follows the Library's rule: past 24 pt, back at 0")
    func theRowFollowsTheLibrarysRule() {
        let (dock, _) = collectionDock(["A"])
        let owner = CollectionFeedOwner(route: AnyHashable("A"), mode: .photos)
        var fold = DockFold()
        func read(_ y: Double, moving: Bool = true) {
            dock.scrolledTab(
                .collections, owner: owner, from: Self.reading(y: y - 1),
                to: Self.reading(y: y), committing: &fold, moving: moving)
        }
        read(DockMode.scopeThreshold)
        #expect(shape(dock) == .tabs, "the row came at the threshold, not past it")
        read(DockMode.scopeThreshold + 1, moving: false)
        #expect(shape(dock) == .tabs, "an idle move brought the row")
        read(DockMode.scopeThreshold + 1)
        #expect(shape(dock) == .modes, "past the threshold the row did not come")
        read(DockMode.scopeThreshold - 20)
        read(1)
        #expect(shape(dock) == .modes, "a scroll up short of the top took the row away")
        read(0)
        #expect(shape(dock) == .tabs, "the top did not give the tabs back")
    }

    @Test("the Collections press over a collection brings its row and pops nothing")
    func theCollectionsPressBringsTheModesRow() {
        let (dock, _) = collectionDock(["A", "B"])
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(shape(dock) == .modes)
        #expect(dock.reselections[.collections, default: 0] == 0, "a reselection was counted")
        #expect(dock.modesStack.count == 2, "the stack moved")
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(shape(dock) == .modes, "a second press took the row away")
    }

    @Test("the row's icon gives the full capsule; the Collections press there brings the row back")
    func theModesIconGivesTheTabsAndCollectionsReturns() {
        let (dock, _) = collectionDock(["A"])
        scrolledDown(dock)
        dock.send(.pressedCollectionsIcon)
        #expect(shape(dock) == .tabs, "the icon did not give the full capsule")
        #expect(dock.collectionModes != nil, "the collection left with the icon's press")
        #expect(dock.reselections[.collections, default: 0] == 0)
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(shape(dock) == .modes, "the Collections press did not bring the row back")
        #expect(dock.reselections[.collections, default: 0] == 0, "the press over A popped")
        #expect(dock.modesStack.count == 1)
    }

    @Test("the Collections press at the root counts one reselection, and the icon there no row")
    func theRootsPressCountsAReselection() {
        let (dock, _) = collectionDock([])
        dock.send(.pressedCollectionsIcon)
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(dock.reselections[.collections, default: 0] == 1)
        #expect(shape(dock) == .tabs)
    }

    @Test("another tab gives the tabs back and keeps the collection, as leaving the Library does")
    func anotherTabKeepsTheCollection() {
        let (dock, _) = collectionDock(["A"])
        scrolledDown(dock)
        dock.send(.pressedTab(.timeline, showing: .collections))
        dock.send(.selected(.timeline))
        dock.send(.pressedTab(.collections, showing: .timeline))
        dock.send(.selected(.collections))
        #expect(shape(dock) == .tabs, "coming back kept the row")
        #expect(dock.collectionModes != nil, "the tab switch lost the collection")
        #expect(dock.reselections[.collections, default: 0] == 0)
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(shape(dock) == .modes, "the collection's row did not come back on its press")
    }

    @Test("the last route gone gives the full capsule, from the row and the tabs")
    func theLastPopGivesTheTabs() {
        let (dock, _) = collectionDock(["A"])
        scrolledDown(dock)
        dock.collectionTrail([])
        #expect(dock.mode == .tabs, "the root opened folded")
        #expect(shape(dock) == .tabs)
        let (other, _) = collectionDock(["A"])
        other.collectionTrail([])
        #expect(other.mode == .tabs)
        #expect(shape(other) == .tabs)
    }

    @Test("a path whose top is unchanged keeps the row; a new top gives the tabs")
    func onlyANewTopResets() {
        let (dock, modes) = collectionDock(["A", "B"])
        scrolledDown(dock)
        dock.collectionTrail(["A", "B"])
        dock.attachModes(CollectionModeChoice(), to: "B")
        #expect(shape(dock) == .modes, "the same path took the row away")
        #expect(dock.collectionModes === modes["B"], "a second attachment replaced B's modes")
        dock.collectionTrail(["B"])
        #expect(shape(dock) == .modes, "a route below the top took the row away")
        #expect(dock.collectionModes === modes["B"])
        let (back, _) = collectionDock(["A", "B"])
        scrolledDown(back)
        back.collectionTrail(["A"])
        #expect(back.mode == .tabs, "Back to A kept B's row")
        #expect(shape(back) == .tabs)
    }

    @Test("a push from a folded root opens the collection unfolded; another tab's fold is kept")
    func aPushUnfoldsOnCollectionsOnly() {
        let (dock, _) = collectionDock([])
        scrolledDown(dock)
        dock.collectionTrail(["A"])
        #expect(dock.mode == .tabs, "the push kept the root's fold")
        // A path the app changes while the Timeline shows leaves the Timeline's fold.
        let (other, _) = collectionDock(["A"])
        other.send(.selected(.timeline))
        other.send(.scrolledTab(.timeline, folds: true, showing: .timeline))
        other.collectionTrail([])
        #expect(other.mode == .folded, "a pop off screen unfolded the Timeline")
    }

    @Test("a re-tap before the top screen attached its modes, or after a switch back, pops nothing")
    func theTopRoutesPresenceSuppressesThePop() {
        let (dock, _) = collectionDock(["A"], attached: false)
        #expect(shape(dock) == .tabs, "a row drawn before the screen attached its modes")
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(dock.reselections[.collections, default: 0] == 0, "the re-tap popped")
        #expect(shape(dock) == .tabs, "a re-tap with no modes attached drew a row or a fold")
        let choice = CollectionModeChoice()
        dock.attachModes(choice, to: "A")
        #expect(shape(dock) == .tabs)
        dock.send(.selected(.timeline))
        dock.send(.selected(.collections))
        dock.send(.pressedTab(.collections, showing: .collections))
        #expect(shape(dock) == .modes)
        #expect(dock.reselections[.collections, default: 0] == 0)
    }

    @Test("modes attached before the path told the route are placed when it is, else dropped")
    func modesAttachedEarlyArePlaced() {
        let dock = AppDock()
        dock.send(.selected(.collections))
        let choice = CollectionModeChoice()
        dock.attachModes(choice, to: "A")
        #expect(shape(dock) == .tabs, "a row with no route on the stack")
        dock.collectionTrail(["A"])
        #expect(dock.collectionModes === choice)
        let stale = AppDock()
        stale.send(.selected(.collections))
        stale.attachModes(CollectionModeChoice(), to: "A")
        stale.collectionTrail([])
        stale.collectionTrail(["A"])
        #expect(stale.collectionModes == nil, "an attachment the path never held was kept")
    }

    @Test("Select takes the bar; its release brings back the row, or the tabs it found")
    func aClaimTakesTheModesRow() {
        let (dock, _) = collectionDock(["A"])
        let select = UUID()
        dock.claim(select, for: .select)
        #expect(shape(dock) == nil)
        dock.release(select)
        #expect(shape(dock) == .tabs)
        scrolledDown(dock)
        dock.claim(select, for: .select)
        #expect(shape(dock) == nil)
        dock.release(select)
        #expect(shape(dock) == .modes)
    }

    @Test("the modes row's control writes the choice its screen reads")
    func theModesControlWritesTheChoice() {
        let (dock, modes) = collectionDock(["A"])
        scrolledDown(dock)
        let picker = CollectionModePicker(choice: dock.collectionModes ?? CollectionModeChoice())
        #expect(modes["A"]?.mode == .photos)
        picker.choice.choose(.map)
        #expect(modes["A"]?.mode == .map, "the row wrote another screen's choice")
        #expect(shape(dock) == .modes, "the Map took the row away")
        #expect(CollectionModePicker.identifier != LibraryScopePicker.identifier)
    }

    /// One drag of 240 pt told to `dock` as a scroll view of `route`'s screen in `mode` reports
    /// it, the way `DockFeed` tells it; `nil` names no owner.
    private func drag(_ dock: AppDock, _ route: String?, _ mode: TripMode) {
        var fold = DockFold()
        let owner = route.map { CollectionFeedOwner(route: AnyHashable($0), mode: mode) }
        dock.scrolledTab(
            .collections, owner: owner, from: Self.reading(y: 0), to: Self.reading(y: 240),
            committing: &fold, moving: true)
    }

    /// A Collections reading is judged against the screen that issued it (MEMNG-822): the
    /// collection under the top, the top in a mode it no longer shows, and a reading that names
    /// no screen fold nothing; the top's own reading in its mode folds the bar.
    @Test("a Collections reading counts only from the collection on top, in the mode it shows")
    func aReadingCountsOnlyFromItsOwner() {
        let (dock, modes) = collectionDock(["A", "B"])
        drag(dock, "A", .photos)
        #expect(dock.mode == .tabs, "the collection under the top folded the bar")
        modes["B"]?.choose(.journal)
        drag(dock, "B", .photos)
        #expect(dock.mode == .tabs, "B's outgoing Photos folded its Journal")
        drag(dock, nil, .journal)
        #expect(dock.mode == .tabs, "a reading of nobody's folded the bar")
        // The control: the top's own reading, in the mode it shows.
        drag(dock, "B", .journal)
        #expect(shape(dock) == .modes, "the top's own reading brought no row")
    }

    /// The Map has no feed to unfold the bar with (MEMNG-822): an outgoing Photos reading heard
    /// after the Map was chosen folds nothing, and a fold however it came leaves the row whole;
    /// back on Photos the fold that stands is drawn.
    @Test("the Map keeps the row it was chosen from; an old Photos reading moves nothing")
    func theMapHoldsItsRow() {
        let (dock, modes) = collectionDock(["A"])
        modes["A"]?.choose(.map)
        drag(dock, "A", .photos)
        #expect(dock.mode == .tabs, "the outgoing Photos reading moved the Map's bar")
        #expect(shape(dock) == .tabs)
        scrolledDown(dock)
        #expect(shape(dock) == .modes, "the Map's row was compacted")
        // Back on Photos the same row stands: no mode folds a collection to the one icon.
        modes["A"]?.choose(.photos)
        #expect(shape(dock) == .modes, "the row did not stand on Photos")
    }

    /// A push or Back unfolds the bar (`collectionStackChanged`); the screen it moved away from
    /// goes on reporting while it goes, and those readings must not fold the bar back.
    @Test("an outgoing collection's reading after a push, a Back or the last pop folds nothing")
    func anOutgoingCollectionsReadingFoldsNothing() {
        let (dock, _) = collectionDock(["A"])
        dock.collectionTrail(["A", "B"])
        dock.attachModes(CollectionModeChoice(), to: "B")
        drag(dock, "A", .photos)
        #expect(dock.mode == .tabs, "A's reading after the push folded B's bar")
        #expect(shape(dock) == .tabs, "A's reading after the push brought B's row")
        dock.collectionTrail(["A"])
        drag(dock, "B", .photos)
        #expect(dock.mode == .tabs, "B's reading after Back folded A's bar")
        dock.collectionTrail([])
        drag(dock, "A", .photos)
        #expect(dock.mode == .tabs, "A's reading after the last pop folded the root's bar")
        #expect(shape(dock) == .tabs)
    }
}
