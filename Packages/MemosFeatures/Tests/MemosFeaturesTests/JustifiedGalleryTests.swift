import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The row solver, held to the SAME vectors as its vitest spec in memos-ng
/// (`frontend/src/lib/__tests__/justified.spec.ts`). The two clients lay a memo's photos out with
/// one algorithm, and a port that drifts from its original is not a port — so when one side's
/// numbers change, both sides change together or the port is broken.
///
/// Every assertion here is an exact row assignment and an exact height, because "it looks about
/// right" is what a screenshot says and this is the thing a screenshot cannot check.
@Suite("Justified rows")
struct JustifiedGalleryTests {
    private func widths(_ row: JustifiedGallery.Row) -> [Double] { row.tiles.map(\.width) }
    private func indices(_ row: JustifiedGallery.Row) -> [Int] { row.tiles.map(\.index) }
    private func filled(_ row: JustifiedGallery.Row, gap: Double) -> Double {
        widths(row).reduce(0, +) + gap * Double(row.tiles.count - 1)
    }

    // MARK: - the SPA's own vectors

    @Test("squares pack to fill the row width exactly, at or below the target height")
    func squaresFillTheRow() {
        let rows = JustifiedGallery.rows(
            ratios: [1, 1, 1], containerWidth: 300, targetHeight: 100, gap: 0
        )
        #expect(rows.count == 1)
        #expect(indices(rows[0]) == [0, 1, 2])
        #expect(abs(rows[0].height - 100) < 0.0001)
        #expect(widths(rows[0]).allSatisfy { abs($0 - 100) < 0.0001 })
        #expect(abs(filled(rows[0], gap: 0) - 300) < 0.0001)
    }

    @Test("a wide photo gets more of the row than a tall one, at the same height")
    func aspectRatiosSurvive() {
        let rows = JustifiedGallery.rows(
            ratios: [16.0 / 9.0, 2.0 / 3.0], containerWidth: 1000, targetHeight: 300, gap: 0
        )
        #expect(rows.count == 1)
        let wide = rows[0].tiles[0]
        let tall = rows[0].tiles[1]
        #expect(wide.width > tall.width)
        #expect(abs(wide.height - tall.height) < 0.0001)
        // The trailing row stands at the target, so these are exact: 16:9 and 2:3 at h=300.
        #expect(abs(rows[0].height - 300) < 0.0001)
        #expect(abs(wide.width - 533.3333) < 0.001)
        #expect(abs(tall.width - 200) < 0.0001)
    }

    @Test("more photos than the width can hold break into further rows")
    func rowsBreak() {
        let rows = JustifiedGallery.rows(
            ratios: [1, 1, 1, 1, 1, 1], containerWidth: 300, targetHeight: 100, gap: 0
        )
        #expect(rows.count == 2)
        #expect(indices(rows[0]) == [0, 1, 2])
        #expect(indices(rows[1]) == [3, 4, 5])
        for row in rows {
            #expect(row.height <= 100 + 0.0001)
            #expect(abs(filled(row, gap: 0) - 300) < 0.0001)
        }
    }

    /// The rule that keeps the last row from looking like a mistake: one photo left over is one
    /// photo at the target height, not one photo stretched across the whole card.
    @Test("the trailing partial row keeps the target height and is not stretched")
    func trailingRowIsNotStretched() {
        let rows = JustifiedGallery.rows(
            ratios: [1], containerWidth: 900, targetHeight: 120, gap: 0
        )
        #expect(rows.count == 1)
        #expect(abs(rows[0].height - 120) < 0.0001)
        #expect(abs(rows[0].tiles[0].width - 120) < 0.0001, "the lone photo was stretched")
    }

    @Test("the gaps between photos come out of the row's width, not out of nowhere")
    func gapsAreBudgeted() {
        let rows = JustifiedGallery.rows(
            ratios: [1, 1], containerWidth: 210, targetHeight: 100, gap: 10
        )
        #expect(rows.count == 1)
        #expect(abs(rows[0].height - 100) < 0.0001)
        #expect(widths(rows[0]).allSatisfy { abs($0 - 100) < 0.0001 })
        #expect(abs(filled(rows[0], gap: 10) - 210) < 0.0001)
    }

    @Test("nothing to lay out, or nowhere to lay it out, is no rows")
    func degenerateInputs() {
        func solve(_ ratios: [Double], _ width: Double, _ target: Double) -> Int {
            JustifiedGallery.rows(
                ratios: ratios, containerWidth: width, targetHeight: target, gap: 0
            ).count
        }
        #expect(solve([], 300, 100) == 0, "no photos produced rows")
        #expect(solve([1], 0, 100) == 0, "a card of no width produced rows")
        #expect(solve([1], 300, 0) == 0, "a row target of nothing produced rows")
        #expect(solve([1], -10, 100) == 0, "a negative width produced rows")
        // The control: the same solver with usable inputs does produce a row.
        #expect(solve([1], 300, 100) == 1)
    }

    // MARK: - a real card

    /// The arrangement a person actually sees: five photos at a card's content width on a 402pt
    /// phone (402 minus the list row's 16pt inset and the card's own 16pt padding, both sides).
    /// Exact assignments and exact heights, because this is the geometry the tap router then has
    /// to route over.
    @Test("five mixed photos at a card's width fall into three exact rows")
    func aRealCard() {
        let width: Double = 338
        let gap = Double(DesignTokens.Space.tight)
        let target = Double(DesignTokens.Metric.photoRow)
        #expect(gap == 4)
        #expect(target == 150)

        let rows = JustifiedGallery.rows(
            ratios: [1.5, 1.5, 1.5, 0.75, 1.0],
            containerWidth: width,
            targetHeight: target,
            gap: gap
        )

        #expect(rows.count == 3)
        #expect(indices(rows[0]) == [0, 1])
        #expect(indices(rows[1]) == [2, 3])
        #expect(indices(rows[2]) == [4])
        #expect(abs(rows[0].height - 111.3333) < 0.001)
        #expect(abs(rows[1].height - 148.4444) < 0.001)
        #expect(abs(rows[2].height - 150) < 0.0001)
        #expect(abs(rows[0].tiles[0].width - 167) < 0.001)
        #expect(abs(rows[1].tiles[0].width - 222.6667) < 0.001)
        #expect(abs(rows[1].tiles[1].width - 111.3333) < 0.001)
        #expect(abs(rows[2].tiles[0].width - 150) < 0.0001)
        // Every committed row fills the card exactly; only the trailing one is short.
        #expect(abs(filled(rows[0], gap: gap) - width) < 0.001)
        #expect(abs(filled(rows[1], gap: gap) - width) < 0.001)
        #expect(filled(rows[2], gap: gap) < width)
        #expect(abs(JustifiedGallery.height(of: rows, gap: gap) - 417.7778) < 0.001)
    }

    /// Every photo the memo holds is placed, exactly once, in order. This is the property the old
    /// three-tile strip broke: the fourth photo onwards was a number on a badge.
    @Test("every photo is placed, once, in order — at any count")
    func nothingIsDropped() {
        for count in 1...25 {
            let ratios = (0..<count).map { Double($0 % 3 + 1) * 0.5 + 0.5 }
            let rows = JustifiedGallery.rows(
                ratios: ratios, containerWidth: 338, targetHeight: 150, gap: 4
            )
            let placed = rows.flatMap { $0.tiles.map(\.index) }
            #expect(placed == Array(0..<count), "count \(count) placed \(placed)")
            #expect(
                rows.allSatisfy { $0.height <= 150 + 0.0001 },
                "a row came out taller than the target at count \(count)"
            )
        }
    }

    /// An attachment the server never measured is a square here, exactly as it is in the SPA
    /// (`FALLBACK_AR = 1`) — no row is skipped over it and no shape is invented for it.
    @Test("an unmeasured photo is treated as a square, not dropped")
    func unmeasuredIsASquare() {
        let measured = MemoAttachment(
            uid: "a1", mime: "image/jpeg", status: .ready, width: 1600, height: 900)
        let unmeasured = MemoAttachment(uid: "a2", mime: "image/jpeg", status: .ready)
        let ratios = JustifiedGallery.ratios(of: [measured, unmeasured])
        #expect(abs(ratios[0] - 16.0 / 9.0) < 0.0001)
        #expect(ratios[1] == JustifiedGallery.fallbackAspectRatio)
        #expect(ratios[1] == 1)

        let rows = JustifiedGallery.rows(
            ratios: ratios, containerWidth: 338, targetHeight: 150, gap: 4
        )
        #expect(rows.flatMap { $0.tiles.map(\.index) } == [0, 1])
    }

    @Test("the height of a block counts the gaps between its rows")
    func blockHeight() {
        let rows = JustifiedGallery.rows(
            ratios: [1, 1, 1, 1, 1, 1], containerWidth: 300, targetHeight: 100, gap: 0
        )
        #expect(abs(JustifiedGallery.height(of: rows, gap: 0) - 200) < 0.0001)
        #expect(abs(JustifiedGallery.height(of: rows, gap: 8) - 208) < 0.0001)
        #expect(JustifiedGallery.height(of: [], gap: 8) == 0)
    }
}
