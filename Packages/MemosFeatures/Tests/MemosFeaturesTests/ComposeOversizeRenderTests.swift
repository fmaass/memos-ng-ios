import Foundation
import SwiftUI
import Testing

@testable import MemosFeatures

/// The compose tile of a file larger than the server's `max_bytes` says so with both sizes
/// (MEMNG-956), read back from the row as it is drawn on a screen.
@MainActor
@Suite("Compose tile: a file over the upload limit is captioned with both sizes")
struct ComposeOversizeRenderTests {
    private static let limit: Int64 = 1_000_000_000
    private static let size: Int64 = 1_600_000_000

    private static func tile(size: Int64?) -> ComposeRowItem {
        let media = PickedMedia(
            url: FileManager.default.temporaryDirectory.appending(path: "\(UUID()).mov"),
            filename: "IMG_0001.mov", mime: "video/quicktime", byteSize: size)
        return .picked(ComposeAttachment(media: media, load: .ready, label: "IMG_0001.mov"))
    }

    private static func format(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    @Test("the drawn tile names the file's size and the limit")
    func theCaptionCarriesBothSizes() throws {
        let labels = ScreenProbe.labels(
            of: PickedThumbnailRow(items: [Self.tile(size: Self.size)], maxUploadBytes: Self.limit))

        #expect(labels.contains("1 file attached"), "the probe saw nothing of the row: \(labels)")
        let captioned = labels.first { $0.hasPrefix("IMG_0001.mov") }
        let caption = try #require(captioned, "no tile was drawn: \(labels)")
        #expect(caption.contains(Self.format(Self.size)), "no file size: \(labels)")
        #expect(caption.contains(Self.format(Self.limit)), "no limit: \(labels)")
        #expect(caption.contains(">"), "the sizes are not compared: \(labels)")
    }

    /// The label above is the tile's own `accessibilityLabel`, which states the sizes whether or
    /// not the caption is drawn — so it cannot tell a sighted reader's tile from a blank one. The
    /// caption is the only white the tile paints in its left half: the Remove control sits in the
    /// top-right corner, and the wash under the caption is dark.
    @Test("the sizes are drawn on the tile, not only spoken")
    func theCaptionIsDrawn() throws {
        let captioned = try #require(Self.whitePixelsInLeftHalf(of: Self.size, limit: Self.limit))
        let plain = try #require(Self.whitePixelsInLeftHalf(of: Self.size, limit: nil))
        #expect(captioned > 40, "no caption was drawn: \(captioned) white pixels")
        #expect(plain * 4 < captioned, "white without a caption: \(plain) vs \(captioned)")
    }

    /// Opaque, near-white pixels in the left half of one drawn tile; nil when nothing was drawn.
    private static func whitePixelsInLeftHalf(of size: Int64, limit: Int64?) -> Int? {
        guard case .picked(let attachment) = tile(size: size) else { return nil }
        let renderer = ImageRenderer(
            content: PickedThumbnail(attachment: attachment, size: 120, maxUploadBytes: limit))
        renderer.scale = 2
        guard let image = renderer.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
            image.width > 0, image.height > 0
        else { return nil }
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var white = 0
        for row in 0..<height {
            for column in 0..<(width / 2) {
                let pixel = (row * width + column) * 4
                if bytes[pixel] > 230, bytes[pixel + 1] > 230, bytes[pixel + 2] > 230,
                    bytes[pixel + 3] > 250
                {
                    white += 1
                }
            }
        }
        return white
    }

    @Test("a file at the limit, or with the limit unknown, carries no size caption")
    func noCaptionWhenItFits() {
        for (size, limit) in [(Self.limit, Optional(Self.limit)), (Self.size, nil)] {
            let labels = ScreenProbe.labels(
                of: PickedThumbnailRow(items: [Self.tile(size: size)], maxUploadBytes: limit))

            #expect(labels.contains("1 file attached"), "the probe saw nothing: \(labels)")
            #expect(labels.contains("IMG_0001.mov"), "the plain tile label is missing: \(labels)")
            #expect(!labels.contains { $0.contains(">") }, "a fitting file is captioned: \(labels)")
        }
    }
}
