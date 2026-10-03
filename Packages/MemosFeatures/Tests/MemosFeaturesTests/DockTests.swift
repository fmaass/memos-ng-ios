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

    @Test("the scope toolbar takes the bar's place on the Library alone, and a claim takes both")
    func barsFollowTheMode() {
        let dock = AppDock()
        #expect(dock.mode == .tabs)
        #expect(MainTab.allCases.allSatisfy { dock.showsSystemBar(on: $0) }, "a bar missing")
        #expect(!dock.showsScopeBar, "the scope toolbar at launch")

        dock.send(.pressedTab(.library, showing: .library))
        #expect(!dock.showsSystemBar(on: .library), "the bar beside the scope toolbar")
        #expect(dock.showsScopeBar)

        // Select mode's toolbar is then the only bottom chrome, and ending it restores the scope.
        let select = UUID()
        dock.claim(select)
        #expect(!dock.showsSystemBar(on: .library), "the bar drawn beside Select")
        #expect(!dock.showsScopeBar, "the scope toolbar drawn beside Select")
        dock.release(select)
        #expect(dock.showsScopeBar, "Select did not hand the scope toolbar back")
        #expect(!dock.showsSystemBar(on: .library))

        dock.send(.pressedLibraryIcon)
        #expect(dock.showsSystemBar(on: .library), "the icon did not give the bar back")
        #expect(!dock.showsScopeBar)
        dock.claim(select)
        #expect(!dock.showsSystemBar(on: .library), "the bar drawn beside Select")
        dock.release(select)
        #expect(dock.showsSystemBar(on: .library), "Select did not hand the bar back")
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
        #expect(dock.showsSystemBar(on: .library), "the Library from the Timeline: no tab bar")
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
    @Test("a scroll under a claim leaves the mode alone, and ending the claim restores the bar")
    func scrollUnderAClaimIsDropped() {
        let dock = AppDock()
        dock.send(.selected(.library))
        let select = UUID()
        dock.claim(select)
        dock.scrolled(to: 300)
        #expect(dock.mode == .tabs, "a scroll under a claim swapped the bars: \(dock.mode)")
        #expect(!dock.showsSystemBar(on: .library), "the tab bar drawn under a claim")
        dock.release(select)
        #expect(dock.showsSystemBar(on: .library), "ending the claim did not restore the tab bar")
        #expect(!dock.showsScopeBar, "ending the claim drew the scope")

        // The same scroll with no claim is a scroll.
        dock.scrolled(to: 300)
        #expect(dock.mode == .scope, "a scroll with no claim left \(dock.mode)")
        #expect(dock.showsScopeBar)
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

        dock.claim(settings)
        dock.claim(settings)
        #expect(dock.isTakenOver)
        dock.release(settings)
        #expect(!dock.isTakenOver, "an appearance delivered twice left the dock away")

        dock.claim(settings)
        dock.claim(another)
        dock.release(settings)
        #expect(dock.isTakenOver, "one release gave the dock back under another claim")
        dock.release(another)
        #expect(!dock.isTakenOver)
        // A release with nothing claimed is no claim at all, not a debt the next claim pays off.
        dock.release(another)
        dock.claim(settings)
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
