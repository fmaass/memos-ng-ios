import CoreGraphics
import MemosCore
import SwiftUI
import UIKit

/// The BlurHash on an attachment, as something SwiftUI can paint.
///
/// Decoding is done at a deliberately tiny resolution — the result is stretched over the tile and
/// smoothed by the interpolator, which is exactly what a blur is.
///
/// It happens OFF the main actor. For a well-formed hash the arithmetic is small, but the string
/// comes from the server and the size it asks for is its own to choose, so the work does not
/// belong on the thread that is drawing. A tile shows its plain fill until the decode lands, and
/// a hash already decoded is answered synchronously from the cache so a tile scrolled back into
/// view does not flash.
///
/// The cache is keyed by hash, not by attachment: the same hash on two screens is the same
/// picture, and re-deriving it per row is how a scroll drops frames.
public enum BlurHashImage {
    nonisolated static let decodeWidth = 32
    nonisolated static let decodeHeight = 24

    private static let cache = NSCache<NSString, UIImage>()

    /// What has already been decoded, if anything. The common case once a tile has been seen,
    /// and it must not cost a frame to answer.
    public static func cached(for hash: String?) -> Image? {
        guard let hash, !hash.isEmpty else { return nil }
        return cache.object(forKey: hash as NSString).map(Image.init(uiImage:))
    }

    /// `nil` for a missing or malformed hash — callers fall back to a plain fill rather than
    /// showing nothing at all.
    public static func image(for hash: String?) async -> Image? {
        guard let uiImage = await uiImage(for: hash) else { return nil }
        return Image(uiImage: uiImage)
    }

    static func uiImage(for hash: String?) async -> UIImage? {
        guard let hash, !hash.isEmpty else { return nil }
        let key = hash as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let decoded = await Task.detached(priority: .utility) { decode(hash) }.value
        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    /// The part that runs off the main actor. `nonisolated` is the point of it, not a detail.
    nonisolated static func decode(_ hash: String) -> UIImage? {
        guard let pixels = BlurHash.decode(hash, width: decodeWidth, height: decodeHeight)
        else { return nil }
        return makeImage(pixels: pixels, width: decodeWidth, height: decodeHeight)
    }

    nonisolated private static func makeImage(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> UIImage? {
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

    @State private var decoded: Image?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image = decoded ?? BlurHashImage.cached(for: blurhash) {
                image
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            }
        }
        .task(id: blurhash) {
            decoded = await BlurHashImage.image(for: blurhash)
        }
    }
}
