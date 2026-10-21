import MemosCore

/// What the viewer's heart shows for one picture (MEMNG-867), decided from two facts and nothing
/// else: the picture's own tags as `FavoriteStore` reports them (`tags(for:shown:)`), and whether
/// a write to it has an unknown outcome (`isPending(_:)`).
///
/// Whose picture it is decides nothing: memos-ng is a family app, so anybody can set and remove
/// the heart on any picture the viewer shows (owner, 2026-10-21).
///
/// Pure, so the matrix is tested here rather than read off a rendered bar. The bar's one-line
/// hookup reads `symbolName`, `showsProgress` and `target`, and a tap calls `setFavorite` with
/// the target.
nonisolated struct FavoriteHeartPresentation: Equatable, Sendable {
    enum Glyph: Equatable, Sendable {
        case filled
        case outline
        /// The server may or may not have taken the last tap: neither state is claimed.
        case pending
    }

    let glyph: Glyph

    init(tags: [String], pending: Bool) {
        if pending {
            glyph = .pending
        } else {
            glyph = tags.contains(FavoriteTag.name) ? .filled : .outline
        }
    }

    /// The state a tap asks for. A pending heart asks for "favorite": the outcome is unknown, and
    /// the store sends it rather than treating it as a no-op.
    var target: Bool {
        switch glyph {
        case .filled: false
        case .outline, .pending: true
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
