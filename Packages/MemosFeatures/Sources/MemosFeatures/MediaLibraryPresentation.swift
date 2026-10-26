import CoreGraphics
import Foundation
import MemosCore

/// What a tile in the library grid draws, and whether it opens.
///
/// The grid is not a memo's gallery: it shows the household's WHOLE library, which contains files
/// that are neither a picture nor a clip. Those get a tile of their own rather than a warning
/// triangle (nothing is wrong with them) and they do not open, because the full-screen viewer has
/// no page for a file it can neither show nor play — `MediaViewerPresentation.pages` drops exactly
/// these, and a tile that swallows a tap is worse than one that never offered.
public enum LibraryTileKind: Equatable, Sendable {
    case image
    case video
    case document
}

/// The library's empty state, as the three parts a `ContentUnavailableView` is made of. Carried
/// as a value so what each tab says when it has nothing is a thing a test can read back.
public struct LibraryEmptyState: Equatable, Sendable {
    public let title: String
    public let symbol: String
    public let message: String
}

/// One row of the Tags section in the Library's options menu.
public struct LibraryTagRow: Identifiable, Equatable, Sendable {
    /// What choosing the row selects: nil for "All tags", otherwise the tag's name.
    public let selection: String?
    public let title: String
    /// The picture count, or nil for "All tags" and for a chosen tag the list does not name.
    public let count: Int?
    public let isSelected: Bool
    public var id: String? { selection }

    /// What the row reads as, count included.
    public var label: String {
        guard let count else { return title }
        return "\(title) (\(count))"
    }
}

/// One file placed in the library, with the box the row solver gave it.
public struct LibraryTile: Identifiable, Equatable, Sendable {
    public let attachment: MemoAttachment
    /// Where this file sits in the WHOLE loaded list, not in its row. The paging trigger is
    /// measured in that number — a row knows nothing about how far down the library it is.
    public let index: Int
    public let width: Double
    public let height: Double

    public var id: String { attachment.uid }
}

/// One justified row of the library.
public struct LibraryGalleryRow: Identifiable, Equatable, Sendable {
    public let tiles: [LibraryTile]
    public let height: Double

    /// The first file in it. A row is identified by its contents rather than by its position,
    /// because a page arriving at the bottom does not move the rows above it — and an index-keyed
    /// row would make SwiftUI rebuild every one of them each time the library grew.
    public var id: String { tiles.first?.id ?? "empty" }
}

/// One picture of a day block, in the frame its slot names.
public struct LibraryDayPicture: Identifiable, Equatable, Sendable {
    public let attachment: MemoAttachment
    /// Where this file sits in the WHOLE loaded list — the number the paging trigger is measured in.
    public let index: Int
    public let slot: MosaicSlot

    public var id: String { attachment.uid }
}

/// One band of a day block: a hero with its sides, a row of squares, or one wide frame.
public struct LibraryDayBand: Identifiable, Equatable, Sendable {
    public let pictures: [LibraryDayPicture]

    /// The first file in it, for the reason `LibraryGalleryRow.id` gives: a page arriving at the
    /// bottom does not rename the bands above it.
    public var id: String { pictures.first?.id ?? "empty" }
}

/// One day of the All view (plan page 3929 decision 13): its heading row and its mosaic block.
public struct LibraryDayGroup: Identifiable, Equatable, Sendable {
    /// `YYYY-MM-DD`, or `undatedSectionKey`.
    public let key: String
    /// "Sat", or "Undated".
    public let weekday: String
    /// "26 Sep", or empty for the undated group.
    public let date: String
    /// The day's place in the whole loaded list, across months: where its block starts the cycle.
    public let dayIndex: Int
    public let bands: [LibraryDayBand]

    public var id: String { key }
    /// What the scroll is brought to when a jump lands on this day: its heading (MEMNG-587, moved
    /// to the heading by decision 13).
    public var headingID: String { Self.headingID(key) }
    /// A day's heading id from its key alone, for what knows only the key (`DayMarkers`).
    public static func headingID(_ key: String) -> String { "day:\(key)" }
    public var pictures: [LibraryDayPicture] { bands.flatMap(\.pictures) }
}

/// Where a band sits in its day: which day, and whether it opens or closes the block.
public struct LibraryBandPlace: Equatable, Sendable {
    public let day: String
    public let dayIndex: Int
    public let first: Bool
    public let last: Bool
}

/// View Options' second group (MEMNG-821): the grid's frames as the mosaic cycles them, or every
/// picture a square. The device's choice (`LibraryPreferences.tileLayout`), read by every
/// `LibraryGrid`; the Months view's busiest-days mosaic is not a grid of pictures and keeps its own.
public enum LibraryTileLayout: String, CaseIterable, Identifiable, Sendable {
    case mixed
    case square

    public var id: String { rawValue }

    /// The menu's words, Photos' own.
    public var label: String {
        switch self {
        case .mixed: "Mixed Sizes"
        case .square: "Square Grid"
        }
    }

    /// The frames for `count` pictures: the mosaic's own, or as many squares. Replaced BEFORE the
    /// bands are cut, so `mosaicBands` makes rows of three and a band is still named by its first
    /// file.
    func slots(_ count: Int, mosaic: (Int) -> [MosaicSlot]) -> [MosaicSlot] {
        switch self {
        case .mixed: mosaic(count)
        case .square: Array(repeating: .square, count: count)
        }
    }
}

/// One row of the All view's lazy stack: a day's heading, or one band of its block.
public enum LibraryAllRow: Identifiable, Equatable, Sendable {
    case heading(LibraryDayGroup)
    case band(LibraryDayBand, LibraryBandPlace)

    /// A heading is `LibraryDayGroup.headingID`, a band its first file.
    public var id: String {
        switch self {
        case .heading(let day): day.headingID
        case .band(let band, _): band.id
        }
    }
}

/// One month of the All view: its header, then its day groups.
public struct LibraryAllMonth: Identifiable, Equatable, Sendable {
    /// `YYYY-MM`, or `undatedSectionKey` (`groupByMonth`).
    public let key: String
    public let label: String
    public let days: [LibraryDayGroup]

    public var id: String { key }

    /// The month as the lazy stack's rows: each day's heading, then its bands.
    public var rows: [LibraryAllRow] {
        days.flatMap { day in
            [LibraryAllRow.heading(day)]
                + day.bands.enumerated().map { place, band in
                    LibraryAllRow.band(
                        band,
                        LibraryBandPlace(
                            day: day.key, dayIndex: day.dayIndex, first: place == 0,
                            last: place == day.bands.count - 1))
                }
        }
    }
}

/// Decisions the library screen needs, kept out of the view — the same split `MemoPresentation`
/// makes, and for the same reason: a SwiftUI body is the worst place to unit-test anything.
public enum MediaLibraryPresentation {
    /// How tall a row of the library stands. No row is ever taller than this, and the trailing
    /// one stands exactly at it.
    ///
    /// Bigger than the old square tile because a justified row spends its height on pictures
    /// rather than on crops: a landscape photograph at this height is about a third of a phone's
    /// width, so a row still holds two or three of them.
    public static let targetRowHeight: Double = 132

    /// The library, packed into justified rows — the arrangement the web app's Resources view uses
    /// (`frontend/src/views/ResourcesView.vue` over `JustifiedGallery.vue`), which is the whole
    /// point of it being the same gallery on both clients.
    ///
    /// It replaced a grid of square crops. A square grid is defensible for a memo's two-up strip,
    /// where the tiles have to line up; for a LIBRARY it is the wrong trade, because every
    /// photograph in it is cropped to a shape it was not taken in, and a panorama and a portrait
    /// arrive looking identical. Here each file keeps its own proportions and the rows fill the
    /// width exactly.
    ///
    /// The row solving itself is `JustifiedGallery` — the same port of the SPA's `justifyRows`
    /// that the memo card uses, so the two surfaces cannot drift into packing the same photographs
    /// differently. What this adds is the part a library needs and a card does not: the index of
    /// each file in the whole loaded list, which is what the paging trigger is measured in.
    public static func rows(
        for items: [MemoAttachment],
        width: Double,
        targetHeight: Double = targetRowHeight,
        gap: Double
    ) -> [LibraryGalleryRow] {
        JustifiedGallery.rows(
            ratios: JustifiedGallery.ratios(of: items),
            containerWidth: width,
            targetHeight: targetHeight,
            gap: gap
        )
        .map { row in
            LibraryGalleryRow(
                tiles: row.tiles.compactMap { tile in
                    guard items.indices.contains(tile.index) else { return nil }
                    return LibraryTile(
                        attachment: items[tile.index],
                        index: tile.index,
                        width: tile.width,
                        height: tile.height
                    )
                },
                height: row.height
            )
        }
    }

    /// The library as month sections, each holding its day groups (MEMNG-597, plan page 3929
    /// decision 13): a day is a calendar day in `timeZone` (`groupByDay`) inside its calendar month
    /// (`groupByMonth`), and its pictures are one mosaic block cycling the Months frame patterns
    /// (`daySlots`), cut into bands the lazy stack builds one at a time.
    ///
    /// A day's index counts days across the WHOLE list, so the cycle runs on over a month boundary,
    /// and every picture keeps its index in the whole list — the number the paging trigger is
    /// measured in — rather than its place in its day. Under `.square` every frame is a square
    /// (MEMNG-821), so the bands are rows of three.
    public static func daySections(
        for items: [LibraryRow], timeZone: String = libraryTimeZone,
        tiles: LibraryTileLayout = .mixed
    ) -> [LibraryAllMonth] {
        // Rows are unique by file (`MediaLibraryStore.merged`), so a uid names one place.
        let position = Dictionary(
            items.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var dayIndex = 0
        return groupByMonth(items, timeZone: timeZone).map { month in
            let days = groupByDay(month.items, timeZone: timeZone).map { day in
                defer { dayIndex += 1 }
                let slots = tiles.slots(day.items.count) { daySlots($0, dayIndex: dayIndex) }
                let pictures = zip(day.items, slots).map { row, slot in
                    LibraryDayPicture(
                        attachment: row.attachment, index: position[row.id] ?? 0, slot: slot)
                }
                let heading = dayHeadingParts(day.key)
                return LibraryDayGroup(
                    key: day.key,
                    weekday: heading.weekday,
                    date: heading.date,
                    dayIndex: dayIndex,
                    bands: mosaicBands(slots).map { LibraryDayBand(pictures: Array(pictures[$0])) }
                )
            }
            return LibraryAllMonth(key: month.key, label: month.label, days: days)
        }
    }

    /// A trip's grid (MEMNG-740): the same list as ONE block, in the order it was handed over —
    /// "a collection is like All in the library", without its days. No month header, no day
    /// heading: the rows are the block's bands alone, its frames one cycle from A, and every
    /// picture keeps its index in the whole list as `daySections` gives it. Each band still names
    /// the day its first picture was taken on, which only the date pill reads.
    public static func flatRows(
        for items: [LibraryRow], timeZone: String = libraryTimeZone,
        tiles: LibraryTileLayout = .mixed
    ) -> [LibraryAllRow] {
        let slots = tiles.slots(items.count) { daySlots($0) }
        let pictures = zip(items, slots).enumerated().map { index, placed in
            LibraryDayPicture(attachment: placed.0.attachment, index: index, slot: placed.1)
        }
        let bands = mosaicBands(slots)
        return bands.enumerated().map { place, range in
            let day = dayKey(items[range.lowerBound].takenAt, timeZone: timeZone)
            return LibraryAllRow.band(
                LibraryDayBand(pictures: Array(pictures[range])),
                LibraryBandPlace(
                    day: day ?? undatedSectionKey, dayIndex: 0, first: place == 0,
                    last: place == bands.count - 1))
        }
    }

    /// The bands a mosaic's slots fall into, as ranges of the slots, read as
    /// `MonthMosaicGeometry.frames` reads them: a hero and at most two sides of its own after it,
    /// a row of at most three squares, or one wide frame alone. A band is what the lazy stack
    /// builds, so a day of two hundred pictures is not one view of two hundred tiles.
    public static func mosaicBands(_ slots: [MosaicSlot]) -> [Range<Int>] {
        // A side with no hero before it is drawn as a square, as the geometry draws it.
        let squareSlots: Set<MosaicSlot> = [.square, .sideRight, .sideLeft]
        var bands: [Range<Int>] = []
        var index = 0
        while index < slots.count {
            let start = index
            switch slots[index] {
            case .heroLeft, .heroRight:
                let side: MosaicSlot = slots[index] == .heroLeft ? .sideRight : .sideLeft
                index += 1
                var stacked = 0
                while stacked < 2, index < slots.count, slots[index] == side {
                    stacked += 1
                    index += 1
                }
            case .wide:
                index += 1
            case .square, .sideRight, .sideLeft:
                var inRow = 0
                while inRow < 3, index < slots.count, squareSlots.contains(slots[index]) {
                    inRow += 1
                    index += 1
                }
            }
            bands.append(start..<index)
        }
        return bands
    }

    /// A day heading's count: the day bucket's, which counts the WHOLE day, or nil while the
    /// buckets are unread, failed or answer another request, and for the undated group. Never the
    /// number of the day's pictures loaded so far (the web's `dayCount`, `ResourcesView.vue`).
    public static func dayCount(_ key: String, in buckets: [LibraryBucket]?) -> Int? {
        guard key != undatedSectionKey else { return nil }
        return buckets?.first { $0.key == key }?.count
    }

    /// What the tile at this file draws. Derived from the KIND rather than from the status: what
    /// a file still being processed looks like is `AttachmentThumbnail`'s decision (it has the
    /// readiness projection and the veil), and duplicating it here would be two answers to one
    /// question.
    public static func tileKind(for attachment: MemoAttachment) -> LibraryTileKind {
        switch attachment.mediaKind {
        case .image: .image
        case .video: .video
        case .other: .document
        }
    }

    /// Whether tapping this tile opens the full-screen viewer.
    public static func isOpenable(_ kind: LibraryTileKind) -> Bool {
        kind != .document
    }

    /// The glyph a non-media file wears. Broad strokes on purpose: the point is that the tile
    /// reads as "a file, not a photo", not that it identifies the format.
    public static func documentSymbol(for mime: String) -> String {
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime == "application/pdf" { return "doc.richtext" }
        if mime.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    /// The name of a kind row in the options menu, which is also the kind's word in the header's
    /// subtitle. The web client's own three (`frontend/src/components/LibraryOptionsMenu.vue`), so
    /// the two clients offer the same choice under the same words (plan page 3929, Phase 3).
    public static func label(for filter: MediaLibraryFilter) -> String {
        switch filter {
        case .all: "All Items"
        case .images: "Photos"
        case .videos: "Videos"
        }
    }

    /// What a tab says when it holds nothing.
    ///
    /// One message per tab rather than one for the screen: "No attachments yet" under Videos, on a
    /// library full of photographs, reads as the library being empty when what is empty is the
    /// filter. The tab that is open is the only thing that makes the sentence true.
    public static func emptyState(for filter: MediaLibraryFilter) -> LibraryEmptyState {
        switch filter {
        case .all:
            LibraryEmptyState(
                title: "No media yet",
                symbol: "photo.on.rectangle.angled",
                message: "Photos and videos posted to your memos appear here."
            )
        case .images:
            LibraryEmptyState(
                title: "No photos yet",
                symbol: "photo",
                message: "Photos posted to your memos appear here."
            )
        case .videos:
            LibraryEmptyState(
                title: "No videos yet",
                symbol: "video",
                message: "Videos posted to your memos appear here."
            )
        }
    }

    /// What the grid says when a tag is chosen and nothing under the open tab carries it
    /// (MEMNG-513). A tag the server does not know answers with an empty list rather than an
    /// error, so this — not an error card — is what an unknown tag looks like.
    public static func emptyState(for filter: MediaLibraryFilter, tag: String) -> LibraryEmptyState
    {
        let noun =
            switch filter {
            case .all: "photos or videos"
            case .images: "photos"
            case .videos: "videos"
            }
        return LibraryEmptyState(
            title: "No pictures with this tag",
            symbol: "tag",
            message: "No \(noun) are tagged “\(tag)”."
        )
    }

    /// Which empty state, if any, sits over the grid: none while it loads, none over an error
    /// (the error card says what went wrong), the tag's own when a tag is chosen, and the tab's
    /// otherwise.
    public static func emptyOverlay(
        itemsEmpty: Bool,
        isLoading: Bool,
        lastError: String?,
        filter: MediaLibraryFilter,
        tag: String?
    ) -> LibraryEmptyState? {
        guard itemsEmpty, !isLoading, lastError == nil else { return nil }
        if let tag { return emptyState(for: filter, tag: tag) }
        return emptyState(for: filter)
    }

    /// The Tags section of the options menu: "All tags" first — the nil selection — then every tag
    /// with its picture count, in the server's order, exactly one of them selected.
    ///
    /// Selection is by VALUE, nil against a name, never by label: a tag the server calls
    /// "All tags" is a row of its own and choosing it is not choosing every tag. A chosen tag the
    /// list does not name (not read yet, or read a moment before the reset) still gets a row, so
    /// the menu never shows a selection with nothing ticked.
    public static func tagRows(_ tags: [LibraryTag], selected: String?) -> [LibraryTagRow] {
        let everyTag = LibraryTagRow(
            selection: nil, title: "All tags", count: nil, isSelected: selected == nil
        )
        var rows = [everyTag]
        rows += tags.map {
            LibraryTagRow(
                selection: $0.name, title: $0.name, count: $0.count,
                isSelected: $0.name == selected
            )
        }
        if let selected, !tags.contains(where: { $0.name == selected }) {
            rows.append(
                LibraryTagRow(selection: selected, title: selected, count: nil, isSelected: true)
            )
        }
        return rows
    }

    /// The line under the Library's title: the kind, the order and, when one is chosen, the tag —
    /// "All Items · Newest First · #recap", the web header's line
    /// (`frontend/src/components/LibraryHeader.vue`). Every choice the options menu holds is on
    /// screen without opening it (plan page 3929 decisions 10 and 12).
    public static func subtitle(
        filter: MediaLibraryFilter,
        order: MediaLibraryOrder,
        tag: String?
    ) -> String {
        ([label(for: filter), order.label] + (tag.map { ["#\($0)"] } ?? []))
            .joined(separator: " · ")
    }

    /// How wide the picture a long press lifts off the grid is drawn.
    ///
    /// Wider than a tile by a large factor, which is the whole point of a context-menu preview: it
    /// is the moment the grid stops being a grid of thumbnails and the file is looked AT. The
    /// height follows the picture's own proportions, so a portrait and a landscape both get their
    /// shape rather than a common box.
    public static let previewWidth: CGFloat = 320

    /// What a tile says out loud. A grid of unlabelled images is a grid VoiceOver cannot describe,
    /// and the kind is the only thing about a file that is knowable without opening it — the list
    /// payload carries no caption, no filename and no duration.
    public static func accessibilityLabel(for kind: LibraryTileKind) -> String {
        switch kind {
        case .image: "Photo"
        case .video: "Video"
        case .document: "File"
        }
    }
}
