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

    /// What a tap on a chip amounts to — a value rather than a call, the way `HeatmapDateJump`
    /// already answers the same question for a day.
    ///
    /// It names BOTH halves because the owner's report (MEMNG-177) was that the tap did only the
    /// first: the query ran, and what it found then sat behind a second tap on "Show results". A
    /// chip is one gesture, and it ends on the results.
    enum Tap: Equatable {
        /// Not a control at all: the tag would search for nothing, or — worse — for everything.
        case none
        /// Run this query with this text in the field, and go straight to what it found.
        case searchAndShow(MemoQuery, showing: String)
    }

    static func tap(on tag: MemoTag) -> Tap {
        guard let query = query(for: tag) else { return .none }
        return .searchAndShow(query, showing: label(for: tag))
    }

    /// Carries a tap out.
    ///
    /// Its own function because "one gesture" IS the fix: spelled out at the call site it is a
    /// convention, and a convention is the thing a later edit keeps half of.
    static func act(
        on tap: Tap,
        search: (MemoQuery, String) -> Void,
        showResults: () -> Void
    ) {
        guard case .searchAndShow(let query, let text) = tap else { return }
        search(query, text)
        showResults()
    }

    /// What VoiceOver reads on a chip: what it searches for, and how much is under it.
    static func accessibilityLabel(for tag: MemoTag) -> String {
        let memos = tag.count == 1 ? "1 memo" : "\(tag.count) memos"
        return "\(label(for: tag)), \(memos)"
    }
}

/// Which of the sheet's two rows of tag chips this is.
///
/// They are twins by design and they land in the SAME place. The shortcut row sits under the
/// collapsed Filters row, where one tap runs the search and leaves for what it found (MEMNG-177);
/// the filter panel's own row is the first thing drawn when that row is opened, where a tap is one
/// of several choices being composed. The sheet swaps one for the other the instant the filters
/// open (`SearchSheetTagShortcut`), so only ever one of them is on screen.
///
/// Drawn identically, that swap is INVISIBLE — same heading, same chips, same order, in the same
/// position — so the row under "Filters" looks untouched and the controls that arrive under it read
/// as filter content opening below the tags rather than under the Filters row. That is what
/// MEMNG-214 reported. The placement was already right; what was missing was anything on screen
/// saying which row is which. So that is a value, decided once here, rather than a heading typed
/// into each of the two views.
enum SearchTagRow: CaseIterable, Sendable {
    /// Under the collapsed Filters row. A tap is a whole gesture that ends on the results.
    case shortcut
    /// Inside the panel the Filters row opens. A tap is a selection, and nothing leaves.
    case filter
}

/// What a tag row is headed, and whether it is drawn on the filter panel's own surface.
struct SearchTagRowSignature: Equatable, Sendable {
    /// The words over the chips. Different for the two rows, because the heading is the one part
    /// of a row of chips that can say what the chips are FOR.
    let heading: String
    /// Whether the row belongs to the card the Filters row opens into. The card is the other half
    /// of the answer: a bare stack under the disclosure is simply more sheet, and more sheet where
    /// a tag row already was is exactly the swap nobody can see. A surface of its own makes the
    /// panel visibly hang from the row that opened it.
    let insidePanel: Bool
}

/// How each of the two rows says which one it is.
enum SearchTagRowStyle {
    static func signature(for row: SearchTagRow) -> SearchTagRowSignature {
        switch row {
        // "Tags" is the way IN: these are the account's tags, and a tap on one goes and finds
        // what is filed under it.
        case .shortcut: SearchTagRowSignature(heading: "Tags", insidePanel: false)
        // Named for what a tap DOES here instead, which is the whole difference between the two
        // rows — and the words that stop the panel opening under a heading that has not changed.
        case .filter: SearchTagRowSignature(heading: "Filter by tag", insidePanel: true)
        }
    }
}

/// The account's most-used tags, as the search sheet's other way in — a word rather than a date.
///
/// The store is owned HERE, like the heatmap's: SwiftUI builds this view fresh for every
/// presentation of the sheet, so the read happens when the sheet opens and never on a launch or a
/// pull of the timeline.
///
/// The read is driven by APPEARING rather than by a bare `.task` — see `SearchSectionLoad` for the
/// first-presentation teardown that made a plain `.task` miss it (MEMNG-175). What it draws is
/// `TagChipRow`, which takes its chips and its phase as plain values so both the waiting row and
/// the loaded one can be measured against each other.
struct SearchSheetTags: View {
    let load: (TagStore) async -> Void
    /// Runs this query, with the text the field should then show.
    let search: (MemoQuery, String) -> Void
    /// Leaves for what the query found. A chip does not stop at running the search (MEMNG-177).
    let showResults: () -> Void

    @State private var tags = TagStore()
    @State private var lifecycle = SearchSectionLoad()

    var body: some View {
        TagChipRow(
            chips: TagChipsPresentation.chips(for: tags.tags),
            phase: SearchSectionPhase.phase(
                hasLoaded: tags.hasLoaded,
                failed: tags.lastError != nil
            ),
            search: search,
            showResults: showResults
        )
        .onAppear { lifecycle.appeared() }
        .task(id: lifecycle.appearances) {
            guard lifecycle.appearances > 0 else { return }
            await load(tags)
        }
    }
}

/// The chips themselves, and the room kept for them while they are still coming.
///
/// Its inputs are plain values so the two states can be MEASURED against each other: a row that
/// grew from nothing to a line of chips as the tags landed pushed everything under it down and the
/// sheet past its detent, which is how the fields above ended up walking up the screen
/// (MEMNG-176). Waiting, it draws the same shapes greyed, at the same height.
struct TagChipRow: View {
    let chips: [MemoTag]
    let phase: SearchSectionPhase
    let search: (MemoQuery, String) -> Void
    let showResults: () -> Void

    /// What a waiting row stands in for. The count is what makes the height right — a chip is a
    /// name beside a number, and both are drawn whatever the words are.
    static let placeholders: [MemoTag] = [
        MemoTag(name: "\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}", count: 0),
        MemoTag(name: "\u{2007}\u{2007}\u{2007}\u{2007}", count: 0),
        MemoTag(name: "\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}", count: 0),
    ]

    /// Whether the row is drawn at all. Waiting, it always is — that is the room being kept. Once
    /// the answer is in, a row with no chips is drawn as nothing rather than as a heading over an
    /// empty line, which is a section that looks broken.
    private var shows: Bool { phase == .loading || !chips.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            if shows {
                Text(SearchTagRowStyle.signature(for: .shortcut).heading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Scrolled rather than wrapped. Chips grow with the text size, and a row that
                // wrapped would push the rest of the sheet off a medium detent at exactly the
                // sizes where there is least room to lose.
                ScrollView(.horizontal) {
                    HStack(spacing: DesignTokens.Space.snug) {
                        if phase == .loading {
                            ForEach(Self.placeholders) { tag in
                                TagChip(tag: tag)
                            }
                            .redacted(reason: .placeholder)
                            .accessibilityHidden(true)
                        } else {
                            ForEach(chips) { tag in
                                chip(tag)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(phase == .loading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reserving the room stops the chips MOVING anything; this stops their arrival being
        // animated into the room, which is the same jump played slowly. Keyed on the phase, so
        // it disables nothing else that happens to be in flight at the time.
        .transaction(value: phase) { $0.disablesAnimations = true }
        .accessibilityLabel(phase == .loading ? "Loading tags" : "Tags")
    }

    /// A chip is a Button only where the query would go somewhere — the same rule the heatmap's
    /// days follow, so a tag that would search for everything is not a control at all.
    @ViewBuilder
    private func chip(_ tag: MemoTag) -> some View {
        let tap = TagChipsPresentation.tap(on: tag)
        if case .searchAndShow = tap, phase.acceptsTaps {
            Button {
                TagChipsPresentation.act(on: tap, search: search, showResults: showResults)
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
        .accessibilityHint("Searches for this tag and shows what it found")
    }
}
