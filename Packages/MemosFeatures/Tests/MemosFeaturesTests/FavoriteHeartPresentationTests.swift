import MemosCore
import Testing

@testable import MemosFeatures

/// The viewer's heart (MEMNG-867): filled when the picture's own tags hold the favorite, pending
/// while a write's outcome is unknown, and a tap always asks for the other state — whose picture
/// it is decides nothing. Every expectation is the matrix written out by hand.
@Suite("Favorite heart presentation")
struct FavoriteHeartPresentationTests {
    // The argument list is read by the test macro outside the main actor, the module's default.
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let tags: [String]
        let pending: Bool
        let glyph: FavoriteHeartPresentation.Glyph
        let symbol: String
        let target: Bool

        var testDescription: String { "tags=\(tags) pending=\(pending)" }
    }

    nonisolated static let matrix: [Case] = [
        // tagged × untagged
        Case(
            tags: ["favorites"], pending: false, glyph: .filled, symbol: "heart.fill",
            target: false),
        Case(tags: ["trip"], pending: false, glyph: .outline, symbol: "heart", target: true),
        Case(
            tags: ["favorites", "trip"], pending: false, glyph: .filled, symbol: "heart.fill",
            target: false),
        Case(tags: [], pending: false, glyph: .outline, symbol: "heart", target: true),
        // pending, whatever the tags say
        Case(tags: ["favorites"], pending: true, glyph: .pending, symbol: "heart", target: true),
        Case(tags: [], pending: true, glyph: .pending, symbol: "heart", target: true),
        // a memo's tag of the same spelling is not the picture's: only own tags reach here, and
        // a near miss in case is not the favorite
        Case(tags: ["Favorites"], pending: false, glyph: .outline, symbol: "heart", target: true),
    ]

    @Test("the heart's state and what a tap asks for", arguments: matrix)
    func heart(_ given: Case) {
        let heart = FavoriteHeartPresentation(tags: given.tags, pending: given.pending)
        #expect(heart.glyph == given.glyph)
        #expect(heart.symbolName == given.symbol)
        #expect(heart.target == given.target)
        #expect(heart.showsProgress == given.pending)
    }

    @Test("the favorite is the one constant the store writes")
    func theTagIsOneConstant() {
        #expect(FavoriteTag.name == "favorites")
    }
}
