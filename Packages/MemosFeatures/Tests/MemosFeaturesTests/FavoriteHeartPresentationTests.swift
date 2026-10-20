import MemosCore
import Testing

@testable import MemosFeatures

/// The viewer's heart (MEMNG-867): filled when the picture's own tags hold the favorite, enabled
/// only on the reader's own picture, dimmed with a notice otherwise, pending while a write's
/// outcome is unknown. Every expectation is the matrix written out by hand.
@Suite("Favorite heart presentation")
struct FavoriteHeartPresentationTests {
    // The argument list is read by the test macro outside the main actor, the module's default.
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let mine: Bool
        let tags: [String]
        let pending: Bool
        let glyph: FavoriteHeartPresentation.Glyph
        let symbol: String
        let enabled: Bool
        let target: Bool?

        var testDescription: String { "mine=\(mine) tags=\(tags) pending=\(pending)" }
    }

    nonisolated static let matrix: [Case] = [
        // mine × tagged
        Case(
            mine: true, tags: ["favorites"], pending: false, glyph: .filled,
            symbol: "heart.fill", enabled: true, target: false),
        Case(
            mine: true, tags: ["trip"], pending: false, glyph: .outline, symbol: "heart",
            enabled: true, target: true),
        Case(
            mine: false, tags: ["favorites", "trip"], pending: false, glyph: .filled,
            symbol: "heart.fill", enabled: false, target: nil),
        Case(
            mine: false, tags: [], pending: false, glyph: .outline, symbol: "heart",
            enabled: false, target: nil),
        // pending, whatever the tags say
        Case(
            mine: true, tags: ["favorites"], pending: true, glyph: .pending, symbol: "heart",
            enabled: true, target: true),
        Case(
            mine: true, tags: [], pending: true, glyph: .pending, symbol: "heart",
            enabled: true, target: true),
        // a memo's tag of the same spelling is not the picture's: only own tags reach here, and
        // a near miss in case is not the favorite
        Case(
            mine: true, tags: ["Favorites"], pending: false, glyph: .outline, symbol: "heart",
            enabled: true, target: true),
    ]

    @Test("the heart's state and whether it writes", arguments: matrix)
    func heart(_ given: Case) {
        let heart = FavoriteHeartPresentation(
            mine: given.mine, tags: given.tags, pending: given.pending)
        #expect(heart.glyph == given.glyph)
        #expect(heart.symbolName == given.symbol)
        #expect(heart.isEnabled == given.enabled)
        #expect(heart.isDimmed == !given.enabled)
        #expect(heart.target == given.target)
        #expect(heart.showsProgress == given.pending)
        #expect(heart.notice == (given.enabled ? nil : FavoriteHeartPresentation.notMineNotice))
    }

    @Test("the favorite is the one constant the store writes")
    func theTagIsOneConstant() {
        #expect(FavoriteTag.name == "favorites")
    }
}
