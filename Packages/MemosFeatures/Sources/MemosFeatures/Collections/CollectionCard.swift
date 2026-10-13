import MemosCore
import SwiftUI

/// One card of the Collections root.
struct CollectionCard: View {
    let cover: MemoAttachment?
    let title: String
    let count: Int

    static let width: CGFloat = 160

    /// The card's identifier when its cover draws `uid`, and when it draws the plain tile.
    static func coverIdentifier(_ uid: String?) -> String {
        uid.map { "collection-card-cover-\($0)" } ?? "collection-card-no-cover"
    }

    /// The card's title.
    static func title(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.hair) {
            Rectangle().fill(.quaternary)
                .frame(width: Self.width, height: Self.width)
            Self.title(title)
        }
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(bucketCountLabel(count))
        .accessibilityIdentifier(Self.coverIdentifier(cover?.uid))
    }
}

/// One tag's card on the root.
struct TagCard: View {
    let tag: LibraryTag
    let covers: TagCoverStore?
    let access: () -> CollectionsAccess?
    let open: () -> Void

    var body: some View {
        TagChip(tag: tag, open: open)
    }
}
