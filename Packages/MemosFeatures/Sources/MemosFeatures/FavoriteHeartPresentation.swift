import MemosCore

/// What the viewer's heart shows for one picture (MEMNG-867), decided from three facts and
/// nothing else: whether the picture is the reader's own, its own tags as `FavoriteStore` reports
/// them (`tags(for:shown:)`), and whether a write to it has an unknown outcome
/// (`isPending(_:)`).
///
/// Pure, so the matrix is tested here rather than read off a rendered bar. The bar's one-line
/// hookup reads `symbolName`, `showsProgress`, `isDimmed` and `target`, and a tap with a target
/// calls `setFavorite` with it.
nonisolated struct FavoriteHeartPresentation: Equatable, Sendable {
    enum Glyph: Equatable, Sendable {
        case filled
        case outline
        /// The server may or may not have taken the last tap: neither state is claimed.
        case pending
    }

    static let notMineNotice = "Only your own pictures can be marked as favorite."

    let glyph: Glyph
    /// Only the reader's own pictures can carry their favorite: the server answers anybody
    /// else's with not-found.
    let isEnabled: Bool

    init(mine: Bool, tags: [String], pending: Bool) {
        if pending {
            glyph = .pending
        } else {
            glyph = tags.contains(FavoriteTag.name) ? .filled : .outline
        }
        isEnabled = mine
    }

    /// Somebody else's picture: drawn, dimmed, and a tap says why instead of writing.
    var isDimmed: Bool { !isEnabled }

    /// What a tap says instead of writing, or nil when a tap writes.
    var notice: String? { isEnabled ? nil : Self.notMineNotice }

    /// The state a tap asks for, or nil when a tap writes nothing. A pending heart asks for
    /// "favorite": the outcome is unknown, and the store sends it rather than treating it as a
    /// no-op.
    var target: Bool? {
        guard isEnabled else { return nil }
        switch glyph {
        case .filled: return false
        case .outline, .pending: return true
        }
    }

    var symbolName: String {
        switch glyph {
        case .filled: "heart.fill"
        case .outline: "heart"
        case .pending: "heart"
        }
    }

    /// A pending heart is an outline with a spinner over it: it claims neither state.
    var showsProgress: Bool { glyph == .pending }
}
