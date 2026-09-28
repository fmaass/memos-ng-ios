import Foundation
import SwiftUI

/// The app's own design vocabulary: one accent, one spacing scale, one radius scale.
///
/// Everything visual in this package resolves through here rather than through a literal at the
/// call site. That is not tidiness — it is what makes the direction assertable: a test can ask
/// "is a link painted in the accent?" only while there is exactly one thing "the accent" means.
///
/// The accent is an ASSET, not a `Color(red:green:blue:)`, because it has to answer differently
/// in light and dark, and because the same asset name is what the system reads for the global
/// tint. It is declared twice — once in the app's catalogue (where the system looks) and once in
/// this package's own catalogue (where this code looks) — and `DesignTokensTests` asserts the two
/// resolve to the same colour, so the pair cannot drift apart unnoticed.
public enum DesignTokens {
    /// The one owned colour. Light `#3E7C4F`, dark `#7FB08C`.
    public static let accent = Color("AccentColor", bundle: .module)

    /// The bundle the design assets are compiled into. Exposed so a test can resolve the accent
    /// asset itself and hold it to those two hex values — a token nobody can read back is a
    /// promise, not a check.
    public static let assetBundle = Bundle.module

    /// Spacing, in the order a card is built out of: hairline gaps, content rhythm, card gutters.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 8
        public static let regular: CGFloat = 12
        public static let roomy: CGFloat = 16
        public static let section: CGFloat = 24
    }

    /// Corner radii. `card` is the generous one the timeline is built from; `tile` is concentric
    /// inside it (a smaller radius inset by the card's own padding reads as parallel, not nested).
    ///
    /// The tile radius is small on purpose. Photos in a justified gallery sit four points apart,
    /// and at 14 the rounding ate the corner of every one of them and turned a row of pictures into
    /// a row of lozenges — the curve has to be a detail of the tile, not a shape imposed on the
    /// picture inside it.
    public enum Radius {
        public static let card: CGFloat = 20
        public static let tile: CGFloat = 8
        /// A Months mosaic tile (plan decision 9): the tiles sit two points apart, edge to edge.
        public static let mosaic: CGFloat = 6
    }

    /// Dimensions that must grow with the type size. Every one of these is read through
    /// `@ScaledMetric` at the point of use — a glyph pinned at 16pt beside 60pt text is the
    /// defect this scale exists to prevent.
    public enum Metric {
        public static let avatar: CGFloat = 28
        /// The square two-up: two photos side by side, cropped into one shared shape.
        public static let photoPair: CGFloat = 132
        /// The tallest a lone photo may stand. It is a CAP, not a height: a photo below it is
        /// shown at its own proportions and nothing is cropped, and one above it narrows rather
        /// than losing its top and bottom.
        public static let photoSolo: CGFloat = 300
        /// The row height the justified packing aims for at a card's content width. Rows come out
        /// at or below it; the trailing row stands exactly on it.
        public static let photoRow: CGFloat = 150
        public static let pickedThumbnail: CGFloat = 72
        public static let signInMark: CGFloat = 96
    }
}
