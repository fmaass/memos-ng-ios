import CoreGraphics
import MemosCore
import SwiftUI
import UIKit

/// The BlurHash on an attachment, as something SwiftUI can paint.
///
/// Decoding is done at a deliberately tiny resolution — the result is stretched over the tile and
/// smoothed by the interpolator, which is exactly what a blur is. That keeps the work small enough
/// to do inline while a view body is being built: at 32x24 it is a few tens of thousands of
/// multiply-adds over a handful of cosine terms.
///
/// The cache is keyed by hash, not by attachment: the same hash on two screens is the same
/// picture, and re-deriving it per row is how a scroll drops frames.
public enum BlurHashImage {
    static let decodeWidth = 32
    static let decodeHeight = 24

    private static let cache = NSCache<NSString, UIImage>()

    /// `nil` for a missing or malformed hash — callers fall back to a plain fill rather than
    /// showing nothing at all.
    public static func image(for hash: String?) -> Image? {
        guard let uiImage = uiImage(for: hash) else { return nil }
        return Image(uiImage: uiImage)
    }

    static func uiImage(for hash: String?) -> UIImage? {
        guard let hash, !hash.isEmpty else { return nil }
        let key = hash as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard
            let pixels = BlurHash.decode(hash, width: decodeWidth, height: decodeHeight),
            let rendered = makeImage(pixels: pixels, width: decodeWidth, height: decodeHeight)
        else { return nil }
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    private static func makeImage(pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        // sRGB explicitly: the decoded bytes ARE sRGB, and letting the device colour space stand
        // in for that is how a green placeholder turns up a shade off the photo it precedes.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard
            let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: info,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// What sits under every thumbnail: the picture's own colours, before the picture arrives.
///
/// This is the reason the timeline stops flashing grey rectangles. The blurhash was already in
/// every attachment payload; until this phase it was fetched and thrown away.
struct BlurHashBackdrop: View {
    let blurhash: String?

    var body: some View {
        if let image = BlurHashImage.image(for: blurhash) {
            image
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}
