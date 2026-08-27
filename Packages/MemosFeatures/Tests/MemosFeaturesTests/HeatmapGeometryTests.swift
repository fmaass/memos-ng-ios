import CoreGraphics
import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

/// The one arithmetic the activity grid is drawn from and hit-tested through (MEMNG-186).
///
/// The defect it replaces was not a wrong number, it was two of them: a square sized by the text
/// scale and a hit test handed that size by hand, neither knowing the width of the card. What is
/// asserted here is therefore both halves at once — that a width produces a grid which FILLS it,
/// and that a square drawn at a place is the square a finger on that place finds.
@Suite("Heatmap geometry")
struct HeatmapGeometryTests {
    /// Midnight UTC on Wednesday 26 August 2026 — the instant the other heatmap suites derive
    /// their windows from.
    private static let today = Date(timeIntervalSince1970: 1_787_702_400)
    private static let gap = DesignTokens.Space.hair
    private static let columns = 12

    /// The card content widths of the phones this app is drawn on: the smallest still sold, the
    /// 393pt and 402pt bodies, and the largest — each less the gutter and the card's padding.
    private static let cardWidths: [CGFloat] = [264, 337, 346, 374]

    private static func geometry(_ width: CGFloat) -> HeatmapGeometry {
        HeatmapGeometry(
            availableWidth: width,
            columns: columns,
            rowsPerColumn: HeatmapPresentation.daysPerColumn,
            gap: gap
        )
    }

    @Test("the grid fills the width it is given on every phone")
    func theGridFillsTheCard() {
        for width in Self.cardWidths {
            let geometry = Self.geometry(width)

            #expect(geometry.width <= width, "the grid overflowed \(width) by \(geometry.width)")
            // What is left over is under a point a column, which is all that flooring the side to
            // whole points can leave behind — not the two thirds of a card a fixed 12pt cell did.
            #expect(
                width - geometry.width < CGFloat(Self.columns),
                "\(width - geometry.width)pt of \(width) went unused"
            )
            // Said the other way, so it is the fill that is asserted and not a tolerance: one more
            // point on every square would not fit.
            #expect(geometry.width + CGFloat(Self.columns) > width)
            // Control: the cap is not what bound it here — the width is.
            #expect(geometry.side < HeatmapGeometry.maximumSide)
            #expect(geometry.side > 0)
        }
    }

    @Test("a card wider than any phone stops at the cap instead of ballooning")
    func theCapHoldsOnAWideCard() {
        let wide = Self.geometry(1_000)

        #expect(wide.side == HeatmapGeometry.maximumSide)
        #expect(wide.width < 1_000, "twelve columns of an iPad's width is a wall of buttons")
        // Control: the same twelve columns on a phone are bound by the width instead.
        #expect(Self.geometry(337).side < wide.side)
        // The cap is a parameter, not a constant baked into the arithmetic.
        let tighter = HeatmapGeometry(
            availableWidth: 1_000,
            columns: Self.columns,
            rowsPerColumn: 7,
            gap: Self.gap,
            maximumSide: 20
        )
        #expect(tighter.side == 20)
    }

    /// What a layout is handed when nothing constrains it — a fitting probe, an unbounded stack.
    /// The answer is the cap rather than nothing at all: a grid that collapsed there would report
    /// a card with no activity in it.
    @Test("an unbounded width is answered at the cap rather than at nothing")
    func anUnboundedWidthAnswersAtTheCap() {
        #expect(Self.geometry(.infinity).side == HeatmapGeometry.maximumSide)
        #expect(Self.geometry(.infinity).width > 0)
    }

    /// The drift MEMNG-186 exists to make unsayable: every square that is DRAWN somewhere is the
    /// square a finger on that place finds. Asserted over a whole grid rather than at one cell,
    /// because an off-by-one pitch agrees at the origin and disagrees everywhere else.
    @Test("a drawn square and the square under a finger on it are the same day")
    func everyDrawnSquareIsTheOneAFingerFinds() throws {
        let grid = HeatmapPresentation.grid(from: ["2026-08-12": 2], today: Self.today)
        #expect(grid.columns.count == 3, "the window was not the clamped three columns")
        let geometry = HeatmapGeometry(availableWidth: 337, of: grid, gap: Self.gap)

        for column in grid.columns.indices {
            for row in grid.columns[column].indices {
                let rect = geometry.rect(column: column, row: row)
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                let found = try #require(
                    HeatmapScrub.cell(at: centre, in: grid, geometry: geometry)
                )
                #expect(
                    found.date == grid.columns[column][row].date,
                    "the centre of \(column),\(row) found \(found.date)"
                )
                // The near corners of the same square, which is where a pitch that is one point
                // out first disagrees.
                let corners = [
                    CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5),
                    CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5),
                ]
                for corner in corners {
                    let hit = try #require(
                        HeatmapScrub.cell(at: corner, in: grid, geometry: geometry)
                    )
                    #expect(hit.date == found.date, "\(corner) fell off \(found.date)")
                }
            }
        }
    }

    /// The gesture reads its geometry back from the frame the layout resolved to, and that frame
    /// is this geometry's own width — so the two are one value rather than two that agree. That
    /// holds only because the arithmetic is idempotent, which is what this asserts.
    @Test("a geometry rebuilt from its own width is the same geometry")
    func theArithmeticIsIdempotent() {
        for width in Self.cardWidths + [1_000, 40] {
            let once = Self.geometry(width)
            let twice = Self.geometry(once.width)
            #expect(twice == once, "\(width) settled at \(once.side) then moved to \(twice.side)")
        }
    }

    @Test("a grid with no columns, and a grid with no room, have no square in them")
    func degenerateGeometriesHaveNoSquare() {
        let noColumns = HeatmapGeometry(
            availableWidth: 337, columns: 0, rowsPerColumn: 7, gap: Self.gap
        )
        #expect(noColumns.side == 0)
        #expect(noColumns.width == 0)
        #expect(noColumns.height == 0)

        for width in [0, -100, CGFloat.nan] {
            #expect(Self.geometry(width).side == 0, "\(width) drew a square")
        }
        // Positive control: a real width in the same call does produce one.
        #expect(Self.geometry(337).side > 0)

        // And a grid that has not been laid out yet answers no finger at all, rather than
        // dividing it by a pitch made of the gap alone.
        let grid = HeatmapPresentation.grid(from: ["2026-08-25": 1], today: Self.today)
        let unmeasured = HeatmapGeometry(availableWidth: 0, of: grid, gap: Self.gap)
        #expect(HeatmapScrub.cell(at: .zero, in: grid, geometry: unmeasured) == nil)
        let measured = HeatmapGeometry(availableWidth: 337, of: grid, gap: Self.gap)
        #expect(HeatmapScrub.cell(at: .zero, in: grid, geometry: measured) != nil)
    }

    /// The rows are the other axis of the same pitch: seven days to a column, and the block is as
    /// tall as it is wide per square.
    @Test("the grid is as many squares tall as it has days to a column")
    func theHeightIsTheRowsAtTheSamePitch() {
        let geometry = Self.geometry(337)
        let rows = CGFloat(HeatmapPresentation.daysPerColumn)

        #expect(geometry.height == rows * geometry.side + Self.gap * (rows - 1))
        #expect(geometry.size == CGSize(width: geometry.width, height: geometry.height))
        // The last row's bottom edge is the block's own bottom edge.
        let last = geometry.rect(column: 0, row: HeatmapPresentation.daysPerColumn - 1)
        #expect(last.maxY == geometry.height)
        let lastColumn = geometry.rect(column: Self.columns - 1, row: 0)
        #expect(lastColumn.maxX == geometry.width)
    }
}
