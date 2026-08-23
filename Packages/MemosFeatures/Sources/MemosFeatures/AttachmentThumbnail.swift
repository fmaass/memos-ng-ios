import MemosCore
import SwiftUI

/// One attachment in the timeline.
///
/// `AsyncImage` reads through the shared `URLCache`, which is configured so that no entry can
/// outlive the signature in its URL — see `SignedMediaURL`. A placeholder that keeps the tile's
/// aspect ratio matters more than it looks: without it the whole timeline reflows as images land.
struct AttachmentThumbnail: View {
    let attachment: MemoAttachment
    var tier: MediaTier = .thumb

    var body: some View {
        Color.clear
            .aspectRatio(attachment.aspectRatio, contentMode: .fit)
            .overlay {
                if let url = MemoPresentation.url(for: attachment, tier: tier) {
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
            .clipShape(.rect(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                if attachment.isVideo {
                    Image(systemName: "play.circle.fill")
                        .padding(6)
                        .foregroundStyle(.white)
                }
            }
    }
}
