import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The dock's two shared objects, asked directly: what the bar and the Library both read.
@MainActor
@Suite("The dock's shared state")
struct DockTests {
    @Test("the segment shows on the Library alone, even while the mode says segment")
    func segmentIsTheLibrarysAlone() {
        let dock = AppDock()
        dock.send(.tapActive(.library))
        #expect(dock.mode == .segment, "precondition: the Library's tap toggled it")
        #expect(dock.showsSegment(on: .library))
        // The instant between a tab switch and the `leaveLibrary` that follows it.
        #expect(!dock.showsSegment(on: .timeline))
        #expect(!dock.showsSegment(on: .places))
        dock.send(.leaveLibrary)
        #expect(dock.mode == .tabs)
    }

    @Test("the system bar stands aside for the Library's segment there alone, and for a takeover")
    func systemBarStandsAside() {
        let dock = AppDock()
        // At rest the bar is the system's on every root (MEMNG-666).
        #expect(MainTab.allCases.allSatisfy { dock.showsSystemBar(on: $0) })

        dock.send(.tapActive(.library))
        #expect(!dock.showsSystemBar(on: .library), "the bar is drawn beside the segment")
        #expect(dock.showsSystemBar(on: .timeline))
        #expect(dock.showsSystemBar(on: .places))

        dock.send(.tapActive(.library))
        #expect(dock.showsSystemBar(on: .library), "the Library icon did not give the bar back")

        let settings = UUID()
        dock.claim(settings)
        #expect(MainTab.allCases.allSatisfy { !dock.showsSystemBar(on: $0) })
        dock.release(settings)
        #expect(MainTab.allCases.allSatisfy { dock.showsSystemBar(on: $0) })
    }

    @Test("a press on another tab moves the selection; on the tab showing it is the dock's tap")
    func pressingTheBar() {
        let dock = AppDock()
        var selection = MainTab.timeline
        var writes: [MainTab] = []
        let root = Binding(
            get: { selection },
            set: { tab in
                writes.append(tab)
                selection = tab
            }
        )
        let pressing = MainTabs<EmptyView>.pressing(selection: root, dock: dock)

        pressing.wrappedValue = .library
        #expect(selection == .library)
        #expect(dock.mode == .tabs, "a switch to the Library collapsed it")

        // The Library pressed while it is showing: the dock's tap, and no write.
        pressing.wrappedValue = .library
        #expect(writes == [.library], "a re-selection wrote the selection")
        #expect(dock.mode == .segment, "the re-selection never reached the dock")

        pressing.wrappedValue = .library
        #expect(dock.mode == .tabs)

        // The Timeline pressed while it is showing is heard and changes nothing.
        pressing.wrappedValue = .timeline
        pressing.wrappedValue = .timeline
        #expect(selection == .timeline)
        #expect(writes == [.library, .timeline])
        #expect(dock.mode == .tabs)
    }

    @Test("the system bar folds on scroll on every tab but the Library, which has its chrome")
    func minimisesEverywhereButTheLibrary() {
        #expect(!MainTabs<EmptyView>.minimizesOnScroll(on: .library))
        #expect(MainTabs<EmptyView>.minimizesOnScroll(on: .timeline))
        #expect(MainTabs<EmptyView>.minimizesOnScroll(on: .places))
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
