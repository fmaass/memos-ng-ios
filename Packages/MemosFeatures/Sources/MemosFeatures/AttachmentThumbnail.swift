import MemosCore
import SwiftUI

/// One attachment in the timeline.
///
/// `AsyncImage` loads through `URLSession.shared`, and therefore through the bounded
/// `URLCache.shared` the app installs at launch. How long an entry lives is normally the server's
/// `Cache-Control` decision; what the server cannot express is that the URL's own signature
/// expires, so an entry whose signature has lapsed is evicted here before the image is requested
/// (`MediaCache.evictExpired`). A placeholder that keeps the tile's aspect ratio matters more than
/// it looks: without it the whole timeline reflows as images land.
struct AttachmentThumbnail: View {
    let attachment: MemoAttachment
    var tier: MediaTier = .thumb

    private var url: URL? { MemoPresentation.url(for: attachment, tier: tier) }

    var body: some View {
        Color.clear
            .aspectRatio(attachment.aspectRatio, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        default:
                            ProgressView()
                        }
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .task(id: url) {
                if let url { MediaCache.evictExpired(url) }
            }
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                if attachment.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                }
            }
    }
}
