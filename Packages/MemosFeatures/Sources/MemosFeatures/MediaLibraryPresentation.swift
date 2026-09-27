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
public struct LibraryRow: Identifiable, Equatable, Sendable {
    public let tiles: [LibraryTile]
    public let height: Double

    /// The first file in it. A row is identified by its contents rather than by its position,
    /// because a page arriving at the bottom does not move the rows above it — and an index-keyed
    /// row would make SwiftUI rebuild every one of them each time the library grew.
    public var id: String { tiles.first?.id ?? "empty" }
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
    ) -> [LibraryRow] {
        JustifiedGallery.rows(
            ratios: JustifiedGallery.ratios(of: items),
            containerWidth: width,
            targetHeight: targetHeight,
            gap: gap
        )
        .map { row in
            LibraryRow(
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

    /// The name of a tab of the filter control. The SPA's own three, so the two clients offer the
    /// same choice under the same words (`frontend/src/views/ResourcesView.vue`).
    public static func label(for filter: MediaLibraryFilter) -> String {
        switch filter {
        case .all: "All"
        case .images: "Images"
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

    /// The line under the Library's title: the chosen tag, or nothing.
    public static func subtitle(for tag: String?) -> String {
        tag.map { "#\($0)" } ?? ""
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
