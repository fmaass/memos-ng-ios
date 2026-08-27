import Foundation
import MemosCore

/// Where the viewer's pages come from — and, for one of the two, where the NEXT ones come from.
///
/// The viewer used to be handed a snapshot and nothing else, which is right for a memo (its media
/// is all there when it opens and never grows) and wrong for the library (60 rows of a list of
/// 1,314, and swiping to the end of them was where the swiping stopped). A source rather than a
/// list is what lets one viewer serve both: the memo's is a value, the library's is the store the
/// grid behind it is reading, so the two surfaces provably page through the same rows in the same
/// order (MEMNG-189).
enum MediaViewerSource {
    /// A memo's own media. What it shows when it opens is all there will ever be.
    case fixed([MediaPage])
    /// The media library, as the grid holds it: the rows loaded so far, and the way to ask the
    /// store behind them for the next page. The request goes through a closure rather than through
    /// the store because asking the server needs the session, and the session belongs to the screen
    /// that presented this viewer, not to the viewer.
    case library(any MediaLibraryPaging, more: @MainActor () async -> Void)

    /// The pages this source can show right now.
    ///
    /// For `.library` this reads the store's rows on every evaluation, which is what makes an
    /// appended page appear under a reader already swiping: read inside a SwiftUI body, the read
    /// is an observation.
    var pages: [MediaPage] {
        switch self {
        case .fixed(let pages): pages
        case .library(let pager, _): MediaViewerPresentation.pages(for: pager.items)
        }
    }

    /// How close to the end of what is loaded a reader has to get before the next page is asked
    /// for: HALF A PAGE.
    ///
    /// Much further ahead than the grid's own dozen tiles, and deliberately. A grid shows a whole
    /// row at a time and a reader scrolls it in bursts; a viewer shows exactly one file and a swipe
    /// crosses it in a moment, so by the time the last loaded page is on screen the fetch has to
    /// have been running for a while already. Half a page is the distance at which a fast swiper
    /// never catches the end — and it is measured in the store's OWN page size, so a store built
    /// with a different one moves this with it rather than around it.
    static func lookahead(pageSize: Int) -> Int {
        max(1, pageSize / 2)
    }

    /// Whether the reader standing on page `index` should already have the next page on its way.
    ///
    /// A fixed source never wants more — there is nothing to want. Everything else is the STORE's
    /// decision, unchanged and undivided: it is the one that knows whether the list has an end,
    /// whether a request is already out, and whether there is a cursor to send. Asking it here
    /// rather than re-deriving the rule is what stops the viewer and the grid from disagreeing
    /// about when a page is due.
    func wantsMore(at index: Int) -> Bool {
        guard case .library(let pager, _) = self else { return false }
        return pager.shouldLoadMore(
            after: index,
            lookahead: Self.lookahead(pageSize: pager.pageSize)
        )
    }

    /// Asks for the next page, if one is due.
    ///
    /// Both halves are here so that no caller can perform one without the other: the guard is what
    /// makes a swipe in the middle of a loaded run cost nothing, and what makes a swipe that
    /// arrives while a page is already in flight cost nothing either.
    func loadMore(nearing index: Int) async {
        guard case .library(_, let more) = self, wantsMore(at: index) else { return }
        await more()
    }
}

/// What the viewer shows after its source has changed underneath it.
///
/// A viewer over the library is open across events the grid behind it is free to have: a page
/// arriving, a pull to refresh, a tab or a direction being changed on the screen it was opened
/// from. Only the first of those is something the reader asked this viewer for, and this is the
/// rule that tells them apart — by what the new list IS, rather than by trying to hear about each
/// event.
enum MediaViewerPager {
    /// The pages to show, given the ones already being shown and the ones the source now holds.
    ///
    /// A source that still BEGINS with what is on screen is the same list, longer: adopt it, and
    /// the reader keeps their page (the pager tracks identity, and every id it was tracking is
    /// still there, at the same offset). Anything else is a DIFFERENT list — emptied by a filter
    /// change, reversed by a sort, replaced by a refresh — and the pages open in front of somebody
    /// are not something to pull out from under them. They are kept until the viewer is dismissed,
    /// which is also the only answer that cannot leave the pager holding an index into nothing.
    static func extended(_ shown: [MediaPage], with source: [MediaPage]) -> [MediaPage] {
        guard source.count >= shown.count else { return shown }
        guard source.prefix(shown.count).map(\.id) == shown.map(\.id) else { return shown }
        return source
    }
}
