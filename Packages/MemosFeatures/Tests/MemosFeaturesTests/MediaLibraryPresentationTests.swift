import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// What the library grid draws for a file, what each tab says when it is empty, and what the app's
/// main navigation offers.
///
/// Every one of these is a decision the SCREEN would otherwise make inline, which is the reason
/// they are functions: a tile kind chosen inside a `ForEach` and a tab title written into a
/// `TabView` are things no test can read back.
@MainActor
@Suite("The media library's presentation")
struct MediaLibraryPresentationTests {
    private func attachment(mime: String, status: AttachmentStatus = .ready) -> MemoAttachment {
        MemoAttachment(uid: "a", mime: mime, status: status)
    }

    @Test("a tile is chosen per kind, and the kinds are all three")
    func tileKindPerCategory() {
        #expect(MediaLibraryPresentation.tileKind(for: attachment(mime: "image/jpeg")) == .image)
        #expect(MediaLibraryPresentation.tileKind(for: attachment(mime: "image/heic")) == .image)
        #expect(MediaLibraryPresentation.tileKind(for: attachment(mime: "video/mp4")) == .video)
        let movie = attachment(mime: "video/quicktime")
        #expect(MediaLibraryPresentation.tileKind(for: movie) == .video)
        // Everything else is a file, not a broken picture.
        #expect(
            MediaLibraryPresentation.tileKind(for: attachment(mime: "application/pdf")) == .document
        )
        #expect(MediaLibraryPresentation.tileKind(for: attachment(mime: "audio/mpeg")) == .document)
        // A mime the server sent that says nothing at all still has to land somewhere.
        #expect(MediaLibraryPresentation.tileKind(for: attachment(mime: "")) == .document)
    }

    @Test("a file the viewer has no page for does not offer to open")
    func onlyMediaOpens() {
        #expect(MediaLibraryPresentation.isOpenable(.image))
        #expect(MediaLibraryPresentation.isOpenable(.video))
        #expect(!MediaLibraryPresentation.isOpenable(.document))
        // The gate and the viewer's own projection have to agree, or a tile offers a tap that
        // opens nothing.
        let paper = attachment(mime: "application/pdf")
        #expect(MediaViewerPresentation.viewer(for: [paper], startingAt: paper.uid) == nil)
        let photo = MemoAttachment(
            uid: "photo",
            mime: "image/jpeg",
            status: .ready,
            thumbnailURL: URL(string: "https://memos.example.invalid/api/attachments/photo/thumb")
        )
        #expect(
            MediaViewerPresentation.viewer(for: [photo], startingAt: photo.uid) != nil,
            "control: a photo does open"
        )
    }

    @Test("the tab a file is under is decided by the same rule the server filters by")
    func filterMatchesKind() {
        #expect(MediaLibraryFilter.all.apiType == nil)
        #expect(MediaLibraryFilter.images.apiType == "image")
        #expect(MediaLibraryFilter.videos.apiType == "video")

        for kind in AttachmentMediaKind.allCases {
            #expect(MediaLibraryFilter.all.includes(kind), "All must hold every kind")
        }
        #expect(MediaLibraryFilter.images.includes(.image))
        #expect(!MediaLibraryFilter.images.includes(.video))
        #expect(!MediaLibraryFilter.images.includes(.other))
        #expect(MediaLibraryFilter.videos.includes(.video))
        #expect(!MediaLibraryFilter.videos.includes(.image))
        #expect(!MediaLibraryFilter.videos.includes(.other))
    }

    @Test("a mime is read as one of exactly three kinds")
    func mediaKindPerCategory() {
        #expect(AttachmentMediaKind.of(mime: "image/png") == .image)
        #expect(AttachmentMediaKind.of(mime: "video/mp4") == .video)
        #expect(AttachmentMediaKind.of(mime: "application/zip") == .other)
        #expect(AttachmentMediaKind.of(mime: "") == .other)
        // A mime that merely CONTAINS the word is not of that kind — the server compares a prefix.
        #expect(AttachmentMediaKind.of(mime: "application/x-image") == .other)
    }

    @Test("the three tabs are named what the web app names them")
    func filterLabels() {
        #expect(MediaLibraryPresentation.label(for: .all) == "All")
        #expect(MediaLibraryPresentation.label(for: .images) == "Images")
        #expect(MediaLibraryPresentation.label(for: .videos) == "Videos")
    }

    @Test("each tab says what IT is missing, not that the library is empty")
    func emptyStatePerTab() {
        let tabs = MediaLibraryFilter.allCases
        let states = tabs.map(MediaLibraryPresentation.emptyState(for:))
        #expect(Set(states.map(\.title)).count == tabs.count, "two tabs share an empty title")
        #expect(Set(states.map(\.message)).count == tabs.count, "two tabs share an empty message")
        #expect(states.allSatisfy { !$0.symbol.isEmpty })
        // The Videos tab is the one that used to lie: "no attachments yet" over a library full of
        // photographs is a sentence about the library, when what is empty is the filter.
        #expect(MediaLibraryPresentation.emptyState(for: .videos).title.contains("video"))
        #expect(MediaLibraryPresentation.emptyState(for: .images).title.contains("photo"))
    }

    @Test("a non-media tile wears a glyph for what it is")
    func documentSymbols() {
        #expect(MediaLibraryPresentation.documentSymbol(for: "audio/mpeg") == "waveform")
        #expect(MediaLibraryPresentation.documentSymbol(for: "application/pdf") == "doc.richtext")
        #expect(MediaLibraryPresentation.documentSymbol(for: "text/plain") == "doc.text")
        #expect(MediaLibraryPresentation.documentSymbol(for: "application/zip") == "doc")
    }

    @Test("every tile says what it is out loud, and no two kinds say the same thing")
    func accessibilityLabels() {
        let labels = [LibraryTileKind.image, .video, .document]
            .map(MediaLibraryPresentation.accessibilityLabel(for:))
        #expect(labels == ["Photo", "Video", "File"])
        #expect(Set(labels).count == labels.count)
    }

    @Test("a tile is narrow enough that a phone fits a row of them")
    func tilesFitAcrossAPhone() {
        // 320 pt is the narrowest screen this app runs on. Four columns is what the grid is for;
        // a minimum that only fits two turns the library into a list of large squares.
        #expect(MediaLibraryPresentation.minimumTileWidth * 3 <= 320)
        #expect(MediaLibraryPresentation.minimumTileWidth > 0)
    }

    @Test("a document tile is square, whatever it is offered")
    func documentTileIsSquare() {
        let size = LayoutProbe.size(
            DocumentTile(mime: "application/pdf"),
            width: MediaLibraryPresentation.minimumTileWidth,
            height: LayoutProbe.unbounded
        )
        #expect(size.width == MediaLibraryPresentation.minimumTileWidth)
        #expect(size.height == size.width, "a tile that is not square breaks the grid's rows")
    }
}

/// What the app's main navigation offers, as a list rather than as two literals in a `TabView`.
@MainActor
@Suite("Main navigation")
struct MainTabTests {
    @Test("the app has exactly two ways in, and the timeline is still the first")
    func tabsAndOrder() {
        #expect(MainTab.allCases == [.timeline, .library])
    }

    @Test("every tab has a name and a glyph, and no two share either")
    func tabsAreDistinct() {
        let titles = MainTab.allCases.map(\.title)
        let symbols = MainTab.allCases.map(\.symbol)
        #expect(titles == ["Timeline", "Library"])
        #expect(Set(symbols).count == MainTab.allCases.count, "two tabs share a glyph")
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(symbols.allSatisfy { UIImage(systemName: $0) != nil }, "a tab names no real symbol")
    }
}
