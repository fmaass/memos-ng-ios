import Foundation
import MemosCore
import Testing

@testable import MemosFeatures

@MainActor
private func file(
    _ uid: String,
    width: Int? = 1000,
    height: Int? = 1000,
    mime: String = "image/jpeg"
) -> MemoAttachment {
    MemoAttachment(uid: uid, mime: mime, status: .ready, width: width, height: height)
}

/// The library, packed into justified rows.
///
/// The old grid cropped every file into a square, which is the wrong trade for a library: a
/// panorama and a portrait arrived looking identical, and the shape a photograph was taken in is
/// most of what tells one apart from another at a glance. These hold the arrangement that replaced
/// it — every file in its own proportions, rows that fill the width — and the one number the view
/// cannot get wrong without breaking paging: where each file sits in the WHOLE list.
@MainActor
@Suite("Library gallery")
struct LibraryGalleryTests {
    private let gap = 4.0
    private let width = 390.0

    private func rows(_ items: [MemoAttachment], width: Double? = nil) -> [LibraryGalleryRow] {
        MediaLibraryPresentation.rows(for: items, width: width ?? self.width, gap: gap)
    }

    @Test("every file is placed exactly once, in the order the library sent it")
    func everyFileIsPlaced() {
        let items = (0..<9).map { file("p\($0)", width: 1000, height: 700) }

        let placed = rows(items).flatMap(\.tiles)

        #expect(placed.map(\.attachment.uid) == items.map(\.uid))
        #expect(placed.count == items.count)
    }

    @Test("a committed row fills the width exactly, gaps included")
    func rowsFillTheWidth() throws {
        let items = (0..<12).map { file("p\($0)", width: 1000, height: 700) }
        let solved = rows(items)
        // The LAST row is the trailing one, which is deliberately short — stretching two
        // photographs across a whole row is what makes a gallery look broken.
        let committed = try #require(solved.dropLast().first)

        let spanned =
            committed.tiles.reduce(0) { $0 + $1.width }
            + gap * Double(committed.tiles.count - 1)
        #expect(abs(spanned - width) < 0.001)
        #expect(solved.count > 1, "control: there was more than one row to choose a committed one")
    }

    @Test("no row is taller than the target, and the trailing one stands at it")
    func rowHeights() throws {
        let items = (0..<7).map { file("p\($0)", width: 1000, height: 700) }
        let solved = rows(items)

        #expect(solved.allSatisfy { $0.height <= MediaLibraryPresentation.targetRowHeight })
        let trailing = try #require(solved.last)
        #expect(trailing.height == MediaLibraryPresentation.targetRowHeight)
    }

    @Test("each file keeps the proportions the server measured")
    func tilesKeepTheirShape() throws {
        let panorama = file("wide", width: 3000, height: 1000)
        let portrait = file("tall", width: 800, height: 1200)
        let solved = rows([panorama, portrait])
        let tiles = solved.flatMap(\.tiles)

        let wide = try #require(tiles.first { $0.attachment.uid == "wide" })
        let tall = try #require(tiles.first { $0.attachment.uid == "tall" })
        #expect(abs(wide.width / wide.height - 3.0) < 0.001)
        #expect(abs(tall.width / tall.height - 800.0 / 1200.0) < 0.001)
        // The whole reason for the change: these two are no longer the same box.
        #expect(wide.width > tall.width)
    }

    @Test("a file the server never measured is a square rather than a hole")
    func unmeasuredFilesAreSquare() throws {
        let solved = rows([file("unknown", width: nil, height: nil, mime: "application/pdf")])
        let tile = try #require(solved.first?.tiles.first)

        #expect(abs(tile.width - tile.height) < 0.001)
        // A document is a row of the library like any other — a grid that silently dropped the
        // PDF somebody attached would be lying about what is there.
        #expect(tile.attachment.uid == "unknown")
    }

    @Test("a tile's index is its place in the whole library, not in its row")
    func indicesAreGlobal() throws {
        let items = (0..<9).map { file("p\($0)", width: 1000, height: 700) }
        let solved = rows(items)

        #expect(solved.flatMap(\.tiles).map(\.index) == Array(0..<9))
        // The number the paging trigger is measured in: a tile in the second row that reported its
        // position WITHIN the row would say 0, and the next page would never be asked for.
        let second = try #require(solved.dropFirst().first)
        #expect((second.tiles.first?.index ?? 0) > 0)
    }

    /// A list whose months interleave — a merged page can bring an older file back above a newer
    /// one — puts a month's files at scattered places in the whole list. Each tile must still
    /// report its own place there, not its place in its month, or the paging trigger fires from
    /// the wrong tile.
    @Test("a tile's index in a month section is its place in the whole library")
    func sectionIndicesAreGlobal() {
        let september = Date(timeIntervalSince1970: 1_789_387_200)  // 2026-09-14 12:00Z
        let august = Date(timeIntervalSince1970: 1_786_708_800)  // 2026-08-14 12:00Z
        let items = [("s0", september), ("a1", august), ("s2", september), ("a3", august)].map {
            LibraryRow(attachment: file($0.0), takenAt: $0.1, mine: true, filename: $0.0)
        }
        let sections = MediaLibraryPresentation.sections(
            for: items, width: width, gap: gap, timeZone: "Europe/Zurich")

        #expect(sections.map(\.label) == ["September 2026", "August 2026"])
        let placed = sections.map { $0.rows.flatMap(\.tiles).map { "\($0.id)@\($0.index)" } }
        #expect(placed == [["s0@0", "s2@2"], ["a1@1", "a3@3"]])
    }

    @Test("no width means no rows, which is what the first frame is")
    func noWidthNoRows() {
        #expect(rows((0..<3).map { file("p\($0)") }, width: 0).isEmpty)
        #expect(rows([]).isEmpty)
    }

    @Test("a page arriving at the bottom leaves the rows above it identical")
    func growingTheLibraryKeepsTheRowsAbove() {
        let first = (0..<12).map { file("p\($0)", width: 1000, height: 700) }
        let grown = first + (12..<24).map { file("p\($0)", width: 1000, height: 700) }

        let before = rows(first)
        let after = rows(grown)

        // Identity is the row's FIRST file, so a row that did not change keeps its id — which is
        // what stops a lazy stack from rebuilding the whole library every time it grows.
        #expect(after.count > before.count, "control: the library really did grow")
        #expect(
            after.prefix(before.count - 1).map(\.id) == before.dropLast().map(\.id),
            "an appended page renamed the rows above it"
        )
    }

    /// The tab split and the layout are two halves of one screen: what the tab admits is decided by
    /// the same rule the server filters by (`MediaLibraryFilter.includes`), and what is laid out is
    /// exactly what the tab admitted.
    @Test("a tab's rows hold that tab's kind and nothing else")
    func rowsHoldOnlyTheTabsKind() {
        let mixed = [
            file("i0"),
            file("v0", mime: "video/mp4"),
            file("d0", width: nil, height: nil, mime: "application/pdf"),
            file("i1"),
        ]

        for filter in MediaLibraryFilter.allCases {
            let admitted = mixed.filter { filter.includes($0.mediaKind) }
            let laid = rows(admitted).flatMap(\.tiles).map(\.attachment.mediaKind)
            #expect(laid.allSatisfy { filter.includes($0) })
            #expect(laid.count == admitted.count, "\(filter) lost a file between filter and layout")
        }
        // The control: the three tabs really do admit different things, so the loop above is not
        // three copies of the same assertion.
        #expect(rows(mixed.filter { MediaLibraryFilter.images.includes($0.mediaKind) }).count == 1)
        #expect(rows(mixed).flatMap(\.tiles).count == 4)
    }
}
