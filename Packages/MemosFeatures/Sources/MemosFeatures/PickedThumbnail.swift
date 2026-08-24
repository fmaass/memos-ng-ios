import ImageIO
import MemosCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reading a small picture out of a big file, off the main thread.
///
/// `nonisolated`: this is file work, and the package is main-actor by default. ImageIO is asked
/// for a THUMBNAIL rather than the image — a photo out of a modern camera is 4000 pixels wide and
/// decoding one to draw it 72 points across is how a picker row stutters.
nonisolated enum PickedThumbnailSource {
    static func isVideo(mime: String) -> Bool { mime.hasPrefix("video/") }

    /// The pixel budget for a tile of this many points on this screen. Rounded up to whole pixels
    /// and never zero — ImageIO reads 0 as "no limit" and hands back the full-size image.
    static func maxPixelSize(forPointSize points: CGFloat, scale: CGFloat) -> Int {
        max(1, Int((points * max(scale, 1)).rounded(.up)))
    }

    static func thumbnail(at url: URL, maxPixelSize: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The photos and videos about to be posted, as pictures.
///
/// It replaces the line that read "3 files attached". A count is not a check: the one thing
/// someone wants to know before posting is WHICH three, and only the pictures can say that.
struct PickedThumbnailRow: View {
    let attachments: [PickedMedia]

    @ScaledMetric(relativeTo: .body) private var tile = DesignTokens.Metric.pickedThumbnail

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Space.snug) {
                ForEach(attachments) { media in
                    PickedThumbnail(media: media, size: tile)
                }
            }
        }
        .frame(height: tile)
        .accessibilityLabel(
            attachments.count == 1 ? "1 file attached" : "\(attachments.count) files attached"
        )
    }
}

struct PickedThumbnail: View {
    let media: PickedMedia
    let size: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?

    private var isVideo: Bool { PickedThumbnailSource.isVideo(mime: media.mime) }

    var body: some View {
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: isVideo ? "film" : "photo")
                    .foregroundStyle(.secondary)
            }
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
        .task(id: media.id) {
            guard !isVideo else { return }
            let budget = PickedThumbnailSource.maxPixelSize(
                forPointSize: size, scale: displayScale
            )
            let url = media.url
            let loaded = await Task.detached(priority: .userInitiated) {
                PickedThumbnailSource.thumbnail(at: url, maxPixelSize: budget)
            }.value
            if let loaded { image = Image(uiImage: loaded) }
        }
    }
}
