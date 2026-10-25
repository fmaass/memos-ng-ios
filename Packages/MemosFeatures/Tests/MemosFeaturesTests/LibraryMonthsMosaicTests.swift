import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The Months mosaic on screen (MEMNG-596, plan decision 9 as MEMNG-607 amends it for the app):
/// a capped month draws its nine busiest days — the two busiest in its two heroes, the other
/// seven in date order — and a line for the rest, a short month draws every day and no line, and no
/// tile says how many files fall on its day.
@MainActor
@Suite("Library Months mosaic")
struct LibraryMonthsMosaicTests {
    /// No cover, so a tile draws its placeholder and nothing is fetched: what is under test is
    /// which days are drawn and what they say, not the picture loader.
    private static func day(_ key: String, _ count: Int) -> LibraryBucket {
        LibraryBucket(key: key, count: count, coverUID: "c-\(key)", coverThumbnailURL: nil)
    }

    /// The web's nine-day vector and three more days, forty added to every count (the 1st's and
    /// the 7th's swapped), so no count can be mistaken for a day number or for the "more days"
    /// line: the 11th and the 1st are the two busiest — the 1st, the earliest day, can only reach
    /// the second hero by its rank — and the 12th wins the ninth place from the 10th and the 6th.
    private static let september = [
        day("2026-09-12", 42), day("2026-09-11", 50), day("2026-09-10", 42),
        day("2026-09-09", 41), day("2026-09-08", 44), day("2026-09-07", 45),
        day("2026-09-06", 42), day("2026-09-05", 47), day("2026-09-04", 44),
        day("2026-09-03", 48), day("2026-09-02", 46), day("2026-09-01", 49),
    ]
    /// Its busiest day is the 20th, so the mirrored month's one hero is not its first day.
    private static let august = [
        day("2026-08-25", 31), day("2026-08-20", 34), day("2026-08-12", 33), day("2026-08-10", 32),
    ]

    /// Every control on screen by the label VoiceOver reads, in the order it reads them.
    /// An element reachable both as a view's accessibility element and through its subviews is
    /// one control, counted once.
    private static func buttons(
        in node: Any, into found: inout [String], seen: inout Set<ObjectIdentifier>
    ) {
        guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted
        else { return }
        if object.accessibilityTraits.contains(.button), let label = object.accessibilityLabel {
            found.append(label)
        }
        for child in object.accessibilityElements ?? [] {
            buttons(in: child, into: &found, seen: &seen)
        }
        if let view = object as? UIView {
            for subview in view.subviews { buttons(in: subview, into: &found, seen: &seen) }
        }
    }

    private static func mosaic(showDay: @escaping (LibraryBucket) -> Void = { _ in }) -> some View {
        LibraryMonthsMosaic(
            months: mosaicMonths(september + august),
            year: nil,
            errorText: nil,
            clearYear: {},
            showDay: showDay
        )
    }

    @Test("twelve days draw nine tiles, the busiest two as heroes, and the line; four draw four")
    func nineTilesThenTheLine() async {
        let labels = await PressProbe.withScreen(Self.mosaic(), height: 2000) { screen in
            await screen.settle(turns: 20)
            var found: [String] = []
            var seen: Set<ObjectIdentifier> = []
            Self.buttons(in: screen.window, into: &found, seen: &seen)
            return found
        }
        // VoiceOver reads the tiles by where they sit, not in the order they were handed over:
        // in September the 11th's hero, its two sides, the row of three, then the left column
        // (the 8th above the 12th) before the 1st's hero right of it; in the mirrored August the
        // left column before the 20th's hero.
        #expect(
            labels == [
                "11", "2", "3", "4", "5", "7", "8", "12", "1", "and 3 more days",
                "10", "12", "20", "25",
            ]
        )
    }

    @Test("no tile says how many files fall on its day")
    func noCountOnATile() async {
        let counts = (Self.september + Self.august).map { "\($0.count)" }
        let said = await PressProbe.withScreen(Self.mosaic(), height: 2000) { screen in
            await screen.settle(turns: 20)
            #expect(screen.says("and 3 more days"), "control: the screen is read")
            return counts.filter { screen.says($0) }
        }
        #expect(said == [])
    }

    @Test("\"and 3 more days\" opens All at the month's first shown day")
    func moreDaysJumpsToTheFirstShownDay() async {
        let asked = Box<[String]>([])
        let pressed = await PressProbe.withScreen(
            Self.mosaic(showDay: { asked.value.append($0.key) }), height: 2000
        ) { screen in
            let pressed = screen.press("and 3 more days")
            await screen.settle(turns: 5)
            return pressed
        }
        #expect(pressed)
        #expect(asked.value == ["2026-09-01"])
    }

    // MARK: - geometry

    /// 304 points wide with 2-point gaps: a square is 100, a hero 202, a wide frame 304 × 171.
    private static func frames(_ slots: [MosaicSlot]) -> MosaicFrames {
        MonthMosaicGeometry.frames(for: slots, width: 304, gap: 2)
    }

    @Test("A then B: a hero left with two squares stacked right, then a row of three")
    func heroLeftThenRow() {
        #expect(
            Self.frames(mosaicSlots(6))
                == MosaicFrames(
                    frames: [
                        CGRect(x: 0, y: 0, width: 202, height: 202),
                        CGRect(x: 204, y: 0, width: 100, height: 100),
                        CGRect(x: 204, y: 102, width: 100, height: 100),
                        CGRect(x: 0, y: 204, width: 100, height: 100),
                        CGRect(x: 102, y: 204, width: 100, height: 100),
                        CGRect(x: 204, y: 204, width: 100, height: 100),
                    ],
                    height: 304
                )
        )
    }

    @Test("C then D: a hero right with two squares stacked left, then a full-width 16:9 frame")
    func heroRightThenWide() {
        #expect(
            Self.frames([.heroRight, .sideLeft, .sideLeft, .wide])
                == MosaicFrames(
                    frames: [
                        CGRect(x: 102, y: 0, width: 202, height: 202),
                        CGRect(x: 0, y: 0, width: 100, height: 100),
                        CGRect(x: 0, y: 102, width: 100, height: 100),
                        CGRect(x: 0, y: 204, width: 304, height: 171),
                    ],
                    height: 375
                )
        )
    }

    /// MEMNG-607: the first hero at the very top, the second two bands further down on the other
    /// side, seven squares around them; the odd month is the same mosaic mirrored.
    @Test("nine days: a hero at the top, a row of three, a second hero further down")
    func nineDaysTwoHeroes() {
        #expect(
            Self.frames(mosaicSlots(9))
                == MosaicFrames(
                    frames: [
                        CGRect(x: 0, y: 0, width: 202, height: 202),
                        CGRect(x: 204, y: 0, width: 100, height: 100),
                        CGRect(x: 204, y: 102, width: 100, height: 100),
                        CGRect(x: 0, y: 204, width: 100, height: 100),
                        CGRect(x: 102, y: 204, width: 100, height: 100),
                        CGRect(x: 204, y: 204, width: 100, height: 100),
                        CGRect(x: 102, y: 306, width: 202, height: 202),
                        CGRect(x: 0, y: 306, width: 100, height: 100),
                        CGRect(x: 0, y: 408, width: 100, height: 100),
                    ],
                    height: 508
                )
        )
        #expect(
            Self.frames(mosaicSlots(9, offset: 1))
                == MosaicFrames(
                    frames: [
                        CGRect(x: 102, y: 0, width: 202, height: 202),
                        CGRect(x: 0, y: 0, width: 100, height: 100),
                        CGRect(x: 0, y: 102, width: 100, height: 100),
                        CGRect(x: 0, y: 204, width: 100, height: 100),
                        CGRect(x: 102, y: 204, width: 100, height: 100),
                        CGRect(x: 204, y: 204, width: 100, height: 100),
                        CGRect(x: 0, y: 306, width: 202, height: 202),
                        CGRect(x: 204, y: 306, width: 100, height: 100),
                        CGRect(x: 204, y: 408, width: 100, height: 100),
                    ],
                    height: 508
                )
        )
    }

    @Test("a pattern cut short keeps its hero's band; nothing is no height")
    func cutPatterns() {
        #expect(
            Self.frames([.heroRight, .sideLeft])
                == MosaicFrames(
                    frames: [
                        CGRect(x: 102, y: 0, width: 202, height: 202),
                        CGRect(x: 0, y: 0, width: 100, height: 100),
                    ],
                    height: 202
                )
        )
        #expect(
            Self.frames([.wide, .heroLeft])
                == MosaicFrames(
                    frames: [
                        CGRect(x: 0, y: 0, width: 304, height: 171),
                        CGRect(x: 0, y: 173, width: 202, height: 202),
                    ],
                    height: 375
                )
        )
        #expect(
            Self.frames(mosaicSlots(4)).frames.last == CGRect(x: 0, y: 204, width: 100, height: 100)
        )
        #expect(Self.frames([]) == MosaicFrames(frames: [], height: 0))
    }

    /// A run of squares longer than a row, as the All view's day blocks will hand over (a B with a
    /// remainder after it), wraps to the next row rather than running off the edge.
    @Test("squares wrap every three")
    func squaresWrap() {
        let five = Self.frames(Array(repeating: .square, count: 5))
        #expect(
            five.frames.map(\.origin) == [
                CGPoint(x: 0, y: 0), CGPoint(x: 102, y: 0), CGPoint(x: 204, y: 0),
                CGPoint(x: 0, y: 102), CGPoint(x: 102, y: 102),
            ])
        #expect(five.height == 202)
    }
}

/// What a Months tile PAINTS, read from its pixels rather than from what it tells VoiceOver: the
/// tile's button reads out its day number whatever the tile draws, so only the drawing can say
/// whether a count came back or which corner the picture is cut to.
///
/// Declared in the loader's suite because it seeds the loader's process-wide store: the cover is
/// a flat red photograph already decoded, so the tile paints it in its first frame.
extension MediaImageLoaderTests {
    private static let tileSide: CGFloat = 120

    /// A Months tile for the 8th, 44 files on it, its cover decoded as flat red.
    private static func paintedTile(uid: String) throws -> [[(r: UInt8, g: UInt8, b: UInt8)]] {
        let bucket = LibraryBucket(
            key: "2026-09-08", count: 44, coverUID: uid,
            coverThumbnailURL: MediaFixture.signed(uid: uid))
        let cover = try #require(LibraryBucketCover.attachment(for: bucket))
        MediaImageLoader.store.store(
            try #require(UIImage(data: MediaFixture.png(.red))),
            forKey: MediaImageLoader.key(for: cover, tier: .thumb),
            generation: MediaImageLoader.store.generation
        )
        let tile = try #require(mosaicMonths([bucket]).first?.tiles.first)
        return try #require(
            PixelGrid.of(
                LibraryDayTile(tile: tile), size: CGSize(width: tileSide, height: tileSide))
        )
    }

    /// How much of the bottom-left 16 × 16 corner is painted red: the smaller the radius, the
    /// more of the corner the picture keeps. The bottom left, because the day number sits top
    /// left and a count badge, were one drawn again, sat bottom right.
    private static func cornerCoverage(_ pixels: [[(r: UInt8, g: UInt8, b: UInt8)]]) -> Int {
        let side = pixels.count
        return pixels[(side - 16)...].reduce(0) { total, row in
            total + row[..<16].filter { $0.r > 128 && $0.g < 100 }.count
        }
    }

    @Test("a Months photo tile is cut to the mosaic's 6-point corner, not the grid's 8")
    func monthsTileCorner() throws {
        let tile = Self.cornerCoverage(try Self.paintedTile(uid: "months-corner"))
        let reference = { (radius: CGFloat) -> Int? in
            PixelGrid.of(
                Color(uiColor: .red).clipShape(.rect(cornerRadius: radius)),
                size: CGSize(width: Self.tileSide, height: Self.tileSide)
            ).map(Self.cornerCoverage)
        }
        let mosaic = try #require(reference(DesignTokens.Radius.mosaic))
        let grid = try #require(reference(DesignTokens.Radius.tile))
        #expect(mosaic > grid + 2, "control: the probe tells 6 from 8 (\(mosaic) vs \(grid))")
        #expect(
            abs(tile - mosaic) <= 1,
            "the tile keeps \(tile) px; 6 pt keeps \(mosaic), 8 keeps \(grid)")
    }

    /// White pixels are text: the picture is flat red and the day number is the only white thing
    /// the tile draws, top left. The box around it is generous; anything white outside it is a
    /// second label — a count badge, wherever it is put.
    @Test("a Months photo tile draws its day number and nothing else in white")
    func monthsTileDrawsNoCount() throws {
        let pixels = try Self.paintedTile(uid: "months-no-count")
        let labelBox = CGRect(x: 0, y: 0, width: 44, height: 40)
        var inBox = 0
        var outside: [CGPoint] = []
        for (y, row) in pixels.enumerated() {
            for (x, pixel) in row.enumerated() where pixel.r > 200 && pixel.g > 200 && pixel.b > 200
            {
                if labelBox.contains(CGPoint(x: x, y: y)) {
                    inBox += 1
                } else {
                    outside.append(CGPoint(x: x, y: y))
                }
            }
        }
        #expect(inBox > 0, "control: the day number drew in white, top left")
        #expect(outside.isEmpty, "white drawn outside the day number: \(outside.prefix(5))")
    }
}
