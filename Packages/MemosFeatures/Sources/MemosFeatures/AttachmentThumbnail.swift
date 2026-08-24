import MemosCore
import SwiftUI

/// Which of the three things a tile can be showing. `AsyncImagePhase` is not `Equatable` and
/// carries the loaded image with it; this is the part a test can name.
public enum ThumbnailPhase: Equatable, Sendable {
    case loading
    case loaded
    case failed

    /// Anything that is not a delivered image or a reported failure is still loading — including
    /// whatever cases a future SwiftUI adds, which must not turn into a warning triangle.
    public static func of(_ phase: AsyncImagePhase) -> ThumbnailPhase {
        switch phase {
        case .success: .loaded
        case .failure: .failed
        default: .loading
        }
    }
}

/// One attachment in the timeline.
///
/// `AsyncImage` loads through `URLSession.shared`, and therefore through the bounded
/// `URLCache.shared` the app installs at launch. How long an entry lives is normally the server's
/// `Cache-Control` decision; what the server cannot express is that the URL's own signature
/// expires, so an entry whose signature has lapsed is evicted here before the image is requested
/// (`MediaCache.evictExpired`).
///
/// Underneath every tile, always, is the attachment's own BlurHash. That is what a tile shows
/// while the photo is in flight: the picture's colours, in the picture's shape — not a spinner,
/// and not a grey box that makes the whole timeline reflow when the image lands.
struct AttachmentThumbnail: View {
    let attachment: MemoAttachment
    var tier: MediaTier = .thumb
    /// The shape of the slot and how much of the picture goes in it. The container takes this
    /// shape immediately, from the server's own measurements, so the layout does not jump when
    /// the image lands — and the blurhash underneath gets that identical frame.
    var slot: AttachmentSlot

    private var url: URL? { MemoPresentation.url(for: attachment, tier: tier) }

    var body: some View {
        Color.clear
            .aspectRatio(slot.aspectRatio, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        ThumbnailContent(
                            attachment: attachment,
                            phase: .of(phase),
                            image: phase.image,
                            contentMode: slot.contentMode
                        )
                    }
                } else {
                    ThumbnailContent(
                        attachment: attachment,
                        phase: .failed,
                        image: nil,
                        contentMode: slot.contentMode
                    )
                }
            }
            .task(id: url) {
                if let url { MediaCache.evictExpired(url) }
            }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
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
