import CoreGraphics
import SwiftUI

/// How big a square of the activity grid is, and where each one sits.
///
/// Before MEMNG-186 this arithmetic existed twice. The view drew a cell whose side came from
/// `@ScaledMetric`, and the hit test was handed that side and the gap by hand; the two agreed by
/// convention only, and neither of them knew how wide the card was. So twelve columns of 12pt
/// squares sat in the left third of a 337pt card, and the only thing that ever widened them was
/// the text size — which is not what a grid of squares is a function of.
///
/// The card's width is the single input now. The side falls out of it, the squares are placed
/// from it (`HeatmapSquaresLayout`), and a touch is read back through the same value
/// (`HeatmapScrub.cell(at:in:geometry:)`) — so the drawn pitch and the hit-tested pitch cannot
/// drift apart, because there is only one of them.
///
/// `nonisolated` deliberately, like `JustifiedGallery`: this package is MainActor by default and
/// the arithmetic is read by `HeatmapSquaresLayout`, which SwiftUI's layout machinery drives from
/// outside any actor of ours.
nonisolated struct HeatmapGeometry: Equatable, Sendable {
    let columns: Int
    let rowsPerColumn: Int
    let gap: CGFloat
    /// The side of one square, in whole points.
    let side: CGFloat

    /// The widest a square may be drawn, however much room the card has.
    ///
    /// On an iPad, or a phone turned on its side, dividing the whole width by twelve gives squares
    /// the better part of an inch across. 44pt is the size the HIG gives a touch target, and a
    /// square at that size has stopped reading as one day among eighty-four and started reading as
    /// something to press — so it is the ceiling. It is not a size: on every phone the width
    /// binds first and this never comes into it.
    static let maximumSide: CGFloat = 44

    init(
        availableWidth: CGFloat,
        columns: Int,
        rowsPerColumn: Int,
        gap: CGFloat,
        maximumSide: CGFloat = HeatmapGeometry.maximumSide
    ) {
        self.columns = max(0, columns)
        self.rowsPerColumn = max(0, rowsPerColumn)
        self.gap = gap
        guard self.columns > 0, !availableWidth.isNaN else {
            side = 0
            return
        }
        let air = gap * CGFloat(self.columns - 1)
        // Whole points, deliberately. A fractional side puts every column on a different sub-pixel
        // boundary, and these squares are a texture: their crispness is most of what they are. The
        // rounding leaves under a point per column unused at the trailing edge, which is a hair
        // rather than the third of a card the fixed side left behind.
        //
        // An unbounded proposal — what a fitting probe makes, and what a layout is handed when
        // nothing constrains it — is infinite here, and answers at the cap.
        let fitted = ((availableWidth - air) / CGFloat(self.columns)).rounded(.down)
        side = min(max(0, fitted), maximumSide)
    }

    /// One square and the air after it: the distance from a square to the same edge of the next.
    var pitch: CGFloat { side + gap }

    /// How wide the squares stand — the last column's trailing edge.
    ///
    /// Nothing at all when there is no square: a grid that has not been laid out yet would
    /// otherwise measure as the air BETWEEN squares that are not there, and the card would keep
    /// room for it.
    var width: CGFloat {
        guard columns > 0, side > 0 else { return 0 }
        return CGFloat(columns) * side + gap * CGFloat(columns - 1)
    }

    /// How tall they stand — the bottom edge of the last row. Nothing, for the same reason.
    var height: CGFloat {
        guard rowsPerColumn > 0, side > 0 else { return 0 }
        return CGFloat(rowsPerColumn) * side + gap * CGFloat(rowsPerColumn - 1)
    }

    var size: CGSize { CGSize(width: width, height: height) }

    /// Where one square is drawn, in the grid's own coordinate space — the space a scrub reports
    /// its location in.
    func rect(column: Int, row: Int) -> CGRect {
        CGRect(
            x: CGFloat(column) * pitch,
            y: CGFloat(row) * pitch,
            width: side,
            height: side
        )
    }
}

extension HeatmapGeometry {
    /// The geometry a grid is drawn with in a card this wide.
    ///
    /// On the MainActor, unlike the arithmetic it forwards to: a `HeatmapGrid` is one of this
    /// package's own MainActor values, and this is called from the card and its tests rather than
    /// from inside the layout.
    @MainActor
    init(availableWidth: CGFloat, of grid: HeatmapGrid, gap: CGFloat) {
        self.init(
            availableWidth: availableWidth,
            columns: grid.columns.count,
            rowsPerColumn: HeatmapPresentation.daysPerColumn,
            gap: gap
        )
    }
}

/// The squares as a real SwiftUI layout.
///
/// A `Layout` rather than a measured `GeometryReader`, for the reason `JustifiedRowsLayout` gives:
/// the side is a function of the width the grid is laid out in, and a layout is handed that width
/// in the same pass it places its children — so the grid is the right size in the frame the card
/// FIRST draws rather than a beat later, and a card in a scroll view never reports a height of
/// nothing while it waits to be measured.
///
/// `nonisolated` deliberately: this package is MainActor by default, and a layout is driven by
/// SwiftUI's own layout machinery rather than called from view code.
nonisolated struct HeatmapSquaresLayout: Layout {
    let columns: Int
    let rowsPerColumn: Int
    let gap: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        geometry(width: proposal.width).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let geometry = self.geometry(width: bounds.width)
        guard geometry.columns > 0 else { return }
        let square = ProposedViewSize(width: geometry.side, height: geometry.side)
        // One subview per slot, in the order the content declares them: rows outermost, so the
        // flat index is row-major. The short trailing column draws an empty slot rather than
        // nothing at all, which is what keeps this mapping exact.
        for index in subviews.indices {
            let rect = geometry.rect(
                column: index % geometry.columns,
                row: index / geometry.columns
            )
            subviews[index].place(
                at: CGPoint(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY),
                anchor: .topLeading,
                proposal: square
            )
        }
    }

    /// The geometry for a width, where an unproposed width is an unbounded one — answered at the
    /// cap rather than at nothing, because a grid that collapsed under a fitting probe would
    /// report a card with no activity in it at all (`JustifiedRowsLayout.idealSize`).
    private func geometry(width: CGFloat?) -> HeatmapGeometry {
        HeatmapGeometry(
            availableWidth: width ?? .infinity,
            columns: columns,
            rowsPerColumn: rowsPerColumn,
            gap: gap
        )
    }
}
