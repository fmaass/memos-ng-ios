import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The card's decisions, each with a case per input category rather than a happy path.
@MainActor
@Suite("Memo card presentation")
struct MemoCardPresentationTests {
    @Test("the photo arrangement has a case for every count, and counts the rest")
    func photoLayouts() {
        #expect(MemoCardPresentation.photoLayout(for: 0) == .none)
        #expect(MemoCardPresentation.photoLayout(for: 1) == .solo)
        #expect(MemoCardPresentation.photoLayout(for: 2) == .pair)
        #expect(MemoCardPresentation.photoLayout(for: 3) == .strip(overflow: 0))
        #expect(MemoCardPresentation.photoLayout(for: 4) == .strip(overflow: 1))
        #expect(MemoCardPresentation.photoLayout(for: 12) == .strip(overflow: 9))
        // A negative count cannot happen, and must not be a crash if it ever does.
        #expect(MemoCardPresentation.photoLayout(for: -1) == .none)
    }

    @Test("what is drawn never exceeds what is there")
    func tileCounts() {
        for count in 0...12 {
            let layout = MemoCardPresentation.photoLayout(for: count)
            let tiles = MemoCardPresentation.tileCount(for: layout)
            #expect(tiles <= count)
            #expect(tiles <= 3)
            if case .strip(let overflow) = layout {
                #expect(tiles + overflow == count)
            }
        }
    }

    @Test("the avatar letter comes from the name, not the address")
    func avatarInitials() {
        #expect(MemoCardPresentation.initial(forOwner: "fabian") == "F")
        #expect(MemoCardPresentation.initial(forOwner: "fabian@example.invalid") == "F")
        #expect(MemoCardPresentation.initial(forOwner: "  ada  ") == "A")
        #expect(MemoCardPresentation.initial(forOwner: "Änna") == "Ä")
        #expect(MemoCardPresentation.initial(forOwner: "") == "?")
        #expect(MemoCardPresentation.initial(forOwner: "   ") == "?")
        #expect(MemoCardPresentation.initial(forOwner: "@example.invalid") == "?")
    }

    @Test("the owner is named the way a person would say it")
    func ownerNames() {
        #expect(MemoCardPresentation.displayName(forOwner: "fabian") == "fabian")
        #expect(MemoCardPresentation.displayName(forOwner: "fabian@example.invalid") == "fabian")
        #expect(MemoCardPresentation.displayName(forOwner: " ada ") == "ada")
        #expect(MemoCardPresentation.displayName(forOwner: "") == "Unknown")
        #expect(MemoCardPresentation.displayName(forOwner: "@example.invalid") == "Unknown")
    }

    @Test("every visibility has a distinct word and a distinct glyph")
    func visibilityVocabulary() {
        let labels = MemoVisibility.allCases.map(\.label)
        let symbols = MemoVisibility.allCases.map(\.symbolName)
        #expect(labels == ["Private", "Protected", "Public"])
        #expect(Set(labels).count == labels.count)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }
}
