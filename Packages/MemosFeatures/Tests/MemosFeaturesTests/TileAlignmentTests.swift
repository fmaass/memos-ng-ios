import Foundation
import MemosCore
import SwiftUI
import Testing
import UIKit

@testable import MemosFeatures

/// The blurhash sat beside the photo instead of under it — offset on timeline tiles, and split
/// left-half/right-half on the detail view. The cause was not an alignment setting: `scaledToFill`
/// REPORTS the oversized dimensions it drew, so a 4:3 blurhash asked to fill a 120x160 slot
/// answered 213x160, the `ZStack` grew to the larger of its two children, and each was centred in
/// a different box.
///
/// These are the assertions that hold every layer to the slot it was given. They are worth having
/// as sizes AND as pixels: the size test names the mechanism, and the pixel test states the thing
/// a person would actually notice — that once a photo has loaded, none of the blur shows.
@MainActor
@Suite("Tile layers share one frame")
struct TileAlignmentTests {
    /// Flat `#3E7C4F` in every pixel, so any blur that shows through is unmistakable.
    private static let flatGreenHash = "007Da1"

    private func attachment(width: Int, height: Int) -> MemoAttachment {
        MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            blurhash: Self.flatGreenHash,
            width: width,
            height: height,
            thumbnailURL: URL(string: "https://memos.example.invalid/thumb")
        )
    }

    private func isBlur(_ pixel: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        abs(Int(pixel.r) - 0x3E) <= 24 && abs(Int(pixel.g) - 0x7C) <= 24
            && abs(Int(pixel.b) - 0x4F) <= 24
    }

    /// The mechanism, stated directly: no layer of a tile may report a size other than the one it
    /// was offered. Before the fix the backdrop answered 213.67x160 to a 120x160 proposal.
    @Test("no layer of a tile grows the frame it was given")
    func everyLayerReportsTheSlotItWasOffered() async {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let photo = SolidImage.of(.magenta)
        let slots = [
            CGSize(width: 120, height: 160),
            CGSize(width: 160, height: 120),
            CGSize(width: 120, height: 120),
            CGSize(width: 340, height: 90),
        ]
        let shapes = [(300, 400), (400, 300), (300, 300), (1200, 300)]
        for slot in slots {
            let backdrop = LayoutProbe.size(
                BlurHashBackdrop(blurhash: Self.flatGreenHash),
                width: slot.width,
                height: slot.height
            )
            #expect(
                abs(backdrop.width - slot.width) < 0.5 && abs(backdrop.height - slot.height) < 0.5,
                "backdrop reported \(backdrop) for a slot of \(slot)"
            )
            for (width, height) in shapes {
                let tile = LayoutProbe.size(
                    ThumbnailContent(
                        attachment: attachment(width: width, height: height),
                        phase: .loaded,
                        image: photo
                    ),
                    width: slot.width,
                    height: slot.height
                )
                #expect(
                    abs(tile.width - slot.width) < 0.5 && abs(tile.height - slot.height) < 0.5,
                    "a \(width)x\(height) tile reported \(tile) for a slot of \(slot)"
                )
            }
        }
    }

    /// What a person sees. A loaded photo fills its tile, so after it arrives there is nowhere in
    /// the tile the blur underneath it can still show. Every pixel is checked, not a sample: the
    /// old bug left the blur down one edge, which a centre sample would have walked straight past.
    @Test("a loaded photo covers its blurhash completely, at any shape")
    func aLoadedPhotoLeavesNoBlurShowing() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let photo = SolidImage.of(.magenta)
        for (width, height) in [(300, 400), (400, 300), (300, 300), (1200, 300)] {
            let attachment = attachment(width: width, height: height)
            let tile = ThumbnailContent(attachment: attachment, phase: .loaded, image: photo)
            let pixels = try #require(
                PixelGrid.of(tile, size: CGSize(width: 120, height: 120)),
                "the tile rendered nothing"
            )
            let showing = pixels.flatMap { $0 }.filter(isBlur).count
            #expect(showing == 0, "\(width)x\(height): blur visible in \(showing) pixels")
        }
    }

    /// The positive control for the test above: with no photo yet, the blur IS what fills the
    /// tile. Without this, painting the backdrop black would pass "no blur is showing".
    @Test("before the photo arrives the blurhash fills the tile")
    func theBlurhashFillsTheTileWhileLoading() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let tile = ThumbnailContent(
            attachment: attachment(width: 400, height: 300),
            phase: .loading,
            image: nil
        )
        let pixels = try #require(PixelGrid.of(tile, size: CGSize(width: 120, height: 120)))
        let flat = pixels.flatMap { $0 }
        let showing = flat.filter(isBlur).count
        #expect(showing > flat.count * 9 / 10, "blur covered only \(showing) of \(flat.count)")
    }
}

/// The detail view is the picture, not a tile of it. The user's rule for that surface is simple:
/// the whole frame is visible, in the proportions the server measured, and nothing is cut off.
///
/// The case worth asserting is the one where the slot and the picture DISAGREE — an attachment the
/// server never measured, so the container falls back to 4:3 while the photo is tall. Cropping
/// would throw most of that photo away. Fitting shows all of it and leaves bars, and the bars are
/// where the blurhash finally earns its place: they are blurred picture, not grey.
@MainActor
@Suite("The detail view shows the whole picture")
struct DetailFitTests {
    private static let flatGreenHash = "007Da1"

    private func isBlur(_ pixel: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        abs(Int(pixel.r) - 0x3E) <= 24 && abs(Int(pixel.g) - 0x7C) <= 24
            && abs(Int(pixel.b) - 0x4F) <= 24
    }

    private func isPhoto(_ pixel: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        pixel.r > 180 && pixel.g < 80 && pixel.b > 180
    }

    /// No width or height from the server, so the slot is the 4:3 fallback while the picture is
    /// 1:4. Fitted, all of it survives as a narrow column; filled, almost all of it is gone.
    @Test("a picture that disagrees with its slot is letterboxed, not cropped")
    func fitKeepsTheWholePicture() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let tallPhoto = SolidImage.of(.magenta, size: CGSize(width: 20, height: 80))
        let unmeasured = MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            blurhash: Self.flatGreenHash,
            previewURL: URL(string: "https://memos.example.invalid/mobile")
        )
        let slot = MemoPresentation.detailSlot(for: unmeasured)
        #expect(slot.contentMode == .fit)

        let frame = CGSize(width: 120, height: 90)
        let fitted = try #require(
            PixelGrid.of(
                ThumbnailContent(
                    attachment: unmeasured, phase: .loaded, image: tallPhoto,
                    contentMode: slot.contentMode
                ),
                size: frame
            )
        )
        let filled = try #require(
            PixelGrid.of(
                ThumbnailContent(
                    attachment: unmeasured, phase: .loaded, image: tallPhoto, contentMode: .fill
                ),
                size: frame
            )
        )

        let middleRow = fitted[fitted.count / 2]
        // The whole picture is on screen, and it does not reach the edges — that is what "fitted"
        // looks like when the slot is a different shape.
        #expect(middleRow.contains(where: isPhoto), "the photo did not render at all")
        #expect(!isPhoto(middleRow[0]), "the photo was cropped to the left edge")
        #expect(!isPhoto(middleRow[middleRow.count - 1]), "the photo was cropped to the right edge")
        // The bars beside it are the blurhash, not a grey gap.
        #expect(isBlur(middleRow[0]), "the left bar is not the blurhash")
        #expect(isBlur(middleRow[middleRow.count - 1]), "the right bar is not the blurhash")

        // The control: the SAME content told to fill does reach both edges, so the two modes
        // genuinely differ and the assertions above are about `fit` rather than about the photo.
        let filledMiddle = filled[filled.count / 2]
        #expect(isPhoto(filledMiddle[0]))
        #expect(isPhoto(filledMiddle[filledMiddle.count - 1]))
    }

    /// A picture whose slot matches it fills that slot exactly — fitted or not, nothing is lost
    /// and nothing is bordered.
    @Test("a measured picture fills its own slot edge to edge")
    func aMeasuredPictureNeedsNoBars() async throws {
        _ = await BlurHashImage.image(for: Self.flatGreenHash)
        let photo = SolidImage.of(.magenta, size: CGSize(width: 40, height: 30))
        let measured = MemoAttachment(
            uid: "a1",
            mime: "image/jpeg",
            status: .ready,
            blurhash: Self.flatGreenHash,
            width: 4000,
            height: 3000,
            previewURL: URL(string: "https://memos.example.invalid/mobile")
        )
        let slot = MemoPresentation.detailSlot(for: measured)
        #expect(abs(slot.aspectRatio - 4.0 / 3.0) < 0.0001)
        let pixels = try #require(
            PixelGrid.of(
                ThumbnailContent(
                    attachment: measured, phase: .loaded, image: photo,
                    contentMode: slot.contentMode
                ),
                size: CGSize(width: 120, height: 90)
            )
        )
        let showing = pixels.flatMap { $0 }.filter(isBlur).count
        #expect(showing == 0, "blur visible in \(showing) pixels of a correctly measured photo")
    }
}
