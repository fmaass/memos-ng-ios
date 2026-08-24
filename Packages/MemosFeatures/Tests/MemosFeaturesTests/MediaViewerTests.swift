import CoreGraphics
import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The media a memo carries, as the viewer sees it.
///
/// The projection is where "which pictures, in what order, at which rendition" is decided once for
/// both surfaces that open the viewer. Everything a swipe, a label or a download depends on is
/// settled here, so it is settled in a test rather than in two view bodies that can drift apart.
@Suite("Viewer pages")
struct MediaViewerPageTests {
    /// Signed URLs in the shape the server actually mints them:
    /// `/api/attachments/{uid}/{tier}?exp=…&scope=…&sig=…`.
    static func url(_ uid: String, _ tier: String, exp: Int = 4_000_000_000) -> URL {
        let path = "https://memos.example.invalid/api/attachments/\(uid)/\(tier)"
        return URL(string: "\(path)?exp=\(exp)&scope=1&sig=abc")!
    }

    static func image(_ uid: String, width: Int = 4000, height: Int = 3000) -> MemoAttachment {
        MemoAttachment(
            uid: uid,
            mime: "image/jpeg",
            status: .ready,
            blurhash: "007Da1",
            width: width,
            height: height,
            thumbnailURL: url(uid, "thumb"),
            previewURL: url(uid, "mobile")
        )
    }

    static func video(_ uid: String) -> MemoAttachment {
        MemoAttachment(
            uid: uid,
            mime: "video/quicktime",
            status: .ready,
            width: 1080,
            height: 1920,
            duration: 12,
            thumbnailURL: url(uid, "thumb"),
            previewURL: url(uid, "mobile"),
            webURL: url(uid, "web"),
            posterURL: url(uid, "poster")
        )
    }

    static func other(_ uid: String, mime: String) -> MemoAttachment {
        MemoAttachment(
            uid: uid,
            mime: mime,
            status: .ready,
            thumbnailURL: url(uid, "thumb"),
            previewURL: url(uid, "mobile")
        )
    }

    @Test("a memo's pictures and videos become its pages, in order and counted")
    func projection() {
        let pages = MediaViewerPresentation.pages(for: [
            Self.image("a1"), Self.video("v1"), Self.image("a2"),
        ])
        #expect(pages.map(\.id) == ["a1", "v1", "a2"])
        #expect(pages.map(\.kind) == [.image, .video, .image])
        #expect(pages.map(\.position) == [1, 2, 3])
        #expect(pages.allSatisfy { $0.total == 3 })
        let labels = pages.map(\.accessibilityLabel)
        #expect(labels == ["Photo 1 of 3", "Video 2 of 3", "Photo 3 of 3"])
    }

    /// One case per input CATEGORY, because a filter with only a happy path is a filter that
    /// silently lets the next category through. A PDF in the swipe order is a black rectangle.
    @Test("only pictures and videos are pages")
    func categories() {
        let pages = MediaViewerPresentation.pages(for: [
            Self.image("a1"),
            Self.other("d1", mime: "application/pdf"),
            Self.video("v1"),
            Self.other("s1", mime: "audio/mpeg"),
            Self.other("z1", mime: ""),
        ])
        #expect(pages.map(\.id) == ["a1", "v1"])
        #expect(pages.map(\.total) == [2, 2])
    }

    @Test("an attachment with nothing to render is not a page")
    func nothingToRender() {
        var blank = Self.image("a1")
        blank.thumbnailURL = nil
        blank.previewURL = nil
        #expect(MediaViewerPresentation.pages(for: [blank]).isEmpty)
    }

    /// The poster is a video's still, but a video whose poster never got derived is still worth
    /// opening: what a video page is FOR is the stream behind it.
    @Test("a video with no poster is still a page, because the stream is what it is for")
    func videoWithoutPoster() {
        var video = Self.video("v1")
        video.posterURL = nil
        video.thumbnailURL = nil
        let pages = MediaViewerPresentation.pages(for: [video])
        #expect(pages.count == 1)
        #expect(pages.first?.kind == .video)
        #expect(pages.first?.stillURL == nil)
        #expect(pages.first?.playbackURL == video.webURL)
    }

    @Test("a page keeps the picture's own shape and its blurhash for the instant layer")
    func shapeAndBlurhash() {
        let portrait = Self.image("a1", width: 3000, height: 4000)
        let page = MediaViewerPresentation.pages(for: [portrait])[0]
        #expect(abs(page.aspectRatio - 0.75) < 0.0001)
        #expect(page.blurhash == "007Da1")

        var unmeasured = Self.image("a2")
        unmeasured.width = nil
        unmeasured.height = nil
        let fallback = MediaViewerPresentation.pages(for: [unmeasured])[0]
        #expect(abs(fallback.aspectRatio - 4.0 / 3.0) < 0.0001)
    }
}

/// Which rendition full screen asks for.
///
/// The rule is "the biggest one that exists, and never the original" — the original is the archive
/// master (ADR-0008), and a phone that downloads a 60 MP HEIC to look at it on a 6-inch screen is
/// spending someone's connection on nothing.
@Suite("Full-screen tier")
struct FullScreenTierTests {
    @Test("full screen asks for the mobile rendition, not the grid thumbnail")
    func biggerThanTheTile() {
        let attachment = MediaViewerPageTests.image("a1")
        #expect(MemoPresentation.fullScreenTier(for: attachment) == .mobile)

        let page = MediaViewerPresentation.pages(for: [attachment])[0]
        #expect(page.stillURL == attachment.previewURL)
        #expect(page.stillURL != attachment.thumbnailURL)
        // The tier is in the path the server routes on: /api/attachments/{uid}/{tier}.
        #expect(page.stillURL?.pathComponents.last == "mobile")
    }

    /// There is no original URL on an attachment at all, and there must not be one in a URL the
    /// viewer builds either: the only image tiers a client can fetch are `thumb` and `mobile`.
    @Test("nothing full screen requests is the original")
    func neverTheOriginal() {
        for attachment in [MediaViewerPageTests.image("a1"), MediaViewerPageTests.video("v1")] {
            let page = MediaViewerPresentation.pages(for: [attachment])[0]
            let requested = page.stillURL?.absoluteString ?? ""
            #expect(!requested.contains("original"))
            let tier = page.stillURL?.pathComponents.last ?? ""
            #expect(["mobile", "thumb", "poster"].contains(tier))
        }
    }

    /// A picture whose 2048 px rendition is missing still opens — at the tier it has, rather than
    /// as a warning triangle in a full-screen black frame.
    @Test("a picture with no mobile rendition falls back to the tier it has")
    func fallsBackToThumb() {
        var attachment = MediaViewerPageTests.image("a1")
        attachment.previewURL = nil
        #expect(MemoPresentation.fullScreenTier(for: attachment) == .thumb)
        let page = MediaViewerPresentation.pages(for: [attachment])[0]
        #expect(page.stillURL == attachment.thumbnailURL)
    }

    @Test("a video page shows its poster and plays the derived rendition")
    func videoStillAndStream() {
        let video = MediaViewerPageTests.video("v1")
        let page = MediaViewerPresentation.pages(for: [video])[0]
        #expect(page.stillURL == video.posterURL)
        #expect(page.playbackURL == video.webURL)
    }

    /// The bigger tier is fetched over the same signed URL as everything else, so the same rule
    /// binds it: a cached copy may not outlive the signature that authorised it.
    @Test("the full-screen rendition is cached no longer than its signature")
    func cacheIsBoundedByTheSignature() throws {
        let exp = 1_800_000_000
        var attachment = MediaViewerPageTests.image("a1")
        attachment.previewURL = MediaViewerPageTests.url("a1", "mobile", exp: exp)
        let page = MediaViewerPresentation.pages(for: [attachment])[0]
        let url = try #require(page.stillURL)

        let signed = SignedMediaURL(url: url)
        #expect(signed.expiresAt == Date(timeIntervalSince1970: TimeInterval(exp)))
        #expect(!signed.isExpired(at: Date(timeIntervalSince1970: TimeInterval(exp - 60))))
        #expect(signed.isExpired(at: Date(timeIntervalSince1970: TimeInterval(exp + 1))))
        // What the viewer does before it asks for the picture: drop a lapsed entry rather than
        // re-serve it (the same call `AttachmentThumbnail` makes for the grid tier).
        let cache = URLCache(memoryCapacity: 4096, diskCapacity: 0, directory: nil)
        #expect(
            MediaCache.evictExpired(
                url,
                at: Date(timeIntervalSince1970: TimeInterval(exp + 1)),
                cache: cache
            )
        )
        #expect(
            !MediaCache.evictExpired(
                url,
                at: Date(timeIntervalSince1970: TimeInterval(exp - 60)),
                cache: cache
            )
        )
    }
}

/// Opening the viewer at the picture that was tapped.
@Suite("Viewer selection")
struct MediaViewerSelectionTests {
    private func memo(_ attachments: [MemoAttachment]) -> Memo {
        Memo(
            uid: "m1",
            owner: "fabian@example.invalid",
            mine: true,
            content: "A memo.",
            visibility: .protected,
            pinned: false,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            attachments: attachments
        )
    }

    @Test("the viewer opens on the picture that was tapped, with the rest a swipe away")
    func opensWhereTheFingerWas() {
        let memo = memo([
            MediaViewerPageTests.image("a1"),
            MediaViewerPageTests.image("a2"),
            MediaViewerPageTests.image("a3"),
        ])
        let selection = MediaViewerPresentation.viewer(for: memo, startingAt: "a3")
        #expect(selection?.startIndex == 2)
        #expect(selection?.startPage.id == "a3")
        #expect(selection?.id == "a3")
        #expect(selection?.pages.count == 3)
    }

    /// The index the viewer opens at is an index into the PAGES, not into the attachments. A memo
    /// whose first upload is not viewable would otherwise open on the wrong picture.
    @Test("an unviewable attachment before it does not shift the page it opens at")
    func indexIsIntoPagesNotAttachments() {
        let memo = memo([
            MediaViewerPageTests.other("d1", mime: "application/pdf"),
            MediaViewerPageTests.image("a1"),
            MediaViewerPageTests.image("a2"),
        ])
        let selection = MediaViewerPresentation.viewer(for: memo, startingAt: "a1")
        #expect(selection?.startIndex == 0)
        #expect(selection?.startPage.id == "a1")
    }

    @Test("there is nothing to open for an attachment the viewer cannot show")
    func nothingToOpen() {
        let memo = memo([MediaViewerPageTests.other("d1", mime: "application/pdf")])
        #expect(MediaViewerPresentation.viewer(for: memo, startingAt: "d1") == nil)
        #expect(MediaViewerPresentation.viewer(for: memo, startingAt: "nope") == nil)
        #expect(MediaViewerPresentation.viewer(for: self.memo([]), startingAt: "a1") == nil)
    }
}

/// The arithmetic behind pinch, pan and double tap.
///
/// A viewer that lets a picture be flung off the screen, or that keeps it stuck off-centre after
/// zooming out, is broken in a way no screenshot review catches — so the limits are asserted, not
/// eyeballed.
@Suite("Zoom and pan")
struct MediaZoomTests {
    private let viewport = CGSize(width: 390, height: 844)

    @Test("a pinch may propose anything; what reaches the picture stays in range")
    func scaleIsClamped() {
        #expect(MediaZoom.clamped(scale: 0.2) == MediaZoom.minimumScale)
        #expect(MediaZoom.clamped(scale: -3) == MediaZoom.minimumScale)
        #expect(MediaZoom.clamped(scale: .nan) == MediaZoom.minimumScale)
        #expect(MediaZoom.clamped(scale: 99) == MediaZoom.maximumScale)
        #expect(MediaZoom.clamped(scale: 2.5) == 2.5)
    }

    @Test("double tap goes in from out, and out from anywhere in")
    func doubleTapToggles() {
        #expect(MediaZoom.scale(afterDoubleTapAt: 1) == MediaZoom.doubleTapScale)
        #expect(MediaZoom.scale(afterDoubleTapAt: 1.0005) == MediaZoom.doubleTapScale)
        #expect(MediaZoom.scale(afterDoubleTapAt: 2.5) == MediaZoom.minimumScale)
        #expect(MediaZoom.scale(afterDoubleTapAt: 6) == MediaZoom.minimumScale)
    }

    /// Deliberately in both directions from the viewport's own shape: a regression that fitted
    /// everything to the width would have to fail the portrait case, and one that fitted
    /// everything to the height would have to fail the landscape case.
    @Test("a picture is fitted whole, at its own shape, inside the screen")
    func fitted() {
        let portrait = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        #expect(abs(portrait.width - 390) < 0.001)
        #expect(abs(portrait.height - 520) < 0.001)

        let landscape = MediaZoom.fittedSize(aspectRatio: 4.0 / 3.0, in: viewport)
        #expect(abs(landscape.width - 390) < 0.001)
        #expect(abs(landscape.height - 292.5) < 0.001)

        let panorama = MediaZoom.fittedSize(aspectRatio: 8, in: viewport)
        #expect(abs(panorama.width - 390) < 0.001)
        #expect(abs(panorama.height - 48.75) < 0.001)

        let tall = MediaZoom.fittedSize(aspectRatio: 0.25, in: viewport)
        #expect(abs(tall.height - 844) < 0.001)
        #expect(abs(tall.width - 211) < 0.001)
    }

    @Test("a degenerate shape lays out as nothing rather than as NaN")
    func degenerate() {
        #expect(MediaZoom.fittedSize(aspectRatio: 0, in: viewport) == .zero)
        #expect(MediaZoom.fittedSize(aspectRatio: -2, in: viewport) == .zero)
        #expect(MediaZoom.fittedSize(aspectRatio: .nan, in: viewport) == .zero)
        #expect(MediaZoom.fittedSize(aspectRatio: 1, in: .zero) == .zero)
    }

    @Test("a picture that fits cannot be dragged around")
    func noPanWhileWhole() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let limit = MediaZoom.panLimit(scale: 1, fitted: fitted, viewport: viewport)
        #expect(limit.width == 0)
        #expect(limit.height == 0)
        let offset = MediaZoom.clampedOffset(
            CGSize(width: 300, height: -400),
            scale: 1,
            fitted: fitted,
            viewport: viewport
        )
        #expect(offset == .zero)
    }

    @Test("a magnified picture may be moved to its edge and no further")
    func panStopsAtTheEdge() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)  // 390 x 520
        let limit = MediaZoom.panLimit(scale: 2, fitted: fitted, viewport: viewport)
        #expect(abs(limit.width - 195) < 0.001)  // (780 - 390) / 2
        #expect(abs(limit.height - 98) < 0.001)  // (1040 - 844) / 2

        let overshoot = MediaZoom.clampedOffset(
            CGSize(width: 5000, height: -5000),
            scale: 2,
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(overshoot.width - limit.width) < 0.001)
        #expect(abs(overshoot.height + limit.height) < 0.001)

        let inside = MediaZoom.clampedOffset(
            CGSize(width: 40, height: -20),
            scale: 2,
            fitted: fitted,
            viewport: viewport
        )
        #expect(inside == CGSize(width: 40, height: -20))
    }

    /// The stuck-off-centre bug, stated: zooming back out shrinks the room a pan was allowed, so
    /// the offset has to be re-clamped against the NEW scale or the picture never comes back.
    @Test("zooming back out recentres a picture that had been panned")
    func settlingReclampsTheOffset() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let panned = MediaZoom.panned(
            MediaZoom.Transform(scale: 3, offset: .zero),
            by: CGSize(width: 200, height: 100),
            fitted: fitted,
            viewport: viewport
        )
        #expect(panned.offset.width > 0)

        let out = MediaZoom.settled(panned, magnifiedBy: 0.1, fitted: fitted, viewport: viewport)
        #expect(out.scale == MediaZoom.minimumScale)
        #expect(out.offset == .zero)
        #expect(!out.isZoomed)
    }

    @Test("a pan accumulates on what was already there")
    func panAccumulates() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let first = MediaZoom.panned(
            MediaZoom.Transform(scale: 2, offset: .zero),
            by: CGSize(width: 50, height: 10),
            fitted: fitted,
            viewport: viewport
        )
        let second = MediaZoom.panned(
            first,
            by: CGSize(width: 50, height: 10),
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(second.offset.width - 100) < 0.001)
        #expect(abs(second.offset.height - 20) < 0.001)
    }

    @Test("a double tap out puts the picture back in the middle")
    func doubleTapRecentres() {
        let zoomed = MediaZoom.Transform(scale: 2.5, offset: CGSize(width: 80, height: 30))
        let out = MediaZoom.doubleTapped(zoomed)
        #expect(out.scale == MediaZoom.minimumScale)
        #expect(out.offset == .zero)
        let back = MediaZoom.doubleTapped(out)
        #expect(back.scale == MediaZoom.doubleTapScale)
        #expect(back.isZoomed)
    }
}

/// Which of a card's two targets a tap landed on.
///
/// This reverses a deliberate earlier decision — the card used to be one target edge to edge —
/// and the reversal is only safe while BOTH halves hold: a tile opens the picture, and every
/// other part of the card still opens the memo.
@Suite("Card tap routing")
struct MemoCardTapTests {
    /// A three-tile strip laid out the way the card lays one out: the card's own horizontal inset,
    /// square tiles, the card's gap between them.
    private func strip(cardWidth: CGFloat = 358, top: CGFloat = 120) -> [MemoCardTap.Tile] {
        let inset: CGFloat = 16
        let gap: CGFloat = 8
        let side = (cardWidth - 2 * inset - 2 * gap) / 3
        return (0..<3).map { index in
            MemoCardTap.Tile(
                uid: "a\(index + 1)",
                frame: CGRect(
                    x: inset + CGFloat(index) * (side + gap),
                    y: top,
                    width: side,
                    height: side
                )
            )
        }
    }

    @Test("a tap on a tile opens that picture")
    func tileOpensThePicture() {
        let tiles = strip()
        for tile in tiles {
            let centre = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            let destination = MemoCardTap.destination(at: centre, tiles: tiles)
            #expect(destination == .attachment(uid: tile.uid))
        }
    }

    @Test("a tap anywhere else on the card still opens the memo")
    func theRestOpensTheMemo() {
        let tiles = strip()
        let elsewhere = [
            CGPoint(x: 60, y: 24),  // the name and the time
            CGPoint(x: 200, y: 80),  // the body text
            CGPoint(x: 40, y: 300),  // the tag row, below the photos
            CGPoint(x: tiles[0].frame.maxX + 4, y: tiles[0].frame.midY),  // the gap between tiles
            CGPoint(x: 4, y: tiles[0].frame.midY),  // the card's inset, beside the first tile
        ]
        for point in elsewhere {
            #expect(MemoCardTap.destination(at: point, tiles: tiles) == .memo)
        }
    }

    /// Before the tiles have reported where they are — the first frame of a card that has just
    /// scrolled in — the card behaves exactly as it did before this feature existed.
    @Test("a card with no measured tiles is one target, as it always was")
    func unmeasuredCardOpensTheMemo() {
        #expect(MemoCardTap.destination(at: CGPoint(x: 100, y: 140), tiles: []) == .memo)
    }
}

/// The viewer's chrome.
///
/// The labels themselves are asserted where they are DECIDED — `MediaPage.accessibilityLabel`,
/// above — because a hosted SwiftUI view does not vend its accessibility elements through UIKit
/// outside an XCUITest, so a probe of the element tree here reads empty whether the labels exist
/// or not. What this suite holds instead is the part a unit test can honestly measure: that the
/// way out stays a real target, and that the viewer actually fills the screen it is handed.
@MainActor
@Suite("Viewer chrome")
struct MediaViewerChromeTests {
    /// 44 points is the HIG minimum. The drag that dismisses is a gesture nobody is told about, so
    /// the button beside it must not shrink into something people have to hunt for.
    @Test("the way out stays at least a 44-point target at every text size")
    func closeControlStaysReachable() {
        for typeSize in [DynamicTypeSize.large, .accessibility5] {
            let size = LayoutProbe.size(
                MediaViewerCloseButton(close: {}),
                width: LayoutProbe.unbounded,
                typeSize: typeSize
            )
            #expect(size.width >= 44, "close control is \(size.width) wide at \(typeSize)")
            #expect(size.height >= 44, "close control is \(size.height) tall at \(typeSize)")
        }
    }

    /// A viewer built out of a `GeometryReader` inside a paging scroll view is exactly the shape
    /// that collapses to nothing when a frame goes missing — and a black screen looks like a
    /// loading state rather than a bug.
    @Test("the viewer fills the screen it is given")
    func fillsTheScreen() throws {
        let selection = try #require(
            MediaViewerPresentation.viewer(
                for: [MediaViewerPageTests.image("a1"), MediaViewerPageTests.image("a2")],
                startingAt: "a1"
            )
        )
        let size = LayoutProbe.size(
            MediaViewerView(selection: selection),
            width: 390,
            height: 844
        )
        #expect(abs(size.width - 390) < 0.5, "viewer reported \(size)")
        #expect(abs(size.height - 844) < 0.5, "viewer reported \(size)")
    }
}
