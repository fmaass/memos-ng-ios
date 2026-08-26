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
    let close: () -> Void
    /// Leaves the sheet and pushes the results, which are a screen of their own over a timeline
    /// that never moved.
    let showResults: () -> Void

    @FocusState private var focused: Bool

    /// The field writes through `typed`, which is where the minimum and the pause live — a
    /// two-way binding straight onto the term would put a request behind every keystroke.
    private var term: Binding<String> {
        Binding(get: { self.search.term }, set: { self.search.typed($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.roomy) {
            SearchSheetHeader(close: close)
            field
            SearchOutcomeRow(outcome: search.outcome, showResults: showResults)
            MonthScrubberSlot()
            Spacer(minLength: 0)
        }
        .padding(DesignTokens.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium])
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
