import CoreGraphics
import Foundation
import MemosCore
import SwiftUI

/// Packing photos into justified rows, the way the web app does it.
///
/// A card used to show at most three photos: three square crops in a strip, with a "+4" badge on
/// the last one standing in for everything else the memo held. Six photos of a day out therefore
/// arrived as three squares and a number, in the wrong shapes, with the rest of them somewhere
/// behind a tap. This is the arrangement the SPA settled on instead — every photo on the card, each
/// in its own proportions, rows that fill the width exactly.
///
/// The algorithm is a straight port of `frontend/src/lib/justified.ts` in memos-ng, down to the
/// commit rule and the trailing-row rule, so the two clients cannot drift into laying the same
/// memo out differently. It is pure and view-free for the same reason the original is: the row
/// assignments are then a thing a test can state exactly.
nonisolated public enum JustifiedGallery {
    /// One photo, placed: which attachment it is, and the box it occupies.
    public struct Tile: Equatable, Sendable {
        /// Index into the array the rows were solved for.
        public let index: Int
        public let width: Double
        public let height: Double

        public init(index: Int, width: Double, height: Double) {
            self.index = index
            self.width = width
            self.height = height
        }
    }

    public struct Row: Equatable, Sendable {
        public let tiles: [Tile]
        public let height: Double

        public init(tiles: [Tile], height: Double) {
            self.tiles = tiles
            self.height = height
        }
    }

    /// The SPA's `FALLBACK_AR`: an attachment the server never measured is treated as a square
    /// rather than dropped or guessed at. `MemoAttachment.aspectRatio` already answers exactly
    /// this, which is why the port needs no fallback of its own.
    public static let fallbackAspectRatio: Double = 1

    public static func ratios(of attachments: [MemoAttachment]) -> [Double] {
        attachments.map(\.aspectRatio)
    }

    /// Lay items out in justified rows.
    ///
    /// A row COMMITS as soon as its items, scaled to fill `containerWidth` (minus the gaps between
    /// them), would stand at or below `targetHeight` — so a row is never taller than the target and
    /// always exactly as wide as the container. The trailing partial row keeps `targetHeight` and
    /// is left-aligned rather than stretched across the full width, because stretching two photos
    /// over a whole row is what makes the last row of a gallery look like a mistake.
    ///
    /// Faithful to `justifyRows` in the SPA: same commit condition, same available-width
    /// arithmetic, same trailing-row treatment, same "no items / no width / no target height means
    /// no rows" guard.
    public static func rows(
        ratios: [Double],
        containerWidth: Double,
        targetHeight: Double,
        gap: Double
    ) -> [Row] {
        guard containerWidth > 0, targetHeight > 0, !ratios.isEmpty else { return [] }
        var rows: [Row] = []
        var current: [Int] = []
        var ratioSum: Double = 0
        for (index, ratio) in ratios.enumerated() {
            current.append(index)
            ratioSum += ratio
            let available = containerWidth - gap * Double(current.count - 1)
            let rowHeight = available / ratioSum
            if rowHeight <= targetHeight {
                rows.append(row(current, ratios: ratios, height: rowHeight))
                current = []
                ratioSum = 0
            }
        }
        if !current.isEmpty {
            rows.append(row(current, ratios: ratios, height: targetHeight))
        }
        return rows
    }

    /// How tall the whole block stands, gaps between rows included.
    public static func height(of rows: [Row], gap: Double) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.height } + gap * Double(rows.count - 1)
    }

    private static func row(_ indices: [Int], ratios: [Double], height: Double) -> Row {
        Row(
            tiles: indices.map { Tile(index: $0, width: ratios[$0] * height, height: height) },
            height: height
        )
    }
}

/// The justified rows as a real SwiftUI layout.
///
/// A `Layout` rather than a measured `GeometryReader`: the row solver needs the width it is being
/// laid out in, and a layout is handed that width in the same pass it places its children — so the
/// photos appear at the right size in the frame the card first draws, instead of a beat later.
///
/// Every tile is a child of this layout, so each one reports its own frame through
/// `onGeometryChange` exactly as the old strip's tiles did, and the card's tap router keeps working
/// over the new geometry without knowing anything about rows.
///
/// `nonisolated` deliberately: this package is MainActor by default, and a layout is driven by
/// SwiftUI's own layout machinery rather than called from view code.
nonisolated struct JustifiedRowsLayout: Layout {
    /// One per subview, in the same order. Read by index, so the two must stay in step — which is
    /// why the card builds both from the same array.
    let ratios: [Double]
    let targetHeight: CGFloat
    let gap: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0 else { return idealSize() }
        let rows = solved(width: Double(width))
        return CGSize(
            width: width,
            height: CGFloat(JustifiedGallery.height(of: rows, gap: Double(gap)))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = solved(width: Double(bounds.width))
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for tile in row.tiles where tile.index < subviews.count {
                subviews[tile.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(
                        width: CGFloat(tile.width),
                        height: CGFloat(tile.height)
                    )
                )
                x += CGFloat(tile.width) + gap
            }
            y += CGFloat(row.height) + gap
        }
    }

    private func solved(width: Double) -> [JustifiedGallery.Row] {
        JustifiedGallery.rows(
            ratios: ratios,
            containerWidth: width,
            targetHeight: Double(targetHeight),
            gap: Double(gap)
        )
    }

    /// What it would like when nothing is proposed — one row at the target height. SwiftUI asks
    /// this of a view in an unbounded context; answering the placeholder 10x10 would make the card
    /// collapse in exactly the probes that measure it.
    private func idealSize() -> CGSize {
        guard !ratios.isEmpty else { return .zero }
        let width =
            ratios.reduce(0) { $0 + $1 * Double(targetHeight) }
            + Double(gap) * Double(ratios.count - 1)
        return CGSize(width: CGFloat(width), height: targetHeight)
    }
}
