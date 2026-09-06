import AVFoundation
import ImageIO
import MemosCore
import MemosOutbox
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Reading a small picture out of a big file, off the main thread.
///
/// `nonisolated`: this is file work, and the package is main-actor by default. ImageIO is asked for
/// a THUMBNAIL rather than the image — a photo out of a modern camera is 4000 pixels wide and
/// decoding one to draw it 72 points across is how a picker row stutters. A movie is asked for one
/// FRAME, on the same budget, for the same reason.
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

    /// Where in a clip to take the tile's frame from.
    ///
    /// Half a second in, not zero: the first frame of a hand-held clip is the one taken while the
    /// phone was still being raised, and a row of black rectangles says less about what was filmed
    /// than the film glyph it replaced. Clamped to the duration, so a third-of-a-second clip still
    /// yields its own last frame rather than nothing.
    static let framePosition = CMTime(seconds: 0.5, preferredTimescale: 600)

    /// One frame from a movie, at the same pixel budget the photographs get.
    ///
    /// Returns nil for anything that is not a readable movie, which is what leaves the film icon
    /// standing. A failure here is never an error anybody is shown: the tile is already saying
    /// "this is a video", and a clip whose first half-second cannot be decoded is still a clip that
    /// uploads perfectly well.
    static func videoFrame(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        // Half a second either way: an exact-frame request on a long-GOP clip decodes forward from
        // the previous keyframe, which is the expensive thing this tile must not do.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var time = framePosition
        if let duration = try? await asset.load(.duration), duration.isNumeric,
            CMTimeCompare(duration, framePosition) < 0
        {
            time = CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
        }
        guard let image = try? await generator.image(at: time).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The photos and videos about to be posted, as pictures — in the order they will be sent.
///
/// It replaces the line that read "3 files attached". A count is not a check: the one thing
/// somebody wants to know before posting is WHICH three, and only the pictures can say that. The
/// ORDER is the second half of the same idea — the row is the order the memo will carry, so the
/// order is something a person can see rather than something they find out afterwards.
struct PickedThumbnailRow: View {
    let attachments: [ComposeAttachment]
    /// What "Try again" on a failed tile asks for.
    var retry: (UUID) -> Void = { _ in }

    @ScaledMetric(relativeTo: .body) private var tile = DesignTokens.Metric.pickedThumbnail

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Space.snug) {
                ForEach(attachments) { attachment in
                    PickedThumbnail(attachment: attachment, size: tile) { retry(attachment.id) }
                }
            }
        }
        .frame(height: tile)
        .accessibilityLabel(
            attachments.count == 1 ? "1 file attached" : "\(attachments.count) files attached"
        )
    }
}

/// One tile: the file, and what is happening to it.
///
/// Everything the tile says is INLINE, on the tile itself. A modal spinner over the sheet was the
/// alternative and it is the wrong one twice over: it hides the thing it is about, and it makes one
/// slow item look like a whole screen that has stopped. Here the item that is loading is the item
/// that says so, the four others are already there to be looked at, and a failure is a caption with
/// a retry rather than a photograph that quietly did not come.
struct PickedThumbnail: View {
    let attachment: ComposeAttachment
    let size: CGFloat
    var retry: () -> Void = {}

    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?

    private var isVideo: Bool {
        guard let media = attachment.media else { return false }
        return PickedThumbnailSource.isVideo(mime: media.mime)
    }

    var body: some View {
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: isVideo ? "film" : "photo")
                    .foregroundStyle(.secondary)
            }
            if isVideo, image != nil {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            state
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: attachment))
        .task(id: attachment.id) {
            guard let media = attachment.media else { return }
            let budget = PickedThumbnailSource.maxPixelSize(
                forPointSize: size, scale: displayScale
            )
            let url = media.url
            let video = PickedThumbnailSource.isVideo(mime: media.mime)
            // Off the main actor, and cancelled with the tile: a row scrolled away while four
            // clips are decoding is four decodes nobody is waiting for.
            let loaded = await Task.detached(priority: .userInitiated) {
                video
                    ? await PickedThumbnailSource.videoFrame(at: url, maxPixelSize: budget)
                    : PickedThumbnailSource.thumbnail(at: url, maxPixelSize: budget)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded { image = Image(uiImage: loaded) }
        }
    }

    /// The badge in the corner, or the caption across the bottom: whichever this item's state calls
    /// for, and nothing at all when it is simply ready.
    @ViewBuilder
    private var state: some View {
        if let failure = attachment.failure {
            VStack(spacing: 2) {
                Spacer()
                Text(failure.tileLabel)
                    .font(.caption2.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Button("Try again", action: retry)
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.accent)
            }
            .padding(2)
            .frame(width: size, height: size, alignment: .bottom)
            .background(.black.opacity(0.35))
            .foregroundStyle(.white)
        } else if attachment.isLoading {
            ProgressView()
                .controlSize(.small)
                .padding(4)
                .background(.black.opacity(0.35), in: .capsule)
        }
    }

    /// What a screen reader hears, which never leaves a state to a picture.
    static func accessibilityLabel(for attachment: ComposeAttachment) -> String {
        if let failure = attachment.failure {
            return "\(attachment.label): \(failure.accessibilityLabel). Try again"
        }
        if attachment.isLoading { return "\(attachment.label): loading" }
        return attachment.label
    }
}
