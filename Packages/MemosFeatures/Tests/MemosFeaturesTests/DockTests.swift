import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The dock's two shared objects, asked directly: what the accessory and the Library both read.
@MainActor
@Suite("The dock's shared state")
struct DockTests {
    @Test("the scope control is the Library's alone, and steps aside while the chrome is claimed")
    func scopeIsTheLibrarysAlone() {
        let dock = AppDock()
        #expect(MainTabs<EmptyView>.showsScope(on: .library, dock: dock))
        #expect(!MainTabs<EmptyView>.showsScope(on: .timeline, dock: dock))
        #expect(!MainTabs<EmptyView>.showsScope(on: .places, dock: dock))

        // Select mode's toolbar stands in the control's place while it holds its claim.
        let select = UUID()
        dock.claim(select)
        #expect(!MainTabs<EmptyView>.showsScope(on: .library, dock: dock), "drawn beside Select")
        dock.release(select)
        #expect(MainTabs<EmptyView>.showsScope(on: .library, dock: dock), "Select kept it away")
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
