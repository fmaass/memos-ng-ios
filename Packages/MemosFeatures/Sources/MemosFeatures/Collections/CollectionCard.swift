import MemosCore
import SwiftUI

/// One card of the Collections root (MEMNG-783), as Photos draws its collections: a square cover
/// with the name inside it, at the foot over a shade, and the count at the top right as the
/// Library's glyph and a number. Nothing stands below the cover, and no date is on it — a trip's
/// dates are its own screen's.
///
/// The title takes two lines at most and ends in an ellipsis after that: the card is never wider
/// than its cover. With no cover — none chosen, none read yet, or a lookup that failed — the card
/// is the plain shaded tile, never an error.
struct CollectionCard: View {
    let cover: MemoAttachment?
    let title: String
    let count: Int
    /// A glyph at the top left, for a card that is no tag, trip or period: the Favorites heart.
    var symbol: String? = nil

    /// The cover's side, and the card's whole width.
    static let width: CGFloat = 160
    /// How far the title and the count stand in from the cover's edges.
    static let inset: CGFloat = 10
    /// How dark the shade under the title is at the cover's foot.
    static let shade = 0.62

    /// The card's identifier when its cover draws `uid`, and when it draws the plain tile.
    static func coverIdentifier(_ uid: String?) -> String {
        uid.map { "collection-card-cover-\($0)" } ?? "collection-card-no-cover"
    }

    /// The title exactly as the card places it: white, semibold, two lines at most within the
    /// cover's width less its insets, truncated at the tail.
    static func title(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(width: width - 2 * inset, alignment: .leading)
    }

    var body: some View {
        picture
            .frame(width: Self.width, height: Self.width)
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(Self.shade)],
                    startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Self.title(title).padding(Self.inset)
            }
            .overlay(alignment: .topTrailing) {
                badge.padding(Self.inset)
            }
            .overlay(alignment: .topLeading) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(Self.inset)
                }
            }
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
            .frame(width: Self.width, height: Self.width)
            .contentShape(.rect(cornerRadius: DesignTokens.Radius.card))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(bucketCountLabel(count))
            // From the very value `picture` draws, so what a test reads is what the card renders.
            .accessibilityIdentifier(Self.coverIdentifier(cover?.uid))
    }

    /// The count as the Library tab's glyph and a number, white over any picture.
    private var badge: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            Image(systemName: MainTab.library.symbol)
            Text("\(count)")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
    }

    @ViewBuilder
    private var picture: some View {
        if let cover {
            AttachmentThumbnail(
                attachment: cover,
                tier: .thumb,
                slot: AttachmentSlot(aspectRatio: 1, contentMode: .fill)
            )
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

/// One tag's card: its newest picture as the cover, looked up the first time the card appears
/// (`TagCoverStore`, one lookup per tag, joined while on the wire), its name with the `#`, and how
/// many files carry it. A tap opens the Library narrowed to it.
struct TagCard: View {
    let tag: LibraryTag
    let covers: TagCoverStore?
    /// The cover chosen for this tag (MEMNG-842), drawn over its newest picture.
    var chosen: MemoAttachment? = nil
    let access: () -> CollectionsAccess?
    let open: () -> Void

    /// What a card says for `name` — "#" included, which also tells it apart from the same tag's
    /// row on the New trip sheet over it.
    static func label(_ name: String) -> String { "#\(name)" }

    var body: some View {
        Button(action: open) {
            CollectionCard(
                cover: chosen ?? covers?.cover(for: tag.name), title: Self.label(tag.name),
                count: tag.count)
        }
        .buttonStyle(.plain)
        .task(id: tag.name) {
            guard let covers, let access = access() else { return }
            await covers.load(tag: tag.name, using: access.handle, baseURL: access.baseURL)
        }
    }
}

/// The Favorites card (MEMNG-868): a heart, "Favorites", the count of pictures carrying the
/// `favorites` picture tag, and the newest of them as the cover — the tag card's `limit: 1` read
/// under `pictureTag=` (`TagCoverStore`), its thumbnail tier like every card. A tap opens the
/// pictures carrying it.
struct FavoritesCard: View {
    let count: Int
    let covers: TagCoverStore?
    let access: () -> CollectionsAccess?
    let open: () -> Void

    /// The heart's symbol, the one the viewer's favorite button fills.
    static let symbol = "heart.fill"
    static var subject: TagCoverStore.Subject { .pictureTag(FavoriteTag.name) }

    var body: some View {
        Button(action: open) {
            CollectionCard(
                cover: covers?.cover(of: Self.subject),
                title: AutomaticCollection.favoritesTitle, count: count, symbol: Self.symbol)
        }
        .buttonStyle(.plain)
        .task {
            guard let covers, let access = access() else { return }
            await covers.load(Self.subject, using: access.handle, baseURL: access.baseURL)
        }
    }
}
