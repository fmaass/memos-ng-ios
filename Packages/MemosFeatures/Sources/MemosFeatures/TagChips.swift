import MemosCore
import SwiftUI

/// Which tags the search sheet offers, in what order, and what a tap on one asks for.
///
/// It is pure and separate from the row that draws it for the same reason `HeatmapDateJump` is:
/// the interesting cases are the ones a finger cannot reach — the tag that would search for
/// everything, and the thirteenth tag that must not be drawn at all.
enum TagChipsPresentation {
    /// How many chips the sheet draws. A household's tag list is unbounded and the sheet is half
    /// a phone: past a dozen a row of "the ones you use" has quietly become a list of all of them.
    static let limit = 12

    /// The chips, in the order they are drawn: most used first, ties settled by name so a row
    /// read twice from the same counts comes out the same way round both times.
    static func chips(for tags: [MemoTag], limit: Int = limit) -> [MemoTag] {
        let usable = tags.filter { query(for: $0) != nil }
        let ordered = usable.sorted {
            $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count
        }
        return Array(ordered.prefix(limit))
    }

    /// What a tap on a chip asks the server for, or nil for a chip that would ask for nothing.
    ///
    /// The nil is not defensive coding. `MemoQuery` normalises a blank tag away, so a tag of
    /// spaces becomes the EMPTY query — the plain timeline — and a "search" for it would hand back
    /// every memo the account can see as though each one carried the tag. A tag nothing is filed
    /// under is refused for the same reason an empty heatmap day is: the jump would be dead.
    static func query(for tag: MemoTag) -> MemoQuery? {
        guard tag.count > 0 else { return nil }
        let query = MemoQuery(tags: [tag.name])
        return query.isEmpty ? nil : query
    }

    /// The tag as a person writes it. The server stores and filters on the bare name; the hash is
    /// this app's way of saying which kind of thing the word is.
    static func label(for tag: MemoTag) -> String { "#\(tag.name)" }

    /// What VoiceOver reads on a chip: what it searches for, and how much is under it.
    static func accessibilityLabel(for tag: MemoTag) -> String {
        let memos = tag.count == 1 ? "1 memo" : "\(tag.count) memos"
        return "\(label(for: tag)), \(memos)"
    }
}

/// The account's most-used tags, as the search sheet's other way in — a word rather than a date.
///
/// The store is owned HERE, like the heatmap's: SwiftUI builds this view fresh for every
/// presentation of the sheet, so the read happens when the sheet opens and never on a launch or a
/// pull of the timeline. The task is on the outer stack rather than inside the `if`, because a
/// row that only read its tags once it had some would never get any.
struct SearchSheetTags: View {
    let load: (TagStore) async -> Void
    /// Runs this query, with the text the field should then show.
    let search: (MemoQuery, String) -> Void

    @State private var tags = TagStore()

    var body: some View {
        let chips = TagChipsPresentation.chips(for: tags.tags)
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            // Nothing at all rather than an empty card: a heading over no chips is a section that
            // looks broken, and a new account has no tags yet.
            if !chips.isEmpty {
                Text("Tags")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Scrolled rather than wrapped. Chips grow with the text size, and a row that
                // wrapped would push the rest of the sheet off a medium detent at exactly the
                // sizes where there is least room to lose.
                ScrollView(.horizontal) {
                    HStack(spacing: DesignTokens.Space.snug) {
                        ForEach(chips) { tag in
                            chip(tag)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await load(tags) }
    }

    /// A chip is a Button only where the query would go somewhere — the same rule the heatmap's
    /// days follow, so a tag that would search for everything is not a control at all.
    @ViewBuilder
    private func chip(_ tag: MemoTag) -> some View {
        if let query = TagChipsPresentation.query(for: tag) {
            Button {
                search(query, TagChipsPresentation.label(for: tag))
            } label: {
                TagChip(tag: tag)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One tag, as the chip a thumb hits. Its own view because the fitting suite measures it: a chip
/// that stopped growing with the text size would be a control nobody can read at the accessibility
/// sizes, and only a measurement says so.
struct TagChip: View {
    let tag: MemoTag

    var body: some View {
        HStack(spacing: DesignTokens.Space.tight) {
            Text(TagChipsPresentation.label(for: tag))
                .font(.subheadline)
            Text("\(tag.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, DesignTokens.Space.regular)
        .padding(.vertical, DesignTokens.Space.snug)
        .background(Color(.tertiarySystemFill))
        .clipShape(.capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(TagChipsPresentation.accessibilityLabel(for: tag))
        .accessibilityHint("Searches for this tag")
    }
}
