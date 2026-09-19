import MemosCore
import SwiftUI

extension MemoArchiveScope {
    /// What the choice is called where a person makes it. The default says what it EXCLUDES rather
    /// than calling itself "Normal": the whole question this control answers is where the archived
    /// memos are, and an option that does not mention them answers it silently.
    public var label: String {
        switch self {
        case .active: "Not archived"
        case .including: "Include archived"
        case .only: "Archived only"
        }
    }
}

/// What the filters say they are doing, in one line.
///
/// Its own type because the line is drawn where the filters are HIDDEN — under a collapsed
/// disclosure — and that is the whole reason it exists. A filter nobody can see is a filter
/// silently hiding memos, which the design settled as the worse failure (design note §5, Q4);
/// this is what stops the sheet ever being narrowed without saying so.
enum SearchFilterSummary {
    /// Each thing that has been narrowed, in the order the controls stand. Only what has actually
    /// been chosen: the archive default is not a filter and does not appear.
    static func pieces(for filters: SearchFilters) -> [String] {
        var pieces = filters.tags.map { "#\($0)" }
        if let visibility = filters.visibility { pieces.append(visibility.label) }
        if filters.archive != .active { pieces.append(filters.archive.label) }
        return pieces
    }

    /// The line itself, or nil when nothing has been narrowed at all.
    static func text(for filters: SearchFilters) -> String? {
        let pieces = pieces(for: filters)
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
    }

    /// What VoiceOver reads on the row, which has to answer the same question the line does
    /// without the reader being able to see whether there is a line at all.
    static func accessibilityLabel(for filters: SearchFilters) -> String {
        guard let text = text(for: filters) else { return "Filters, none set" }
        return "Filters, \(text)"
    }
}

/// Which tags the filter row draws.
///
/// Not simply the top dozen. A tag that has been CHOSEN has to stay on the row whatever the counts
/// say, because the row is also how it comes off: a chosen tag pushed out of the top twelve — by
/// the counts moving, or by a household with fifty tags — would go on narrowing the list from
/// somewhere nobody can see or reach.
enum SearchFilterTags {
    static func chips(offering tags: [MemoTag], chosen: [String]) -> [MemoTag] {
        let offered = TagChipsPresentation.chips(for: tags)
        let known = Dictionary(
            tags.map({ ($0.name, $0) }),
            uniquingKeysWith: { first, _ in first }
        )
        let offeredNames = Set(offered.map(\.name))
        let missing = chosen.filter({ !offeredNames.contains($0) })
        // A chosen tag the server has not (or no longer) mentioned still draws, at the count it is
        // actually known to have: none. It is a control because it is chosen, not because of its
        // count.
        return offered + missing.map({ known[$0] ?? MemoTag(name: $0, count: 0) })
    }
}

/// The search sheet's filters: the tags, the visibility and where the archived memos are.
///
/// It is COLLAPSED when the sheet opens, and that is deliberate rather than tidy. The shortcut row
/// above it is one gesture — a tap on a tag runs the search and leaves for what it found
/// (MEMNG-177) — and a tap that leaves can never pick a second tag. So narrowing is a place of its
/// own, entered on purpose, where a chip is a SELECTION and nothing leaves until the person says
/// so. Two surfaces, two meanings, and neither one has to compromise for the other.
///
/// It owns its `TagStore` and reads it when it is first opened, not when the sheet is: a sheet
/// nobody narrows costs the tags endpoint exactly what it cost before.
struct SearchFiltersSection: View {
    let filters: SearchFilters
    /// Reads the account's tags into the store the chips draw — a closure rather than a client,
    /// because this layer cannot name the API layer's types (the dependency rule).
    let load: (TagStore) async -> Void
    /// Narrows the search to these filters. Every control here goes through it, so there is one
    /// place where a change becomes a request.
    let apply: (SearchFilters) -> Void
    /// Owned by the SHEET, not by this view: the shortcut tag row above withdraws while the
    /// filters are open, so the two rows of chips that mean opposite things are never both drawn.
    @Binding var expanded: Bool

    @State private var tags = TagStore()
    @State private var lifecycle = SearchSectionLoad()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            SearchFilterDisclosure(filters: filters, expanded: expanded) {
                expanded.toggle()
            }
            if expanded {
                panel { controls }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opening the filters is what reads the tags, and every opening reads them — the store
        // fences the duplicates, and a read tied to a view identity would be lost to the same
        // first-presentation teardown `SearchSectionLoad` exists for (MEMNG-175).
        .onChange(of: expanded) { _, now in
            if now { lifecycle.appeared() }
        }
        .task(id: lifecycle.appearances) {
            guard lifecycle.appearances > 0 else { return }
            await load(tags)
        }
    }

    /// Puts what the disclosure opened on a surface of its own — or does not. Which of the two is
    /// `SearchTagRowStyle`'s decision rather than this view's, because it is the same decision as
    /// which heading the row inside carries: both are how the opened panel says it is not the
    /// shortcut row it replaced (MEMNG-214).
    @ViewBuilder
    private func panel(@ViewBuilder _ content: () -> some View) -> some View {
        if SearchTagRowStyle.signature(for: .filter).insidePanel {
            SearchFilterPanel { content() }
        } else {
            content()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.regular) {
            FilterTagChipRow(
                chips: SearchFilterTags.chips(offering: tags.tags, chosen: filters.tags),
                chosen: filters.tags,
                phase: SearchSectionPhase.phase(
                    hasLoaded: tags.hasLoaded,
                    failed: tags.lastError != nil
                ),
                toggle: { self.apply(self.filters.toggling($0.name)) }
            )
            SearchFilterRow(title: "Visibility") {
                Picker("Visibility", selection: visibility) {
                    Text("Any").tag(MemoVisibility?.none)
                    ForEach(MemoVisibility.allCases, id: \.self) { option in
                        Text(option.label).tag(MemoVisibility?.some(option))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            SearchFilterRow(title: "Archived") {
                Picker("Archived", selection: archive) {
                    ForEach(MemoArchiveScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    /// A menu is what these two are, rather than a segmented control: four visibilities and three
    /// archive scopes each need a word, and four words across the width of a phone become stumps
    /// at the accessibility text sizes — the same reason the compose sheet's own visibility
    /// control is a menu (`VisibilityMenu`).
    private var visibility: Binding<MemoVisibility?> {
        Binding(
            get: { self.filters.visibility },
            set: { chosen in
                var next = self.filters
                next.visibility = chosen
                self.apply(next)
            }
        )
    }

    private var archive: Binding<MemoArchiveScope> {
        Binding(
            get: { self.filters.archive },
            set: { chosen in
                var next = self.filters
                next.archive = chosen
                self.apply(next)
            }
        )
    }
}

/// The card the Filters row opens into.
///
/// Its own type so that it is measurable: a surface that does not inset what it draws is not a
/// surface, and only a measurement says so (`SearchFilterControlsTests`). The tokens are the
/// sheet's own — the same card the field, the matched-outcome row and the activity panel are drawn
/// on — so the opened filters read as one more of the sheet's blocks rather than a shape of their
/// own.
struct SearchFilterPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DesignTokens.Space.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }
}

/// One filter, named at one end and chosen at the other.
struct SearchFilterRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: DesignTokens.Space.regular) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: DesignTokens.Space.snug)
            control
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The row that says whether the search has been narrowed, and opens the place where it is.
///
/// The summary is drawn WHILE COLLAPSED. That is the point of the row: the filters may be out of
/// sight, but a list that is quietly missing memos may not be.
struct SearchFilterDisclosure: View {
    let filters: SearchFilters
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: DesignTokens.Space.snug) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Filters").font(.subheadline.weight(.semibold))
                if let summary = SearchFilterSummary.text(for: filters) {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DesignTokens.Space.snug)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SearchFilterSummary.accessibilityLabel(for: filters))
        .accessibilityHint(expanded ? "Hides the filters" : "Shows the filters")
    }
}

/// The tags, as a selection.
///
/// It is the shortcut row's twin and deliberately not the same view: there a tap is a whole
/// gesture that ends on the results, and here it is one of several choices being composed. Same
/// chips, same waiting shapes, opposite meanings — which is exactly why they are two types and not
/// one with a flag.
struct FilterTagChipRow: View {
    let chips: [MemoTag]
    let chosen: [String]
    let phase: SearchSectionPhase
    let toggle: (MemoTag) -> Void

    /// Whether the row is drawn at all — the shortcut row's rule, for its reason. Waiting, it
    /// always is: that is the room being kept. Answered and empty, it draws nothing rather than a
    /// heading over a blank line, which is a section that looks broken. A CHOSEN tag is always a
    /// chip, so a narrowed search can never reach this.
    private var shows: Bool { phase == .loading || !chips.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.snug) {
            if shows {
                Text(SearchTagRowStyle.signature(for: .filter).heading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Scrolled rather than wrapped, for the reason the shortcut row is: chips grow
                // with the text size, and a row that wrapped would push the rest of the sheet off
                // a medium detent at exactly the sizes where there is least room to lose.
                ScrollView(.horizontal) {
                    HStack(spacing: DesignTokens.Space.snug) {
                        if phase == .loading {
                            ForEach(TagChipRow.placeholders) { tag in
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
        // No label on the row itself. The heading is a `Text` VoiceOver already reads, and every
        // chip under it carries its own label — a label here would make the row ONE element and
        // put the chips out of reach of the very gesture they exist for.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A tag nothing is filed under would narrow the list to nothing, so it is not a control — the
    /// same rule the shortcut row follows. Already CHOSEN it stays one, because that tap is how it
    /// comes off again.
    @ViewBuilder
    private func chip(_ tag: MemoTag) -> some View {
        let selected = chosen.contains(tag.name)
        if selected || TagChipsPresentation.query(for: tag) != nil, phase.acceptsTaps {
            Button {
                toggle(tag)
            } label: {
                FilterTagChip(tag: tag, selected: selected)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One tag, chosen or not.
///
/// The ring is drawn OVER the chip rather than replacing its background, so a chosen chip is
/// exactly the size of an unchosen one: a selection that resized the chip would shuffle every tag
/// after it along the row on every tap.
struct FilterTagChip: View {
    let tag: MemoTag
    let selected: Bool

    var body: some View {
        TagChip(tag: tag)
            .overlay {
                Capsule().strokeBorder(DesignTokens.accent, lineWidth: selected ? 2 : 0)
            }
            .accessibilityLabel(TagChipsPresentation.accessibilityLabel(for: tag))
            .accessibilityHint(hint)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The ring is a colour and a trait; neither reaches a reader who cannot see the row, so the
    /// hint has to say which way this tap goes.
    private var hint: String {
        selected ? "Stops narrowing the search to this tag" : "Narrows the search to this tag"
    }
}
