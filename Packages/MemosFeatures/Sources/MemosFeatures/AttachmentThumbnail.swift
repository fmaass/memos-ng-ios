import MemosCore
import SwiftUI

/// Which of the three things a tile can be showing. Named separately from the loader so a stalled
/// load can be rendered and asserted without a network.
public enum ThumbnailPhase: Equatable, Sendable {
    case loading
    case loaded
    case failed
}

/// One attachment in the timeline.
///
/// The photo comes from `MediaImageLoader`, which is the whole point of this view's shape. A
/// `List` builds a fresh `AttachmentThumbnail` every time a row scrolls back, so the tile is asked
/// for its picture again and again — and with `AsyncImage` each of those started at "no image" and
/// flashed the blurhash before the photo reappeared, when it did not go back to the server for it.
/// Here
/// `MediaImageLoader.cached(for:)` is read in `body`, synchronously: a remounted row that has been
/// seen before paints the decoded photo in the very frame it appears in, and never enters
/// `.loading` at all.
///
/// A tile that has NOT been seen keeps the old sequence exactly: blurhash first, photo when it
/// lands. Underneath every tile, always, is the attachment's own BlurHash — the picture's colours,
/// in the picture's shape, not a spinner and not a grey box that reflows the timeline.
///
/// The signature is still enforced here: an entry whose signed URL has lapsed can only be stale,
/// so it is dropped from the media cache before the fetch (`MediaCache.evictExpired`).
struct AttachmentThumbnail: View {
    let attachment: MemoAttachment
    var tier: MediaTier = .thumb
    /// The shape of the slot and how much of the picture goes in it. The container takes this
    /// shape immediately, from the server's own measurements, so the layout does not jump when
    /// the image lands — and the blurhash underneath gets that identical frame.
    var slot: AttachmentSlot

    /// What THIS view instance loaded, tagged with the key it was loaded for. The tag is not
    /// bookkeeping: a tile whose attachment or tier changes under it would otherwise keep painting
    /// the previous photo until the new one arrived, which is the one wrong picture a cache is
    /// able to show.
    @State private var loaded: (key: MediaImageKey, image: Image)?
    /// The key whose load came back with nothing. Also tagged, for the same reason.
    @State private var failedKey: MediaImageKey?

    private var url: URL? { MemoPresentation.url(for: attachment, tier: tier) }
    private var key: MediaImageKey { MediaImageLoader.key(for: attachment, tier: tier) }

    /// Read in `body`, and synchronous on both paths. The cache lookup is what makes a scroll-back
    /// free; `loaded` is only how an async arrival gets a frame to be drawn in.
    private var image: Image? {
        if let loaded, loaded.key == key { return loaded.image }
        return MediaImageLoader.cached(for: key)
    }

    private var phase: ThumbnailPhase {
        if image != nil { return .loaded }
        if url == nil || failedKey == key { return .failed }
        return .loading
    }

    var body: some View {
        Color.clear
            .aspectRatio(slot.aspectRatio, contentMode: .fit)
            .overlay {
                ThumbnailContent(
                    attachment: attachment,
                    phase: phase,
                    image: image,
                    contentMode: slot.contentMode
                )
            }
            .task(id: url) { await load() }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
    }

    private func load() async {
        guard let url else { return }
        MediaCache.evictExpired(url)
        // Already decoded: `body` has painted it already, and there is nothing to fetch, nothing
        // to decode and no state to change.
        if MediaImageLoader.cached(for: key) != nil { return }

        // Captured before the await: the view can be handed a different attachment while the
        // fetch is in flight, and the answer belongs to the key it was asked for.
        let requested = key
        let image = await MediaImageLoader.image(for: requested, url: url)
        if let image {
            loaded = (requested, image)
            if failedKey == requested { failedKey = nil }
        } else {
            failedKey = requested
        }
    }
}

/// A layer pinned to the slot it was given, however it draws inside it.
///
/// `scaledToFill` reports the oversized dimensions it drew, not the space it was offered: a 4:3
/// image asked to fill a 120x160 slot answers 213x160. Two such layers in one `ZStack` therefore
/// grow the stack to the larger of them and centre each inside it — so a blurhash (always 4:3
/// from a 32x24 decode) and a photo of some other shape ended up centred in different boxes, and
/// the blur sat visibly beside the picture it was supposed to be under.
///
/// `Color.clear` accepts whatever it is offered and reports exactly that, so putting the filled
/// content in its overlay keeps the reported size equal to the slot. Every layer of a tile goes
/// through here, which is what pins them all to one frame.
struct AspectPinnedLayer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Color.clear
            .overlay { content }
            .clipped()
    }
}

/// The tile itself, with the load phase handed IN rather than fetched — so what a stalled load
/// looks like can be rendered and asserted without a network.
struct ThumbnailContent: View {
    let attachment: MemoAttachment
    let phase: ThumbnailPhase
    let image: Image?
    /// `fill` crops to the slot, `fit` shows the whole picture inside it. The BACKDROP always
    /// fills whichever way this goes: when a fitted picture does not reach the edges, the blur is
    /// what should be behind it, not a grey bar.
    var contentMode: TileContentMode = .fill

    var body: some View {
        ZStack {
            BlurHashBackdrop(blurhash: attachment.blurhash)
            if phase == .loaded, let image {
                AspectPinnedLayer {
                    if contentMode == .fit {
                        image.resizable().scaledToFit()
                    } else {
                        image.resizable().scaledToFill()
                    }
                }
            }
            if phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            if attachment.isVideo && phase != .failed {
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
            }
        }
        .clipped()
    }
}
