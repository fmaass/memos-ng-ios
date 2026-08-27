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

    /// Whether the server still has rows this source has not read.
    var hasMore: Bool {
        switch self {
        case .fixed: false
        case .library(let pager, _): pager.hasMore
        }
    }

    /// Whether the reader standing on the page with this id should already have the next page on
    /// its way.
    ///
    /// The page is looked up by UID in the store's OWN rows, and that is the load-bearing detail.
    /// The viewer's pages are a PROJECTION of those rows — documents are dropped, because a PDF is
    /// a black rectangle nobody can leave — so page 40 of the viewer can be row 55 of the store. A
    /// projected offset handed to `shouldLoadMore`, which measures against `items.count`, reads as
    /// further from the end than the reader actually is, by exactly the number of documents behind
    /// them; on a library with many attachments that are not pictures the next page is asked for
    /// too late or never (MEMNG-189, review round 1).
    ///
    /// A fixed source never wants more — there is nothing to want. Everything else is the STORE's
    /// decision, unchanged and undivided: it knows whether the list has an end, whether a request
    /// is already out, and whether there is a cursor to send.
    func wantsMore(atPageWithID id: String) -> Bool {
        guard case .library(let pager, _) = self else { return false }
        guard let raw = pager.items.firstIndex(where: { $0.uid == id }) else { return false }
        return pager.shouldLoadMore(
            after: raw,
            lookahead: Self.lookahead(pageSize: pager.pageSize)
        )
    }

    /// How many pages that showed this viewer NOTHING will be read through in one ask.
    ///
    /// A bound rather than "until something appears", because the tail of a library can be any
    /// length of documents and a reader who swiped once must not set a request loop running that
    /// only the end of the list can stop. Eight pages is several hundred rows — far past any real
    /// run of PDFs — and if it is not enough the next swipe asks again.
    static let maximumBlankContinuations = 8

    /// Asks for the next page, and keeps asking while the pages that come back hold nothing this
    /// viewer can show.
    ///
    /// The continuation lives HERE rather than in the view, and that is the fix rather than a
    /// tidying. A page of documents grows the store's rows and leaves the viewer's projection the
    /// same length, so nothing the view observes changes — no `onChange` fires, and the view gets
    /// no second chance to ask. Worse, by then the raw list HAS grown, so the near-end guard is no
    /// longer true and a second ask would be refused anyway. The only place that knows a page
    /// arrived and yielded nothing is the code that awaited it (MEMNG-189, review round 2).
    ///
    /// The near-end guard is deliberately checked ONCE, on entry: after the first page it has
    /// already done its job, and re-testing it is what would end the run early.
    func loadMore(nearingPageWithID id: String) async {
        guard case .library(let pager, let more) = self, wantsMore(atPageWithID: id) else { return }
        for _ in 0..<Self.maximumBlankContinuations {
            let shown = pages.count
            await more()
            // Something to look at arrived, or the server says there is nothing left to ask for.
            if pages.count > shown || !pager.hasMore { return }
        }
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
