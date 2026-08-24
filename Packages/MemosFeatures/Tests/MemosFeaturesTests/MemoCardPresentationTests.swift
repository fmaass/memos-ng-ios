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

    /// "Default" alone answers the question with the question. The whole point of the control is
    /// who will see this, and a person can only safely leave it alone if they are told what
    /// leaving it alone does.
    @Test("the default choice names what it resolves to, once the account has said")
    func defaultNamesItsResolution() {
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: .private)
                == "Default (Private)"
        )
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: .public) == "Default (Public)"
        )
        // An explicit choice speaks for itself and never mentions the default.
        #expect(
            VisibilityChoice.title(selection: .protected, accountDefault: .public) == "Protected"
        )
        #expect(
            VisibilityChoice.symbol(selection: .protected, accountDefault: .public)
                == MemoVisibility.protected.symbolName
        )
    }

    /// A pill that refuses to truncate must still fit the sheet. At an accessibility text size
    /// the framed form wants 518pt of the 369 a compose sheet has, so at those sizes it keeps the
    /// answer and drops the framing — the word "Default" is what the menu's checkmark already
    /// says, and the visibility is what nobody should have to guess.
    @Test("at an accessibility text size the answer survives and the framing goes")
    func compactKeepsTheAnswer() {
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: .protected, compact: true)
                == "Protected"
        )
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: .protected, compact: false)
                == "Default (Protected)"
        )
        // Nothing to shorten when nothing is known, and an explicit choice is already short.
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: nil, compact: true)
                == "Default")
        #expect(
            VisibilityChoice.title(selection: .public, accountDefault: .private, compact: true)
                == "Public"
        )
    }

    /// The one case where saying less is right: until the account has answered, the app does not
    /// know what "Default" means, and naming a guess would be a promise about who can read a memo.
    @Test("an unknown account default is not invented")
    func unknownDefaultStaysVague() {
        #expect(VisibilityChoice.title(selection: nil, accountDefault: nil) == "Default")
        #expect(
            VisibilityChoice.symbol(selection: nil, accountDefault: nil) == "person.crop.circle"
        )
        // And the glyph follows the resolution as soon as there is one.
        #expect(
            VisibilityChoice.symbol(selection: nil, accountDefault: .private)
                == MemoVisibility.private.symbolName
        )
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
