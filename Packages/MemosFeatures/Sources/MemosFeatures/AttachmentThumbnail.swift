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
    /// The shape of the SLOT. `nil` keeps the photo's own proportions — right for a memo with one
    /// photo, where the picture decides the shape of the card. A value crops to a fixed slot,
    /// which is what a row of tiles needs to line up at all.
    var aspectRatio: Double?

    private var url: URL? { MemoPresentation.url(for: attachment, tier: tier) }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio ?? attachment.aspectRatio, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        ThumbnailContent(
                            attachment: attachment,
                            phase: .of(phase),
                            image: phase.image
                        )
                    }
                } else {
                    ThumbnailContent(attachment: attachment, phase: .failed, image: nil)
                }
            }
            .task(id: url) {
                if let url { MediaCache.evictExpired(url) }
            }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
    }
}

/// The tile itself, with the load phase handed IN rather than fetched — so what a stalled load
/// looks like can be rendered and asserted without a network.
struct ThumbnailContent: View {
    let attachment: MemoAttachment
    let phase: ThumbnailPhase
    let image: Image?

    var body: some View {
        ZStack {
            BlurHashBackdrop(blurhash: attachment.blurhash)
            if phase == .loaded, let image {
                image.resizable().scaledToFill()
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
