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

        // The Library pressed from another tab: selected AND the scope toolbar.
        pressing.wrappedValue = .library
        #expect(held.value == .library)
        #expect(dock.mode == .scope, "a press on the Library from the Timeline left \(dock.mode)")
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
