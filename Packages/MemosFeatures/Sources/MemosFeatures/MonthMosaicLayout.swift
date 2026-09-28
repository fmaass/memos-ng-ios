import MemosCore
import SwiftUI

/// Where each tile of a mosaic sits, and how tall the mosaic is.
nonisolated struct MosaicFrames: Equatable, Sendable {
    /// One per slot, in the slots' order.
    let frames: [CGRect]
    let height: CGFloat
}

/// The mosaic's 3-column grid as frames (plan decision 9): a square is one column, a hero two
/// columns by two rows with the gap between them, a wide frame the full width at 16:9.
///
/// Bands are read off the slots rather than off the pattern that made them, so any walk of the
/// patterns lays out: a hero opens a band and takes the sides that follow it, at most two;
/// squares fill rows of three; a wide frame is a band alone. A side with no hero before it is
/// drawn as a square. A hero on the RIGHT comes first in the list — its day is the earlier one —
/// and still takes the top of its band, which is why this places frames instead of stacking views.
nonisolated enum MonthMosaicGeometry {
    static func frames(for slots: [MosaicSlot], width: CGFloat, gap: CGFloat) -> MosaicFrames {
        let column = max((width - 2 * gap) / 3, 0)
        let hero = 2 * column + gap
        var frames: [CGRect] = []
        frames.reserveCapacity(slots.count)
        var y: CGFloat = 0
        var index = 0
        while index < slots.count {
            switch slots[index] {
            case .heroLeft, .heroRight:
                let left = slots[index] == .heroLeft
                let side: MosaicSlot = left ? .sideRight : .sideLeft
                frames.append(
                    CGRect(x: left ? 0 : column + gap, y: y, width: hero, height: hero))
                index += 1
                var stacked = 0
                while stacked < 2, index < slots.count, slots[index] == side {
                    frames.append(
                        CGRect(
                            x: left ? hero + gap : 0,
                            y: y + CGFloat(stacked) * (column + gap),
                            width: column,
                            height: column
                        ))
                    stacked += 1
                    index += 1
                }
                y += hero + gap
            case .wide:
                let height = width * 9 / 16
                frames.append(CGRect(x: 0, y: y, width: width, height: height))
                index += 1
                y += height + gap
            case .square, .sideRight, .sideLeft:
                var inRow = 0
                while inRow < 3, index < slots.count, Self.isSquare(slots[index]) {
                    frames.append(
                        CGRect(
                            x: CGFloat(inRow) * (column + gap), y: y, width: column,
                            height: column))
                    inRow += 1
                    index += 1
                }
                y += column + gap
            }
        }
        return MosaicFrames(frames: frames, height: max(y - gap, 0))
    }

    private static func isSquare(_ slot: MosaicSlot) -> Bool {
        slot == .square || slot == .sideRight || slot == .sideLeft
    }
}

/// The mosaic as a SwiftUI layout: each child placed in the frame its slot names, at that frame's
/// size, so a tile's picture is asked for at the shape it is drawn in.
///
/// Children are taken in the order they are given — date order — whatever their place on screen.
/// `nonisolated` for the reason `JustifiedRowsLayout` gives: SwiftUI's layout machinery drives it,
/// not view code.
nonisolated struct MonthMosaicLayout: Layout {
    /// One per child, in the same order.
    let slots: [MosaicSlot]
    let gap: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0 else { return .zero }
        return CGSize(
            width: width,
            height: MonthMosaicGeometry.frames(for: slots, width: width, gap: gap).height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let frames = MonthMosaicGeometry.frames(for: slots, width: bounds.width, gap: gap).frames
        for (index, subview) in subviews.enumerated() {
            // A child with no slot is placed at no size rather than over another tile.
            let frame = index < frames.count ? frames[index] : .zero
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}
