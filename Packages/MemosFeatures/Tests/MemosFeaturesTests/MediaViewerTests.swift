import CoreGraphics
import Foundation
import MemosCore
import MemosOutbox
import SwiftUI
import Testing
import UIKit

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

    @Test("a memo's pictures and videos become its pages, in order")
    func projection() {
        let pages = MediaViewerPresentation.pages(for: [
            Self.image("a1"), Self.video("v1"), Self.image("a2"),
        ])
        #expect(pages.map(\.id) == ["a1", "v1", "a2"])
        #expect(pages.map(\.kind) == [.image, .video, .image])
        // No count, on the page or in what it says out loud: the library's viewer pages through a
        // list that GROWS as it is swiped, so any number here would be a number of what happened
        // to be loaded (MEMNG-189).
        let labels = pages.map(\.accessibilityLabel)
        #expect(labels == ["Photo", "Video", "Photo"])
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
        #expect(pages.count == 2)
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
    /// binds it: a cached copy may not outlive the signature that authorised it. That the PAGE
    /// actually enforces it is asserted end to end in "Viewer loading" below; this holds the half
    /// that is a property of the URL the tier choice produced.
    @Test("the full-screen rendition carries the expiry its cache is bounded by")
    func theRenditionCarriesItsExpiry() throws {
        let exp = 1_800_000_000
        var attachment = MediaViewerPageTests.image("a1")
        attachment.previewURL = MediaViewerPageTests.url("a1", "mobile", exp: exp)
        let page = MediaViewerPresentation.pages(for: [attachment])[0]
        let url = try #require(page.stillURL)

        let signed = SignedMediaURL(url: url)
        #expect(signed.expiresAt == Date(timeIntervalSince1970: TimeInterval(exp)))
        #expect(!signed.isExpired(at: Date(timeIntervalSince1970: TimeInterval(exp - 60))))
        #expect(signed.isExpired(at: Date(timeIntervalSince1970: TimeInterval(exp + 1))))
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

    /// The picture's own centre on screen — the viewport's centre carried by whatever offset the
    /// picture already has. A pinch anchored there is the one that leaves the offset alone, so it
    /// is what a case about something other than the anchor asks for.
    private func pictureCentre(of transform: MediaZoom.Transform) -> CGPoint {
        CGPoint(
            x: viewport.width / 2 + transform.offset.width,
            y: viewport.height / 2 + transform.offset.height
        )
    }

    /// An anchor given as a vector from the viewport's centre, which is how every case below
    /// reasons about one: right and down are positive, as on screen.
    private func anchor(x: Double, y: Double) -> CGPoint {
        CGPoint(x: viewport.width / 2 + x, y: viewport.height / 2 + y)
    }

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
            underPinch: nil,
            fitted: fitted,
            viewport: viewport
        )
        #expect(panned.offset.width > 0)

        let out = MediaZoom.settled(
            panned,
            magnifiedBy: 0.1,
            anchoredAt: pictureCentre(of: panned),
            fitted: fitted,
            viewport: viewport
        )
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
            underPinch: nil,
            fitted: fitted,
            viewport: viewport
        )
        let second = MediaZoom.panned(
            first,
            by: CGSize(width: 50, height: 10),
            underPinch: nil,
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(second.offset.width - 100) < 0.001)
        #expect(abs(second.offset.height - 20) < 0.001)
    }

    /// The stale-transform bug, stated: a rotation re-fits the picture under a transform that was
    /// clamped against the OLD screen. Clamping only what is DRAWN leaves the stored offset in the
    /// previous geometry, and the next pan spends itself absorbing that delta before the picture
    /// moves — which feels like a picture stuck against an edge it is not against.
    @Test("a viewport change brings the stored transform with it")
    func viewportChangeRenormalisesTheStoredTransform() {
        let portrait = CGSize(width: 390, height: 844)
        let landscape = CGSize(width: 844, height: 390)
        let ratio = 4.0 / 3.0

        // Zoomed and panned hard against the right-hand edge of the PORTRAIT screen.
        let fittedPortrait = MediaZoom.fittedSize(aspectRatio: ratio, in: portrait)
        let atTheEdge = MediaZoom.panned(
            MediaZoom.Transform(scale: 2, offset: .zero),
            by: CGSize(width: 4000, height: 0),
            underPinch: nil,
            fitted: fittedPortrait,
            viewport: portrait
        )
        let portraitLimit = MediaZoom.panLimit(
            scale: 2,
            fitted: fittedPortrait,
            viewport: portrait
        )
        #expect(abs(atTheEdge.offset.width - portraitLimit.width) < 0.001)

        // The screen turns, and the picture is re-fitted with far less room to move sideways. The
        // STORED offset has to land inside the new limits, not merely be drawn inside them.
        let fittedLandscape = MediaZoom.fittedSize(aspectRatio: ratio, in: landscape)
        let landscapeLimit = MediaZoom.panLimit(
            scale: 2,
            fitted: fittedLandscape,
            viewport: landscape
        )
        #expect(landscapeLimit.width < portraitLimit.width, "the fixture proves nothing otherwise")

        let carried = MediaZoom.renormalized(
            atTheEdge,
            fitted: fittedLandscape,
            viewport: landscape
        )
        #expect(abs(carried.offset.width - landscapeLimit.width) < 0.001)
        #expect(carried.scale == atTheEdge.scale)

        // And the symptom itself: the very next pan moves the picture instead of being eaten by
        // the stale delta.
        let nudged = MediaZoom.panned(
            carried,
            by: CGSize(width: -30, height: 0),
            underPinch: nil,
            fitted: fittedLandscape,
            viewport: landscape
        )
        #expect(abs(nudged.offset.width - (landscapeLimit.width - 30)) < 0.001)
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

    /// Anchored on the picture's own centre there is nothing for the anchoring to do, panned or
    /// not — the arithmetic has to leave the offset exactly where it found it.
    @Test("a pinch centred on the picture leaves the offset alone")
    func pinchAtThePictureCentre() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)

        let unpanned = MediaZoom.Transform(scale: 2, offset: .zero)
        let stillCentred = MediaZoom.settled(
            unpanned,
            magnifiedBy: 1.5,
            anchoredAt: pictureCentre(of: unpanned),
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(stillCentred.scale - 3) < 0.001)
        #expect(stillCentred.offset == .zero)

        let moved = MediaZoom.Transform(scale: 2, offset: CGSize(width: 40, height: -20))
        let carried = MediaZoom.settled(
            moved,
            magnifiedBy: 1.5,
            anchoredAt: pictureCentre(of: moved),
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(carried.offset.width - 40) < 0.001)
        #expect(abs(carried.offset.height + 20) < 0.001)
    }

    /// What the whole thing is for: the point under the fingers stays under them, which means the
    /// offset travels AWAY from the anchor — pinch in the upper right and the picture's centre
    /// goes left and down.
    @Test("a pinch in the upper right pushes the offset away from it")
    func pinchInACornerMovesTheOffsetAway() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let out = MediaZoom.settled(
            MediaZoom.Transform(scale: 2, offset: .zero),
            magnifiedBy: 1.5,
            anchoredAt: anchor(x: 100, y: -50),
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(out.scale - 3) < 0.001)
        // a - m*a at m = 1.5: half the anchor vector, the other way about.
        #expect(abs(out.offset.width + 50) < 0.001)
        #expect(abs(out.offset.height - 25) < 0.001)
    }

    /// The committed offset is an input of the same formula, not a special case bolted beside it.
    @Test("a pinch in a corner of a panned picture carries the old offset through")
    func pinchInACornerOfAPannedPicture() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let out = MediaZoom.settled(
            MediaZoom.Transform(scale: 2, offset: CGSize(width: 40, height: -20)),
            magnifiedBy: 1.5,
            anchoredAt: anchor(x: 100, y: -50),
            fitted: fitted,
            viewport: viewport
        )
        // a - m*(a - o), and inside the limits at scale 3, so nothing is trimmed here.
        #expect(abs(out.offset.width - 10) < 0.001)
        #expect(abs(out.offset.height + 5) < 0.001)
    }

    /// Anchoring does not get to push a picture off the screen: the target meets the same limits a
    /// drag does, and only on the axis that ran out of room.
    @Test("an anchored target beyond the edge is trimmed on that axis alone")
    func anchoredTargetBeyondTheEdge() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let room = MediaZoom.panLimit(scale: 6, fitted: fitted, viewport: viewport)
        #expect(room.width > 900, "the fixture proves nothing if it starts out of bounds")

        let out = MediaZoom.settled(
            MediaZoom.Transform(scale: 6, offset: CGSize(width: 900, height: 100)),
            magnifiedBy: 0.5,
            anchoredAt: anchor(x: 195, y: 0),
            fitted: fitted,
            viewport: viewport
        )
        let limit = MediaZoom.panLimit(scale: 3, fitted: fitted, viewport: viewport)
        #expect(abs(out.scale - 3) < 0.001)
        // 547.5 asked for on the wide axis, the limit granted.
        #expect(abs(out.offset.width - limit.width) < 0.001)
        // Well inside its own limit, so untouched.
        #expect(abs(out.offset.height - 50) < 0.001)
    }

    /// At the top of the range a further pinch has no effective ratio left, so there is nothing for
    /// the anchor to act on. The anchor is deliberately off the picture's centre and the offset
    /// well inside the limits: any movement here would show rather than be trimmed away.
    @Test("a pinch past the scale limit moves nothing")
    func pinchPastTheScaleLimit() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let atTheLimit = MediaZoom.Transform(
            scale: MediaZoom.maximumScale,
            offset: CGSize(width: 40, height: -20)
        )
        let out = MediaZoom.settled(
            atTheLimit,
            magnifiedBy: 2,
            anchoredAt: anchor(x: 100, y: 50),
            fitted: fitted,
            viewport: viewport
        )
        #expect(out.scale == MediaZoom.maximumScale)
        #expect(abs(out.offset.width - 40) < 0.001)
        #expect(abs(out.offset.height + 20) < 0.001)
    }

    /// Coming back out needs no special case: at fitted size the pan limit is zero on both axes,
    /// so the clamp that stops a drag at the edge is what puts the picture back in the middle.
    @Test("pinching back to fitted size recentres whatever the anchor was")
    func backToFittedRecentres() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let out = MediaZoom.settled(
            MediaZoom.Transform(scale: 3, offset: CGSize(width: 200, height: 100)),
            magnifiedBy: 0.2,
            anchoredAt: anchor(x: 100, y: -50),
            fitted: fitted,
            viewport: viewport
        )
        #expect(out.scale == MediaZoom.minimumScale)
        #expect(out.offset == MediaZoom.Transform.identity.offset)
        #expect(!out.isZoomed)
    }

    /// A magnified panorama still has no room to move vertically, however the fingers land: the
    /// anchor's vertical share has to end up trimmed to nothing rather than lifting the picture
    /// off its own edges.
    @Test("an axis the magnified picture does not overflow stays centred")
    func nonOverflowingAxisStaysCentred() {
        let panorama = MediaZoom.fittedSize(aspectRatio: 8, in: viewport)
        let limit = MediaZoom.panLimit(scale: 3, fitted: panorama, viewport: viewport)
        #expect(limit.height == 0, "the fixture proves nothing if it can move vertically")

        let out = MediaZoom.settled(
            MediaZoom.Transform(scale: 2, offset: .zero),
            magnifiedBy: 1.5,
            anchoredAt: anchor(x: 100, y: -50),
            fitted: panorama,
            viewport: viewport
        )
        #expect(out.offset.height == 0)
    }

    /// The pinch and the drag are separate recognisers and nothing says which of them ends first.
    /// Either order has to leave the picture exactly where the fingers had it, and both orders
    /// have to end on the same committed transform — all of it inside the limits here, so a clamp
    /// cannot be what makes the numbers agree.
    @Test("either gesture may end first and the picture does not jump")
    func eitherGestureMayEndFirst() {
        let fitted = MediaZoom.fittedSize(aspectRatio: 0.75, in: viewport)
        let committed = MediaZoom.Transform(scale: 2, offset: .zero)
        let pinch = MediaZoom.Pinch(magnification: 1.5, anchor: anchor(x: 100, y: 0))
        let drag = CGSize(width: 20, height: 0)

        let underTheFingers = MediaZoom.live(
            committed,
            pinch: pinch,
            pannedBy: drag,
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(underTheFingers.scale - 3) < 0.001)
        #expect(abs(underTheFingers.offset.width + 30) < 0.001)

        // The drag ends first, and what it stores is rebased so the pinch redraws the same frame.
        let afterTheDrag = MediaZoom.panned(
            committed,
            by: drag,
            underPinch: pinch,
            fitted: fitted,
            viewport: viewport
        )
        let acrossTheDragsEnd = MediaZoom.live(
            afterTheDrag,
            pinch: pinch,
            pannedBy: .zero,
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(acrossTheDragsEnd.offset.width + 30) < 0.001)
        let dragFirst = MediaZoom.settled(
            afterTheDrag,
            magnifiedBy: pinch.magnification,
            anchoredAt: pinch.anchor,
            fitted: fitted,
            viewport: viewport
        )

        // The pinch ends first, and the drag is still in screen points, so it adds the same 20.
        let afterThePinch = MediaZoom.settled(
            committed,
            magnifiedBy: pinch.magnification,
            anchoredAt: pinch.anchor,
            fitted: fitted,
            viewport: viewport
        )
        let acrossThePinchsEnd = MediaZoom.live(
            afterThePinch,
            pinch: nil,
            pannedBy: drag,
            fitted: fitted,
            viewport: viewport
        )
        #expect(abs(acrossThePinchsEnd.offset.width + 30) < 0.001)
        let pinchFirst = MediaZoom.panned(
            afterThePinch,
            by: drag,
            underPinch: nil,
            fitted: fitted,
            viewport: viewport
        )

        #expect(abs(dragFirst.scale - 3) < 0.001)
        #expect(abs(dragFirst.offset.width + 30) < 0.001)
        #expect(abs(pinchFirst.scale - dragFirst.scale) < 0.001)
        #expect(abs(pinchFirst.offset.width - dragFirst.offset.width) < 0.001)
        #expect(abs(pinchFirst.offset.height - dragFirst.offset.height) < 0.001)
    }

    @Test("a picture at rest holds nothing back")
    func nothingHeldAtRest() {
        let holds = MediaZoom.holds(.identity, pinch: nil)
        #expect(!holds.pager)
        #expect(!holds.dismissal)
    }

    /// Two fingers on a picture are never a page turn, even before they have changed the scale at
    /// all — which is why the pager is answered from the pinch and not from the transform.
    @Test("fingers on the picture hold the pager")
    func fingersHoldThePager() {
        let held = MediaZoom.holds(
            .identity,
            pinch: MediaZoom.Pinch(magnification: 0.5, anchor: anchor(x: 0, y: 0))
        )
        #expect(held.pager)
    }

    /// The narrower answer, deliberately: a picture that is already whole is closed by pinching
    /// in, and that has to keep working.
    @Test("a pinch in at fitted size does not hold dismissal")
    func fittedPinchInDoesNotHoldDismissal() {
        let held = MediaZoom.holds(
            .identity,
            pinch: MediaZoom.Pinch(magnification: 0.5, anchor: anchor(x: 0, y: 0))
        )
        #expect(!held.dismissal)
    }

    /// The committed transform only changes when the fingers leave, so a pinch that has already
    /// taken the picture past fitted size has to be answered from the LIVE scale — otherwise the
    /// viewer starts closing underneath a zoom-in.
    @Test("a live scale past the tolerance holds dismissal")
    func liveScaleHoldsDismissal() {
        let held = MediaZoom.holds(
            .identity,
            pinch: MediaZoom.Pinch(magnification: 1.5, anchor: anchor(x: 100, y: -50))
        )
        #expect(held.dismissal)
    }

    /// And the other side of it: a zoomed picture pinched back down to fitted size keeps both
    /// holds while the fingers are still on it, because what it is committed to is still zoomed.
    @Test("a committed zoom holds both until the fingers leave")
    func committedZoomHoldsBoth() {
        let held = MediaZoom.holds(
            MediaZoom.Transform(scale: 2, offset: .zero),
            pinch: MediaZoom.Pinch(magnification: 0.3, anchor: anchor(x: 0, y: 0))
        )
        #expect(held.pager)
        #expect(held.dismissal)
    }
}

/// Which of a card's targets a tap landed on.
///
/// This reverses a deliberate earlier decision — the card used to be one target edge to edge — and
/// the reversal is only safe while BOTH halves hold: a tile opens the picture, and every other part
/// of the card still opens the memo.
///
/// The tiles here are the ones the CARD MEASURED, not rectangles this file worked out for itself.
/// That distinction is the whole point: the frames come from `mediaTapTarget`'s `onGeometryChange`
/// through the card's own state, so deleting that reporting empties these tests rather than leaving
/// them quietly green — and a tap is routed against the geometry a finger would actually meet.
@MainActor
@Suite("Card tap routing")
struct MemoCardTapTests {
    /// Photos the server measured, with no URLs at all: the layout comes from the metadata, so
    /// these lay out exactly as real ones do while touching no network.
    private func photos(_ shapes: [(Int, Int)]) -> [MemoAttachment] {
        shapes.enumerated().map { index, shape in
            MemoAttachment(
                uid: "a\(index + 1)",
                mime: "image/jpeg",
                status: .ready,
                width: shape.0,
                height: shape.1
            )
        }
    }

    /// Hosts a real card and hands back the tiles it reported.
    private func measuredTiles(
        of attachments: [MemoAttachment],
        width: CGFloat = 402
    ) -> [MemoCardTap.Tile] {
        let seen = Box<[MemoCardTap.Tile]>([])
        let memo = MemoFixture.memo(content: "A day out.", attachments: attachments)
        ScreenProbe.settle(
            MemoCard(memo: memo, reportTiles: { seen.value = $0 })
                .frame(width: width),
            size: CGSize(width: width, height: 874)
        )
        return seen.value
    }

    @Test("the card reports a frame for every photo it drew")
    func everyPhotoIsMeasured() {
        let tiles = measuredTiles(of: photos([(3, 2), (3, 2), (3, 2), (2, 3), (1, 1)]))
        // If this is empty the card reported nothing — which is what deleting `mediaTapTarget`'s
        // `onGeometryChange` does, and what every assertion below then has nothing to stand on.
        #expect(tiles.count == 5, "the card measured \(tiles.count) tiles, not five")
        #expect(Set(tiles.map(\.uid)).count == 5, "two tiles reported the same attachment")
        for tile in tiles {
            #expect(tile.frame.width > 1, "\(tile.uid) was measured at \(tile.frame)")
            #expect(tile.frame.height > 1, "\(tile.uid) was measured at \(tile.frame)")
        }
    }

    /// The measured geometry IS justified rows: several rows, each of them wider than one tile,
    /// and every tile in a row standing at that row's height. This is what makes the arrangement
    /// a fact about the running card rather than about the solver alone.
    @Test("the measured tiles really are justified rows, not a strip")
    func theMeasuredLayoutIsJustified() {
        let tiles = measuredTiles(of: photos([(3, 2), (3, 2), (3, 2), (2, 3), (1, 1)]))
        #expect(tiles.count == 5, "the card measured \(tiles.count) tiles, not five")
        let rows = Dictionary(grouping: tiles) { ($0.frame.minY / 4).rounded() }
        #expect(rows.count >= 2, "every photo landed on one line — that is the old strip")
        for (_, row) in rows where row.count > 1 {
            let heights = row.map(\.frame.height)
            #expect(
                (heights.max() ?? 0) - (heights.min() ?? 0) < 1.5,
                "tiles sharing a row came out at different heights: \(heights)"
            )
            // Photos in one row do not overlap, which is what makes "the first frame containing
            // the point" a sound rule.
            let ordered = row.sorted { $0.frame.minX < $1.frame.minX }
            for (left, right) in zip(ordered, ordered.dropFirst()) {
                #expect(left.frame.maxX <= right.frame.minX + 0.5, "two tiles overlap")
            }
        }
        // A portrait photo is narrower than a landscape one standing beside it.
        let byUid = Dictionary(uniqueKeysWithValues: tiles.map { ($0.uid, $0.frame) })
        if let landscape = byUid["a1"], let portrait = byUid["a4"] {
            #expect(
                portrait.width / portrait.height < landscape.width / landscape.height,
                "the tiles were cropped to one shape instead of keeping their own"
            )
        }
    }

    @Test("a tap on a measured tile opens that picture")
    func tileOpensThePicture() {
        let tiles = measuredTiles(of: photos([(3, 2), (3, 2), (3, 2), (2, 3), (1, 1)]))
        #expect(!tiles.isEmpty, "no measured tiles: the card reported nothing to route over")
        for tile in tiles {
            let centre = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            #expect(MemoCardTap.destination(at: centre, tiles: tiles) == .attachment(uid: tile.uid))
        }
    }

    /// A tap on the eighth photo of a memo has to reach the eighth photo. The strip could not be
    /// asked this question — it only ever drew three.
    @Test("the photo a tap opens is the photo under the finger, at any count")
    func everyPhotoIsItsOwnTarget() {
        let tiles = measuredTiles(of: photos(Array(repeating: (3, 2), count: 9)))
        #expect(tiles.count == 9, "the card measured \(tiles.count) of nine photos")
        for tile in tiles {
            let inside = CGPoint(x: tile.frame.minX + 2, y: tile.frame.maxY - 2)
            #expect(MemoCardTap.destination(at: inside, tiles: tiles) == .attachment(uid: tile.uid))
        }
    }

    @Test("a tap anywhere else on the card still opens the memo")
    func theRestOpensTheMemo() {
        let tiles = measuredTiles(of: photos([(3, 2), (3, 2), (3, 2), (2, 3), (1, 1)]))
        let ordered = tiles.sorted {
            ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
        }
        // A `guard` rather than an index: with no measured tiles this must FAIL, not crash the
        // whole bundle and take every other suite in the process with it.
        guard let first = ordered.first?.frame else {
            #expect(Bool(false), "the card reported no tiles to route around")
            return
        }
        let lowest = tiles.map(\.frame.maxY).max() ?? 0
        let elsewhere = [
            CGPoint(x: 60, y: 4),  // the name and the time, above everything
            CGPoint(x: 200, y: max(0, first.minY - 6)),  // the body text
            CGPoint(x: 40, y: lowest + 20),  // the tag row, below the last row of photos
            CGPoint(x: 4, y: first.midY),  // the card's inset, beside the first tile
        ]
        for point in elsewhere {
            #expect(
                MemoCardTap.destination(at: point, tiles: tiles) == .memo,
                "\(point) did not open the memo"
            )
        }
    }

    /// Before the tiles have reported where they are — the first frame of a card that has just
    /// scrolled in — the card behaves exactly as it did before this feature existed.
    @Test("a card with no measured tiles is one target, as it always was")
    func unmeasuredCardOpensTheMemo() {
        #expect(MemoCardTap.destination(at: CGPoint(x: 100, y: 140), tiles: []) == .memo)
    }

    // MARK: - what a tap on a VIDEO means

    /// Tapping a video used to open the viewer, which showed a still of the video with a play
    /// button on it: the picture of the video, and a second tap needed before anything moved.
    /// A tap on a video means play it.
    @Test("a video tile plays and a photo tile opens the viewer — over the card's own geometry")
    func videoPlaysAndPhotoOpens() {
        var attachments = photos([(3, 2), (16, 9), (3, 2)])
        attachments[1].mime = "video/quicktime"
        attachments[1].webURL = URL(string: "https://memos.example.invalid/w.mp4")
        let tiles = measuredTiles(of: attachments)
        #expect(tiles.count == 3)

        func tapped(_ tile: MemoCardTap.Tile) -> MemoCardTap.Destination {
            MemoCardTap.destination(
                at: CGPoint(x: tile.frame.midX, y: tile.frame.midY), tiles: tiles
            )
        }
        for tile in tiles {
            if tile.uid == "a2" {
                #expect(
                    tapped(tile) == .playback(uid: "a2"),
                    "a video tile did not route as the tap that plays"
                )
            } else {
                #expect(
                    tapped(tile) == .attachment(uid: tile.uid),
                    "a photo tile started playing something"
                )
            }
        }
        // And the two are genuinely different answers, not two spellings of one.
        #expect(MemoCardTap.Destination.playback(uid: "a2") != .attachment(uid: "a2"))
    }

    /// Which attachments that routing applies to, case by case. A video with nothing streamable
    /// has nothing to play, so it falls back to the viewer, where its poster is at least something.
    @Test("only a video with a streamable rendition plays on tap")
    func playsIsAboutTheStream() {
        let playable = MemoAttachment(
            uid: "v1",
            mime: "video/quicktime",
            status: .ready,
            webURL: URL(string: "https://memos.example.invalid/w.mp4"),
            posterURL: URL(string: "https://memos.example.invalid/p")
        )
        let unstreamable = MemoAttachment(
            uid: "v2",
            mime: "video/quicktime",
            status: .ready,
            posterURL: URL(string: "https://memos.example.invalid/p")
        )
        let photo = MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            thumbnailURL: URL(string: "https://memos.example.invalid/t")
        )
        #expect(MemoCardTap.plays(playable))
        #expect(!MemoCardTap.plays(unstreamable))
        #expect(!MemoCardTap.plays(photo))
    }

    /// The other half of the rule, and the half that must NOT change: inside the viewer a video
    /// page reached by swiping keeps its poster and its play button. Autoplaying something
    /// somebody swiped past is the surprising thing there, and the page still carries both the
    /// still it shows and the stream it waits to be asked for.
    @Test("a video page inside the viewer still waits to be asked")
    func inViewerVideoStillWaits() {
        let video = MemoAttachment(
            uid: "v1",
            mime: "video/quicktime",
            status: .ready,
            thumbnailURL: URL(string: "https://memos.example.invalid/t"),
            webURL: URL(string: "https://memos.example.invalid/w.mp4"),
            posterURL: URL(string: "https://memos.example.invalid/p")
        )
        let pages = MediaViewerPresentation.pages(for: [video])
        #expect(pages.count == 1)
        #expect(pages[0].kind == .video)
        #expect(pages[0].stillURL != nil, "the page lost the poster it shows until it is tapped")
        #expect(pages[0].playbackURL != nil)
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

    /// The page's own sizing, measured where it can be seen: a picture is drawn at ITS shape
    /// inside the screen, not stretched over the whole of it.
    ///
    /// Measuring the viewer's outer frame proved nothing — the black backdrop fills that frame
    /// whatever the pager does. What is load-bearing is the band the picture occupies, so that is
    /// what is counted: a 4:3 photo on a 390x844 screen is 292 rows of picture with black above
    /// and below it. Drop the fitted frame and the blur floods the screen; drop the outer frame
    /// and the band moves off centre.
    @Test("a page draws the picture at its own shape, not stretched over the screen")
    func pictureIsDrawnAtItsOwnShape() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        var attachment = MediaViewerPageTests.image("a1", width: 4000, height: 3000)
        attachment.blurhash = Self.flatGreenHash
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)

        let viewport = CGSize(width: 390, height: 844)
        let grid = try #require(
            PixelGrid.of(
                MediaViewerPage(page: page, onHoldsChange: { _ in }, player: nil, play: {})
                    .background(.black),
                size: viewport
            )
        )
        let middleColumn = Int(viewport.width) / 2
        let column = grid.map { $0[middleColumn] }
        let band = column.filter { isBlur($0) }.count
        let fitted = MediaZoom.fittedSize(aspectRatio: 4.0 / 3.0, in: viewport)

        #expect(
            abs(Double(band) - fitted.height) <= 4,
            "the picture covers \(band) rows, expected about \(fitted.height)"
        )
        #expect(isBlur(grid[Int(viewport.height) / 2][middleColumn]), "no picture in the middle")
        #expect(!isBlur(grid[8][middleColumn]), "the picture reached the top of the screen")
        #expect(
            !isBlur(grid[Int(viewport.height) - 8][middleColumn]),
            "the picture reached the bottom of the screen"
        )
    }

    /// Flat `#3E7C4F` in every pixel, so any picture that shows is unmistakable.
    private static let flatGreenHash = "007Da1"

    private func isBlur(_ pixel: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        abs(Int(pixel.r) - 0x3E) <= 24 && abs(Int(pixel.g) - 0x7C) <= 24
            && abs(Int(pixel.b) - 0x4F) <= 24
    }
}

/// What a page does before it asks the network for its picture.
///
/// Driven through the page's REAL appearance path — hosted in a window, its own `task` — because
/// the rule only holds if the wiring holds: calling `MediaCache.evictExpired` from a test proves
/// the cache helper works, not that anything ever calls it.
@MainActor
@Suite("Viewer loading")
struct MediaViewerLoadingTests {
    @Test("a page drops a lapsed signature before it asks for the picture")
    func lapsedEntryIsEvictedOnAppear() async throws {
        // Long past whatever clock the simulator runs on: the page evicts against `Date()`.
        let lapsed = 1_700_000_000
        var attachment = MediaViewerPageTests.image("evict1")
        attachment.previewURL = MediaViewerPageTests.url("evict1", "mobile", exp: lapsed)
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)
        let url = try #require(page.stillURL)

        // A cache of this test's OWN, handed to the page, and memory-only so nothing outlives the
        // run. Seeding the default instead — a process-wide singleton — made the result depend on
        // which cache the composition root won at launch, on whatever else in the bundle was
        // touching that singleton in parallel, and on whether `AsyncImage`'s load raced the task.
        // None of those can reach a cache nobody else holds a reference to, so a failure here now
        // means the page did not evict, which is the only thing this test is for. What keeps the
        // page's DEFAULT honest is the test below.
        let cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
        let request = URLRequest(url: url)
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/jpeg"]
            )
        )
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data([0xFF, 0xD8, 0xFF, 0xE0])),
            for: request
        )
        // The entry really is there before the page appears — otherwise this asserts nothing.
        #expect(cache.cachedResponse(for: request) != nil)

        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(
            rootView: MediaViewerPage(
                page: page, onHoldsChange: { _ in }, player: nil, play: {}, cache: cache
            )
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        var dropped = false
        for _ in 0..<60 where !dropped {
            try await Task.sleep(for: .milliseconds(50))
            dropped = cache.cachedResponse(for: request) == nil
        }
        window.isHidden = true
        #expect(dropped, "the page never dropped the entry whose signature had lapsed")
    }

    /// What the test above deliberately steps around: the cache a page reaches for when nobody
    /// hands it one, and whether evicting from it means anything.
    ///
    /// This is the defect MEMNG-147 closed, stated as the property that closes it. The still used
    /// to be an `AsyncImage`, which fetches through `URLSession.shared` — a session that binds
    /// whatever `URLCache.shared` was the first time anything in the process touched it. So the
    /// cache being evicted from and the cache being read were one object only on a launch the
    /// composition root happened to win, and on any other one a lapsed signature went on being
    /// served out of a cache nothing had evicted from.
    ///
    /// Asserted by IDENTITY rather than by storing and looking. The media session's cache is
    /// disk-backed, and `storeCachedResponse` on a disk-backed `URLCache` lands asynchronously —
    /// a seed-then-read test of it is a timing test wearing a correctness test's clothes, which
    /// is the thing this whole rework is removing. Identity has no timing.
    @Test("the cache a page evicts from is the cache its still is fetched through")
    func stillFetchAndEvictionNameOneCache() throws {
        var attachment = MediaViewerPageTests.image("evict-default")
        attachment.previewURL = MediaViewerPageTests.url("evict-default", "mobile")
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)

        // The defaults the memberwise initialiser applies — production passes neither.
        let unconfigured = MediaViewerPage(
            page: page, onHoldsChange: { _ in }, player: nil, play: {}
        )
        let media = try #require(
            unconfigured.transport as? MediaSession,
            "the still must be fetched through a session this app built, not URLSession.shared"
        )

        // The one assertion the whole ticket is: the object the fetch reads is the object the
        // eviction writes to. Not two caches that resemble each other, and not two singletons
        // that ought to agree — one `URLCache`.
        #expect(media.session.configuration.urlCache === unconfigured.cache)
        #expect(unconfigured.cache === MediaSession.shared.cache)
    }

    /// And that the page really does fetch through that seam.
    ///
    /// The test above pins two defaults to one object; this one pins the CODE to those defaults.
    /// A page handed a transport of its own is watched being asked for exactly the still's URL —
    /// which is what `AsyncImage` never did and could not be made to do, and is therefore the
    /// assertion that goes red if the still is ever routed back through `URLSession.shared`.
    @Test("a page asks its own transport for the still, and asks it for the still's URL")
    func theStillGoesThroughThePagesTransport() async throws {
        let attachment = MediaViewerPageTests.image("still-route")
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)
        let url = try #require(page.stillURL)
        // A hit in the decoded-image store would be answered without a fetch, and this test would
        // then be asserting nothing. Nothing else in the bundle uses this uid.
        #expect(
            MediaImageLoader.cachedUIImage(for: page.stillKey) == nil,
            "something warmed this key — the fetch below would not happen"
        )

        let recorder = RecordingTransport()
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844)))
        window.rootViewController = UIHostingController(
            rootView: MediaViewerPage(
                page: page,
                onHoldsChange: { _ in },
                player: nil,
                play: {},
                cache: URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil),
                transport: recorder
            )
        )
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        var asked: [URL] = []
        for _ in 0..<60 where asked.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            asked = await recorder.requested
        }
        window.isHidden = true
        #expect(
            asked.first == url,
            "the page did not fetch its still through the transport it was handed: \(asked)"
        )
    }
}

/// A transport that answers nothing and remembers what it was asked for.
///
/// `RefusingTransport` next door counts calls; what is load-bearing here is WHICH url was asked
/// for, because that is what distinguishes the still's own fetch from anything else a hosted page
/// might do. Refusing rather than answering keeps the test to one fact: a picture that decoded
/// would drag the decode, the store and the identity clock into an assertion about routing.
actor RecordingTransport: MediaTransport {
    private(set) var requested: [URL] = []

    func fetch(_ request: URLRequest, under authority: SendAuthority) async throws
        -> (Data, URLResponse)
    {
        if let url = request.url { requested.append(url) }
        throw URLError(.notConnectedToInternet)
    }
}

/// The cross-identity fence as the full-screen viewer meets it, rather than as the loader's own
/// tests call it: a page asked for a photograph while one account was signed in, answered after the
/// device has become somebody else, with a page for the SAME photo already on screen by then.
///
/// It belongs to `MediaImageLoaderTests` and not to a suite of its own for the reason that suite
/// exists: the decoded store is process-wide, that suite installs one of its own per test against
/// its own identity clock, and it is `.serialized`, so exactly one installed store is in force
/// while a hosted page reaches it.
extension MediaImageLoaderTests {
    @Test("a page opened after an identity change keeps its picture when the old answer lands")
    func aHostedPageIsNotRepaintedByThePreviousIdentitysAnswer() async throws {
        let attachment = MediaViewerPageTests.image("hosted-rotation")
        let page = try #require(MediaViewerPresentation.pages(for: [attachment]).first)
        let key = page.stillKey
        // A hit would be answered without going near a transport, and nothing below would race.
        #expect(
            MediaImageLoader.cachedUIImage(for: key) == nil,
            "something warmed this key — the fetch this case parks would never happen"
        )

        func host(_ transport: any MediaTransport) -> UIWindow {
            let cache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
            let window = UIWindow(
                frame: CGRect(origin: .zero, size: CGSize(width: 390, height: 844))
            )
            window.rootViewController = UIHostingController(
                rootView: MediaViewerPage(
                    page: page,
                    onHoldsChange: { _ in },
                    player: nil,
                    play: {},
                    cache: cache,
                    transport: transport
                )
            )
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            return window
        }

        // The photograph the reader opened before signing out, parked on the wire.
        let previous = GatedTransport(payload: MediaFixture.png(.red))
        let leaving = host(previous)
        await previous.waitUntilStarted()

        // The device becomes somebody else, and the same photograph is opened again. A uid is
        // unique only within one server, which is why both pages name one key.
        identity.rotate()
        let arriving = host(ScriptedTransport(payload: MediaFixture.png(.blue)))

        var standing: UIImage?
        for _ in 0..<60 where standing == nil {
            try await Task.sleep(for: .milliseconds(50))
            standing = MediaImageLoader.cachedUIImage(for: key)
        }
        let painted = try #require(standing, "the page opened after the change never painted")

        // Only now does the page that was left behind get its answer.
        await previous.release()
        var replaced = false
        for _ in 0..<40 where !replaced {
            try await Task.sleep(for: .milliseconds(50))
            replaced = MediaImageLoader.cachedUIImage(for: key) !== painted
        }
        leaving.isHidden = true
        arriving.isHidden = true
        #expect(!replaced, "the previous identity's answer replaced the picture on screen")

        // And the parked request really did carry the identity it started in — the stamp is what
        // files its bytes where this identity will never name them.
        let sent = try #require(await previous.requests.first)
        let stamp = try #require(MediaFetchGeneration.generation(of: sent))
        #expect(stamp != identity.generation, "the page's still was stamped when it landed")
    }
}
