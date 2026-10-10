import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The card's decisions, each with a case per input category rather than a happy path.
@MainActor
@Suite("Memo card presentation")
struct MemoCardPresentationTests {
    @Test("the photo arrangement has a case for every count, and three or more justifies")
    func photoLayouts() {
        #expect(MemoCardPresentation.photoLayout(for: 0) == .none)
        #expect(MemoCardPresentation.photoLayout(for: 1) == .solo)
        #expect(MemoCardPresentation.photoLayout(for: 2) == .pair)
        #expect(MemoCardPresentation.photoLayout(for: 3) == .justified)
        #expect(MemoCardPresentation.photoLayout(for: 4) == .justified)
        #expect(MemoCardPresentation.photoLayout(for: 12) == .justified)
        // A negative count cannot happen, and must not be a crash if it ever does.
        #expect(MemoCardPresentation.photoLayout(for: -1) == .none)
    }

    /// The property the capped strip broke: a memo with six photos showed three and a "+3". Every
    /// photo is drawn now, at every count, and nothing is hidden behind a number.
    @Test("every photo a memo holds is drawn — nothing is hidden behind a count")
    func tileCounts() {
        for count in 0...12 {
            let layout = MemoCardPresentation.photoLayout(for: count)
            let tiles = MemoCardPresentation.tileCount(for: layout, of: count)
            #expect(tiles == count, "\(count) photos drew \(tiles) tiles")
        }
        // The arrangements cap at what is actually there, so a mismatched pair cannot index past
        // the end of the array.
        #expect(MemoCardPresentation.tileCount(for: .pair, of: 1) == 1)
        #expect(MemoCardPresentation.tileCount(for: .solo, of: 0) == 0)
        #expect(MemoCardPresentation.tileCount(for: .justified, of: -1) == 0)
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
        // Public is the one resolution with no word at all — see publicIsCarriedByItsGlyph.
        #expect(VisibilityChoice.title(selection: nil, accountDefault: .public) == nil)
        // An explicit choice speaks for itself and never mentions the default.
        #expect(
            VisibilityChoice.title(selection: .protected, accountDefault: .public) == "Just us"
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
                == "Just us"
        )
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: .protected, compact: false)
                == "Default (Just us)"
        )
        // Nothing to shorten when nothing is known, and an explicit choice is already short.
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: nil, compact: true)
                == "Default")
        // Public has no word to shorten in the first place.
        #expect(
            VisibilityChoice.title(selection: .public, accountDefault: .private, compact: true)
                == nil
        )
        #expect(
            VisibilityChoice.title(selection: .private, accountDefault: .public, compact: true)
                == "Private"
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

    /// Public is the household norm, so the pill stops saying it — the globe does. The word stays
    /// everywhere the app SPEAKS: menus, and the accessibility label a screen reader reads.
    @Test("only the exceptions get a word on the pill")
    func publicIsCarriedByItsGlyph() {
        #expect(MemoVisibility.public.pillLabel == nil)
        #expect(MemoVisibility.private.pillLabel == "Private")
        #expect(MemoVisibility.protected.pillLabel == "Just us")
        // The full word is untouched — that is what the a11y label and the menu rows use.
        #expect(MemoVisibility.public.label == "Public")
        #expect(MemoVisibility.public.symbolName == "globe")
    }

    @Test("the compose pill drops the word for public however public was arrived at")
    func composePillDropsPublicEitherWay() {
        // Explicitly chosen, and inherited from the account: the same memo either way.
        #expect(VisibilityChoice.title(selection: .public, accountDefault: nil) == nil)
        #expect(VisibilityChoice.title(selection: nil, accountDefault: .public) == nil)
        #expect(VisibilityChoice.title(selection: .public, accountDefault: .private) == nil)
        #expect(VisibilityChoice.symbol(selection: nil, accountDefault: .public) == "globe")
        // Everything that is NOT public still says what it is.
        #expect(VisibilityChoice.title(selection: .private, accountDefault: .public) == "Private")
        #expect(
            VisibilityChoice.title(selection: nil, accountDefault: .protected)
                == "Default (Just us)"
        )
        #expect(VisibilityChoice.title(selection: nil, accountDefault: nil) == "Default")
    }

    /// The word leaves the screen, not the app. An icon-only control that announced itself as
    /// "Visibility" would have made the common case unreadable to a screen reader.
    @Test("what a screen reader hears is never abbreviated")
    func accessibilityAlwaysSpellsItOut() {
        #expect(
            VisibilityChoice.accessibilityLabel(selection: .public, accountDefault: nil)
                == "Visibility: Public"
        )
        #expect(
            VisibilityChoice.accessibilityLabel(selection: nil, accountDefault: .public)
                == "Visibility: Public, the account default"
        )
        #expect(
            VisibilityChoice.accessibilityLabel(selection: .private, accountDefault: .public)
                == "Visibility: Private"
        )
        #expect(
            VisibilityChoice.accessibilityLabel(selection: nil, accountDefault: nil)
                == "Visibility: the account default"
        )
        // Every state names a visibility or says why it cannot — none is ever just "Visibility".
        for selection in [nil, MemoVisibility.private, .protected, .public] {
            for fallback in [nil, MemoVisibility.private, .protected, .public] {
                let spoken = VisibilityChoice.accessibilityLabel(
                    selection: selection, accountDefault: fallback
                )
                #expect(spoken != "Visibility")
                #expect(spoken.hasPrefix("Visibility: "))
            }
        }
    }

    /// The default state of the date pill is the one everybody sees, and it has to read as a
    /// control rather than as a caption.
    @Test("the date pill says Now until a date is chosen")
    func theDatePillDefaultsToNow() {
        #expect(MemoDateChoice.title(for: nil) == "Now")
        #expect(MemoDateChoice.title(for: nil, compact: true) == "Now")
        let moment = Date(timeIntervalSince1970: 1_750_000_000)
        let chosen = MemoDateChoice.title(for: moment, locale: Locale(identifier: "en_GB"))
        #expect(chosen != "Now")
        #expect(!chosen.isEmpty)
    }

    @Test("every visibility has a distinct word and a distinct glyph")
    func visibilityVocabulary() {
        let labels = MemoVisibility.allCases.map(\.label)
        let symbols = MemoVisibility.allCases.map(\.symbolName)
        #expect(labels == ["Private", "Just us", "Public"])
        #expect(Set(labels).count == labels.count)
        #expect(Set(symbols).count == symbols.count)
        #expect(symbols.allSatisfy { !$0.isEmpty })
    }
}
