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

/// The memo's pictures, as pictures — what it already has, and what is about to be posted, in the
/// order they will be in.
///
/// It replaces the line that read "3 files attached". A count is not a check: the one thing
/// somebody wants to know before posting is WHICH three, and only the pictures can say that. The
/// ORDER is the second half of the same idea — the row is the order the memo will carry, so the
/// order is something a person can see rather than something they find out afterwards.
struct PickedThumbnailRow: View {
    let items: [ComposeRowItem]
    /// What "Try again" on a failed tile asks for. Only a picked file has one: nothing here can
    /// fail for a picture the memo already has.
    var retry: (UUID) -> Void = { _ in }
    /// What the x on a picked tile asks for. A picked file has not been posted yet, so taking it
    /// off is this sheet's business alone; a picture the memo already has is the server's, and the
    /// existing tiles are not given one.
    var remove: (UUID) -> Void = { _ in }

    @ScaledMetric(relativeTo: .body) private var tile = DesignTokens.Metric.pickedThumbnail

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Space.snug) {
                ForEach(items) { item in
                    switch item {
                    case .existing(let existing):
                        ExistingThumbnail(attachment: existing.attachment, size: tile)
                    case .picked(let attachment):
                        PickedThumbnail(
                            attachment: attachment, size: tile,
                            retry: { retry(attachment.id) },
                            remove: { remove(attachment.id) })
                    }
                }
            }
        }
        .frame(height: tile)
        .accessibilityLabel(
            items.count == 1 ? "1 file attached" : "\(items.count) files attached"
        )
    }
}

/// One picture the memo already has.
///
/// It goes through `AttachmentThumbnail`, the same remote path every other picture in the app is
/// drawn by, so it rides that view's fetch generation fence rather than opening a second way to a
/// photograph. The tile clips itself to the same radius the picked ones use; all this adds is the
/// square the row is built from.
struct ExistingThumbnail: View {
    let attachment: MemoAttachment
    let size: CGFloat

    var body: some View {
        AttachmentThumbnail(attachment: attachment, tier: .thumb, slot: MemoPresentation.gridSlot)
            .frame(width: size, height: size)
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
    var remove: () -> Void = {}

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
        // Over the merged element rather than inside it. A control the tile has already folded
        // into its one element is no longer a control: it is an action on the picture, which is
        // not what a thing you press in the corner of it is.
        .overlay(alignment: .topTrailing) { dropControl }
        .task(id: Self.thumbnailKey(for: attachment)) {
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

    /// Taking this picture off the memo again, before it is posted.
    ///
    /// Nothing is asked first, and what that costs depends on where the picture came from. One
    /// picked from the library is still in the library and can be picked again. A photograph taken
    /// in this app is not: the only copy is the one this sheet is holding, so removing it is the
    /// end of it, and its staged bytes sit in the temporary directory until iOS reclaims them.
    /// It is offered on every picked tile whatever state it is in — an item that is still loading
    /// or that failed to load is exactly the one somebody wants rid of.
    private var dropControl: some View {
        Button("Remove", systemImage: "xmark.circle.fill", action: remove)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .shadow(radius: 4)
            .padding(2)
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

    /// What the tile's own load is keyed on: the FILE, not the item.
    ///
    /// The item's identity deliberately survives a retry — it is the same tile — so keying on it
    /// would leave a recovered item showing the placeholder it had while it was failing. The copy's
    /// url is what actually changes when the picker exports again, and nil (a tile with no file)
    /// starts nothing at all.
    static func thumbnailKey(for attachment: ComposeAttachment) -> URL? { attachment.media?.url }

    /// What a screen reader hears, which never leaves a state to a picture.
    static func accessibilityLabel(for attachment: ComposeAttachment) -> String {
        if let failure = attachment.failure {
            return "\(attachment.label): \(failure.accessibilityLabel). Try again"
        }
        if attachment.isLoading { return "\(attachment.label): loading" }
        return attachment.label
    }
}
