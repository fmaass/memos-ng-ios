import Foundation
import MemosCore
import SwiftUI
import Testing

@testable import MemosFeatures

/// The blurhash was already in every attachment payload and was thrown away. These tests are what
/// says it reaches the screen: one renders a tile whose image has NOT arrived and reads the pixel
/// back, which is the only way to tell a painted placeholder from a grey box.
@MainActor
@Suite("Thumbnails")
struct ThumbnailTests {
    /// `007Da1` carries one component in each direction, so it decodes to exactly one colour —
    /// `#3E7C4F` — in every pixel. That makes the expected pixel a number, not a judgement.
    private static let flatGreenHash = "007Da1"

    @Test("a tile whose image has not arrived is painted with the picture's own colour")
    func stalledLoadingShowsTheDecodedBlurhash() async throws {
        // The decode runs off the main actor now, so it is awaited here exactly as the tile's own
        // `.task` awaits it. What is asserted is unchanged: once the placeholder exists, it is
        // what a tile with no image on it paints.
        #expect(await BlurHashImage.image(for: Self.flatGreenHash) != nil)
        let view = ThumbnailContent(
            attachment: MemoFixture.attachment(blurhash: Self.flatGreenHash),
            phase: .loading,
            image: nil
        )
        let pixel = try #require(
            PixelProbe.centre(of: view, size: CGSize(width: 40, height: 40)),
            "the tile rendered nothing at all"
        )
        #expect(abs(Int(pixel.r) - 0x3E) <= 8, "red was \(pixel.r)")
        #expect(abs(Int(pixel.g) - 0x7C) <= 8, "green was \(pixel.g)")
        #expect(abs(Int(pixel.b) - 0x4F) <= 8, "blue was \(pixel.b)")
    }

    /// The control for the test above: without a hash the same tile paints something else
    /// entirely, so the green in that test came from the decode and not from the tile's own fill.
    @Test("a tile with no blurhash falls back to a plain fill")
    func withoutABlurhashItIsNotGreen() throws {
        let view = ThumbnailContent(
            attachment: MemoFixture.attachment(blurhash: nil),
            phase: .loading,
            image: nil
        )
        let pixel = try #require(PixelProbe.centre(of: view, size: CGSize(width: 40, height: 40)))
        let isTheGreen =
            abs(Int(pixel.r) - 0x3E) <= 8 && abs(Int(pixel.g) - 0x7C) <= 8
            && abs(Int(pixel.b) - 0x4F) <= 8
        #expect(!isTheGreen, "the fallback fill painted the blurhash colour: \(pixel)")
    }

    @Test("a malformed blurhash is a plain fill, not a crash")
    func malformedBlurhashDoesNotCrash() async {
        #expect(await BlurHashImage.image(for: "not-a-blurhash") == nil)
        #expect(await BlurHashImage.image(for: "") == nil)
        #expect(await BlurHashImage.image(for: nil) == nil)
        #expect(await BlurHashImage.image(for: String(repeating: "L", count: 8_000_000)) == nil)
        #expect(await BlurHashImage.image(for: Self.flatGreenHash) != nil)
    }

    @Test("a decoded blurhash is derived once and reused")
    func decodesAreCached() async throws {
        let first = try #require(await BlurHashImage.uiImage(for: Self.flatGreenHash))
        let second = try #require(await BlurHashImage.uiImage(for: Self.flatGreenHash))
        #expect(first === second)
    }

    /// The synchronous path a view body takes. Nothing is cached until the off-main decode has
    /// finished, and everything is afterwards — which is what keeps a tile scrolled back into
    /// view from flashing its plain fill again.
    @Test("a hash is answered synchronously only after it has been decoded")
    func theCacheIsTheSynchronousPath() async {
        // Its own hash, so no other test in this suite can have warmed it first.
        let hash = "001{~h"
        #expect(BlurHashImage.cached(for: hash) == nil)
        #expect(await BlurHashImage.image(for: hash) != nil)
        #expect(BlurHashImage.cached(for: hash) != nil)
        #expect(BlurHashImage.cached(for: nil) == nil)
    }

}

@MainActor
@Suite("Picked media thumbnails")
struct PickedThumbnailSourceTests {
    @Test("a video is recognised from its mime type, whatever the container")
    func videoDetection() {
        #expect(PickedThumbnailSource.isVideo(mime: "video/quicktime"))
        #expect(PickedThumbnailSource.isVideo(mime: "video/mp4"))
        #expect(!PickedThumbnailSource.isVideo(mime: "image/heic"))
        #expect(!PickedThumbnailSource.isVideo(mime: "application/octet-stream"))
    }

    /// ImageIO reads a maximum pixel size of 0 as "no limit" and decodes the full image, so the
    /// budget is never allowed to round down to nothing.
    @Test("the decode budget is whole pixels and never zero")
    func pixelBudget() {
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 72, scale: 3) == 216)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 72, scale: 2) == 144)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 0.2, scale: 1) == 1)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 72, scale: 0) == 72)
        #expect(PickedThumbnailSource.maxPixelSize(forPointSize: 0, scale: 3) == 1)
    }

    @Test("a file that is not an image yields no thumbnail rather than a broken one")
    func unreadableFile() throws {
        let url = URL.temporaryDirectory.appending(path: "not-an-image-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PickedThumbnailSource.thumbnail(at: url, maxPixelSize: 64) == nil)
    }
}
