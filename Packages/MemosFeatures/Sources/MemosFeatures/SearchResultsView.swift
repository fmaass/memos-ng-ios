import MemosCore
import SwiftUI

/// The results of the search the sheet ran. A route rather than a value: what is being searched
/// for lives in the screen's `MemoSearch`, and putting the term in the path would make going back
/// and searching again two different lists of the same thing.
struct SearchResultsRoute: Hashable {}

/// What the results screen is called.
///
/// The field's own text, when there is any — including the "#travel" a tag shortcut writes into it.
/// A search narrowed by FILTERS alone puts nothing in the field, though, and a screen pushed from
/// one would otherwise arrive with an empty navigation bar over a list nobody can name. So the
/// filters say what it is instead, in the same words the sheet's collapsed row uses.
enum SearchResultsTitle {
    static func text(term: String, filters: SearchFilters) -> String {
        let typed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return SearchFilterSummary.text(for: filters) ?? "Results"
    }
}

/// What the search found, as a screen of its own.
///
/// PUSHED rather than applied to the timeline. The home list is scrolled, often a long way, and
/// filtering it in place spends that position twice — once to see the result and once to get back.
/// So the results are their own list over a timeline that has not moved, built from the same cards
/// and the same day sections, off the search's own `TimelineStore`.
///
/// The live media channel patches exactly ONE store — the timeline's (`MediaChannel.consume`) —
/// and it carries no memo the stream can add or remove. A results list therefore gets no tier
/// updates at all while it is up, which is what the existing remedy is for: one
/// `MediaChannel.reconcile` when the screen appears re-reads only the attachments still showing a
/// waiting tile, and costs nothing when none is.
struct SearchResultsView: View {
    @Environment(SessionStore.self) private var session
    let search: MemoSearch
    /// The timeline's namespace, handed down rather than declared here: the full-screen viewer
    /// this screen's tiles open into belongs to the navigation stack above, and a zoom transition
    /// only matches inside one namespace.
    let mediaZoom: Namespace.ID
    let openMemo: (String) -> Void
    let openAttachment: (MemoAttachment, Memo) -> Void

    var body: some View {
        list
            .listStyle(.plain)
            .listRowSpacing(DesignTokens.Space.regular)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(SearchResultsTitle.text(term: search.term, filters: search.filters))
            .navigationBarTitleDisplayMode(.inline)
            .overlay { empty }
            .task { await reconcile() }
    }

    @ViewBuilder
    private var list: some View {
        // The flat position of each memo, so the prefetch trigger still knows how close to the end
        // of the LIST a row is once the list has been cut into days.
        let positions = Dictionary(
            uniqueKeysWithValues: search.results.memos.enumerated().map { ($1.uid, $0) }
        )
        List {
            if let error = search.results.lastError {
                NoticeCard(text: error, tone: .error).cardRow()
            }
            ForEach(TimelineGrouping.sections(for: search.results.memos)) { section in
                Section {
                    ForEach(section.memos) { memo in
                        MemoCard(
                            memo: memo,
                            mediaZoom: mediaZoom,
                            openMemo: { openMemo(memo.uid) },
                            openAttachment: { openAttachment($0, memo) }
                        )
                        .cardRow()
                        .task {
                            guard let index = positions[memo.uid],
                                search.results.shouldLoadMore(after: index)
                            else { return }
                            guard let client = session.api, let baseURL = session.serverBaseURL
                            else { return }
                            await search.results.loadMore(using: client, baseURL: baseURL)
                        }
                    }
                } header: {
                    SectionHeading(title: TimelineGrouping.title(for: section.day))
                }
            }
            if search.results.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .cardRow()
            }
        }
    }

    /// Nothing found is an answer, and it is drawn as one. The sentence about whole words is the
    /// outcome's own, so this screen and the sheet say it identically.
    @ViewBuilder
    private var empty: some View {
        if search.results.memos.isEmpty, search.outcome == .noMatches {
            ContentUnavailableView {
                Label(MemoSearchOutcome.noMatches.title ?? "", systemImage: "magnifyingglass")
            } description: {
                Text(MemoSearchOutcome.noMatches.detail ?? "")
            }
        }
    }

    private func reconcile() async {
        guard let client = session.api, let baseURL = session.serverBaseURL else { return }
        await MediaChannel.reconcile(search.results, using: client, baseURL: baseURL)
    }
}
