import MemosCore
import SwiftUI

/// One memo, as a card.
///
/// The card is the whole target. There is no chevron and no separately-scrollable photo strip,
/// which is what made the photos dead to the touch before: a horizontal `ScrollView` inside a row
/// eats the tap, so the only way into a memo was the disclosure arrow at the far edge. The photos
/// are laid out now instead of scrolled, so anywhere on the card opens the memo.
struct MemoCard: View {
    let memo: Memo

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var avatar = DesignTokens.Metric.avatar
    @ScaledMetric(relativeTo: .body) private var stripHeight = DesignTokens.Metric.photoStrip
    @ScaledMetric(relativeTo: .body) private var soloHeight = DesignTokens.Metric.photoSolo

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            header
            if MemoPresentation.hasRenderableBody(memo.content) {
                MemoMarkdownView(content: memo.content)
                    .padding(.horizontal, DesignTokens.Space.roomy)
            }
            photos
            if !memo.tags.isEmpty {
                tags
            }
        }
        .padding(.vertical, DesignTokens.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }

    /// At an accessibility text size a row of avatar, name and pill cannot share a line without
    /// something being cut; it stacks instead. That is the whole reason this is a switch and not
    /// one `HStack`.
    @ViewBuilder
    private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
                HStack(spacing: DesignTokens.Space.snug) {
                    OwnerAvatar(owner: memo.owner, size: avatar)
                    identity
                }
                HStack(spacing: DesignTokens.Space.snug) {
                    pin
                    VisibilityPill(visibility: memo.visibility)
                }
            }
            .padding(.horizontal, DesignTokens.Space.roomy)
        } else {
            HStack(spacing: DesignTokens.Space.snug) {
                OwnerAvatar(owner: memo.owner, size: avatar)
                identity
                Spacer(minLength: DesignTokens.Space.snug)
                pin
                VisibilityPill(visibility: memo.visibility)
            }
            .padding(.horizontal, DesignTokens.Space.roomy)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MemoCardPresentation.displayName(forOwner: memo.owner))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(memo.createdAt, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var pin: some View {
        if memo.pinned {
            Image(systemName: "pin.fill")
                .font(.caption)
                .foregroundStyle(DesignTokens.accent)
                .accessibilityLabel("Pinned")
        }
    }

    @ViewBuilder
    private var photos: some View {
        let layout = MemoCardPresentation.photoLayout(for: memo.attachments.count)
        switch layout {
        case .none:
            EmptyView()
        case .solo:
            AttachmentThumbnail(attachment: memo.attachments[0], tier: .mobile)
                .frame(maxHeight: soloHeight)
                .padding(.horizontal, DesignTokens.Space.roomy)
        case .pair, .strip:
            HStack(spacing: DesignTokens.Space.snug) {
                let shown = MemoCardPresentation.tileCount(for: layout)
                ForEach(Array(memo.attachments.prefix(shown).enumerated()), id: \.element.uid) {
                    index, attachment in
                    AttachmentThumbnail(attachment: attachment, aspectRatio: 1)
                        .overlay {
                            if case .strip(let overflow) = layout, overflow > 0,
                                index == shown - 1
                            {
                                overflowBadge(overflow)
                            }
                        }
                }
            }
            .frame(maxHeight: stripHeight)
            .padding(.horizontal, DesignTokens.Space.roomy)
        }
    }

    private func overflowBadge(_ overflow: Int) -> some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.45))
            Text("+\(overflow)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.tile))
        .accessibilityLabel("\(overflow) more")
    }

    private var tags: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            ForEach(memo.tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, DesignTokens.Space.snug)
                    .padding(.vertical, DesignTokens.Space.hair)
                    .background(DesignTokens.accent.opacity(0.12), in: .capsule)
                    .foregroundStyle(DesignTokens.accent)
            }
        }
        .padding(.horizontal, DesignTokens.Space.roomy)
    }
}

/// The owner, as a letter in a circle. Decorative: the name is spelled out beside it, so a screen
/// reader that also read the initial would just be stuttering.
struct OwnerAvatar: View {
    let owner: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(DesignTokens.accent.opacity(0.16))
            .frame(width: size, height: size)
            .overlay {
                Text(MemoCardPresentation.initial(forOwner: owner))
                    .font(.caption.weight(.bold))
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(DesignTokens.accent)
            }
            .accessibilityHidden(true)
    }
}

/// Who can see this memo, said in one small capsule.
///
/// `fixedSize` is load-bearing rather than decorative: it makes the pill take the width its label
/// actually needs, at any text size, so the label can never be shortened to an ellipsis. Whatever
/// else has to give when the type gets huge, it is not the word that says whether something is
/// private. `DynamicTypeFittingTests` holds that promise to the widest label at the largest size.
struct VisibilityPill: View {
    let visibility: MemoVisibility

    var body: some View {
        Label {
            Text(visibility.label)
        } icon: {
            Image(systemName: visibility.symbolName)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DesignTokens.Space.snug)
        .padding(.vertical, DesignTokens.Space.hair)
        .background(.quaternary, in: .capsule)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Visibility: \(visibility.label)")
    }
}

/// A capture that has not reached the server yet, in the same card the finished memos use — a
/// queued memo is a memo, and a row that looks like a system notice makes it read like an error.
struct PendingCard: View {
    let row: PendingRow
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            HStack(spacing: DesignTokens.Space.tight) {
                Image(
                    systemName: row.needsAttention
                        ? "exclamationmark.circle.fill" : "clock.arrow.up"
                )
                Text(row.status)
                if row.attachmentCount > 0 {
                    Label("\(row.attachmentCount)", systemImage: "paperclip")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(
                row.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
            )
            if !row.snippet.isEmpty {
                Text(row.snippet).font(.body)
            }
            if row.needsAttention {
                Button("Try again", action: retry)
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .tint(DesignTokens.accent)
            }
        }
        .padding(DesignTokens.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(
                    row.needsAttention ? AnyShapeStyle(.orange.opacity(0.5))
                        : AnyShapeStyle(DesignTokens.accent.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: row.needsAttention ? [] : [4, 3])
                )
        }
    }
}
