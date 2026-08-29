import MemosCore
import SwiftUI

/// The sheet the corner loupe raises.
///
/// The loupe is a TARGET, not a control. On a 402×874 pt phone the trailing corner of the
/// navigation bar is about as far from a thumb as the screen gets, so the one thing it may cost is
/// a single tap; everything a search is actually made of — typing, clearing, dismissing — belongs
/// down here, where a sheet rising from the bottom puts the field and the keyboard together.
///
/// Nothing is remembered between openings. A term left over from yesterday is a filter silently
/// hiding memos, which is a worse failure than typing a word again (design note §5, Q4): the
/// screen builds a fresh `MemoSearch` each time the loupe is tapped.
struct SearchSheet: View {
    let search: MemoSearch
    /// Reads the activity heatmap into the store the empty state draws. A closure rather than a
    /// client, because this layer cannot name the API layer's types (the dependency rule) — and
    /// because it is what makes the read the SHEET's: it happens when the sheet opens, and at no
    /// other moment.
    let loadHeatmap: (HeatmapStore) async -> Void
    /// Takes the timeline to a day, and says whether the sheet goes with it.
    ///
    /// Scrubbing and picking leave the sheet UP. The heatmap is a scrubber (MEMNG-178): a sheet
    /// that put itself away on every release would be a date field nobody could correct, and the
    /// highlight a typed date moves would never be seen moving. That is narrowed rather than
    /// overturned by MEMNG-187 — what stays up is the FIELD being moved. The commit row under it
    /// is the one verb that settles the day, and settling it is what dismisses the sheet, because
    /// the anchored list and the notice naming the day are drawn underneath it.
    ///
    /// Which of the two happened is `SearchDayChoice`'s to say. The sheet does not decide which
    /// days can be chosen — `HeatmapDateJump` does — and it does not do the jumping either.
    let chose: (SearchDayChoice) -> Void
    /// Reads the account's tags into the store the chips draw. Same shape and same lifetime as
    /// `loadHeatmap`: one read, when the sheet opens.
    let loadTags: (TagStore) async -> Void
    /// Runs a query the field did not type — a tag chip — with the text the field should show.
    let runSearch: (MemoQuery, String) -> Void
    let close: () -> Void
    /// Leaves the sheet and pushes the results, which are a screen of their own over a timeline
    /// that never moved.
    let showResults: () -> Void

    @FocusState private var focused: Bool
    /// Whether the filters are open. Held here rather than inside the section because the shortcut
    /// tag row's presence depends on it, and two views that have to agree about one fact should
    /// not each keep their own copy of it.
    @State private var filtersExpanded = false

    /// The field writes through `typed`, which is where the minimum and the pause live — a
    /// two-way binding straight onto the term would put a request behind every keystroke.
    private var term: Binding<String> {
        Binding(get: { self.search.term }, set: { self.search.typed($0) })
    }

    var body: some View {
        SearchSheetColumn {
            SearchSheetHeader(close: close)
            field
            SearchOutcomeRow(outcome: search.outcome, showResults: showResults)
            // Always drawn, and NOT gated on the outcome like the two rows below it. Narrowing is
            // the one thing a person does to a search that is already running — a second tag, a
            // visibility — so the row that carries it has to survive the search it started. It
            // stays collapsed until it is opened, so a sheet nobody narrows looks as it always did.
            SearchFiltersSection(
                filters: search.filters,
                load: loadTags,
                apply: { self.search.apply($0) },
                expanded: $filtersExpanded
            )
            // Tags before the heatmap: a word is the commoner way back to a memo than a day, and
            // the chips are one line where the heatmap is a card — first is where they are still
            // on a medium detent at the larger text sizes. Whether they are drawn at all is
            // `SearchSheetTagShortcut`'s to say, so it is a decision a test can read back.
            if SearchSheetTagShortcut.shows(
                outcome: search.outcome,
                filters: search.filters,
                filtersExpanded: filtersExpanded
            ) {
                SearchSheetTags(load: loadTags, search: runSearch, showResults: showResults)
            }
            // Nothing typed yet: the way in is a date rather than a word. Once there is a term the
            // sheet is about that term, and a heatmap under it would be answering a question
            // nobody is asking any more.
            if search.outcome == .idle {
                SearchSheetHeatmap(load: loadHeatmap, chose: chose)
            }
            MonthScrubberSlot()
        }
        // Medium is what it opens at. Large is offered because the heatmap is twelve weeks of
        // squares that grow with the text size: at the accessibility sizes the card alone is
        // taller than half a phone, and a detent nobody can grow would simply cut it off.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // The sheet exists to be typed into, so it opens with the keyboard up.
        .task { focused = true }
    }

    private var field: some View {
        HStack(spacing: DesignTokens.Space.snug) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search memos", text: term)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit {
                    if search.outcome == .matched { showResults() }
                }
            if !search.term.isEmpty {
                Button {
                    search.typed("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear")
            }
        }
        .padding(DesignTokens.Space.regular)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
    }
}

/// Whether the shortcut row of tag chips is on screen at all.
///
/// Three things have to be true of it at once, and none of them is about the tags. The sheet is
/// still IDLE: once there is a term the sheet is about that term. Nothing has been narrowed yet:
/// the two rows mean opposite things about the same tags — this one's tap is a whole gesture that
/// ends on the results (MEMNG-177), the filter panel's is a choice being composed — so a search
/// that is already narrowed belongs to the panel. And the filters are CLOSED: the panel draws a row
/// of its own the moment it opens, and two rows of the same chips meaning opposite things is the
/// confusion MEMNG-214 reported. Only ever one of them is on screen.
///
/// A value rather than three conditions inline in a view body, because "only ever one of them" is
/// the assertion, and an assertion nobody can read back is a convention.
enum SearchSheetTagShortcut {
    static func shows(
        outcome: MemoSearchOutcome,
        filters: SearchFilters,
        filtersExpanded: Bool
    ) -> Bool {
        outcome == .idle && filters.isEmpty && !filtersExpanded
    }
}

/// Everything the sheet draws, in the one arrangement that cannot walk away from under a reader.
///
/// Stacked bare, the sheet's content is laid out inside whatever the detent offers, and the moment
/// it wants more room than that — the tags landing, the keyboard arriving, an accessibility text
/// size — an over-tall stack is CENTRED in what it was offered, which walks the title and the
/// field up off the top while the sheet is still growing into place. That is what MEMNG-176
/// reported: "every field moves up by itself while the sheet grows".
///
/// A scroll pinned to the top has nowhere to walk to. Content that does not fit scrolls, and
/// everything above whatever landed stays exactly where it was put. It is its own type so that is
/// measurable: `SearchSheetTests` offers it less height than it wants and reads back that it took
/// the offer rather than overflowing it.
struct SearchSheetColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.roomy) {
                content
            }
            .padding(DesignTokens.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Nothing to bounce against when it all fits, which is the ordinary case: a sheet that
        // rubber-bands under a thumb reads as a list, and this is not one.
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
    }
}

/// The sheet's title. Its own view because the header's fitting assertion measures it: the header
/// puts a flexible gap between this and the button, and a flexible gap reports back whatever width
/// it is offered rather than the width the header needs (`SearchSheetTests`).
struct SearchSheetTitle: View {
    var body: some View {
        Text("Search").font(.headline)
    }
}

/// The button that puts the sheet away. A word rather than a glyph, because it is measured beside
/// the title at accessibility text sizes and a word is what grows predictably with them.
struct SearchSheetCloseButton: View {
    let close: () -> Void

    var body: some View {
        Button("Done", action: close)
            .font(.headline)
    }
}

/// Title at one end, dismissal at the other, on one line at every text size.
struct SearchSheetHeader: View {
    let close: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Space.regular) {
            SearchSheetTitle()
            Spacer(minLength: DesignTokens.Space.regular)
            SearchSheetCloseButton(close: close)
        }
    }
}

/// What the search has to say, wherever it has got to — and, when it has something, the way in.
///
/// The copy is `MemoSearchOutcome`'s, not this view's: the results screen says the same sentences
/// about the same states, and a sentence written in two places is a sentence that drifts.
struct SearchOutcomeRow: View {
    let outcome: MemoSearchOutcome
    let showResults: () -> Void

    var body: some View {
        switch outcome {
        case .searching:
            HStack(spacing: DesignTokens.Space.snug) {
                ProgressView()
                Text(outcome.title ?? "").font(.subheadline).foregroundStyle(.secondary)
            }
        case .matched:
            Button(action: showResults) {
                HStack {
                    Text(outcome.title ?? "").font(.headline)
                    Spacer(minLength: DesignTokens.Space.snug)
                    Image(systemName: "chevron.right").font(.footnote)
                }
                .padding(DesignTokens.Space.regular)
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.rect(cornerRadius: DesignTokens.Radius.card))
            }
            .buttonStyle(.plain)
        default:
            VStack(alignment: .leading, spacing: DesignTokens.Space.tight) {
                if let title = outcome.title {
                    Text(title).font(.headline)
                }
                if let detail = outcome.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The date field with the activity heatmap under it as its scrubber — and the store behind it.
///
/// The store is OWNED here, and that is the point of the type. SwiftUI builds this view fresh for
/// every presentation of the sheet, so its `@State` is new each time and its `.task` runs each
/// time: the heatmap is read when the sheet opens, once, and never on a launch or a pull of the
/// timeline (MEMNG-126, and the refresh coupling MEMNG-166 complained about).
///
/// It takes plain closures rather than a client or a search, which is also what makes it the piece
/// a test can host: `SearchSheetTests` hosts it in a window and reads back that appearing is what
/// loads it.
struct SearchSheetHeatmap: View {
    let load: (HeatmapStore) async -> Void
    let chose: (SearchDayChoice) -> Void

    @State private var heatmap = HeatmapStore()
    @State private var lifecycle = SearchSectionLoad()

    var body: some View {
        SearchDateScrubber(
            grid: HeatmapPresentation.grid(from: heatmap.counts),
            // The grid is a window on these; the commit row and the picker's range need the whole
            // of them (`SearchDayCounts`).
            counts: heatmap.counts,
            // Whether that emptiness is an answer. `phase` below cannot say: it counts a failed
            // read as answered, and a failed read is the one case that must not claim the
            // household wrote nothing (`SearchDayCounts.loaded`).
            countsLoaded: heatmap.hasLoaded,
            chose: chose,
            phase: SearchSectionPhase.phase(
                hasLoaded: heatmap.hasLoaded,
                failed: heatmap.lastError != nil
            )
        )
        // Appearing is what reads it, and every appearance reads it — a bare `.task` runs once
        // for a view's identity and a first presentation SwiftUI re-attaches would lose the read
        // it started (`SearchSectionLoad`, MEMNG-175). The store fences duplicates.
        .onAppear { lifecycle.appeared() }
        .task(id: lifecycle.appearances) {
            guard lifecycle.appearances > 0 else { return }
            await load(heatmap)
        }
    }
}

/// Where the month scrubber goes — the year row and month row of the design note's option A,
/// between the field and what the search has to say (MEMNG-120 phase 3).
///
/// It draws nothing yet, deliberately. A visible placeholder is a control that does not work, and
/// this sheet ships before the scrubber does; the slot is here so the scrubber arrives in the
/// position the design chose for it rather than wherever the next hand finds room.
struct MonthScrubberSlot: View {
    var body: some View {
        EmptyView()
    }
}
