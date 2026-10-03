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
        dock.scrolled(to: 10)
        #expect(dock.swappedAt == shown, "a scroll that swapped nothing was stamped")
        dock.scrolled(to: 300)
        let collapsed = try #require(dock.swappedAt)
        #expect(collapsed > shown, "the swap to the scope was not stamped")
        try await Task.sleep(for: apart)
        dock.scrolled(to: 900)
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
        dock.scrolled(to: 300)
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
    @Test("a scroll counts while the Library is the tab on screen, and only then")
    func scrollCountsOnTheLibraryAlone() {
        let dock = AppDock()
        dock.scrolled(to: 300)
        #expect(dock.mode == .tabs, "a scroll before any tab was known left \(dock.mode)")

        dock.send(.selected(.timeline))
        dock.scrolled(to: 300)
        #expect(dock.mode == .tabs, "a scroll while the Timeline shows left \(dock.mode)")

        dock.send(.selected(.library))
        dock.scrolled(to: 24)
        #expect(dock.mode == .tabs, "a scroll to 24 points left \(dock.mode)")
        dock.scrolled(to: 25)
        #expect(dock.mode == .scope, "a scroll to 25 points left \(dock.mode)")
        dock.scrolled(to: 0)
        #expect(dock.mode == .scope, "a scroll back to the top gave the tabs back")
    }

    @Test("the bar folds on scroll down on Timeline and Places, never on the Library")
    func minimisesOffTheLibrary() {
        #expect(!Tabs.minimizesOnScroll(on: .library))
        #expect(Tabs.minimizesOnScroll(on: .timeline))
        #expect(Tabs.minimizesOnScroll(on: .places))
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
}
